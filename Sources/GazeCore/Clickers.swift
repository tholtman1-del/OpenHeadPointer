import Foundation
import CoreGraphics

/// Fires a click when the gaze rests within `radius` of one spot for `dwellTime` seconds.
/// After firing it disarms until the gaze leaves the spot, so staring doesn't machine-gun clicks.
public struct DwellDetector: Sendable {
    public var dwellTime: Double
    public var radius: Double

    public private(set) var progress = 0.0
    private var anchor: CGPoint?
    private var start = 0.0
    private var armed = true

    public init(dwellTime: Double = 1.0, radius: Double = 60) {
        self.dwellTime = dwellTime
        self.radius = radius
    }

    /// Returns the click location when a dwell completes.
    public mutating func update(_ p: CGPoint, at t: Double) -> CGPoint? {
        guard let a = anchor, hypot(Double(p.x - a.x), Double(p.y - a.y)) <= radius else {
            anchor = p
            start = t
            progress = 0
            armed = true
            return nil
        }
        // Let the anchor follow the fixation's centre slowly.
        anchor = CGPoint(x: a.x + (p.x - a.x) * 0.1, y: a.y + (p.y - a.y) * 0.1)
        guard armed else { progress = 0; return nil }
        progress = min(1, (t - start) / dwellTime)
        guard progress >= 1 else { return nil }
        armed = false
        progress = 0
        return anchor
    }

    public mutating func reset() {
        anchor = nil
        progress = 0
        armed = true
    }
}

/// Detects deliberate long blinks (both eyes closed for `minDuration...maxDuration`),
/// ignoring natural blinks, which are much shorter (~0.1–0.3 s).
public struct BlinkDetector: Sendable {
    /// Eyes count as closed below this fraction of the learned open-eye openness.
    public var closedRatio: Double
    public var minDuration: Double
    public var maxDuration: Double
    /// "Closed" for longer than this can't be a blink: the open-eye level was learned wrong (e.g. from a
    /// bad frame) or conditions changed, so the current level is taken as the new open-eye level.
    public var relearnAfter = 2.0

    public private(set) var baseline: Double?
    public private(set) var eyesClosed = false
    /// Set on the frame where a blink ends (eyes reopen): how long the eyes were closed, in seconds.
    public private(set) var completedBlink: Double?
    private var closedSince: Double?

    public init(closedRatio: Double = 0.55, minDuration: Double = 0.4, maxDuration: Double = 1.5) {
        self.closedRatio = closedRatio
        self.minDuration = minDuration
        self.maxDuration = maxDuration
    }

    /// Returns true on the frame where a deliberate blink ends.
    public mutating func update(openness: Double, at t: Double) -> Bool {
        completedBlink = nil
        let closed = baseline.map { openness < $0 * closedRatio } ?? false
        if closed {
            if closedSince == nil { closedSince = t }
            if let since = closedSince, t - since > relearnAfter {
                baseline = openness
                closedSince = nil
                eyesClosed = false
                return false
            }
            eyesClosed = true
            return false
        }
        baseline = baseline.map { $0 * 0.98 + openness * 0.02 } ?? openness
        eyesClosed = false
        guard let since = closedSince else { return false }
        closedSince = nil
        let duration = t - since
        completedBlink = duration
        return duration >= minDuration && duration <= maxDuration
    }

    public mutating func reset() {
        eyesClosed = false
        closedSince = nil
    }

    /// How long the eyes have been closed so far (0 if open).
    public func closedDuration(at t: Double) -> Double {
        closedSince.map { t - $0 } ?? 0
    }
}

/// Fires once when a face gesture (e.g. mouth open) is held for `hold` seconds,
/// then waits for the gesture to end before it can fire again.
public struct HoldGesture: Sendable {
    public var hold: Double
    /// 0…1 while the gesture is held, for a progress ring.
    public private(set) var progress = 0.0
    private var since: Double?
    private var fired = false

    public init(hold: Double = 0.3) {
        self.hold = hold
    }

    public mutating func update(active: Bool, at t: Double) -> Bool {
        guard active else {
            reset()
            return false
        }
        let start = since ?? t
        since = start
        guard !fired else { progress = 0; return false }
        progress = min(1, (t - start) / hold)
        guard t - start >= hold else { return false }
        fired = true
        progress = 0
        return true
    }

    public mutating func reset() {
        since = nil
        fired = false
        progress = 0
    }
}

/// Recognizes a quick series of ordinary (short) blinks, e.g. three within 1.5 s, as a command.
/// Spontaneous blinking (~15–20 a minute) almost never packs three blinks that closely.
public struct MultiBlinkDetector: Sendable {
    public var count: Int
    public var window: Double
    /// Blinks longer than this don't count (they're deliberate long blinks, used for clicking).
    public var maxBlinkDuration: Double
    /// Shorter than this is a single-frame flicker, not a blink (real blinks last ~0.1–0.3 s): ignored.
    public var minBlinkDuration = 0.05
    private var times: [Double] = []
    /// How many blinks of the current series have been seen (for display).
    public var progress: Int { times.count }

    public init(count: Int = 3, window: Double = 1.5, maxBlinkDuration: Double = 0.4) {
        self.count = count
        self.window = window
        self.maxBlinkDuration = maxBlinkDuration
    }

    /// Feed each completed blink (its duration and end time). Returns true when the series completes.
    public mutating func blinked(duration: Double, at t: Double) -> Bool {
        guard duration >= minBlinkDuration else { return false }
        guard duration < maxBlinkDuration else {
            times.removeAll()
            return false
        }
        times = times.filter { t - $0 <= window } + [t]
        guard times.count >= count else { return false }
        times.removeAll()
        return true
    }
}
