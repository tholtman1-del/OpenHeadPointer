import Foundation
import CoreGraphics

/// The 1€ filter (Casiez et al., 2012): heavy smoothing when the signal is still,
/// light smoothing when it moves fast. Ideal for a gaze cursor: no jitter on a
/// fixation, little lag on a saccade.
public struct OneEuroFilter: Sendable {
    /// Cutoff (Hz) at rest. Lower = steadier but laggier.
    public var minCutoff: Double
    /// How quickly the cutoff rises with speed. Higher = more responsive to fast moves.
    public var beta: Double
    public var derivativeCutoff: Double

    private var value: Double?
    private var derivative = 0.0
    private var lastTime: Double?

    public init(minCutoff: Double = 0.6, beta: Double = 0.004, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let prev = value, let lt = lastTime else {
            value = x; lastTime = t
            return x
        }
        let dt = t - lt
        guard dt > 0 else { return prev }
        let rawDerivative = (x - prev) / dt
        let ad = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        derivative = ad * rawDerivative + (1 - ad) * derivative
        let cutoff = minCutoff + beta * abs(derivative)
        let a = Self.alpha(cutoff: cutoff, dt: dt)
        let out = a * x + (1 - a) * prev
        value = out
        lastTime = t
        return out
    }

    public mutating func reset() {
        value = nil
        lastTime = nil
        derivative = 0
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

public struct PointFilter: Sendable {
    public var x: OneEuroFilter
    public var y: OneEuroFilter

    public init(minCutoff: Double = 0.6, beta: Double = 0.004) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    public mutating func configure(minCutoff: Double, beta: Double) {
        x.minCutoff = minCutoff; x.beta = beta
        y.minCutoff = minCutoff; y.beta = beta
    }

    public mutating func filter(_ p: CGPoint, at t: Double) -> CGPoint {
        CGPoint(x: x.filter(Double(p.x), at: t), y: y.filter(Double(p.y), at: t))
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }
}

/// Gaze-specific smoothing built around how eyes actually move: they hold still
/// (fixations, ~0.2–1 s) and then jump (saccades, ~30–80 ms).
///
/// - During a fixation the output is the mean of the last `window` seconds of points,
///   so per-frame noise averages away and the cursor stays put.
/// - A jump is accepted only when `confirmFrames` consecutive points land outside the
///   jump radius *and* agree with each other. A single noisy frame can't move the cursor.
/// - The jump radius scales with the measured noise, so it adapts to lighting and camera.
public struct FixationFilter: Sendable {
    /// Seconds of gaze averaged while fixating. Longer = steadier, but slower to follow drift.
    public var window: Double
    /// Jump radius as a multiple of the measured noise. Higher = stickier.
    public var stickiness: Double
    public var minRadius = 30.0
    public var maxRadius = 300.0
    public var confirmFrames = 3

    /// Estimated per-frame scatter of the input (points, 1σ).
    public private(set) var noise = 30.0
    public var radius: Double { min(max(noise * stickiness, minRadius), maxRadius) }

    private static let medianSize = 5
    private var recent: [CGPoint] = []
    private var deviations: [Double] = []
    private var fixation: [(point: CGPoint, time: Double)] = []
    private var candidates: [CGPoint] = []
    private var centre: CGPoint?
    private var output: CGPoint?

    public init(window: Double = 0.6, stickiness: Double = 2.5) {
        self.window = window
        self.stickiness = stickiness
    }

    public mutating func filter(_ p: CGPoint, at t: Double) -> CGPoint {
        // A 5-frame median removes single-frame outliers (blink onsets, landmark glitches).
        recent.append(p)
        if recent.count > Self.medianSize { recent.removeFirst() }
        let m = Self.median(recent)

        guard let c = centre else {
            startFixation([m], at: t)
            output = m
            return m
        }

        // Noise estimate: median distance of raw points from the fixation centre.
        // Saccade frames are rare enough that the median ignores them.
        deviations.append(Self.distance(p, c))
        if deviations.count > 60 { deviations.removeFirst() }
        if deviations.count >= 15 {
            noise = Self.median(deviations) / 1.1774   // Rayleigh median → σ
        }

        if Self.distance(m, c) <= radius {
            candidates.removeAll()
            fixation.append((m, t))
            while fixation.count > 1, let first = fixation.first, first.time < t - window {
                fixation.removeFirst()
            }
            centre = Self.mean(fixation.map(\.point))
        } else {
            candidates.append(m)
            if candidates.count >= confirmFrames {
                let cm = Self.mean(candidates)
                if candidates.allSatisfy({ Self.distance($0, cm) <= radius }) {
                    startFixation(candidates, at: t)
                } else {
                    candidates.removeFirst()
                }
            }
        }

        // Glide to the centre over a few frames instead of teleporting.
        let target = centre!
        let o = output ?? target
        let next = CGPoint(x: o.x + (target.x - o.x) * 0.55, y: o.y + (target.y - o.y) * 0.55)
        output = next
        return next
    }

    public mutating func reset() {
        recent.removeAll()
        fixation.removeAll()
        candidates.removeAll()
        centre = nil
        output = nil
    }

    private mutating func startFixation(_ points: [CGPoint], at t: Double) {
        fixation = points.map { ($0, t) }
        candidates.removeAll()
        centre = Self.mean(points)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(Double(a.x - b.x), Double(a.y - b.y)) }

    static func mean(_ ps: [CGPoint]) -> CGPoint {
        let n = CGFloat(ps.count)
        return CGPoint(x: ps.reduce(0) { $0 + $1.x } / n, y: ps.reduce(0) { $0 + $1.y } / n)
    }

    static func median(_ ps: [CGPoint]) -> CGPoint {
        CGPoint(x: median(ps.map { Double($0.x) }), y: median(ps.map { Double($0.y) }))
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Head pose and face position change slowly, but Vision reports them with frame-to-frame
/// jitter that the gaze regression would turn into cursor shake. This smooths just those fields.
public struct HeadSmoother: Sendable {
    public var alpha: Double
    private var last: GazeSample?

    public init(alpha: Double = 0.2) {
        self.alpha = alpha
    }

    public mutating func smooth(_ s: GazeSample) -> GazeSample {
        guard let l = last else { last = s; return s }
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * alpha }
        var out = s
        out.yaw = mix(l.yaw, s.yaw)
        out.pitch = mix(l.pitch, s.pitch)
        out.roll = mix(l.roll, s.roll)
        out.faceX = mix(l.faceX, s.faceX)
        out.faceY = mix(l.faceY, s.faceY)
        out.faceSize = mix(l.faceSize, s.faceSize)
        last = out
        return out
    }

    public mutating func reset() {
        last = nil
    }
}

/// RMS scatter of the last `capacity` points around their mean, for the noise readout.
public struct JitterMeter: Sendable {
    public var capacity: Int
    private var points: [CGPoint] = []

    public init(capacity: Int = 30) {
        self.capacity = capacity
    }

    public mutating func add(_ p: CGPoint) {
        points.append(p)
        if points.count > capacity { points.removeFirst() }
    }

    public var rms: Double? {
        guard points.count >= 10 else { return nil }
        let m = FixationFilter.mean(points)
        let sq = points.reduce(0.0) { $0 + pow(Double($1.x - m.x), 2) + pow(Double($1.y - m.y), 2) }
        return (sq / Double(points.count)).squareRoot()
    }

    public mutating func reset() {
        points.removeAll()
    }
}
