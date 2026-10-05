import Foundation

/// Linear ridge regression on standardized features.
public struct RidgeRegression: Codable, Sendable {
    public var means: [Double]
    public var scales: [Double]
    public var weights: [Double]
    public var intercept: Double

    /// - Parameters:
    ///   - lambda: regularization strength, scaled by sample count so it is independent of it.
    ///   - minScales: per-feature floor for the standardization scale. Without it, a feature
    ///     that barely varied during calibration (e.g. head yaw) gets inflated to unit variance
    ///     and can blow up predictions when it later moves.
    public static func fit(features X: [[Double]], targets y: [Double], lambda: Double,
                           minScales: [Double]? = nil) -> RidgeRegression? {
        let n = X.count
        guard n > 0, n == y.count else { return nil }
        let d = X[0].count
        guard d > 0, X.allSatisfy({ $0.count == d }) else { return nil }

        var means = [Double](repeating: 0, count: d)
        for row in X { for j in 0..<d { means[j] += row[j] } }
        for j in 0..<d { means[j] /= Double(n) }

        var scales = [Double](repeating: 0, count: d)
        for row in X { for j in 0..<d { let c = row[j] - means[j]; scales[j] += c * c } }
        for j in 0..<d {
            let sd = (scales[j] / Double(n)).squareRoot()
            scales[j] = max(sd, minScales?[j] ?? 1e-9, 1e-9)
        }

        let yMean = y.reduce(0, +) / Double(n)

        // Normal equations: (ZᵀZ + λnI) w = Zᵀ(y - ȳ)
        var A = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var b = [Double](repeating: 0, count: d)
        var z = [Double](repeating: 0, count: d)
        for (row, target) in zip(X, y) {
            for j in 0..<d { z[j] = (row[j] - means[j]) / scales[j] }
            let r = target - yMean
            for j in 0..<d {
                b[j] += z[j] * r
                for k in j..<d { A[j][k] += z[j] * z[k] }
            }
        }
        for j in 0..<d {
            for k in 0..<j { A[j][k] = A[k][j] }
            A[j][j] += lambda * Double(n)
        }

        guard let w = solve(A, b) else { return nil }
        return RidgeRegression(means: means, scales: scales, weights: w, intercept: yMean)
    }

    public func predict(_ x: [Double]) -> Double {
        var out = intercept
        for j in 0..<weights.count {
            out += weights[j] * (x[j] - means[j]) / scales[j]
        }
        return out
    }

    /// Gaussian elimination with partial pivoting. Small systems only.
    public static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var A = matrix, b = rhs
        let n = b.count
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<max(col + 1, n) where abs(A[r][col]) > abs(A[pivot][col]) { pivot = r }
            guard abs(A[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { A.swapAt(pivot, col); b.swapAt(pivot, col) }
            for r in (col + 1)..<max(col + 1, n) {
                let f = A[r][col] / A[col][col]
                if f == 0 { continue }
                for c in col..<n { A[r][c] -= f * A[col][c] }
                b[r] -= f * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<max(r + 1, n) { s -= A[r][c] * x[c] }
            x[r] = s / A[r][r]
        }
        return x
    }
}
