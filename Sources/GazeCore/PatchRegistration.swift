import Foundation
import CoreGraphics

/// A small grayscale image with float pixels (top-left origin).
public struct FloatImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Copies a region out of a camera image. Out-of-bounds pixels are clamped to the edge.
    public init(cropping image: GrayImage, x: Int, y: Int, width: Int, height: Int) {
        self.width = width
        self.height = height
        var px = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let sy = min(max(y + row, 0), image.height - 1)
            for col in 0..<width {
                let sx = min(max(x + col, 0), image.width - 1)
                px[row * width + col] = Float(image.pixel(sx, sy))
            }
        }
        pixels = px
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Float { pixels[y * width + x] }

    /// Bilinear sample, or nil outside the image.
    @inline(__always) func sample(_ x: Double, _ y: Double) -> Float? {
        guard x >= 0, y >= 0, x <= Double(width - 1), y <= Double(height - 1) else { return nil }
        let x0 = min(Int(x), width - 2), y0 = min(Int(y), height - 2)
        let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
        let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// Half resolution by 2×2 averaging (one pyramid level).
    func downsampled() -> FloatImage {
        let w = width / 2, h = height / 2
        var px = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                px[y * w + x] = (at(2 * x, 2 * y) + at(2 * x + 1, 2 * y) + at(2 * x, 2 * y + 1) + at(2 * x + 1, 2 * y + 1)) / 4
            }
        }
        return FloatImage(width: w, height: h, pixels: px)
    }
}

/// Measures how far an image patch moved between two frames, to a small fraction of a pixel,
/// by Lucas–Kanade alignment (inverse compositional, translation only, two pyramid levels).
///
/// Landmark detectors re-estimate every point from scratch each frame and jitter by pixels.
/// Registration compares the actual pixels of the whole patch, so it's far steadier.
public enum PatchRegistration {
    public struct Result: Sendable {
        /// Displacement of the patch content from the previous frame to this one, in pixels.
        public var shift: CGVector
        /// RMS intensity error after alignment (0–255 scale). High means the patch changed shape.
        public var residual: Double
    }

    /// Finds `d` such that `image(templateOrigin + x + d) ≈ template(x)`.
    ///
    /// - Parameters:
    ///   - template: patch from the previous frame, cut at `templateOrigin` (image coordinates).
    ///   - image: a region of the current frame, cut at `imageOrigin`, larger than the template
    ///     by a margin that covers the expected motion.
    ///   - initial: a guess for `d` (e.g. from landmarks).
    ///   - mask: optional per-pixel flags for the template; `false` pixels are ignored
    ///     (e.g. to keep the nose out of the cheek patch).
    public static func align(template: FloatImage, templateOrigin: CGPoint,
                             image: FloatImage, imageOrigin: CGPoint,
                             initial: CGVector = .zero, mask: [Bool]? = nil) -> Result? {
        guard template.width >= 16, template.height >= 16 else { return nil }
        let coarseMask = mask.map { downsample($0, width: template.width, height: template.height) }
        // Coarse level first: half the resolution doubles the motion it can catch.
        let coarse = lucasKanade(
            template: template.downsampled(),
            offset: ((Double(templateOrigin.x) - Double(imageOrigin.x)) / 2,
                     (Double(templateOrigin.y) - Double(imageOrigin.y)) / 2),
            image: image.downsampled(),
            start: (Double(initial.dx) / 2, Double(initial.dy) / 2), iterations: 15, mask: coarseMask)
        let start = coarse.map { ($0.d.0 * 2, $0.d.1 * 2) } ?? (Double(initial.dx), Double(initial.dy))
        guard let fine = lucasKanade(
            template: template,
            offset: (Double(templateOrigin.x - imageOrigin.x), Double(templateOrigin.y - imageOrigin.y)),
            image: image, start: start, iterations: 15, mask: mask)
        else { return nil }
        return Result(shift: CGVector(dx: fine.d.0, dy: fine.d.1), residual: fine.rms)
    }

