import AppKit
import AVFoundation
import Carbon.HIToolbox
import GazeCore
import Observation

struct AppSettings: Codable, Equatable {
    var dwellClickEnabled = false
    var dwellTime = 1.0
    var dwellRadius = 60.0
    var blinkClickEnabled = false
    /// Long blink to click: how long the eyes must stay closed (seconds).
    var blinkClickTime = 0.4
    var showGazeDot = true
    var yieldToMouse = true
    var refineIris = true
    /// Seconds of gaze averaged during a fixation.
    var steadiness = 0.6
    /// Jump threshold as a multiple of measured noise.
    var stickiness = 2.5
    var cameraID: String?

    /// "face": point by moving your face (no calibration). "gaze": experimental eye tracking.
    var pointerMode = "face"
    /// Face pointer: face travel in eye-distances for the full screen width (smaller = faster).
    var headSpan = 0.5
    /// 0 = follow the whole face; higher adds extra weight on the nose, so turning counts more than shifting.
    var noseEmphasis = 0.0
    /// Blink three times quickly to put the pointer back in the screen centre.
    var tripleBlinkRecenter = true
    /// Hold the mouth open to click.
    var mouthClickEnabled = false
    /// Mouth opening (inner-lip height ÷ mouth width) that counts as "open".
    var mouthThreshold = 0.35
    /// Head pointer smoothing: 1€ filter cutoff at rest (Hz). Lower = steadier.
    var headSmoothing = 1.0
    /// Face pointer dead zone (points): movements smaller than this are ignored. 0 = off.
    var faceDeadZone = 4.0
    /// "turn": head rotation drives the pointer (sliding/leaning the face is ignored).
    /// "position": where the face is in the camera image drives it.
    var faceInput = "position"
    /// "absolute": facing straight ahead = screen centre. "relative": speed-sensitive, like mouse acceleration.
    var motion = "relative"
    /// Speed-sensitive mode: how strongly the cursor is pulled back to where this head position
    /// put it before (0 = free, drifts; 1 = nearly a fixed mapping).
    var faceConsistency = 0.8
    /// Tilt compensation: how far below the tracked point your head tilts around, in eye-distances.
    /// Tilting swings the tracked point sideways by about this × the tilt angle; that swing is removed.
    /// 0 = off. Set by "Calibrate tilt".
    var tiltPivot = 0.0
    /// Head-turn input, direct mode: degrees of head turn that sweep the full screen width.
    var turnSpan = 25.0
    /// Speed-sensitive mode: overall speed multiplier.
    var faceSpeed = 0.4

    // Target prediction
    var predictTargets = true
    /// Snap the cursor to the predicted element when its probability reaches this.
    var snapThreshold = 0.6
    var learnFromClicks = true
    /// "none" or "apple" (on-device).
    var semanticProvider = "none"
    var semanticTrust = 0.7
    var shadowEvaluate = true

    /// Minimal mode: face position + speed-sensitive pointer, with every other feature off.
    mutating func restrictToMinimal() {
        pointerMode = "face"
        faceInput = "position"
        motion = "relative"
        faceConsistency = 0
        tiltPivot = 0
        predictTargets = false
        dwellClickEnabled = false
        mouthClickEnabled = false
    }

    /// Decodes saved settings, filling any keys added since they were saved with defaults.
    static func load(_ data: Data?) -> AppSettings {
        let defaults = AppSettings()
        guard let data,
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encodedDefaults = try? JSONEncoder().encode(defaults),
              var merged = try? JSONSerialization.jsonObject(with: encodedDefaults) as? [String: Any]
        else { return defaults }
        merged.merge(saved) { _, new in new }
        if merged["pointerMode"] as? String == "head" { merged["pointerMode"] = "face" } // renamed
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData)
        else { return defaults }
        return settings
    }
}

private struct CalibrationRecord: Codable {
    var mapper: GazeMapper
    var expectedError: Double?
}

