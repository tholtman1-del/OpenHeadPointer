import Foundation
import CoreGraphics

/// Maps a `GazeSample` to a screen point with a pair of ridge regressions
/// (one for x, one for y) over quadratic eye terms plus head-pose terms.
public struct GazeMapper: Codable, Sendable {
    public var x: RidgeRegression
    public var y: RidgeRegression
    /// Additive correction from "recenter" (drift correction), in points.
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    /// The calibrated screen in global CoreGraphics coordinates.
    public var screenFrame: CGRect
    public var createdAt: Date

    public static let defaultLambda = 0.01

    public static func features(_ s: GazeSample) -> [Double] {
        let u = s.eyeX, v = s.eyeY
        return [u, v, u * v, u * u, v * v, s.yaw, s.pitch, s.faceX, s.faceY, s.faceSize]
    }

    /// Smallest variation we consider meaningful for each feature (see `RidgeRegression.fit`).
    static let minScales: [Double] = [0.01, 0.01, 0.0005, 0.0005, 0.0005, 0.04, 0.04, 0.02, 0.02, 0.01]

    public static func fit(_ points: [CalibrationPoint], screenFrame: CGRect,
                           lambda: Double = defaultLambda) -> GazeMapper? {
        guard points.count >= 10 else { return nil }
        let X = points.map { features($0.sample) }
        guard let rx = RidgeRegression.fit(features: X, targets: points.map { Double($0.target.x) },
                                           lambda: lambda, minScales: minScales),
              let ry = RidgeRegression.fit(features: X, targets: points.map { Double($0.target.y) },
                                           lambda: lambda, minScales: minScales)
        else { return nil }
        return GazeMapper(x: rx, y: ry, screenFrame: screenFrame, createdAt: Date())
    }

    public func predict(_ s: GazeSample) -> CGPoint {
        let f = Self.features(s)
        return CGPoint(x: x.predict(f) + offsetX, y: y.predict(f) + offsetY)
    }

    public func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, screenFrame.minX), screenFrame.maxX - 1),
                y: min(max(p.y, screenFrame.minY), screenFrame.maxY - 1))
    }

    /// Mean distance between each target and the average prediction for its samples.
    public func meanTargetError(_ groups: [[CalibrationPoint]]) -> Double {
        let errors = groups.compactMap { group -> Double? in
            guard let target = group.first?.target else { return nil }
            let ps = group.map { predict($0.sample) }
            let mx = ps.reduce(0) { $0 + Double($1.x) } / Double(ps.count)
            let my = ps.reduce(0) { $0 + Double($1.y) } / Double(ps.count)
            return hypot(mx - Double(target.x), my - Double(target.y))
        }
        return errors.isEmpty ? .nan : errors.reduce(0, +) / Double(errors.count)
    }

    /// Leave-one-target-out error: an honest estimate of accuracy on points the model never saw.
    public static func crossValidatedError(_ groups: [[CalibrationPoint]], screenFrame: CGRect,
                                           lambda: Double = defaultLambda) -> Double? {
        guard groups.count >= 5 else { return nil }
        var errors: [Double] = []
        for i in groups.indices {
            let train = groups.enumerated().filter { $0.offset != i }.flatMap(\.element)
            guard let m = fit(train, screenFrame: screenFrame, lambda: lambda) else { continue }
            let e = m.meanTargetError([groups[i]])
            if e.isFinite { errors.append(e) }
        }
        return errors.isEmpty ? nil : errors.reduce(0, +) / Double(errors.count)
    }
}

public enum CalibrationFilter {
    /// Drops samples whose eye position is far from the target's median (glances, blinks, tracking glitches).
    public static func robust(_ samples: [GazeSample], madLimit: Double = 3) -> [GazeSample] {
        guard samples.count >= 5 else { return samples }
        let mx = median(samples.map(\.eyeX)), my = median(samples.map(\.eyeY))
        let dx = max(median(samples.map { abs($0.eyeX - mx) }), 0.002)
        let dy = max(median(samples.map { abs($0.eyeY - my) }), 0.002)
        return samples.filter { abs($0.eyeX - mx) <= madLimit * dx && abs($0.eyeY - my) <= madLimit * dy }
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
