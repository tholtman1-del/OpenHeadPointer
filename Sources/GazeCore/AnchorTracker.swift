import Foundation
import CoreGraphics

/// Tracks a point on the face (the anchor) to a small fraction of a pixel.
///
/// It aligns the current frame against a fixed **keyframe** patch rather than against the
/// previous frame. Frame-to-frame alignment adds a little error at every step, and those errors
/// pile up into a slow wander even on a still face. Against a keyframe, errors don't accumulate.
/// The keyframe is replaced only after real movement (or when the patch's appearance changes),
/// so a still face gives a still anchor.
///
/// Vision's landmarks are used only to start, and as a safety net if tracking slips off the face.
public struct AnchorTracker: Sendable {
    public struct Output: Sendable {
        public var position: CGPoint
        /// Accumulated in-plane rotation (radians, image coordinates: positive = clockwise on screen).
        /// Only measured when `estimateRotation` is on.
        public var rotation: Double = 0
        public var locked: Bool
        public var residual: Double?
        public var displacement: CGVector?
        public var refreshed: Bool
    }

    /// Replace the keyframe after this much movement (pixels): larger moves change the patch's appearance.
    public var refreshDistance = 6.0
    /// Search margin around the expected position (pixels). Fast head movements reach 30–40 px per frame.
    public var margin = 40
    /// Patch size as multiples of the face scale (eye distance).
    public var widthFactor: Double
    public var heightFactor: Double
    /// Patch centre offset from the landmark, in multiples of the face scale (top-left image coordinates).
    public var offset: CGVector
    public var maxSide = 400
    /// Patches larger than this (pixels) are aligned at half resolution.
    public var halfResolutionAbove = 160
    /// Also measure in-plane rotation (head tilt). Off by default: shift-only alignment is the reference behaviour.
    public var estimateRotation = false
    /// Keeps the patch anchored to the face. Registration is precise frame to frame, but when the head
    /// turns the patch's appearance changes and it slowly slides across the face. While moving, the
    /// position is nudged toward the (smoothed) landmark by at most this fraction of each frame's
    /// movement. Holding still never moves it. 0 = off.
    public var landmarkPull = 0.0
    /// Smoothed landmark − tracked position: how far the patch has slid.
    public private(set) var slip = CGVector.zero
    private var lastOutput: CGPoint?
    private var previousOutput: CGPoint?
    /// Region to ignore, relative to the patch centre in multiples of the face scale
    /// (e.g. the nose, so a cheek patch measures only the cheeks).
    public var exclude: CGRect?

    private struct Keyframe {
        /// Template pixels, at 1/`factor` resolution.
        var template: FloatImage
        var mask: [Bool]?
        var factor: Int
        var size: (w: Int, h: Int)
        var origin: CGPoint
        var position: CGPoint
        var landmark: CGPoint
        var baseResidual: Double?
        /// Accumulated rotation when this keyframe was taken.
        var baseRotation: Double
    }

    private var key: Keyframe?
    private var rotation = 0.0
    private var totalRotation = 0.0

    public init(widthFactor: Double = 0.7, heightFactor: Double = 0.7, offset: CGVector = .zero) {
        self.widthFactor = widthFactor
        self.heightFactor = heightFactor
        self.offset = offset
    }

