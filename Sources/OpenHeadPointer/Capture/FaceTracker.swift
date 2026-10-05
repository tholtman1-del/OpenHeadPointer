import CoreGraphics
import CoreVideo
import GazeCore
import Vision

/// Landmarks for the debug view, in Vision's normalized image space (origin bottom-left).
struct DebugLandmarks: Sendable {
    var imageSize: CGSize
    var faceBox: CGRect
    var eyeContours: [[CGPoint]]
    var visionPupils: [CGPoint]
    var irisCentres: [CGPoint]
    /// Close-ups of each eye, only filled while the debug window is open.
    var eyePatches: [EyePatch] = []
    /// Every face landmark, and the rigid subset whose centre drives the face pointer.
    var allPoints: [CGPoint] = []
    var anchorPoints: [CGPoint] = []
    var anchor: CGPoint?
    /// The image patches that registration tracks (normalized, Vision space): cheek band and nose.
    var anchorBox: CGRect?
    var noseBox: CGRect?
    var mouthOpenness: Double = 0
}

/// The pixels around one eye that the iris detector works on, plus what it derived from them.
/// All points are in patch pixel coordinates (top-left origin, unmirrored).
struct EyePatch: Sendable {
    var width: Int
    var height: Int
    /// Grayscale pixels after temporal denoising, row-major.
    var pixels: [UInt8]
    /// Pixels counted as iris by the dark-pixel detector.
    var irisMask: [Bool]
    var outline: [CGPoint]
    var searchArea: [CGPoint]
    var corners: [CGPoint]
    var iris: CGPoint
    var visionPupil: CGPoint?
    var threshold: UInt8?
    /// Where the patch sits in the camera image (x), to order the eyes on screen.
    var sourceX: Int
    var eyeWidth: Double
    var openness: Double
    var irisOffset: CGPoint
    var brightness: Double
    /// 90th minus 10th percentile brightness: low means a flat, washed-out or dark image.
    var contrast: Double
    /// RMS movement of the iris centre over the last second, in camera pixels.
    /// Holding still, this should be well under 1 px.
    var irisJitter: Double?
}

struct TrackingFrame: Sendable {
    var sample: GazeSample?
    var debug: DebugLandmarks?
    var anchor: AnchorDiagnostics?
    /// When the camera captured this frame, when the app received it, and when tracking finished
    /// (host clock, seconds): for the latency breakdown.
    var captureTime: Double?
    var arrivalTime: Double?
    var processedTime: Double?
    /// Whether Vision face detection ran on this frame (it's skipped on most frames when possible).
    var visionRan = true
}

/// How the face anchor was measured this frame (top-left camera pixels).
struct AnchorDiagnostics: Sendable {
    var landmark: CGPoint
    var fused: CGPoint
    /// True when image registration held its lock; false means it fell back to landmarks.
    var locked: Bool
    var residual: Double?
    var shift: CGVector?
}

/// Camera frame → face landmarks → `GazeSample`.
/// Confined to the camera's video queue, which is what makes the unchecked conformance sound.
final class FaceTracker: @unchecked Sendable {
    /// Replace Vision's coarse pupil landmark with a dark-pixel centroid.
    var refineIris = true
    /// Build `EyePatch` close-ups (debug window open).
    var wantsEyePatches = false
    /// Run the per-pixel iris detector. Off in face mode: the face pointer doesn't need it.
    var trackIris = true

    /// Per-eye state that keeps the iris signal steady while the eye is still.
    private struct EyeState {
        /// Crop window in image pixels. It moves only when the eye really moves, so the
        /// denoiser compares the same pixels frame to frame.
        var crop: (x: Int, y: Int, w: Int, h: Int)?
        /// Motion-adaptive running average of the crop's pixels.
        var denoised: [Float] = []
        /// Dark-pixel cutoff, smoothed over time.
        var threshold: Double?
        /// Recent iris centres in image pixels, for the steadiness readout.
        var history: [CGPoint] = []
    }

    private var eyes = [EyeState(), EyeState()]
    private var smoothedContours: [[CGPoint]]?
    private var lastFaceCentre: CGPoint?

