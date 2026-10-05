import CoreMediaIO
import CoreMedia
import Foundation

/// Low-latency capture path: reads camera frames straight from CoreMediaIO, the layer under AVFoundation.
///
/// Measured on the built-in FaceTime HD camera: macOS's camera system hands a frame on ~46 ms after capture
/// either way, but AVFoundation then adds another 12–18 ms (worst 10%: 24–30 ms) before the app gets it,
/// whereas this path delivers it within ~2 ms. The stream is exclusive: AVFoundation can't use the camera
/// at the same time.
final class CMIOCapture: @unchecked Sendable {
    /// Same contract as `CameraCapture.onFrame`: pixel buffer and capture time, on `deliveryQueue`.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Every frame as a sample buffer (for the preview), on the CoreMediaIO thread.
    var onSample: ((CMSampleBuffer) -> Void)?
    var deliveryQueue: DispatchQueue?
    let stats = FrameStats()
    private(set) var description = ""
    private(set) var isRunning = false

    private var device: CMIOObjectID = 0
    private var stream: CMIOStreamID = 0
    private var queue: CMSimpleQueue?

    /// Starts streaming from the CoreMediaIO device whose UID matches `deviceUID` (AVCaptureDevice.uniqueID).
    func start(deviceUID: String, setFormat: Bool = true) -> Bool {
        stop()
        stats.reset()
        guard let dev = Self.devices().first(where: { Self.string($0, kCMIODevicePropertyDeviceUID) == deviceUID }),
              let st = Self.objects(dev, CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
                                    scope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput)).first
        else { description = "CMIO: device or stream not found"; return false }
        device = dev
        stream = st

        // Prefer a 1280×720 format, as the AVFoundation path does.
        if setFormat, let formats = Self.formatDescriptions(st),
           let f720 = formats.first(where: {
               let d = CMVideoFormatDescriptionGetDimensions($0)
               return d.width == 1280 && d.height == 720
           }) {
            var addr = Self.address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
            var value = Unmanaged.passUnretained(f720)
            _ = CMIOObjectSetPropertyData(st, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CMFormatDescription>>.size), &value)
        }

        var unmanagedQueue: Unmanaged<CMSimpleQueue>?
        let refCon = Unmanaged.passUnretained(self).toOpaque()
        let status = CMIOStreamCopyBufferQueue(st, { _, _, refCon in
            guard let refCon else { return }
            Unmanaged<CMIOCapture>.fromOpaque(refCon).takeUnretainedValue().drain()
        }, refCon, &unmanagedQueue)
        guard status == noErr, let q = unmanagedQueue?.takeRetainedValue() else {
            description = "CMIO: buffer queue failed (\(status))"
            return false
        }
        queue = q
        let started = CMIODeviceStartStream(dev, st)
        let current = Self.formatDescription(st).map { CMVideoFormatDescriptionGetDimensions($0) }
        description = "CMIO direct: \(Self.string(dev, kCMIOObjectPropertyName) ?? "?") "
            + "\(current.map { "\($0.width)x\($0.height)" } ?? "?"), start status \(started)"
        isRunning = started == noErr
        return isRunning
    }

    func stop() {
        guard isRunning else { return }
        CMIODeviceStopStream(device, stream)
        var none: Unmanaged<CMSimpleQueue>?
        _ = CMIOStreamCopyBufferQueue(stream, nil, nil, &none) // detach our buffer queue
        queue = nil
        isRunning = false
    }

    /// Called by CoreMediaIO when buffers are queued.
    private func drain() {
        guard let q = queue else { return }
        while let raw = CMSimpleQueueDequeue(q) {
            let sample = Unmanaged<CMSampleBuffer>.fromOpaque(raw).takeRetainedValue()
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            stats.delivered(pts: pts)
            onSample?(sample)
            if let deliver = onFrame {
                if let dq = deliveryQueue { dq.async { deliver(pixelBuffer, pts) } } else { deliver(pixelBuffer, pts) }
            }
        }
    }

    // MARK: CoreMediaIO property helpers

    private static func address(_ selector: CMIOObjectPropertySelector,
                                scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal))
        -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope,
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector,
                                scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal))
        -> [CMIOObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func devices() -> [CMIOObjectID] {
        objects(CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var addr = address(CMIOObjectPropertySelector(selector))
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                                        &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func formatDescriptions(_ stream: CMIOStreamID) -> [CMFormatDescription]? {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescriptions))
        var value: Unmanaged<CFArray>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size),
                                        &used, &value) == noErr, let array = value?.takeRetainedValue()
        else { return nil }
        return (array as NSArray).compactMap { $0 as! CMFormatDescription? }
    }

    private static func formatDescription(_ stream: CMIOStreamID) -> CMFormatDescription? {
        var addr = address(CMIOObjectPropertySelector(kCMIOStreamPropertyFormatDescription))
        var value: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size),
                                        &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }
}

