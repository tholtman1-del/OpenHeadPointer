import Foundation
import CoreGraphics

public struct EyeMeasurement: Sendable, Equatable {
    /// Iris offset from the eye-corner midpoint along the corner axis, in eye widths.
    public var irisOffsetX: Double
    /// Iris offset perpendicular to the corner axis, in eye widths.
    public var irisOffsetY: Double
    /// Eyelid opening (extent perpendicular to the corner axis) divided by eye width.
    public var openness: Double
    /// Corner-to-corner distance in the contour's units (pixels).
    public var width: Double
}

public enum EyeGeometry {
    /// The eye's reference frame, estimated continuously from all outline points.
    ///
    /// Picking two specific outline points as "the corners" is unstable: when two points are
    /// nearly tied (common on a level, still face), the pick flips frame to frame and the
    /// whole reference jumps. The principal axis of all points can't flip like that, and
    /// extents measured along it change smoothly even when the extreme point changes.
    public struct Frame: Sendable {
        /// Midpoint of the eye along its axis, at the outline's mean height.
        public var origin: CGPoint
        /// Unit vector along the eye, oriented toward +x.
        public var axis: CGVector
        /// Extent along the axis (≈ corner to corner).
        public var width: Double
        /// Extent perpendicular to the axis (eyelid opening).
        public var height: Double

        public var corners: (CGPoint, CGPoint) {
            let h = width / 2
            return (CGPoint(x: origin.x - axis.dx * h, y: origin.y - axis.dy * h),
                    CGPoint(x: origin.x + axis.dx * h, y: origin.y + axis.dy * h))
        }
    }

    public static func frame(_ contour: [CGPoint]) -> Frame? {
        guard contour.count >= 4 else { return nil }
        let n = Double(contour.count)
        let mx = contour.reduce(0) { $0 + Double($1.x) } / n
        let my = contour.reduce(0) { $0 + Double($1.y) } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in contour {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        var ux = cos(angle), uy = sin(angle)
        if ux < 0 { ux = -ux; uy = -uy }
        let px = -uy, py = ux

        var lo = Double.infinity, hi = -Double.infinity, plo = Double.infinity, phi = -Double.infinity
        for p in contour {
            let dx = Double(p.x) - mx, dy = Double(p.y) - my
            let a = dx * ux + dy * uy, b = dx * px + dy * py
            lo = min(lo, a); hi = max(hi, a)
            plo = min(plo, b); phi = max(phi, b)
        }
        let width = hi - lo
        guard width > 1e-6 else { return nil }
        let c = (lo + hi) / 2
        return Frame(origin: CGPoint(x: mx + ux * c, y: my + uy * c), axis: CGVector(dx: ux, dy: uy),
                     width: width, height: phi - plo)
    }

    /// Measures where the iris sits inside an eye outline.
    ///
    /// - Parameters:
    ///   - contour: eye outline points (any consistent 2D coordinate system).
    ///   - iris: iris centre in the same coordinate system.
    public static func measure(contour: [CGPoint], iris: CGPoint) -> EyeMeasurement? {
        guard let f = frame(contour) else { return nil }
        let ux = Double(f.axis.dx), uy = Double(f.axis.dy)
        let px = -uy, py = ux
        let dx = Double(iris.x - f.origin.x), dy = Double(iris.y - f.origin.y)
        return EyeMeasurement(irisOffsetX: (dx * ux + dy * uy) / f.width,
                              irisOffsetY: (dx * px + dy * py) / f.width,
                              openness: f.height / f.width,
                              width: f.width)
    }

    /// Ends of the eye's axis (for display).
    public static func corners(_ contour: [CGPoint]) -> (CGPoint, CGPoint)? {
        frame(contour)?.corners
    }

    /// Combines both eyes, trusting the larger (closer-to-camera, less foreshortened) eye more.
    public static func combine(_ l: EyeMeasurement, _ r: EyeMeasurement) -> (x: Double, y: Double) {
        let total = l.width + r.width
        guard total > 0 else { return ((l.irisOffsetX + r.irisOffsetX) / 2, (l.irisOffsetY + r.irisOffsetY) / 2) }
        let wl = l.width / total, wr = r.width / total
        return (l.irisOffsetX * wl + r.irisOffsetX * wr, l.irisOffsetY * wl + r.irisOffsetY * wr)
    }

    static func squaredDistance(_ p: CGPoint, _ q: CGPoint) -> Double {
        let dx = Double(p.x - q.x), dy = Double(p.y - q.y)
        return dx * dx + dy * dy
    }
}