    /// One pyramid level. `offset` is the template origin relative to the image region.
    /// A coarse-level pixel is used only if all four fine pixels are.
    static func downsample(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        let w = width / 2, h = height / 2
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * width + 2 * x
                out[y * w + x] = mask[i] && mask[i + 1] && mask[i + width] && mask[i + width + 1]
            }
        }
        return out
    }

    static func lucasKanade(template t: FloatImage, offset: (Double, Double), image: FloatImage,
                            start: (Double, Double), iterations: Int,
                            mask: [Bool]? = nil) -> (d: (Double, Double), rms: Double)? {
        let w = t.width, h = t.height
        // Template gradients and the Gauss–Newton Hessian are fixed: that's the
        // "inverse compositional" trick that keeps each iteration cheap.
        var gx = [Float](repeating: 0, count: w * h), gy = gx
        var h11 = 0.0, h12 = 0.0, h22 = 0.0, tSum = 0.0, count = 0
        var use = mask ?? [Bool](repeating: true, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard use[i] else { continue }
                gx[i] = (t.at(x + 1, y) - t.at(x - 1, y)) / 2
                gy[i] = (t.at(x, y + 1) - t.at(x, y - 1)) / 2
                h11 += Double(gx[i] * gx[i]); h12 += Double(gx[i] * gy[i]); h22 += Double(gy[i] * gy[i])
                tSum += Double(t.pixels[i])
                count += 1
            }
        }
        let det = h11 * h22 - h12 * h12
        guard count > 0, det > 1e-6 * max(h11 * h22, 1) else { return nil } // no texture to lock onto
        let tMean = Float(tSum / Double(count))
        // Border pixels have no gradient; drop them along with masked ones.
        for x in 0..<w { use[x] = false; use[(h - 1) * w + x] = false }
        for y in 0..<h { use[y * w] = false; use[y * w + w - 1] = false }

        var d = start
        var rms = 0.0
        for _ in 0..<iterations {
            // Mean-subtract both sides so a camera exposure change doesn't read as motion.
            var samples = [Float](repeating: .nan, count: w * h)
            var iSum = 0.0, n = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) where use[y * w + x] {
                    if let v = image.sample(offset.0 + Double(x) + d.0, offset.1 + Double(y) + d.1) {
                        samples[y * w + x] = v
                        iSum += Double(v)
                        n += 1
                    }
                }
            }
            guard n > count * 3 / 4 else { return nil } // drifted out of the search region
            let iMean = Float(iSum / Double(n))
            var b1 = 0.0, b2 = 0.0, sse = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let v = samples[i]
                    guard !v.isNaN else { continue }
                    let e = Double((v - iMean) - (t.pixels[i] - tMean))
                    b1 += Double(gx[i]) * e
                    b2 += Double(gy[i]) * e
                    sse += e * e
                }
            }
            let dx = (h22 * b1 - h12 * b2) / det
            let dy = (h11 * b2 - h12 * b1) / det
            d.0 -= dx
            d.1 -= dy
            rms = (sse / Double(n)).squareRoot()
            if dx * dx + dy * dy < 1e-5 { break }
        }
        return (d, rms)
    }
}

/// Like `PatchRegistration`, but also measures in-plane rotation (head tilt), to a few hundredths of a degree.
/// Inverse-compositional Lucas–Kanade with a rigid warp: x ↦ c + t + R(θ)(x − c), c = template centre.
public enum RigidRegistration {
    public struct Result: Sendable {
        public var shift: CGVector
        /// Radians, image coordinates (y down): positive turns the content clockwise on screen.
        public var rotation: Double
        public var residual: Double
    }