/// Central state. Camera frames arrive here (on the main actor) and flow through
/// mapping → smoothing → overlay / cursor / click logic.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    /// Minimal mode: only the face-position, speed-sensitive pointer (plus long-blink clicking, the overlay
    /// dot and debug window). Eye tracking, head turn, direct mode, target prediction, other clicking and
    /// all drift/tilt corrections are off and hidden. The code is still here; set this to false to bring the full feature set back.
    static let minimal = true

    // MARK: Live state

    var cameraName = ""
    var cameraError: String?
    var cameraRunning = false
    var faceDetected = false
    var fps = 0.0
    /// Latest sample, published at most 15×/s for display. `latestSample` is the per-frame value.
    var lastSample: GazeSample?
    @ObservationIgnored private var latestSample: GazeSample?
    @ObservationIgnored private var lastLivePublish = 0.0
    @ObservationIgnored private var debugWindowOpen = false
    var debug: DebugLandmarks?
    var accessibilityGranted = CursorController.isTrusted
    private(set) var controlEnabled = false
    var pausedForMouse = false
    var message: String?
    private(set) var calibrationSession: CalibrationSession?

    /// RMS scatter over the last second, before and after the fixation filter (points).
    var jumpRadius: Double?

    @ObservationIgnored let targets = TargetEngine()

    var mapper: GazeMapper? {
        didSet { saveCalibration() }
    }
    var expectedError: Double?

    var settings: AppSettings {
        didSet { settingsChanged(from: oldValue) }
    }


    // MARK: Pipeline

    @ObservationIgnored private let camera = CameraCapture()
    @ObservationIgnored private let cmio = CMIOCapture()
    /// Feeds the debug window's live camera view with the frames the app already receives.
    @ObservationIgnored let preview = PreviewSink()
    @ObservationIgnored private let tracker = FaceTracker()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private let calibrationWindow = CalibrationWindowController()
    @ObservationIgnored private var filter = FixationFilter()
    @ObservationIgnored private var headPointer = HeadPointer()
    @ObservationIgnored private var headFilter = PointFilter(minCutoff: 1.0, beta: 0.004)
    @ObservationIgnored private var deadZone = DeadZoneFilter()

    /// Milliseconds from the camera capturing a frame to the app acting on it (tracking + processing).
    var processingLatency: Double?
    @ObservationIgnored private var latencyAverage: Double?
    /// Where that time goes (ms): camera → app, tracking, waiting for the main thread; and how often Vision ran.
    var latencyBreakdown: (delivery: Double, tracking: Double, mainWait: Double, visionShare: Double)?
    @ObservationIgnored private var breakdownAverage: (delivery: Double, tracking: Double, mainWait: Double, visionShare: Double)?

    @ObservationIgnored private var relativePointer = RelativePointer()
    @ObservationIgnored private var lastSignal: CGPoint?
    /// Set when the relative pointer must continue from the real cursor (the mouse was used).
    @ObservationIgnored private var resyncPointer = true
    /// Set when the current head position should become "screen centre" (control turned on, recentre).
    @ObservationIgnored private var retiePointer = true
    /// Smoothed head speed in eye-distances per second (speed-sensitive mode), for the debug window.
    var headSpeed: Double?
    /// How far the cursor is from where this head position put it before (speed-sensitive mode), in points.
    var driftOffset: Double?
    @ObservationIgnored private var consistentTarget: CGPoint?
    /// Samples (tracked x, tilt, scale) while calibrating tilt compensation.
    @ObservationIgnored private var tiltSamples: [(x: Double, roll: Double, scale: Double)]?
    @ObservationIgnored private var tiltCalibrationEnd = 0.0
    var calibratingTilt: Bool { tiltCalibrationActive }
    private(set) var tiltCalibrationActive = false
    @ObservationIgnored private var trace: [String]?
    @ObservationIgnored private var traceStart = 0.0
    @ObservationIgnored private var traceDuration = 10.0
    @ObservationIgnored private var lockAverage = 1.0
    @ObservationIgnored private var residualAverage = 0.0
    @ObservationIgnored private var lastDiagnosticsPublish = 0.0
    /// Live face-tracking health for the debug window.
    var anchorLockRate: Double?
    var anchorResidual: Double?
    var leashRadius: Double?
    var snappingNow = false
    var traceStatus: String?
    @ObservationIgnored private var lastPatchTime = 0.0
    @ObservationIgnored private var mouth = HoldGesture(hold: 0.3)
    @ObservationIgnored private var tripleBlink = MultiBlinkDetector()
    /// When recent quick blinks (seen by the per-frame detector) ended.
    @ObservationIgnored private var quickBlinkTimes: [Double] = []
    /// Blink counters for the debug window.
    var blinkCount = 0
    var lastBlinkDuration: Double?
    var blinkSeries = 0
    var tripleBlinkCount = 0
    /// Quick-blink detection from eye-region brightness, every frame (face mode). Fed 1000 / brightness, so
    /// "closed" = brightness more than 1.11× its open-eye level (validated on a recorded triple-blink trace).
    @ObservationIgnored private var eyePixelBlink = BlinkDetector(closedRatio: 0.9)
    /// Mouth opening, for the menu's live meter.
    var mouthOpenness = 0.0
    @ObservationIgnored private var snappedID: String?
    @ObservationIgnored private var shownID: String?
    @ObservationIgnored private var head = HeadSmoother()
    @ObservationIgnored private var rawMeter = JitterMeter()
    @ObservationIgnored private var cursorMeter = JitterMeter()
    @ObservationIgnored private var lastJitterPublish = 0.0
    @ObservationIgnored private var dwell = DwellDetector()
    @ObservationIgnored private var blink = BlinkDetector()

    @ObservationIgnored private var lastFrameTime: Double?
    @ObservationIgnored private var fpsAverage = 0.0
    @ObservationIgnored private var lastFPSPublish = 0.0
    @ObservationIgnored private var lastFaceTime = 0.0
    @ObservationIgnored private var lastPosted: CGPoint?
    @ObservationIgnored private var mouseOverrideUntil = 0.0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var accessibilityTimer: Timer?

    private init() {
        settings = AppSettings.load(UserDefaults.standard.data(forKey: "settings"))
        if Self.minimal { settings.restrictToMinimal() }
        if let data = try? Data(contentsOf: Self.calibrationURL),
           let record = try? JSONDecoder().decode(CalibrationRecord.self, from: data) {
            mapper = record.mapper
            expectedError = record.expectedError
        }
    }

    func start() {
        guard !started else { return }
        started = true
        applySettings()

        tracker.callbackQueue = camera.videoQueue
        let onFrame: (CVPixelBuffer, Double) -> Void = { [tracker] pixelBuffer, captureTime in
            let arrived = CACurrentMediaTime()
            var frame = tracker.process(pixelBuffer, captureTime: captureTime)
            frame.captureTime = captureTime
            frame.arrivalTime = arrived
            frame.processedTime = CACurrentMediaTime()
            Task { @MainActor in AppModel.shared.handle(frame) }
        }
        camera.onFrame = onFrame
        cmio.onFrame = onFrame
        cmio.deliveryQueue = camera.videoQueue
        camera.onSample = { [preview] in preview.show($0) }
        cmio.onSample = { [preview] in preview.show($0) }
        startCamera()
        watchCameraConnections()
        registerHotKeys()
        watchUserInput()
        if !Self.minimal { targets.start() } // target prediction watches clicks and reads UI elements
        // Moving the cursor is the whole point: ask up front instead of failing silently later.
        if !CursorController.isTrusted { CursorController.requestTrust() }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                let trusted = CursorController.isTrusted
                if model.accessibilityGranted != trusted { model.accessibilityGranted = trusted }
            }
        }
    }

    // MARK: Camera

    @ObservationIgnored private var cameraObservers: [NSObjectProtocol] = []

    /// An iPhone (Continuity Camera) can come and go. If the chosen camera disconnects, fall back to the
    /// built-in one; when it reconnects, switch back to it.
    private func watchCameraConnections() {
        guard cameraObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            cameraObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let device = note.object as? AVCaptureDevice
                MainActor.assumeIsolated {
                    let model = AppModel.shared
                    // Restart only if this concerns the chosen camera or the one currently in use.
                    if device?.uniqueID == model.settings.cameraID || device?.localizedName == model.cameraName {
                        model.startCamera()
                    }
                }
            })
        }
    }

    var cameraDevices: [(id: String, name: String)] {
        CameraCapture.availableDevices().map { ($0.uniqueID, $0.localizedName) }
    }

    /// Whether frames come straight from CoreMediaIO (low latency) rather than through AVFoundation.
    private(set) var usingDirectCamera = false

    func startCamera() {
        Task {
            guard await CameraCapture.requestAccess() else {
                cameraError = "Camera access denied. Allow it in System Settings → Privacy & Security → Camera."
                cameraRunning = false
                return
            }
            camera.stop()
            cmio.stop()
            // Low-latency path first: frames straight from CoreMediaIO (~13 ms sooner than AVFoundation).
            let device = settings.cameraID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
            if let device, cmio.start(deviceUID: device.uniqueID) {
                usingDirectCamera = true
                cameraName = device.localizedName
                cameraRunning = true
                cameraError = nil
                // If it delivers nothing within 2 s, fall back to AVFoundation.
                let started = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let model = AppModel.shared
                    guard model.usingDirectCamera, model.cmio.stats.framesReceived == 0,
                          ProcessInfo.processInfo.systemUptime - started >= 2 else { return }
                    model.cmio.stop()
                    model.startAVFoundationCamera()
                }
                return
            }
            startAVFoundationCamera()
        }
    }

    private func startAVFoundationCamera() {
        usingDirectCamera = false
        camera.start(deviceID: settings.cameraID) { result in
            Task { @MainActor in
                let model = AppModel.shared
                switch result {
                case .success(let name):
                    model.cameraName = name
                    model.cameraRunning = true
                    model.cameraError = nil
                case .failure(let error):
                    model.cameraError = error.localizedDescription
                    model.cameraRunning = false
                }
            }
        }
    }

    // MARK: Frame handling

    func handle(_ frame: TrackingFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        if let captured = frame.captureTime {
            let handled = CACurrentMediaTime()
            let ms = (handled - captured) * 1000
            if ms > 0, ms < 1000 { latencyAverage = latencyAverage.map { $0 * 0.9 + ms * 0.1 } ?? ms }
            if let arrived = frame.arrivalTime, let processed = frame.processedTime {
                let b = (delivery: (arrived - captured) * 1000, tracking: (processed - arrived) * 1000,
                         mainWait: (handled - processed) * 1000, visionShare: frame.visionRan ? 1.0 : 0.0)
                breakdownAverage = breakdownAverage.map {
                    (delivery: $0.delivery * 0.9 + b.delivery * 0.1, tracking: $0.tracking * 0.9 + b.tracking * 0.1,
                     mainWait: $0.mainWait * 0.9 + b.mainWait * 0.1, visionShare: $0.visionShare * 0.9 + b.visionShare * 0.1)
                } ?? b
            }
        }
        updateFPS(now)
        // Values shown in the menu and debug window are published at most 15×/s (redrawing those windows
        // on every frame cost more CPU than the tracking itself); the landmark overlay only while the
        // debug window is open.
        let publishLive = now - lastLivePublish >= 1.0 / 15
        if publishLive {
            lastLivePublish = now
            if debugWindowOpen { updateDebug(frame.debug, now: now) }
        }

        guard let raw = frame.sample else {
            if now - lastFaceTime > 0.4 { faceLost() }
            return
        }
        lastFaceTime = now
        if !faceDetected { faceDetected = true }
        let sample = head.smooth(raw)
        latestSample = sample
        if publishLive {
            lastSample = sample
            if abs(mouthOpenness - raw.mouthOpenness) > 0.01 { mouthOpenness = raw.mouthOpenness }
        }

        // Long blinks (click) come from Vision's eye openness: slow, but a deliberate ~1 s blink is
        // unmistakable in it. Quick blinks (triple blink) come from the eye pixels, every frame: Vision's
        // eye outlines are smoothed and refreshed ~10×/s, so quick blinks merge together in them.
        let longBlink = blink.update(openness: sample.openness, at: now)
        let visionBlinkDuration = blink.completedBlink
        var completedBlink = blink.completedBlink
        if settings.pointerMode == "face", raw.eyeMean > 0 {
            // A closed eyelid (skin) is brighter than the iris and lashes: measured on the user's blinks,
            // eye-area brightness jumps from ~72 to 85–95 and stays within 70–76 while open.
            _ = eyePixelBlink.update(openness: 1000 / raw.eyeMean, at: now)
            completedBlink = eyePixelBlink.completedBlink
        }
        if let duration = completedBlink, settings.pointerMode == "face" {
            blinkCount += 1
            lastBlinkDuration = duration
            if duration >= 0.05, duration < 0.4 {
                quickBlinkTimes.append(now)
                if quickBlinkTimes.count > 10 { quickBlinkTimes.removeFirst() }
            }
            if settings.tripleBlinkRecenter, tripleBlink.blinked(duration: duration, at: now) {
                tripleBlinkCount += 1
                if controlEnabled { recenterFace() }
            }
            blinkSeries = tripleBlink.progress
        }

        if let session = calibrationSession {
            session.add(sample, eyesClosed: blink.eyesClosed)
            return
        }

        // Vision's eye openness is slow and merges a quick series of blinks (e.g. a triple blink) into what
        // looks like one long blink. If the per-frame detector saw two or more quick blinks in that time,
        // it was a series, not a deliberate long blink: don't click.
        let quickBlinksInside = quickBlinkTimes.filter { now - $0 <= (visionBlinkDuration ?? 1) + 0.3 }.count
        if longBlink, quickBlinksInside < 2, settings.blinkClickEnabled, isDriving(now), let p = lastPosted {
            click(at: p)
            dwell.reset()
        }

        if settings.mouthClickEnabled,
           mouth.update(active: raw.mouthOpenness >= settings.mouthThreshold, at: now),
           isDriving(now), let p = lastPosted {
            click(at: p)
            dwell.reset()
        }

        if settings.pointerMode == "face" {
            handleFace(raw, anchor: frame.anchor, now: now)
        } else {
            handleGaze(sample, now: now)
        }
    }

    /// Face pointer: the centre of the rigid face landmarks (nose + face sides, no eyes) drives
    /// the cursor; no calibration needed.
    private func handleFace(_ sample: GazeSample, anchor: AnchorDiagnostics?, now: Double) {
        if let a = anchor { noteAnchor(a, now: now) }
        recordTiltSample(sample, now: now)
        guard sample.eyeDistance > 0 else { return }
        // Opening the mouth tugs the face, so hold the pointer while a mouth click is building up.
        guard !(settings.mouthClickEnabled && sample.mouthOpenness >= settings.mouthThreshold * 0.6) else {
            if let p = lastPosted { drive(p, gaze: p, on: headPointer.screen, now: now, target: nil, snapped: false) }
            return
        }
        if headPointer.screen.isEmpty {
            headPointer.screen = ScreenGeometry.cgRect(of: ScreenGeometry.screenUnderMouse())
        }
        let (signal, scale) = faceSignal(sample)
        // If tracking lost its lock and restarted (usually during a fast movement), the reading jumps.
        // Absorb the jump so the pointer stays put instead of leaping.
        let restarted = settings.faceInput == "turn" ? !sample.turnValid : anchor?.locked == false
        if restarted, let last = lastSignal {
            headPointer.shiftNeutral(by: CGVector(dx: signal.x - last.x, dy: signal.y - last.y))
            relativePointer.reset()
        }
        lastSignal = signal
        let raw: CGPoint, smoothed: CGPoint, point: CGPoint
        if settings.motion == "relative" {
            relativePointer.screen = headPointer.screen
            let centre = CGPoint(x: headPointer.screen.midX, y: headPointer.screen.midY)
            if retiePointer {
                relativePointer.recentre(at: centre)   // head as it is now = screen centre
                retiePointer = false
                resyncPointer = false
            } else if resyncPointer {
                relativePointer.place(at: controlEnabled ? CursorController.location : centre)
                resyncPointer = false
            }
            // Registration is already precise and the speed curve ignores drift: no extra smoothing needed.
            raw = relativePointer.update(anchor: signal, scale: scale, at: now)
            consistentTarget = relativePointer.consistentPosition(for: signal, scale: scale)
            smoothed = raw
            point = raw
        } else {
            raw = headPointer.point(nose: signal, eyeDistance: scale)
            smoothed = headFilter.filter(raw, at: now)
            point = deadZone.filter(smoothed)
        }
        rawMeter.add(raw)
        cursorMeter.add(point)
        publishJitter(now)
        // The head pointer is precise, so targets need to be close to attract it.
        let sigma = max(12, (rawMeter.rms ?? 15) * 1.5)
        let final = pointAt(point, evidence: raw, sigma: sigma, screen: headPointer.screen, now: now)
        if trace != nil {
            let mouse = CursorController.location
            let a = anchor
            func f(_ v: CGFloat?) -> String { v.map { String(format: "%.3f", Double($0)) } ?? "" }
            trace?.append([
                String(format: "%.4f", now - traceStart),
                f(a?.landmark.x), f(a?.landmark.y), f(a?.fused.x), f(a?.fused.y),
                a.map { $0.locked ? "1" : "0" } ?? "", a?.residual.map { String(format: "%.2f", $0) } ?? "",
                f(a?.shift?.dx), f(a?.shift?.dy),
                f(raw.x), f(raw.y), f(smoothed.x), f(smoothed.y), f(point.x), f(point.y),
                f(final.point.x), f(final.point.y), final.snapped ? "1" : "0",
                String(format: "%.2f", deadZone.radius), f(mouse.x), f(mouse.y),
                String(format: "%.3f", sample.turnX), String(format: "%.3f", sample.turnY), sample.turnValid ? "1" : "0",
                f(consistentTarget?.x), f(consistentTarget?.y),
                String(format: "%.3f", sample.openness), String(format: "%.1f", sample.eyeSpread),
                String(format: "%.2f", sample.eyeStd), String(format: "%.1f", sample.eyeMean),
                eyePixelBlink.eyesClosed ? "1" : "0", String(format: "%.1f", eyePixelBlink.baseline ?? 0),
            ].joined(separator: ","))
            if now - traceStart >= traceDuration { finishTrace() }
        }
    }

    private func handleGaze(_ sample: GazeSample, now: Double) {
        guard let mapper else { return }
        // Iris position is meaningless with closed eyes, so hold the last point.
        guard !blink.eyesClosed else { return }

        let gaze = mapper.clamped(mapper.predict(sample))
        let fixated = filter.filter(gaze, at: now)
        rawMeter.add(gaze)
        cursorMeter.add(fixated)
        publishJitter(now)
        // Per-frame noise plus most of the calibration error (a bias that doesn't average out).
        let bias = 0.7 * (expectedError ?? 80)
        let sigma = (filter.noise * filter.noise + bias * bias).squareRoot()
        pointAt(fixated, evidence: gaze, sigma: sigma, screen: mapper.screenFrame, now: now)
    }

    /// Probabilistic layout: snap to the most likely element once it's likely enough.
    /// Hysteresis on both snapping and the highlight keeps them from blinking at the threshold.
    @discardableResult
    private func pointAt(_ point: CGPoint, evidence: CGPoint, sigma: Double, screen: CGRect,
                         now: Double) -> (point: CGPoint, snapped: Bool) {
        var snapped: (target: Target, probability: Double)?
        var shown: (target: Target, probability: Double)?
        if settings.predictTargets, accessibilityGranted,
           let c = targets.update(raw: evidence, filtered: point, sigma: sigma, now: now) {
            let held = c.target.id == snappedID
            if c.probability >= settings.snapThreshold || (held && c.probability >= settings.snapThreshold - 0.15) {
                snapped = c
            }
            if c.probability >= 0.35 || (c.target.id == shownID && c.probability >= 0.2) { shown = c }
        }
        snappedID = snapped?.target.id
        shownID = (snapped ?? shown)?.target.id
        if snappingNow != (snapped != nil) { snappingNow = snapped != nil }
        drive(snapped?.target.centre ?? point, gaze: point, on: screen, now: now,
              target: snapped ?? shown, snapped: snapped != nil)
        return (snapped?.target.centre ?? point, snapped != nil)
    }

    /// Keeps the last eye close-ups for half a second when Vision misses a frame,
    /// so the debug view doesn't blink.
    private func updateDebug(_ new: DebugLandmarks?, now: Double) {
        guard var d = new else {
            if now - lastFaceTime > 0.5 { debug = nil }
            return
        }
        if d.eyePatches.isEmpty, now - lastPatchTime < 0.5, let old = debug?.eyePatches {
            d.eyePatches = old
        } else if !d.eyePatches.isEmpty {
            lastPatchTime = now
        }
        debug = d
    }

    private func noteAnchor(_ a: AnchorDiagnostics, now: Double) {
        lockAverage = lockAverage * 0.97 + (a.locked ? 0.03 : 0)
        if let r = a.residual { residualAverage = residualAverage * 0.9 + r * 0.1 }
        guard now - lastDiagnosticsPublish > 0.5 else { return }
        lastDiagnosticsPublish = now
        anchorLockRate = lockAverage
        anchorResidual = residualAverage
        leashRadius = deadZone.radius
    }

    @ObservationIgnored private var latencyLog: FileHandle?
    @ObservationIgnored private var lastLatencyLog = 0.0

    /// Appends the latency breakdown to latency.log every 2 s (numbers only), so it can be analysed later.
    private func logLatency(_ now: Double) {
        guard now - lastLatencyLog >= 2, let total = latencyAverage, let b = breakdownAverage else { return }
        lastLatencyLog = now
        if latencyLog == nil {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("OpenHeadPointer", isDirectory: true)
            let url = dir.appendingPathComponent("latency.log")
            FileManager.default.createFile(atPath: url.path,
                contents: Data(("# camera reactions enabled: \(AVCaptureDevice.reactionEffectsEnabled)\n"
                                + "# camera: \(usingDirectCamera ? cmio.description : camera.activeConfiguration)\n"
                                + "time,total_ms,camera_to_app_ms,tracking_ms,main_thread_ms,vision_share,fps,control,head_speed,"
                                + "delivered_fps,dropped_fps,drop_reason,capture_interval_ms\n").utf8))
            latencyLog = try? FileHandle(forWritingTo: url)
            latencyLog?.seekToEndOfFile()
        }
        let control = !controlEnabled ? "off" : (pausedForMouse ? "paused" : "on")
        let d = usingDirectCamera ? cmio.stats.snapshot : camera.stats.snapshot
        let line = String(format: "%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.1f,%@,%.4f,%.1f,%.1f,%@,%.1f\n", now, total, b.delivery,
                          b.tracking, b.mainWait, b.visionShare, fps, control, relativePointer.speed,
                          d.delivered, d.dropped, d.dropReason.isEmpty ? "-" : d.dropReason, d.captureIntervalMs)
        latencyLog?.write(Data(line.utf8))
    }

    /// Records every stage of the face pipeline for `seconds`, as CSV (numbers only, no images).
    func startTrace(seconds: Double = 10) {
        guard trace == nil else { return }
        trace = ["t,landmark_x,landmark_y,fused_x,fused_y,locked,residual,shift_x,shift_y,"
                 + "pointer_x,pointer_y,smoothed_x,smoothed_y,leash_x,leash_y,final_x,final_y,snapped,"
                 + "leash_radius,mouse_x,mouse_y,turn_x,turn_y,turn_valid,consistent_x,consistent_y,"
                 + "vision_openness,eye_spread,eye_std,eye_mean,pixel_closed,pixel_baseline"]
        traceStart = ProcessInfo.processInfo.systemUptime
        traceDuration = seconds
        traceStatus = "Recording… hold your head still for 5 s, then move slowly."
        NSSound(named: "Tink")?.play()
    }

    private func finishTrace() {
        guard let rows = trace else { return }
        trace = nil
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenHeadPointer", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("trace-\(formatter.string(from: Date())).csv")
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            traceStatus = "Saved \(rows.count - 1) frames to \(url.path)"
        } catch {
            traceStatus = "Couldn't save trace: \(error.localizedDescription)"
        }
        NSSound(named: "Pop")?.play()
    }

    /// The pointer's input signal and its scale: head turn in degrees (scale 1), or the face
    /// position in camera pixels (scale = eye distance).
    private func faceSignal(_ s: GazeSample) -> (CGPoint, Double) {
        if settings.faceInput == "turn" { return (CGPoint(x: s.turnX, y: s.turnY), 1) }
        let k = settings.noseEmphasis
        // Tilting pivots the head around a point below the tracked one, swinging it sideways by
        // ≈ pivot distance × tilt angle. Add that swing back so tilting doesn't move the pointer.
        let tilt = settings.tiltPivot * s.eyeDistance * s.faceRoll
        return (CGPoint(x: s.faceAnchorX + k * (s.noseX - s.faceAnchorX) + tilt,
                        y: s.faceAnchorY + k * (s.noseY - s.faceAnchorY)), s.eyeDistance)
    }

    /// Records 6 s of tilting and fits how far the tracked point swings per radian of tilt.
    func startTiltCalibration() {
        guard tiltSamples == nil, settings.pointerMode == "face", settings.faceInput == "position" else { return }
        tiltSamples = []
        tiltCalibrationEnd = ProcessInfo.processInfo.systemUptime + 6
        tiltCalibrationActive = true
        applySettings()
        message = "Tilt your head toward each shoulder a few times, keeping your nose pointed at the screen…"
        NSSound(named: "Tink")?.play()
    }

    private func recordTiltSample(_ s: GazeSample, now: Double) {
        guard tiltSamples != nil else { return }
        let k = settings.noseEmphasis
        tiltSamples?.append((s.faceAnchorX + k * (s.noseX - s.faceAnchorX), s.faceRoll, s.eyeDistance))
        guard now >= tiltCalibrationEnd, let samples = tiltSamples else { return }
        tiltSamples = nil
        tiltCalibrationActive = false
        NSSound(named: "Pop")?.play()

        let n = Double(samples.count)
        let mx = samples.reduce(0) { $0 + $1.x } / n, mr = samples.reduce(0) { $0 + $1.roll } / n
        let ms = samples.reduce(0) { $0 + $1.scale } / n
        let cov = samples.reduce(0) { $0 + ($1.x - mx) * ($1.roll - mr) } / n
        let varR = samples.reduce(0) { $0 + ($1.roll - mr) * ($1.roll - mr) } / n
        let varX = samples.reduce(0) { $0 + ($1.x - mx) * ($1.x - mx) } / n
        let rollRange = (samples.map(\.roll).max() ?? 0) - (samples.map(\.roll).min() ?? 0)
        guard samples.count > 60, rollRange > 6 * .pi / 180, ms > 0, varR > 0 else {
            message = "Not enough tilt detected. Tilt further toward each shoulder (about 10°) and try again."
            applySettings()
            return
        }
        let pivot = -cov / varR / ms
        let fit = cov * cov / (varR * max(varX, 1e-9)) // R²: how much of the sideways swing tilt explains
        settings.tiltPivot = min(max(pivot, -1), 4)
        message = String(format: "Tilt compensation set: pivot %.1f eye-distances below (tilt explained %.0f%% of the swing).",
                         settings.tiltPivot, fit * 100)
    }

    /// Face mode: the current face position becomes the screen centre.
    func recenterFace() {
        guard let s = latestSample, s.eyeDistance > 0 else { return }
        headPointer.screen = ScreenGeometry.cgRect(of: ScreenGeometry.screenUnderMouse())
        relativePointer.screen = headPointer.screen
        relativePointer.recentre(at: CGPoint(x: headPointer.screen.midX, y: headPointer.screen.midY))
        let (signal, scale) = faceSignal(s)
        headPointer.recenter(nose: signal, eyeDistance: scale)
        headFilter.reset()
        deadZone.reset()
        NSSound(named: "Tink")?.play()
    }

    private func drive(_ point: CGPoint, gaze: CGPoint, on screenFrame: CGRect, now: Double,
                       target: (target: Target, probability: Double)?, snapped: Bool) {
        var progress = 0.0
        var driving = false

        if controlEnabled, accessibilityGranted {
            // Touchpad or mouse in use (seen directly by `watchUserInput`): stay out of the way.
            if settings.yieldToMouse, now - lastUserInput < 0.8 {
                mouseOverrideUntil = max(mouseOverrideUntil, lastUserInput + 0.8)
            }

            if now < mouseOverrideUntil {
                lastPosted = nil
                resyncPointer = true
                dwell.reset()
            } else {
                driving = true
                if lastPosted.map({ distance($0, point) > 0.5 }) ?? true {
                    lastPosted = point
                    lastPostTime = now
                    CursorController.move(to: point)
                }
                lastPosted = point
                if settings.dwellClickEnabled {
                    if let at = dwell.update(point, at: now) {
                        // When snapped, click the element's centre, not the drifting anchor.
                        click(at: snapped ? point : at)
                    }
                    progress = dwell.progress
                }
            }
            if pausedForMouse == driving { pausedForMouse = !driving }
        }

        if settings.mouthClickEnabled { progress = max(progress, mouth.progress) }
        if settings.showGazeDot {
            overlay.update(point: gaze, on: screenFrame, dwellProgress: progress, driving: driving,
                           target: target.map { ($0.target.frame, $0.target.label, $0.probability) },
                           snapped: snapped)
        }
    }

    private func click(at p: CGPoint) {
        targets.noteSyntheticClick(at: p)
        CursorController.click(at: p)
        lastPosted = p
    }

    private func publishJitter(_ now: Double) {
        guard now - lastJitterPublish > 0.5 else { return }
        lastJitterPublish = now
        headSpeed = settings.motion == "relative" ? relativePointer.speed : nil
        if settings.motion == "relative", let t = consistentTarget, let p = relativePointer.position {
            driftOffset = hypot(Double(t.x - p.x), Double(t.y - p.y))
        } else {
            driftOffset = nil
        }
        processingLatency = latencyAverage
        latencyBreakdown = breakdownAverage
        logLatency(now)
        jumpRadius = filter.radius
    }

    private func isDriving(_ now: Double) -> Bool {
        controlEnabled && accessibilityGranted && now >= mouseOverrideUntil
    }

    private func faceLost() {
        if faceDetected { faceDetected = false }
        calibrationSession?.noteFace(false)
        filter.reset()
        head.reset()
        rawMeter.reset()
        cursorMeter.reset()
        dwell.reset()
        blink.reset()
        targets.reset()
        headFilter.reset()
        deadZone.reset()
        relativePointer.reset()
        overlay.hide()
    }

    private func updateFPS(_ now: Double) {
        if let last = lastFrameTime, now > last {
            fpsAverage = fpsAverage == 0 ? 1 / (now - last) : fpsAverage * 0.9 + 0.1 / (now - last)
        }
        lastFrameTime = now
        if now - lastFPSPublish > 0.5 {
            fps = fpsAverage
            lastFPSPublish = now
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    // MARK: Cursor control

    func toggleControl() {
        setControl(!controlEnabled)
    }

    /// Last time the touchpad or mouse was used (system uptime). Our own posted events are ignored.
    @ObservationIgnored private var lastUserInput = -100.0
    @ObservationIgnored private var lastPostTime = -100.0
    @ObservationIgnored private var inputMonitors: [Any] = []

    /// Watches for real touchpad/mouse input, so face control pauses the moment you touch it rather than
    /// fighting it. Our own cursor events carry a tag and are ignored.
    private func watchUserInput() {
        guard inputMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let note: (NSEvent) -> Void = { event in
            guard !CursorController.isOwnEvent(event.cgEvent) else { return }
            let location = event.cgEvent?.location
            MainActor.assumeIsolated {
                let model = AppModel.shared
                let now = ProcessInfo.processInfo.systemUptime
                // Backup in case the tag gets lost: a move to exactly where we just put the cursor is ours.
                if event.type == .mouseMoved, let p = location, let posted = model.lastPosted,
                   now - model.lastPostTime < 0.1, model.distance(p, posted) < 1 { return }
                model.lastUserInput = now
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: note) {
            inputMonitors.append(global)
        }
        // Events aimed at our own windows (menu, debug window) only reach a local monitor.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { note($0); return $0 }) {
            inputMonitors.append(local)
        }
    }

    func setControl(_ on: Bool) {
        if on {
            guard settings.pointerMode == "face" || mapper != nil else {
                message = "Calibrate first (⌃⌥⌘C)."
                NSSound.beep()
                return
            }
            guard CursorController.isTrusted else {
                accessibilityGranted = false
                CursorController.requestTrust()
                message = "Allow OpenHeadPointer in Accessibility settings, then turn control on again."
                return
            }
            accessibilityGranted = true
        }
        message = nil
        if on, settings.pointerMode == "face" {
            headPointer.reset()   // direct mode: start centred on the current pose
            if Self.minimal {
                resyncPointer = true  // continue from wherever the cursor is
            } else {
                retiePointer = true   // speed-sensitive mode: current head position = screen centre
            }
        }
        controlEnabled = on
        pausedForMouse = false
        lastPosted = nil
        mouseOverrideUntil = 0
        dwell.reset()
        NSSound(named: on ? "Tink" : "Pop")?.play()
    }

    // MARK: Calibration

    func startCalibration(_ mode: CalibrationSession.Mode = .full) {
        guard calibrationSession == nil else { return }
        guard cameraRunning else {
            message = "The camera isn't running."
            return
        }
        if mode == .recenter, mapper == nil { return startCalibration(.full) }

        let screen = (mode == .recenter ? mapper.flatMap { ScreenGeometry.screen(matchingCG: $0.screenFrame) } : nil)
            ?? ScreenGeometry.screenUnderMouse()
        let session = CalibrationSession(mode: mode, screenFrame: ScreenGeometry.cgRect(of: screen))
        session.noteFace(faceDetected)
        session.onCollected = { [unowned session] samples in
            AppModel.shared.finishCalibration(session, samples: samples, screen: screen)
        }
        session.onClose = { AppModel.shared.endCalibration() }
        calibrationSession = session
        overlay.hide()
        calibrationWindow.present(session, on: screen)
    }

    private func finishCalibration(_ session: CalibrationSession, samples: [[GazeSample]],
                                   screen: NSScreen) -> (message: String, success: Bool) {
        let failure = "Couldn't track your eyes reliably.\nCheck that your face is evenly lit and fully in view, then try again."

        switch session.mode {
        case .full:
            var groups: [[CalibrationPoint]] = []
            for (i, raw) in samples.enumerated() {
                let kept = CalibrationFilter.robust(raw)
                guard kept.count >= 5 else { continue }
                let target = session.targetCG(i)
                groups.append(kept.map { CalibrationPoint(sample: $0, target: target) })
            }
            guard groups.count >= 9,
                  let fitted = GazeMapper.fit(groups.flatMap { $0 }, screenFrame: session.screenFrame)
            else { return (failure, false) }

            let error = GazeMapper.crossValidatedError(groups, screenFrame: session.screenFrame)
                ?? fitted.meanTargetError(groups)
            expectedError = error
            mapper = fitted
            resetTracking()
            return ("Calibrated. Expected accuracy is about \(describe(error, on: screen)).\n"
                    + "Press ⌃⌥⌘G to control the cursor, and ⌃⌥⌘R to recenter if it drifts.", true)

        case .recenter:
            guard var current = mapper,
                  let raw = samples.first,
                  case let kept = CalibrationFilter.robust(raw), kept.count >= 5
            else { return (failure, false) }
            let predictions = kept.map { current.predict($0) }
            let mx = predictions.reduce(0) { $0 + Double($1.x) } / Double(predictions.count)
            let my = predictions.reduce(0) { $0 + Double($1.y) } / Double(predictions.count)
            let target = session.targetCG(0)
            let shift = hypot(Double(target.x) - mx, Double(target.y) - my)
            current.offsetX += Double(target.x) - mx
            current.offsetY += Double(target.y) - my
            mapper = current
            resetTracking()
            return ("Recentered (shifted by \(Int(shift.rounded())) pt).", true)
        }
    }

    private func endCalibration() {
        calibrationWindow.close()
        calibrationSession = nil
        resetTracking()
    }

    private func resetTracking() {
        filter.reset()
        dwell.reset()
        targets.reset()
        lastPosted = nil
    }

    func clearCalibration() {
        setControl(false)
        mapper = nil
        expectedError = nil
        overlay.hide()
    }

    func describe(_ points: Double, on screen: NSScreen? = nil) -> String {
        let screen = screen ?? mapper.flatMap { ScreenGeometry.screen(matchingCG: $0.screenFrame) }
        if let screen, let perMM = ScreenGeometry.pointsPerMillimetre(screen) {
            return String(format: "%.0f pt (%.1f cm)", points, points / perMM / 10)
        }
        return String(format: "%.0f pt", points)
    }

    /// The debug window's landmark overlay and eye close-ups are only computed while it's open.
    func setDebugWindowOpen(_ open: Bool) {
        debugWindowOpen = open
        if !open { debug = nil }
        camera.videoQueue.async { [tracker] in tracker.wantsEyePatches = open }
    }

    // MARK: Settings and persistence

    private func settingsChanged(from old: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: "settings")
        }
        applySettings()
        if settings.cameraID != old.cameraID, started { startCamera() }
        if !settings.showGazeDot { overlay.hide() }
        if !settings.dwellClickEnabled { dwell.reset() }
        if settings.motion != old.motion || settings.tiltPivot != old.tiltPivot {
            retiePointer = true
            relativePointer.reset()
            headPointer.reset()
        }
        if settings.pointerMode != old.pointerMode || settings.noseEmphasis != old.noseEmphasis
            || settings.faceInput != old.faceInput {
            lastSignal = nil
            retiePointer = true
            relativePointer.reset()
            headPointer.reset()
            headFilter.reset()
            filter.reset()
            targets.reset()
            if settings.pointerMode == "gaze", mapper == nil, controlEnabled { setControl(false) }
        }
    }

    private func applySettings() {
        // Units differ by input: head turn is in degrees, face position in eye-distances.
        let turn = settings.faceInput == "turn"
        headPointer.span = turn ? settings.turnSpan : settings.headSpan
        let trackIris = settings.pointerMode == "gaze"
        let measureTurn = settings.faceInput == "turn"
        let measureTilt = settings.faceInput == "position" && (settings.tiltPivot != 0 || tiltSamples != nil)
        let full = !Self.minimal
        camera.videoQueue.async { [tracker] in
            tracker.noseOnlyAnchor = full
            tracker.antiSlip = full
            if tracker.measureTurn != measureTurn {
                tracker.measureTurn = measureTurn
                tracker.resetSmoothing()
            }
            tracker.measureTilt = measureTilt
        }
        camera.videoQueue.async { [tracker] in tracker.trackIris = trackIris }
        headFilter.configure(minCutoff: settings.headSmoothing, beta: 0.004)
        deadZone.radius = settings.faceDeadZone
        blink.minDuration = settings.blinkClickTime
        relativePointer.fastSpan = (turn ? 15 : 0.3) / max(settings.faceSpeed, 0.1)
        relativePointer.fastSpeed = turn ? 30 : 0.35
        relativePointer.consistency = settings.faceConsistency
        // ≈ 75° per eye-distance of nose movement, so 0.02 ed/s ≈ 1.5°/s.
        relativePointer.driftThreshold = 0.02 * (turn ? 75 : 1)
        filter.window = settings.steadiness
        filter.stickiness = settings.stickiness
        targets.settings = TargetSettings(
            learnFromClicks: settings.learnFromClicks,
            provider: settings.semanticProvider,
            trust: settings.semanticTrust,
            shadowEvaluate: settings.shadowEvaluate
        )
        dwell.dwellTime = settings.dwellTime
        dwell.radius = settings.dwellRadius
        let refine = settings.refineIris
        camera.videoQueue.async { [tracker] in tracker.refineIris = refine }
    }

    private static var calibrationURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenHeadPointer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("calibration.json")
    }

    private func saveCalibration() {
        guard let mapper else {
            try? FileManager.default.removeItem(at: Self.calibrationURL)
            return
        }
        let record = CalibrationRecord(mapper: mapper, expectedError: expectedError)
        if let data = try? JSONEncoder().encode(record) {
            try? data.write(to: Self.calibrationURL, options: .atomic)
        }
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let keys = HotKeys.shared
        keys.register(keyCode: kVK_ANSI_G) { AppModel.shared.toggleControl() }
        if !Self.minimal {
            keys.register(keyCode: kVK_ANSI_C) { AppModel.shared.startCalibration(.full) }
            keys.register(keyCode: kVK_ANSI_D) {
                let model = AppModel.shared
                model.settings.dwellClickEnabled.toggle()
                NSSound(named: model.settings.dwellClickEnabled ? "Tink" : "Pop")?.play()
            }
        }
        keys.register(keyCode: kVK_ANSI_R) {
            let model = AppModel.shared
            if model.settings.pointerMode == "face" {
                model.recenterFace()
            } else {
                model.startCalibration(.recenter)
            }
        }
        keys.register(keyCode: kVK_ANSI_V) { DebugWindowController.shared.show() }
        keys.register(keyCode: kVK_ANSI_T) { AppModel.shared.startTrace() }
    }
}