    /// Nose and cheek patches tracked by keyframe image registration (see `HeadTurnTracker`).
    private var turnTracker = HeadTurnTracker()
    /// Face-position input: a square patch around the nose and face sides, at full resolution.
    private var positionTracker: AnchorTracker = {
        var t = AnchorTracker()
        t.maxSide = 200
        t.halfResolutionAbove = 1000
        // Leave out the patch's top strip (the skin just under the eyes): it moves when you blink, which
        // tugged the tracked point down ~1–1.5 px per blink. The cursor should follow the head, not the eyes.
        t.exclude = CGRect(x: -0.4, y: -0.4, width: 0.8, height: 0.2)
        return t
    }()
    /// Place the face-position patch on the nose landmarks only (otherwise nose + face sides).
    var noseOnlyAnchor = false
    /// Nudge the face-position patch back onto the face while moving, so it can't slowly slide off.
    var antiSlip = false {
        didSet { positionTracker.landmarkPull = antiSlip ? 0.1 : 0 }
    }
    /// Head-turn input needs the nose/cheek pair; face-position input needs one patch.
    var measureTurn = false
    /// Measure head tilt with the face-position patch (for tilt compensation).
    var measureTilt = false {
        didSet { if measureTilt != oldValue { positionTracker.estimateRotation = measureTilt; positionTracker.reset() } }
    }
    private var lastAnchorDiagnostics: AnchorDiagnostics?
    /// How strongly each frame pulls the fused anchor back toward the landmark anchor.
    /// Small: landmarks only correct slow drift, so their jitter barely gets through.
    private let landmarkPull: CGFloat = 0.03

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest = VNDetectFaceLandmarksRequest()

    init() {
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        landmarksRequest.constellation = .constellation76Points
    }

    // MARK: Fast path

    /// Vision (face detection + landmarks) is the slowest step, but the face-position pointer follows
    /// image registration, which is fast. So when nothing else needs fresh landmarks, Vision runs on
    /// every `visionInterval`-th frame and registration alone handles the frames in between. That cuts
    /// processing delay on those frames. Vision still runs whenever registration loses its lock.
    var visionInterval = 3
    private var framesSinceVision = 0
    private struct FastPathCache {
        var sample: GazeSample
        var debug: DebugLandmarks
        /// Landmark minus tracked position at the last Vision frame (top-left pixels).
        var landmarkOffset: CGVector
        /// Eye centres minus tracked position at the last Vision frame (top-left pixels).
        var eyeOffsets: [CGVector]
        var scale: Double
        var height: CGFloat
    }
    private var fastCache: FastPathCache?
    /// Set when tracking lost its lock and restarted from the landmarks during this frame. The
    /// position then jumps, and that jump must not be read as head movement.
    private var restartedThisFrame = false

    private var fastPathAllowed: Bool {
        !measureTurn && !trackIris && !measureTilt && !antiSlip
    }

    // MARK: Background Vision

    /// Run Vision on a background queue instead of in the frame that needs it, so no frame ever waits
    /// for it: every frame only does image registration (a few ms). The background result updates the
    /// cached landmark information, matched to the frame it was computed for.
    var asyncVision = true
    /// Where background results are delivered (the camera's video queue, which owns this tracker).
    var callbackQueue: DispatchQueue?
    private var isBackgroundDetector = false
    /// Background detector: the face box it follows between full detections (normalized, Vision space).
    private var knownFaceBox: CGRect?
    private var faceBoxOffset = CGVector.zero
    private var lastFaceDetection = -100.0
    private lazy var backgroundDetector: FaceTracker = {
        let t = FaceTracker()
        t.isBackgroundDetector = true
        t.visionInterval = 1
        t.trackIris = false // landmarks only; no eye-tracking pixel work
        return t
    }()
    private let backgroundQueue = DispatchQueue(label: "gaze.landmarks", qos: .userInitiated)
    private var backgroundBusy = false
    private var lastBackgroundRequest = -1.0
    private var backgroundMisses = 0
    /// Tracked positions by capture time, to match background results to the frame they came from.
    private var positionHistory: [(time: Double, position: CGPoint)] = []

