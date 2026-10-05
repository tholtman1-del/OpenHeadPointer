import Foundation
import CoreGraphics

/// Turns small head movements into a screen position ("point with your nose").
///
/// The signal is the centre of Vision's nose landmarks in the camera image. Many points
/// averaged together are far steadier than an iris a few pixels wide. Motion is measured
/// in eye-distances, so sitting closer or further from the camera doesn't change the feel.
public struct HeadPointer: Sendable {
    /// Nose travel, in eye-distances, that sweeps the full screen width.
    /// About 0.6 is roughly ±10° of head turn.
    public var span: Double
    /// Extra vertical gain: nodding has less range than turning.
    public var verticalBoost: Double
    public var screen: CGRect
    /// Pushing past a screen edge drags the centre along (like lifting a mouse). Off keeps
    /// "facing straight ahead = screen centre" fixed: the pointer just stops at the edge.
    public var pushNeutralAtEdges = false

    /// Nose position (camera pixels) that maps to the screen centre.
    public private(set) var neutral: CGPoint?
    private var scale = 0.0

    public init(span: Double = 0.6, verticalBoost: Double = 1.4, screen: CGRect = .zero) {
        self.span = span
        self.verticalBoost = verticalBoost
        self.screen = screen
    }

    /// The current nose position becomes the screen centre.
    public mutating func recenter(nose: CGPoint, eyeDistance: Double) {
        neutral = nose
        scale = max(eyeDistance, 1)
    }

    public mutating func reset() {
        neutral = nil
    }

    /// Moves the neutral by `delta` (input units), e.g. to absorb a jump when tracking restarts
    /// so the pointer stays where it was.
    public mutating func shiftNeutral(by delta: CGVector) {
        guard var n = neutral else { return }
        n.x += delta.dx
        n.y += delta.dy
        neutral = n
    }

    /// - Parameters:
    ///   - nose: nose centre in camera pixels, Vision space (origin bottom-left, not mirrored).
    /// - Returns: a point on `screen` in CoreGraphics coordinates. Pushing past an edge drags
    ///   the neutral position along, so the cursor responds the moment you turn back, like
    ///   lifting and re-placing a mouse.
    public mutating func point(nose: CGPoint, eyeDistance: Double) -> CGPoint {
        if neutral == nil { recenter(nose: nose, eyeDistance: eyeDistance) }
        guard var n = neutral, screen.width > 0 else { return CGPoint(x: screen.midX, y: screen.midY) }

        let gain = Double(screen.width) / (span * scale)   // screen points per camera pixel
        // The camera isn't mirrored: turning right moves the nose toward image-left.
        // Vision's y points up, screen y points down.
        let x = Double(screen.midX) - Double(nose.x - n.x) * gain
        let y = Double(screen.midY) - Double(nose.y - n.y) * gain * verticalBoost

        let cx = min(max(x, Double(screen.minX)), Double(screen.maxX) - 1)
        let cy = min(max(y, Double(screen.minY)), Double(screen.maxY) - 1)
        if pushNeutralAtEdges {
            n.x -= CGFloat((x - cx) / gain)
            n.y -= CGFloat((y - cy) / (gain * verticalBoost))
            neutral = n
        }
        return CGPoint(x: cx, y: cy)
    }
}

/// Speed-sensitive (relative) face pointer, like mouse acceleration.
///
/// Head *speed* sets pointer gain:
/// - below `driftThreshold` (breathing, sway, heartbeat) the pointer doesn't move at all;
/// - slow, deliberate movement gets low gain, for precision;
/// - fast movement gets high gain, to cross the screen quickly.
/// The pointer isn't tied to a head pose, so it never needs recentring.
public struct RelativePointer: Sendable {
    public var screen: CGRect
    /// Face travel (eye-distances) that sweeps the full screen width when moving fast.
    public var fastSpan: Double
    /// Gain for slow movements as a fraction of the fast gain.
    public var precision: Double
    /// Speeds below this (eye-distances per second) count as drift and are ignored.
    public var driftThreshold: Double
    /// Speed (eye-distances per second) at which the full fast gain applies.
    public var fastSpeed = 0.35
    public var verticalBoost = 1.4
    /// How strongly the pointer is pulled back to where this head position put it before (0…1).
    /// 0 = pure relative motion, which drifts; 1 = nearly a fixed head-position mapping.
    public var consistency = 0.8
    /// Gain of the head-position-to-cursor reference, as a fraction of the fast gain.
    public var referenceGain = 0.5

