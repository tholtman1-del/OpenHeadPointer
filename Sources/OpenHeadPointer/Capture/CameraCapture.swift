import AVFoundation

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera found."
        case .cannotAddInput: "The camera could not be opened (is another app using it?)."
        }
    }
}

/// Owns the capture session and delivers frames on `videoQueue`.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "gaze.video", qos: .userInteractive)

    /// Called on `videoQueue` for every frame, with its capture time (host clock, seconds). Work done
    /// here blocks the next frame, and late frames are dropped, so the pipeline never builds a backlog.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Every frame as a sample buffer (for the preview), before `onFrame`.
    var onSample: ((CMSampleBuffer) -> Void)?

    private let output = AVCaptureVideoDataOutput()
    /// What the camera actually ended up configured as (for the latency log).
    private(set) var activeConfiguration = ""
    private let sessionQueue = DispatchQueue(label: "gaze.session")
    private var input: AVCaptureDeviceInput?

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start(deviceID: String?, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        sessionQueue.async { [self] in
            do {
                let name = try configure(deviceID: deviceID)
                if !session.isRunning { session.startRunning() }
                reapplyFrameRate()
                completion(.success(name))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// The fastest format chosen in `configure`.
    private var chosenFormat: AVCaptureDevice.Format?

    /// Continuity Camera switches back to its 30 fps format when the session starts (the iPhone offers a
    /// 30 fps and a 60 fps variant of each resolution). So once running, the chosen fast format and its
    /// frame rate are applied again, and what the camera reports afterwards is logged.
    private func reapplyFrameRate() {
        guard let device = input?.device, let format = chosenFormat,
              (try? device.lockForConfiguration()) != nil else { return }
        let before = device.activeVideoMinFrameDuration.seconds * 1000
        if device.activeFormat != format { device.activeFormat = format }
        let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let interval = CMTime(value: 1, timescale: Int32(fps.rounded(.down)))
        device.activeVideoMinFrameDuration = interval
        device.activeVideoMaxFrameDuration = interval
        device.unlockForConfiguration()
        activeConfiguration += String(format: "; after start: %.1f ms → set again → %.1f–%.1f ms", before,
                                      device.activeVideoMinFrameDuration.seconds * 1000,
                                      device.activeVideoMaxFrameDuration.seconds * 1000)
    }

    private func configure(deviceID: String?) throws -> String {
        let devices = Self.availableDevices()
        guard let device = devices.first(where: { $0.uniqueID == deviceID })
                ?? AVCaptureDevice.default(for: .video)
                ?? devices.first
        else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if let input { session.removeInput(input) }
        let newInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(newInput) else { throw CameraError.cannotAddInput }
        session.addInput(newInput)
        input = newInput

        // Lowest latency: the camera's native 720p mode with the highest frame rate (60 fps on an iPhone,
        // 30 on the FaceTime HD camera), used directly (no scaling; 720p also measured faster than 1080p
        // and 480p), and locked there so a dim room can't make the camera slow down.
        let maxRate = { (f: AVCaptureDevice.Format) in f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        let native720 = device.formats
            .filter {
                let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                return d.width == 1280 && d.height == 720 && maxRate($0) >= 30
            }
            .max { maxRate($0) < maxRate($1) }
        chosenFormat = native720
        if let format = native720, (try? device.lockForConfiguration()) != nil {
            let fps = Int32(maxRate(format).rounded(.down))
            device.activeFormat = format
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: fps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: fps)
            device.unlockForConfiguration()
        } else {
            session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        }

        // Ask for the camera's own pixel format, so frames aren't converted on the way: bi-planar YUV,
        // "video range" on the FaceTime HD camera. Vision accepts it, and plane 0 is a grayscale image.
        let nativePixelFormat = native720.map { CMFormatDescriptionGetMediaSubType($0.formatDescription) }
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pixelFormat = output.availableVideoPixelFormatTypes.contains(nativePixelFormat)
            ? nativePixelFormat : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        activeConfiguration = String(format: "%@ [%@] %dx%d, frame interval %.1f–%.1f ms, center stage %@, exposure point %@",
                                     device.localizedName, device.deviceType.rawValue, d.width, d.height,
                                     device.activeVideoMinFrameDuration.seconds * 1000,
                                     device.activeVideoMaxFrameDuration.seconds * 1000,
                                     device.isCenterStageActive ? "active" : "off",
                                     device.isExposurePointOfInterestSupported ? "supported" : "not supported")
        return device.localizedName
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        stats.delivered(pts: pts)
        onSample?(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }

    // MARK: Frame-rate diagnostics

    let stats = FrameStats()

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        stats.dropped(reason: CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                              attachmentModeOut: nil) as? String)
    }
}
