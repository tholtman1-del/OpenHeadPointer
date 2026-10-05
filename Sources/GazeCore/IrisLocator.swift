import Foundation
import CoreGraphics

/// A borrowed 8-bit grayscale image (e.g. the Y plane of a camera frame). Top-left origin.
public struct GrayImage {
    public let base: UnsafePointer<UInt8>
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    @inline(__always) public func pixel(_ x: Int, _ y: Int) -> UInt8 {
        base[y * bytesPerRow + x]
    }
}

/// Finds the iris centre as the weighted centroid of the darkest pixels inside the eye outline.
///
/// Vision's pupil landmark is a coarse estimate; the iris is the darkest large blob
/// in the eye, so this usually gives a steadier, more precise position.
public enum IrisLocator {
    public struct Result: Sendable {
        /// Iris centre in pixel coordinates (top-left origin).
        public var centre: CGPoint
        /// Pixels at or below this brightness (inside `polygon`) were counted as iris.
        public var threshold: UInt8
        /// This frame's own percentile threshold. Callers can smooth it over time and pass it back in.
        public var percentileThreshold: UInt8
        /// The shrunken search outline actually used.
        public var polygon: [CGPoint]
    }

    public static func locate(in image: GrayImage, polygon: [CGPoint],
                              darkFraction: Double = 0.22, shrink: Double = 0.85) -> CGPoint? {
        locateDetailed(in: image, polygon: polygon, darkFraction: darkFraction, shrink: shrink)?.centre
    }

    /// - Parameters:
    ///   - polygon: eye outline in pixel coordinates (top-left origin).
    ///   - darkFraction: share of the eye's pixels treated as iris.
    ///   - shrink: scales the outline toward its centre to drop lashes and corner shadows.
    ///   - threshold: use this brightness cutoff instead of this frame's percentile (for temporal smoothing).
    public static func locateDetailed(in image: GrayImage, polygon: [CGPoint],
                                      darkFraction: Double = 0.22, shrink: Double = 0.85,
                                      threshold fixedThreshold: UInt8? = nil) -> Result? {
        guard polygon.count >= 3 else { return nil }

        let cx = polygon.reduce(0) { $0 + Double($1.x) } / Double(polygon.count)
        let cy = polygon.reduce(0) { $0 + Double($1.y) } / Double(polygon.count)
        let poly = polygon.map { CGPoint(x: cx + (Double($0.x) - cx) * shrink, y: cy + (Double($0.y) - cy) * shrink) }

        let minX = max(0, Int(floor(poly.map(\.x).min()!)))
        let maxX = min(image.width - 1, Int(ceil(poly.map(\.x).max()!)))
        let minY = max(0, Int(floor(poly.map(\.y).min()!)))
        let maxY = min(image.height - 1, Int(ceil(poly.map(\.y).max()!)))
        guard maxX > minX + 2, maxY > minY + 1 else { return nil }

        var xs: [Int32] = [], ys: [Int32] = [], vals: [UInt8] = []
        var histogram = [Int](repeating: 0, count: 256)
        for y in minY...maxY {
            for x in minX...maxX where contains(poly, Double(x) + 0.5, Double(y) + 0.5) {
                let v = image.pixel(x, y)
                xs.append(Int32(x)); ys.append(Int32(y)); vals.append(v)
                histogram[Int(v)] += 1
            }
        }
        guard vals.count >= 12 else { return nil }

        // Intensity threshold at the requested percentile.
        let wanted = max(4, Int(Double(vals.count) * darkFraction))
        var cumulative = 0, percentile = 255
        for i in 0..<256 {
            cumulative += histogram[i]
            if cumulative >= wanted { percentile = i; break }
        }
        let threshold = fixedThreshold.map(Int.init) ?? percentile

        // Darker pixels count more, which pulls the estimate toward the pupil.
        var sx = 0.0, sy = 0.0, sw = 0.0
        for i in 0..<vals.count where Int(vals[i]) <= threshold {
            let w = Double(threshold - Int(vals[i]) + 1)
            sx += (Double(xs[i]) + 0.5) * w
            sy += (Double(ys[i]) + 0.5) * w
            sw += w
        }
        guard sw > 0 else { return nil }
        return Result(centre: CGPoint(x: sx / sw, y: sy / sw), threshold: UInt8(threshold),
                      percentileThreshold: UInt8(percentile), polygon: poly)
    }

    /// Even-odd ray casting.
    public static func contains(_ poly: [CGPoint], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let xi = Double(poly[i].x), yi = Double(poly[i].y)
            let xj = Double(poly[j].x), yj = Double(poly[j].y)
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