    public private(set) var position: CGPoint?
    /// Smoothed head speed (eye-distances per second), for display.
    public private(set) var speed = 0.0
    private var last: (anchor: CGPoint, time: Double)?
    /// Ties a head position to a cursor position: (head, cursor) when control started.
    private var reference: (head: CGPoint, cursor: CGPoint)?
    private var needsReference = true

    public init(screen: CGRect = .zero, fastSpan: Double = 0.3, precision: Double = 0.2,
                driftThreshold: Double = 0.02) {
        self.screen = screen
        self.fastSpan = fastSpan
        self.precision = precision
        self.driftThreshold = driftThreshold
    }

    /// Puts the pointer somewhere (e.g. where the real cursor moved to) without changing which
    /// cursor position each head position belongs to.
    public mutating func place(at p: CGPoint) {
        position = clamp(p)
        if reference == nil { needsReference = true }
    }

    /// Puts the pointer at `p` and ties the next head position to it (e.g. head centred = screen centre).
    public mutating func recentre(at p: CGPoint) {
        position = clamp(p)
        needsReference = true
    }

    /// Where this head position puts the cursor in the consistent (head-position) reference.
    /// Not clamped, so pushing past an edge is remembered rather than re-anchored.
    public func consistentPosition(for anchor: CGPoint, scale: Double) -> CGPoint? {
        guard let r = reference, scale > 0 else { return nil }
        let g = Double(screen.width) / fastSpan * referenceGain
        return CGPoint(x: Double(r.cursor.x) - Double(anchor.x - r.head.x) / scale * g,
                       y: Double(r.cursor.y) - Double(anchor.y - r.head.y) / scale * g * verticalBoost)
    }

    public mutating func reset() {
        last = nil
        speed = 0
    }

    /// - Parameters:
    ///   - anchor: face anchor in camera pixels, Vision space (origin bottom-left, not mirrored).
    ///     Drives the motion, so it should be smooth (image registration).
    ///   - reference: where the head really is, for keeping the cursor tied to head position. It
    ///     should be drift-free (smoothed landmarks); registration slowly slides over the face.
    ///     Defaults to `anchor`.
    ///   - scale: face scale in camera pixels (eye distance).
    public mutating func update(anchor: CGPoint, reference ref: CGPoint? = nil, scale: Double, at t: Double) -> CGPoint {
        let current = position ?? CGPoint(x: screen.midX, y: screen.midY)
        let headPosition = ref ?? anchor
        defer { last = (anchor, t) }
        if needsReference {
            reference = (headPosition, current)
            needsReference = false
        }
        guard let l = last, t > l.time, scale > 0 else {
            position = current
            return current
        }
        let dx = Double(anchor.x - l.anchor.x) / scale
        let dy = Double(anchor.y - l.anchor.y) / scale
        // Fast attack, slower release: the gain responds as soon as you start moving (no sluggish
        // start), but doesn't drop out mid-movement on a single slow frame.
        let v = hypot(dx, dy) / (t - l.time)
        speed = v > speed ? speed * 0.15 + v * 0.85 : speed * 0.6 + v * 0.4
        let g = gain(speed)
        // Camera isn't mirrored (turning right moves the face toward image-left);
        // Vision's y points up, screen y points down.
        var next = CGPoint(x: Double(current.x) - dx * g, y: Double(current.y) - dy * g * verticalBoost)

        // Drift correction, only while the head is moving (above the drift threshold): the offset from
        // the consistent position shrinks by a fraction for every bit of head movement. It decays with
        // movement instead of building up, while each movement keeps its speed-sensitive gain.
        // Holding still never moves the pointer.
        if consistency > 0, g > 0, let target = consistentPosition(for: headPosition, scale: scale) {
            let length = 0.3 * (1 - consistency) + 0.02   // eye-distances of movement per e-fold
            let k = 1 - exp(-hypot(dx, dy) / length)
            next = CGPoint(x: Double(next.x) + Double(target.x - next.x) * k,
                           y: Double(next.y) + Double(target.y - next.y) * k)
        }
        next = clamp(next)
        position = next
        return next
    }

    /// Screen points per eye-distance of face movement, at a given head speed.
    public func gain(_ v: Double) -> Double {
        let fast = Double(screen.width) / fastSpan
        guard v > driftThreshold else { return 0 }
        // Fade in over one threshold's worth of speed, so starting to move isn't a jolt.
        let fadeIn = min(1, (v - driftThreshold) / max(driftThreshold, 1e-6))
        let x = min(1, max(0, (v - 2 * driftThreshold) / (fastSpeed - 2 * driftThreshold)))
        let curve = x * x * (3 - 2 * x)
        return fast * (precision + (1 - precision) * curve) * fadeIn
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        guard screen.width > 0 else { return p }
        return CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
    }
}