    func process(_ pixelBuffer: CVPixelBuffer, captureTime: Double = 0) -> TrackingFrame {
        restartedThisFrame = false
        if asyncVision, !isBackgroundDetector, callbackQueue != nil, fastPathAllowed, let cache = fastCache {
            if let frame = processFast(pixelBuffer, cache) {
                recordPosition(at: captureTime)
                requestBackgroundLandmarks(pixelBuffer, captureTime: captureTime)
                return frame
            }
            // Lost lock: find the face again right now, synchronously.
        } else if fastPathAllowed, framesSinceVision + 1 < visionInterval, let cache = fastCache,
                  let frame = processFast(pixelBuffer, cache) {
            framesSinceVision += 1
            return frame
        }
        framesSinceVision = 0
        let frame = processFull(pixelBuffer)
        if !fastPathAllowed { fastCache = nil }
        recordPosition(at: captureTime)
        return frame
    }

    private func recordPosition(at time: Double) {
        guard let p = lastAnchorDiagnostics?.fused else { return }
        positionHistory.append((time, p))
        if positionHistory.count > 45 { positionHistory.removeFirst() }
    }

    /// Hands this frame to the background detector, about 10 times a second, if it's free. (Running it
    /// every frame competed with the rest of the app and was felt as lag; blinks are read from pixels instead.)
    private func requestBackgroundLandmarks(_ pixelBuffer: CVPixelBuffer, captureTime: Double) {
        guard !backgroundBusy, captureTime - lastBackgroundRequest >= 0.1, let callback = callbackQueue else { return }
        backgroundBusy = true
        lastBackgroundRequest = captureTime
        let detector = backgroundDetector
        let noseOnly = noseOnlyAnchor
        backgroundQueue.async {
            detector.noseOnlyAnchor = noseOnly
            let result = detector.process(pixelBuffer)
            callback.async { self.applyBackgroundLandmarks(result, captureTime: captureTime) }
        }
    }

    /// Updates the cached landmark information from a background Vision result.
    private func applyBackgroundLandmarks(_ result: TrackingFrame, captureTime: Double) {
        backgroundBusy = false
        guard fastPathAllowed, var cache = fastCache else { return }
        guard let sample = result.sample, let debug = result.debug, let landmark = result.anchor?.landmark else {
            // No face in that frame. Twice in a row: drop the cache so the next frame re-checks synchronously.
            backgroundMisses += 1
            if backgroundMisses >= 2 { fastCache = nil }
            return
        }
        backgroundMisses = 0
        guard let tracked = positionHistory.min(by: { abs($0.time - captureTime) < abs($1.time - captureTime) }),
              abs(tracked.time - captureTime) < 0.05
        else { return }
        let offset = CGVector(dx: landmark.x - tracked.position.x, dy: landmark.y - tracked.position.y)
        // Tracking slid well away from the face: restart from landmarks on the next frame.
        if hypot(offset.dx - cache.landmarkOffset.dx, offset.dy - cache.landmarkOffset.dy) > sample.eyeDistance * 0.35 {
            fastCache = nil
            positionTracker.reset()
            return
        }
        cache.landmarkOffset = offset
        let height = debug.imageSize.height, width = debug.imageSize.width
        cache.eyeOffsets = debug.eyeContours.compactMap { contour -> CGVector? in
            guard !contour.isEmpty else { return nil }
            let cx = contour.reduce(0) { $0 + $1.x } / CGFloat(contour.count) * width
            let cy = (1 - contour.reduce(0) { $0 + $1.y } / CGFloat(contour.count)) * height
            return CGVector(dx: cx - tracked.position.x, dy: cy - tracked.position.y)
        }
        cache.scale = sample.eyeDistance
        cache.sample = sample
        cache.debug = debug
        fastCache = cache
    }

