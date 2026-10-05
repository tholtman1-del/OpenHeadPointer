import Foundation

/// A model that estimates which element the user will click next from app context alone.
/// Implementations: Apple's on-device model, …
public protocol SemanticPriorProvider: Sendable {
    /// Stable key used for the scoreboard and settings.
    var id: String { get }
    var displayName: String { get }
    /// Returns P(next click = target) keyed by `Target.id`. Missing targets mean "no opinion".
    func predict(_ query: SemanticQuery) async throws -> SemanticPrediction
}

public struct SemanticPrediction: Sendable {
    public var probabilities: [String: Double]
    public var latency: TimeInterval

    public init(probabilities: [String: Double], latency: TimeInterval) {
        self.probabilities = probabilities
        self.latency = latency
    }
}

/// Scores priors against what the user actually clicked, so models can be compared on real use
/// instead of guesswork. Uses only clicks the gaze engine didn't make: a gaze click was
/// steered by the prior itself and would flatter it.
public struct PriorScoreboard: Codable, Sendable {
    public struct Stats: Codable, Sendable {
        public var clicks = 0
        /// Sum of −ln p(clicked element), with p renormalized over the candidates.
        public var logLoss = 0.0
        /// Sum of ln(n): the log-loss a uniform guess would get.
        public var uniformLogLoss = 0.0
        public var top1 = 0
        public var latency = 0.0
        public var latencySamples = 0

        /// Average bits of information per click beyond a uniform guess. Higher is better; 0 = useless.
        public var bitsGained: Double { clicks == 0 ? 0 : (uniformLogLoss - logLoss) / Double(clicks) / log(2) }
        public var top1Accuracy: Double { clicks == 0 ? 0 : Double(top1) / Double(clicks) }
        public var meanLatency: Double? { latencySamples == 0 ? nil : latency / Double(latencySamples) }
    }

    public private(set) var stats: [String: Stats] = [:]

    public init() {}

    /// - Parameters:
    ///   - probabilities: the provider's prediction for this layout, keyed by target id.
    ///   - candidates: ids of every element in the query.
    ///   - clicked: the id the user clicked. Clicks outside the candidate set are skipped.
    public mutating func record(_ provider: String, probabilities: [String: Double],
                                candidates: Set<String>, clicked: String) {
        guard candidates.count >= 2, candidates.contains(clicked) else { return }
        let n = Double(candidates.count)
        // Floor so a confident miss is penalized but can't produce an infinite loss.
        let floor = 0.01 / n
        let total = candidates.reduce(0.0) { $0 + max(probabilities[$1] ?? 0, floor) }
        let p = max(probabilities[clicked] ?? 0, floor) / total
        var s = stats[provider, default: Stats()]
        s.clicks += 1
        s.logLoss += -log(p)
        s.uniformLogLoss += log(n)
        if let best = candidates.max(by: { (probabilities[$0] ?? 0) < (probabilities[$1] ?? 0) }),
           best == clicked, (probabilities[clicked] ?? 0) > 0 {
            s.top1 += 1
        }
        stats[provider] = s
    }

    public mutating func recordLatency(_ provider: String, _ seconds: TimeInterval) {
        var s = stats[provider, default: Stats()]
        s.latency += seconds
        s.latencySamples += 1
        stats[provider] = s
    }

    public mutating func reset() {
        stats = [:]
    }
}