    public static func align(template: FloatImage, templateOrigin: CGPoint, image: FloatImage, imageOrigin: CGPoint,
                             initial: CGVector = .zero, initialRotation: Double = 0, mask: [Bool]? = nil) -> Result? {
        guard template.width >= 16, template.height >= 16 else { return nil }
        let coarseMask = mask.map { PatchRegistration.downsample($0, width: template.width, height: template.height) }
        let coarse = solve(template: template.downsampled(),
                           offset: ((Double(templateOrigin.x) - Double(imageOrigin.x)) / 2,
                                    (Double(templateOrigin.y) - Double(imageOrigin.y)) / 2),
                           image: image.downsampled(),
                           start: (Double(initial.dx) / 2, Double(initial.dy) / 2, initialRotation), mask: coarseMask)
        let start = coarse.map { ($0.p.0 * 2, $0.p.1 * 2, $0.p.2) }
            ?? (Double(initial.dx), Double(initial.dy), initialRotation)
        guard let fine = solve(template: template,
                               offset: (Double(templateOrigin.x - imageOrigin.x), Double(templateOrigin.y - imageOrigin.y)),
                               image: image, start: start, mask: mask)
        else { return nil }
        return Result(shift: CGVector(dx: fine.p.0, dy: fine.p.1), rotation: fine.p.2, residual: fine.rms)
    }

    static func solve(template t: FloatImage, offset: (Double, Double), image: FloatImage,
                      start: (Double, Double, Double), mask: [Bool]?,
                      iterations: Int = 20) -> (p: (Double, Double, Double), rms: Double)? {
        let w = t.width, h = t.height
        let cx = Double(w - 1) / 2, cy = Double(h - 1) / 2
        var use = mask ?? [Bool](repeating: true, count: w * h)
        for x in 0..<w { use[x] = false; use[(h - 1) * w + x] = false }
        for y in 0..<h { use[y * w] = false; use[y * w + w - 1] = false }

        // Steepest-descent images [gx, gy, −Y·gx + X·gy] and the 3×3 Hessian, fixed for all iterations.
        var sd = [(Double, Double, Double)](repeating: (0, 0, 0), count: w * h)
        var H = [[Double]](repeating: [0, 0, 0], count: 3)
        var tSum = 0.0, count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) where use[y * w + x] {
                let gx = Double(t.at(x + 1, y) - t.at(x - 1, y)) / 2
                let gy = Double(t.at(x, y + 1) - t.at(x, y - 1)) / 2
                let X = Double(x) - cx, Y = Double(y) - cy
                let s = (gx, gy, -Y * gx + X * gy)
                sd[y * w + x] = s
                let v = [s.0, s.1, s.2]
                for i in 0..<3 { for j in 0..<3 { H[i][j] += v[i] * v[j] } }
                tSum += Double(t.at(x, y))
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let tMean = tSum / Double(count)

        var (tx, ty, th) = start
        var rms = 0.0
        for _ in 0..<iterations {
            let c = cos(th), s = sin(th)
            var samples = [Double](repeating: .nan, count: w * h)
            var iSum = 0.0, n = 0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) where use[y * w + x] {
                    let X = Double(x) - cx, Y = Double(y) - cy
                    let px = offset.0 + cx + tx + c * X - s * Y
                    let py = offset.1 + cy + ty + s * X + c * Y
                    if let v = image.sample(px, py) {
                        samples[y * w + x] = Double(v)
                        iSum += Double(v)
                        n += 1
                    }
                }
            }
            guard n > count * 3 / 4 else { return nil }
            let iMean = iSum / Double(n)
            var b = [0.0, 0.0, 0.0], sse = 0.0
            for i in 0..<(w * h) where !samples[i].isNaN {
                let e = (samples[i] - iMean) - (Double(t.pixels[i]) - tMean)
                b[0] += sd[i].0 * e; b[1] += sd[i].1 * e; b[2] += sd[i].2 * e
                sse += e * e
            }
            guard let d = RidgeRegression.solve(H, b) else { return nil }
            // Compose with the inverse of the increment: θ ← θ − Δθ, t ← t − R(θ_new)·Δt.
            th -= d[2]
            let c2 = cos(th), s2 = sin(th)
            tx -= c2 * d[0] - s2 * d[1]
            ty -= s2 * d[0] + c2 * d[1]
            rms = (sse / Double(n)).squareRoot()
            if d[0] * d[0] + d[1] * d[1] < 1e-5, abs(d[2]) < 1e-6 { break }
        }
        return ((tx, ty, th), rms)
    }
}