    /// Registration only, reusing the last Vision frame's landmarks and measurements.
    private func processFast(_ pixelBuffer: CVPixelBuffer, _ c: FastPathCache) -> TrackingFrame? {
        guard let last = lastAnchorDiagnostics?.fused else { return nil }
        let landmark = CGPoint(x: last.x + c.landmarkOffset.dx, y: last.y + c.landmarkOffset.dy)
        var out: AnchorTracker.Output?
        var eyes = (spread: 0.0, std: 0.0, mean: 0.0)
        withLuma(pixelBuffer) { image in
            guard let image else { return }
            let o = positionTracker.update(landmark: landmark, scale: c.scale, image: image)
            out = o
            if o.locked {
                let centres = c.eyeOffsets.map { CGPoint(x: o.position.x + $0.dx, y: o.position.y + $0.dy) }
                eyes = measureEyes(image, centres: centres, scale: c.scale)
            }
        }
        guard let o = out, o.locked else { // lost lock: let Vision re-find the face
            restartedThisFrame = true
            return nil
        }
        let anchor = CGPoint(x: o.position.x, y: c.height - o.position.y) // Vision space
        var sample = c.sample
        sample.faceAnchorX = Double(anchor.x)
        sample.faceAnchorY = Double(anchor.y)
        (sample.eyeSpread, sample.eyeStd, sample.eyeMean) = eyes
        var debug = c.debug
        let size = debug.imageSize
        debug.anchor = CGPoint(x: anchor.x / size.width, y: anchor.y / size.height)
        debug.anchorBox = visionRect(positionTracker, at: o.position, scale: c.scale, size: size)
        lastAnchorDiagnostics = AnchorDiagnostics(landmark: landmark, fused: o.position, locked: true,
                                                  residual: o.residual, shift: o.displacement)
        return TrackingFrame(sample: sample, debug: debug, anchor: lastAnchorDiagnostics, visionRan: false)
    }

    /// Brightness statistics of both eye regions (0.45 × 0.22 eye-distances around each eye centre),
    /// sampling every other pixel: well under a millisecond. Averaged over both eyes.
    private func measureEyes(_ image: GrayImage, centres: [CGPoint], scale: Double) -> (spread: Double, std: Double, mean: Double) {
        let w = max(Int(scale * 0.45), 8), h = max(Int(scale * 0.22), 4)
        var spread = 0.0, std = 0.0, mean = 0.0, n = 0
        for c in centres {
            var values: [Int] = []
            for y in stride(from: Int(c.y) - h / 2, to: Int(c.y) + h / 2, by: 2) where y >= 0 && y < image.height {
                for x in stride(from: Int(c.x) - w / 2, to: Int(c.x) + w / 2, by: 2) where x >= 0 && x < image.width {
                    values.append(Int(image.pixel(x, y)))
                }
            }
            guard values.count >= 20 else { continue }
            values.sort()
            let m = Double(values.reduce(0, +)) / Double(values.count)
            spread += Double(values[values.count * 9 / 10] - values[values.count / 10])
            std += (values.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(values.count)).squareRoot()
            mean += m
            n += 1
        }
        guard n > 0 else { return (0, 0, 0) }
        return (spread / Double(n), std / Double(n), mean / Double(n))
    }

    // MARK: Full path