    /// Size and centre of the tracked patch for a given landmark and face scale (top-left image pixels).
    public func patch(for landmark: CGPoint, scale: Double) -> CGRect {
        let w = min(max(Int(scale * widthFactor) / 2 * 2, 32), maxSide)
        let h = min(max(Int(scale * heightFactor) / 2 * 2, 32), maxSide)
        let c = CGPoint(x: landmark.x + offset.dx * scale, y: landmark.y + offset.dy * scale)
        return CGRect(x: c.x - CGFloat(w) / 2, y: c.y - CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h))
    }

    public mutating func reset() {
        key = nil
        lastOutput = nil
        previousOutput = nil
        slip = .zero
        totalRotation = 0
        rotation = 0
    }

    /// - Parameters:
    ///   - landmark: Vision's anchor estimate (top-left image pixels).
    ///   - scale: face scale in pixels (eye distance); sets the patch size.
    public mutating func update(landmark rawLandmark: CGPoint, scale: Double, image: GrayImage) -> Output {
        // Track the patch centre, which sits at `offset` from the landmark.
        let landmark = CGPoint(x: rawLandmark.x + offset.dx * scale, y: rawLandmark.y + offset.dy * scale)
        if var k = key {
            // Constant-velocity guess from the last two tracked positions (these survive keyframe
            // refreshes, which happen every frame during fast movement), then a landmark-based guess.
            var velocityGuess = CGVector.zero
            if let p1 = lastOutput, let p0 = previousOutput {
                velocityGuess = CGVector(dx: 2 * p1.x - p0.x - k.position.x, dy: 2 * p1.y - p0.y - k.position.y)
            } else if let p1 = lastOutput {
                velocityGuess = CGVector(dx: p1.x - k.position.x, dy: p1.y - k.position.y)
            }
            let landmarkGuess = CGVector(dx: landmark.x - k.landmark.x, dy: landmark.y - k.landmark.y)
            for guess in [velocityGuess, landmarkGuess] {
                guard let r = align(k, guess: guess, image: image) else { continue }
                var position = CGPoint(x: k.position.x + r.shift.dx, y: k.position.y + r.shift.dy)
                slip = CGVector(dx: slip.dx + (landmark.x - position.x - slip.dx) * 0.1,
                                dy: slip.dy + (landmark.y - position.y - slip.dy) * 0.1)
                if landmarkPull > 0, let last = lastOutput {
                    let step = hypot(Double(position.x - last.x), Double(position.y - last.y))
                    let size = hypot(Double(slip.dx), Double(slip.dy))
                    if size > 0 {
                        let k2 = CGFloat(min(1, landmarkPull * step / size))
                        let fix = CGVector(dx: slip.dx * k2, dy: slip.dy * k2)
                        position.x += fix.dx; position.y += fix.dy
                        k.position.x += fix.dx; k.position.y += fix.dy // keep the correction
                        slip.dx -= fix.dx; slip.dy -= fix.dy
                        key = k
                    }
                }
                previousOutput = lastOutput
                lastOutput = position
                // Safety net: if we've slid well off the landmarks, tracking has lost the face.
                guard hypot(position.x - landmark.x, position.y - landmark.y) < max(scale * 0.35, 20) else { break }

                rotation = r.rotation
                totalRotation = k.baseRotation + r.rotation
                if k.baseResidual == nil { k.baseResidual = r.residual; key = k }
                let moved = hypot(Double(r.shift.dx), Double(r.shift.dy)) > refreshDistance || abs(r.rotation) > 0.05
                let changed = r.residual > (k.baseResidual ?? r.residual) * 1.8 + 3
                if moved || changed {
                    startKeyframe(at: position, landmark: landmark, scale: scale, image: image)
                }
                return Output(position: position, rotation: totalRotation, locked: true, residual: r.residual,
                              displacement: r.shift, refreshed: moved || changed)
            }
        }
        // (Re)start from the landmarks.
        slip = .zero
        previousOutput = nil
        lastOutput = landmark
        startKeyframe(at: landmark, landmark: landmark, scale: scale, image: image)
        return Output(position: landmark, rotation: totalRotation, locked: false, residual: nil,
                      displacement: nil, refreshed: true)
    }

    private func align(_ k: Keyframe, guess: CGVector, image: GrayImage) -> RigidRegistration.Result? {
        let f = k.factor, m = margin * f
        let rx = Int((k.origin.x + guess.dx).rounded()) - m
        let ry = Int((k.origin.y + guess.dy).rounded()) - m
        var region = FloatImage(cropping: image, x: rx, y: ry, width: k.size.w + 2 * m, height: k.size.h + 2 * m)
        if f == 2 { region = region.downsampled() }
        let s = CGFloat(f)
        let templateOrigin = CGPoint(x: k.origin.x / s, y: k.origin.y / s)
        let imageOrigin = CGPoint(x: CGFloat(rx) / s, y: CGFloat(ry) / s)
        let initial = CGVector(dx: guess.dx / s, dy: guess.dy / s)
        let r: RigidRegistration.Result?
        if estimateRotation {
            r = RigidRegistration.align(template: k.template, templateOrigin: templateOrigin, image: region,
                                        imageOrigin: imageOrigin, initial: initial, initialRotation: rotation,
                                        mask: k.mask)
        } else {
            r = PatchRegistration.align(template: k.template, templateOrigin: templateOrigin, image: region,
                                        imageOrigin: imageOrigin, initial: initial, mask: k.mask)
                .map { RigidRegistration.Result(shift: $0.shift, rotation: 0, residual: $0.residual) }
        }
        guard let r else { return nil }
        let shift = CGVector(dx: r.shift.dx * s, dy: r.shift.dy * s)
        guard hypot(shift.dx - guess.dx, shift.dy - guess.dy) < CGFloat(m) * 0.6, r.residual < 30 else { return nil }
        return RigidRegistration.Result(shift: shift, rotation: r.rotation, residual: r.residual)
    }

    private mutating func startKeyframe(at position: CGPoint, landmark: CGPoint, scale: Double, image: GrayImage) {
        let w = min(max(Int(scale * widthFactor) / 2 * 2, 32), maxSide)
        let h = min(max(Int(scale * heightFactor) / 2 * 2, 32), maxSide)
        // Big patches are aligned at half resolution: plenty of pixels for precision, a quarter of the work.
        let factor = max(w, h) > halfResolutionAbove ? 2 : 1
        let origin = CGPoint(x: (position.x - CGFloat(w) / 2).rounded(), y: (position.y - CGFloat(h) / 2).rounded())
        var template = FloatImage(cropping: image, x: Int(origin.x), y: Int(origin.y), width: w, height: h)
        if factor == 2 { template = template.downsampled() }
        var mask: [Bool]?
        if let ex = exclude {
            // Excluded rectangle in template pixels (at the template's resolution).
            let f = CGFloat(factor), sc = CGFloat(scale)
            let r = CGRect(x: (CGFloat(w) / 2 + ex.minX * sc) / f, y: (CGFloat(h) / 2 + ex.minY * sc) / f,
                           width: ex.width * sc / f, height: ex.height * sc / f)
            mask = (0..<(template.width * template.height)).map { i in
                !r.contains(CGPoint(x: CGFloat(i % template.width) + 0.5, y: CGFloat(i / template.width) + 0.5))
            }
        }
        key = Keyframe(template: template, mask: mask, factor: factor, size: (w, h),
                       origin: origin, position: position, landmark: landmark, baseResidual: nil,
                       baseRotation: totalRotation)
        rotation = 0
    }
}

