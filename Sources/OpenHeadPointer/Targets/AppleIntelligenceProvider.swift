import Foundation
import GazeCore

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct ClickRanking {
    @Guide(description: "The up to 5 most likely elements, most likely first")
    var picks: [ClickPick]
}

@available(macOS 26.0, *)
@Generable
struct ClickPick {
    @Guide(description: "The element's label exactly as listed, for example e3")
    var label: String
    @Guide(description: "Chance in percent (0 to 100) that this is the next click")
    var percent: Int
}

/// Apple's on-device foundation model (Apple Intelligence, macOS 26+): free, private, offline.
/// Its percentages are not trained to be calibrated, so expect a weak prior.
/// The scoreboard shows how much weaker in practice.
@available(macOS 26.0, *)
struct AppleIntelligenceProvider: SemanticPriorProvider {
    var id: String { "apple" }
    var displayName: String { "Apple on-device model" }

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func predict(_ query: SemanticQuery) async throws -> SemanticPrediction {
        let start = Date()
        let session = LanguageModelSession(instructions: """
            You predict which user-interface element a person will click next, given the app context. \
            Give honest, calibrated percentages: spread them out when unsure.
            """)
        let elements = query.criteria
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
        let c = query.context
        let prompt = """
            App: \(c.app)
            Window: \(c.window ?? "unknown")
            Focused element: \(c.focusedElement ?? "none")
            Recent clicks (oldest first): \(c.recentClicks.isEmpty ? "none" : c.recentClicks.joined(separator: "; "))

            Elements:
            \(elements)
            """
        let response = try await session.respond(to: prompt, generating: ClickRanking.self)

        // Picked labels get their stated share; the leftover mass is spread over the rest.
        var picks: [String: Double] = [:]
        for pick in response.content.picks where query.criteria[pick.label] != nil {
            picks[pick.label] = Double(min(max(pick.percent, 0), 100)) / 100
        }
        let stated = picks.values.reduce(0, +)
        if stated > 1 { for k in picks.keys { picks[k]! /= stated } }
        let rest = query.criteria.keys.filter { picks[$0] == nil }
        let leftover = max(0, 1 - picks.values.reduce(0, +))
        for label in rest { picks[label] = leftover / Double(rest.count) }

        return SemanticPrediction(probabilities: query.targetProbabilities(picks),
                                  latency: Date().timeIntervalSince(start))
    }
}
#endif

enum SemanticProviders {
    static var appleAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleIntelligenceProvider.isAvailable }
        #endif
        return false
    }

    static func make(id: String) -> (any SemanticPriorProvider)? {
        switch id {
        case "apple":
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), AppleIntelligenceProvider.isAvailable { return AppleIntelligenceProvider() }
            #endif
            return nil
        default:
            return nil
        }
    }
}