    private func processFull(_ pixelBuffer: CVPixelBuffer) -> TrackingFrame {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // Finding the face in the whole frame is the most expensive Vision step (~2/3 of its time). The
        // background detector already knows where the face is from its previous result, so it reuses that
        // box (following the landmarks) and runs the full face detector only about once a second, or
        // whenever the landmarks fail. Face rectangles (revision 3) also carry yaw/pitch/roll.
        let now = ProcessInfo.processInfo.systemUptime
        let face: VNFaceObservation
        var detectedNow = false
        if isBackgroundDetector, let box = knownFaceBox, now - lastFaceDetection < 1 {
            face = VNFaceObservation(boundingBox: box)
        } else {
            guard (try? handler.perform([faceRequest])) != nil,
                  let detected = faceRequest.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) })
            else {
                knownFaceBox = nil
                resetSmoothing()
                return TrackingFrame()
            }
            face = detected
            detectedNow = true
            lastFaceDetection = now
            knownFaceBox = detected.boundingBox
        }

        landmarksRequest.inputFaceObservations = [face]
        guard (try? handler.perform([landmarksRequest])) != nil,
              let observation = landmarksRequest.results?.first,
              let landmarks = observation.landmarks,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye
        else {
            knownFaceBox = nil // lost it: detect properly next time
            return TrackingFrame()
        }

        // Keep following the face: same box size, re-centred on where the landmarks are now.
        if isBackgroundDetector, let points = landmarks.allPoints?.pointsInImage(imageSize: size), !points.isEmpty,
           let box = knownFaceBox {
            let c = centroid(points)
            let centre = CGPoint(x: c.x / size.width, y: c.y / size.height)
            if detectedNow { faceBoxOffset = CGVector(dx: box.midX - centre.x, dy: box.midY - centre.y) }
            knownFaceBox = CGRect(x: centre.x + faceBoxOffset.dx - box.width / 2,
                                  y: centre.y + faceBoxOffset.dy - box.height / 2,
                                  width: box.width, height: box.height)
        }

        // Pixel coordinates, origin bottom-left.
        let contours = smooth([leftEye.pointsInImage(imageSize: size), rightEye.pointsInImage(imageSize: size)],
                              faceBox: face.boundingBox)
        let pupils = [landmarks.leftPupil, landmarks.rightPupil].map { region in
            region?.pointsInImage(imageSize: size).first
        }

        let flip = CGFloat(height)
        func flipped(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: flip - p.y) } // bottom-left ⇄ top-left

        var irises: [CGPoint] = []
        var patches: [EyePatch?] = []
        if !trackIris {
            irises = (0..<2).map { pupils[$0] ?? centroid(contours[$0]) }
            patches = [nil, nil]
        } else { withLuma(pixelBuffer) { image in
            for i in 0..<2 {
                let fallback = pupils[i] ?? centroid(contours[i])
                guard let image else {
                    irises.append(fallback)
                    patches.append(nil)
                    continue
                }
                let result = processEye(i, image: image, outline: contours[i].map(flipped),
                                        pupil: pupils[i].map(flipped))
                irises.append(result.iris.map(flipped) ?? fallback)
                patches.append(result.patch)
            }
        } }

        guard let left = EyeGeometry.measure(contour: contours[0], iris: irises[0]),
              let right = EyeGeometry.measure(contour: contours[1], iris: irises[1])
        else { return TrackingFrame() }

        let eye = EyeGeometry.combine(left, right)
        let box = face.boundingBox
        let noseTip = landmarks.nose?.pointsInImage(imageSize: size) ?? []
        let nosePoints = noseTip + (landmarks.noseCrest?.pointsInImage(imageSize: size) ?? [])
        let nose = nosePoints.isEmpty ? CGPoint.zero : centroid(nosePoints)
        let noseCentre = noseTip.isEmpty ? nose : centroid(noseTip)
        let eyeCentres = contours.map(centroid)
        let eyeDistance = Double(hypot(eyeCentres[0].x - eyeCentres[1].x, eyeCentres[0].y - eyeCentres[1].y))

        // Landmarks that stay put when you look around, blink, talk or make expressions: the nose, and
        // (unless `noseOnlyAnchor`) the sides of the face outline above the mouth. The outline points
        // aren't symmetric, so nose-only centres the anchor on the nose.
        let lipsTop = landmarks.outerLips?.pointsInImage(imageSize: size).map(\.y).max() ?? nose.y
        let faceSides = (landmarks.faceContour?.pointsInImage(imageSize: size) ?? []).filter { $0.y > lipsTop }
        let positionPoints = noseOnlyAnchor ? nosePoints : nosePoints + faceSides

        // Sub-pixel image registration. Vision's landmarks only place the patches and catch tracking if it slips.
        //  - Face position: one patch around the nose and face sides.
        //  - Head turn: nose patch vs cheek band (parallax); see `HeadTurnTracker`.
        var turn: HeadTurnTracker.Output?
        var position: AnchorTracker.Output?
        withLuma(pixelBuffer) { image in
            guard let image, eyeDistance > 0 else { return }
            if measureTurn {
                turn = turnTracker.update(noseLandmark: flipped(noseCentre), scale: eyeDistance, image: image)
            } else if !isBackgroundDetector { // the camera path already tracks the patch; no need to repeat it
                position = positionTracker.update(landmark: flipped(centroid(positionPoints)), scale: eyeDistance,
                                                  image: image)
            }
        }
        let anchor = turn.map { flipped($0.face.position) } ?? position.map { flipped($0.position) } ?? nose
        let landmarkAnchor = measureTurn ? flipped(noseCentre) : flipped(centroid(positionPoints))
        lastAnchorDiagnostics = turn.map {
            AnchorDiagnostics(landmark: landmarkAnchor, fused: $0.face.position, locked: $0.valid,
                              residual: $0.face.residual, shift: $0.face.displacement)
        } ?? position.map {
            AnchorDiagnostics(landmark: landmarkAnchor, fused: $0.position, locked: $0.locked && !restartedThisFrame,
                              residual: $0.residual, shift: $0.displacement)
        } ?? (isBackgroundDetector
              ? AnchorDiagnostics(landmark: landmarkAnchor, fused: landmarkAnchor, locked: true, residual: nil, shift: nil)
              : nil)
        let lips = landmarks.innerLips?.pointsInImage(imageSize: size) ?? []
        let mouthWidth = EyeGeometry.frame(landmarks.outerLips?.pointsInImage(imageSize: size) ?? [])?.width ?? 0
        let mouthOpenness = mouthWidth > 0 ? (EyeGeometry.frame(lips)?.height ?? 0) / mouthWidth : 0
        let sample = GazeSample(
            eyeX: eye.x, eyeY: eye.y,
            yaw: (face.yaw ?? observation.yaw)?.doubleValue ?? 0,
            pitch: (face.pitch ?? observation.pitch)?.doubleValue ?? 0,
            roll: (face.roll ?? observation.roll)?.doubleValue ?? 0,
            faceX: box.midX, faceY: box.midY, faceSize: box.width,
            leftOpenness: left.openness, rightOpenness: right.openness,
            noseX: Double(nose.x), noseY: Double(nose.y), eyeDistance: eyeDistance
        )
        var sampleOut = sample
        sampleOut.faceAnchorX = Double(anchor.x)
        sampleOut.faceAnchorY = Double(anchor.y)
        sampleOut.mouthOpenness = mouthOpenness
        if let p = position {
            sampleOut.faceRoll = -p.rotation // image rotation is clockwise-positive (y down)
        }
        if let t = turn {
            sampleOut.turnX = Double(t.turn.dx)
            sampleOut.turnY = -Double(t.turn.dy)
            sampleOut.turnValid = t.valid
        }

        for (i, m) in [left, right].enumerated() {
            patches[i]?.eyeWidth = m.width
            patches[i]?.openness = m.openness
            patches[i]?.irisOffset = CGPoint(x: m.irisOffsetX, y: m.irisOffsetY)
        }

        func normalized(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
        let debug = DebugLandmarks(
            imageSize: size,
            faceBox: box,
            eyeContours: contours.map { $0.map(normalized) },
            visionPupils: pupils.compactMap { $0.map(normalized) },
            irisCentres: irises.map(normalized),
            eyePatches: patches.compactMap { $0 },
            allPoints: (landmarks.allPoints?.pointsInImage(imageSize: size) ?? []).map(normalized),
            anchorPoints: (measureTurn ? nosePoints : positionPoints).map(normalized),
            anchor: normalized(anchor),
            anchorBox: turn.map { visionRect(turnTracker.face, at: $0.face.position, scale: eyeDistance, size: size) }
                ?? position.map { visionRect(positionTracker, at: $0.position, scale: eyeDistance, size: size) },
            noseBox: turn.map { visionRect(turnTracker.nose, at: $0.nose.position, scale: eyeDistance, size: size) },
            mouthOpenness: mouthOpenness
        )
        if let p = position, p.locked {
            let eyeCentres = contours.map { flipped(centroid($0)) }
            withLuma(pixelBuffer) { image in
                if let image { (sampleOut.eyeSpread, sampleOut.eyeStd, sampleOut.eyeMean) =
                    measureEyes(image, centres: eyeCentres, scale: eyeDistance) }
            }
            fastCache = FastPathCache(
                sample: sampleOut, debug: debug,
                landmarkOffset: CGVector(dx: landmarkAnchor.x - p.position.x, dy: landmarkAnchor.y - p.position.y),
                eyeOffsets: eyeCentres.map { CGVector(dx: $0.x - p.position.x, dy: $0.y - p.position.y) },
                scale: eyeDistance, height: size.height)
        } else {
            fastCache = nil
        }
        return TrackingFrame(sample: sampleOut, debug: debug, anchor: lastAnchorDiagnostics)
    }

    // MARK: Per-eye processing

    /// Crops, denoises and locates the iris for one eye. Points are top-left image pixels.
    private func processEye(_ index: Int, image: GrayImage, outline: [CGPoint],
                            pupil: CGPoint?) -> (iris: CGPoint?, patch: EyePatch?) {
        guard let frame = EyeGeometry.frame(outline) else { return (nil, nil) }
        var state = eyes[index]

        // 1. A stable crop window (2:1, 1.6× the eye width) with hysteresis.
        let cx = Double(frame.origin.x), cy = Double(frame.origin.y)
        let w = min(max(Int(frame.width * 1.6), 24), image.width)
        let h = min(max(w / 2, 8), image.height)
        let x = min(max(Int(cx) - w / 2, 0), image.width - w)
        let y = min(max(Int(cy) - h / 2, 0), image.height - h)
        if let c = state.crop, abs(c.x + c.w / 2 - Int(cx)) <= 4, abs(c.y + c.h / 2 - Int(cy)) <= 3,
           abs(c.w - w) <= max(3, w / 7), c.x + c.w <= image.width, c.y + c.h <= image.height {
            // Keep the old window: the eye hasn't really moved.
        } else {
            state.crop = (x, y, w, h)
            state.denoised = []
            state.threshold = nil
        }
        let crop = state.crop!

        // 2. Motion-adaptive temporal denoising: average still pixels over ~3 frames,
        //    take changed pixels (a saccade or blink) immediately.
        let n = crop.w * crop.h
        var fresh = [Float](repeating: 0, count: n)
        for row in 0..<crop.h {
            for col in 0..<crop.w {
                fresh[row * crop.w + col] = Float(image.pixel(crop.x + col, crop.y + row))
            }
        }
        if state.denoised.count == n {
            for k in 0..<n {
                let d = fresh[k] - state.denoised[k]
                state.denoised[k] += (abs(d) > 28 ? 1 : 0.35) * d
            }
        } else {
            state.denoised = fresh
        }
        let pixels = state.denoised.map { UInt8(min(max($0.rounded(), 0), 255)) }

        // 3. Iris on the denoised pixels, with a dark-pixel cutoff smoothed over time.
        let shift = CGPoint(x: crop.x, y: crop.y)
        let local = outline.map { CGPoint(x: $0.x - shift.x, y: $0.y - shift.y) }
        var detail: IrisLocator.Result?
        if refineIris {
            detail = pixels.withUnsafeBufferPointer { buf in
                IrisLocator.locateDetailed(in: GrayImage(base: buf.baseAddress!, width: crop.w, height: crop.h,
                                                         bytesPerRow: crop.w),
                                           polygon: local,
                                           threshold: state.threshold.map { UInt8($0.rounded()) })
            }
            if let d = detail {
                let p = Double(d.percentileThreshold)
                state.threshold = state.threshold.map { $0 * 0.85 + p * 0.15 } ?? p
            }
        }
        let iris = detail.map { CGPoint(x: $0.centre.x + shift.x, y: $0.centre.y + shift.y) }

        if let iris {
            state.history.append(iris)
            if state.history.count > 30 { state.history.removeFirst() }
        }
        eyes[index] = state

        guard wantsEyePatches else { return (iris, nil) }

        // Debug close-up of exactly what the detector saw.
        var mask = [Bool](repeating: false, count: n)
        if let d = detail {
            for row in 0..<crop.h {
                for col in 0..<crop.w where pixels[row * crop.w + col] <= d.threshold
                    && IrisLocator.contains(d.polygon, Double(col) + 0.5, Double(row) + 0.5) {
                    mask[row * crop.w + col] = true
                }
            }
        }
        let sorted = pixels.sorted()
        let toLocal = { (p: CGPoint) in CGPoint(x: p.x - shift.x, y: p.y - shift.y) }
        let (c0, c1) = frame.corners
        let patch = EyePatch(
            width: crop.w, height: crop.h, pixels: pixels, irisMask: mask,
            outline: local, searchArea: detail?.polygon ?? [], corners: [toLocal(c0), toLocal(c1)],
            iris: toLocal(iris ?? pupil ?? frame.origin), visionPupil: pupil.map(toLocal),
            threshold: detail?.threshold, sourceX: crop.x, eyeWidth: 0, openness: 0, irisOffset: .zero,
            brightness: Double(pixels.reduce(0) { $0 + Int($1) }) / Double(n),
            contrast: Double(sorted[n * 9 / 10]) - Double(sorted[n / 10]),
            irisJitter: rms(state.history)
        )
        return (iris, patch)
    }

    // MARK: Helpers

    /// Gives `body` the luma (Y) plane as a grayscale image, or nil if the format has none.
    private func withLuma(_ pixelBuffer: CVPixelBuffer, _ body: (GrayImage?) -> Void) {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return body(nil) }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return body(nil) }
        body(GrayImage(
            base: base.assumingMemoryBound(to: UInt8.self),
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        ))
    }

    /// Smooths Vision's eye outlines. Vision wobbles them by a pixel or two even on a still face,
    /// and the outline sets both the eye reference frame and the iris search area. Smoothing is
    /// heavy while the head is still and light while it moves, so it doesn't lag behind real motion.
    private func smooth(_ contours: [[CGPoint]], faceBox: CGRect) -> [[CGPoint]] {
        let centre = CGPoint(x: faceBox.midX, y: faceBox.midY)
        defer { lastFaceCentre = centre }
        guard let previous = smoothedContours,
              let last = lastFaceCentre,
              previous.map(\.count) == contours.map(\.count)
        else {
            smoothedContours = contours
            return contours
        }
        let movement = hypot(centre.x - last.x, centre.y - last.y) / max(faceBox.width, 0.01)
        guard movement < 0.15 else {
            smoothedContours = contours
            return contours
        }
        let a: CGFloat = movement < 0.005 ? 0.12 : (movement < 0.02 ? 0.3 : 0.65)
        let result = zip(previous, contours).map { old, new in
            zip(old, new).map { o, n in CGPoint(x: o.x + (n.x - o.x) * a, y: o.y + (n.y - o.y) * a) }
        }
        smoothedContours = result
        return result
    }

    /// A tracker's patch centred on its tracked position, as a normalized Vision-space rect for drawing.
    private func visionRect(_ tracker: AnchorTracker, at centre: CGPoint, scale: Double, size: CGSize) -> CGRect {
        let r = tracker.patch(for: .zero, scale: scale)
        return CGRect(x: (centre.x - r.width / 2) / size.width,
                      y: (size.height - centre.y - r.height / 2) / size.height,
                      width: r.width / size.width, height: r.height / size.height)
    }

    func resetSmoothing() {
        fastCache = nil
        positionHistory.removeAll()
        turnTracker.reset()
        positionTracker.reset()
        smoothedContours = nil
        lastFaceCentre = nil
        eyes = [EyeState(), EyeState()]
    }

    private func rms(_ points: [CGPoint]) -> Double? {
        guard points.count >= 10 else { return nil }
        let n = CGFloat(points.count)
        let mx = points.reduce(0) { $0 + $1.x } / n, my = points.reduce(0) { $0 + $1.y } / n
        let sq = points.reduce(0.0) { $0 + Double(($1.x - mx) * ($1.x - mx) + ($1.y - my) * ($1.y - my)) }
        return (sq / Double(n)).squareRoot()
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }
}