/// Holds the pointer still until the input moves more than `radius` points away, then follows
/// it at that distance. Unlike smoothing, it never moves the pointer on its own.
public struct DeadZoneFilter: Sendable {
    public var radius: Double
    private var output: CGPoint?

    public init(radius: Double = 4) {
        self.radius = radius
    }

    public mutating func filter(_ p: CGPoint) -> CGPoint {
        guard let o = output else {
            output = p
            return p
        }
        let d = hypot(Double(p.x - o.x), Double(p.y - o.y))
        guard d > radius else { return o }
        let k = CGFloat((d - radius) / d)
        let next = CGPoint(x: o.x + (p.x - o.x) * k, y: o.y + (p.y - o.y) * k)
        output = next
        return next
    }

    public mutating func reset() {
        output = nil
    }
}

/// Measures head *rotation* (turning and nodding) independently of where the face is in the frame.
///
/// When you turn your head, the nose tip (≈3 cm in front of the cheeks) moves further in the
/// camera image than the cheeks do. That's parallax. When you slide or lean, everything moves
/// together. So the head turn is the nose patch's position minus the cheek patch's position.
/// Translation cancels out, and both are measured by sub-pixel image registration.
public struct HeadTurnTracker: Sendable {
    /// Nose parallax per degree of head turn, in eye-distances: ≈ 30 mm × π/180 ÷ 63 mm.
    /// Approximate; the speed setting absorbs individual differences.
    public static let parallaxPerDegree = 0.008

    public var nose = AnchorTracker(widthFactor: 0.4, heightFactor: 0.4)
    /// A wide band across the cheeks and nose, below the eyes and above the mouth:
    /// blinking, eye movement and talking barely touch it.
    public var face: AnchorTracker = {
        var t = AnchorTracker(widthFactor: 1.5, heightFactor: 0.8, offset: CGVector(dx: 0, dy: -0.15))
        // Leave the nose out, so the band measures only the cheeks (the nose sits 0.15 below its centre).
        t.exclude = CGRect(x: -0.3, y: -0.15, width: 0.6, height: 0.6)
        return t
    }()

    public struct Output: Sendable {
        /// Head turn in degrees, plus an arbitrary constant (only changes matter).
        /// Image orientation: +x = nose toward image-right, +y = nose toward image-bottom.
        public var turn: CGVector
        public var nose: AnchorTracker.Output
        public var face: AnchorTracker.Output
        /// False when either patch lost its lock and restarted from landmarks (the turn may jump).
        public var valid: Bool
    }

    public init() {}

    public mutating func reset() {
        nose.reset()
        face.reset()
    }

    /// - Parameter noseLandmark: Vision's nose centre, top-left image pixels.
    public mutating func update(noseLandmark: CGPoint, scale: Double, image: GrayImage) -> Output {
        let n = nose.update(landmark: noseLandmark, scale: scale, image: image)
        let f = face.update(landmark: noseLandmark, scale: scale, image: image)
        let k = 1 / (max(scale, 1) * Self.parallaxPerDegree)
        let turn = CGVector(dx: (n.position.x - f.position.x) * k, dy: (n.position.y - f.position.y) * k)
        return Output(turn: turn, nose: n, face: f, valid: n.locked && f.locked)
    }
}
