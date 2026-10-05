import AVFoundation

/// Shows camera frames in the debug window by displaying the frames the app already receives,
/// so the camera isn't opened a second time (the direct camera path uses it exclusively).
final class PreviewSink: @unchecked Sendable {
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?

    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        lock.withLock { self.renderer = renderer }
    }

    /// Called from the camera thread for every frame; cheap when nothing is attached.
    func show(_ sample: CMSampleBuffer) {
        guard let renderer = lock.withLock({ self.renderer }) else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        if renderer.status == .failed { renderer.flush() }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
    }
}

/// Frames delivered per second, dropped per second and the median capture interval, measured where a
/// capture path hands frames to the app. Thread-safe.
final class FrameStats: @unchecked Sendable {
    struct Snapshot: Sendable {
        var delivered = 0.0
        var dropped = 0.0
        var dropReason = ""
        var captureIntervalMs = 0.0
    }

    private let lock = NSLock()
    private var delivered = 0, dropped = 0, lastDropReason = ""
    private var intervals: [Double] = []
    private var lastPTS: Double?
    private var windowStart = CACurrentMediaTime()
    private var latest = Snapshot()
    private(set) var total = 0

    var snapshot: Snapshot { lock.withLock { latest } }
    var framesReceived: Int { lock.withLock { total } }

    func delivered(pts: Double) {
        lock.withLock {
            delivered += 1
            total += 1
            if let last = lastPTS, pts > last { intervals.append((pts - last) * 1000) }
            lastPTS = pts
            roll()
        }
    }

    func dropped(reason: String?) {
        lock.withLock {
            dropped += 1
            if let reason { lastDropReason = reason }
            roll()
        }
    }

    func reset() {
        lock.withLock {
            delivered = 0; dropped = 0; total = 0; intervals.removeAll(); lastPTS = nil
            windowStart = CACurrentMediaTime()
        }
    }

    private func roll() {
        let now = CACurrentMediaTime()
        guard now - windowStart >= 1 else { return }
        let span = now - windowStart
        let sorted = intervals.sorted()
        latest = Snapshot(delivered: Double(delivered) / span, dropped: Double(dropped) / span,
                          dropReason: lastDropReason, captureIntervalMs: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
        delivered = 0; dropped = 0; lastDropReason = ""; intervals.removeAll(); windowStart = now
    }
}
