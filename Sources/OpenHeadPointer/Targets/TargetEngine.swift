import AppKit
import GazeCore
import Observation

struct TargetSettings: Equatable {
    var learnFromClicks = true
    /// "none" or "apple": the provider whose prior steers the engine.
    var provider = "none"
    /// 0 = ignore the semantic model, 1 = take its probabilities at face value.
    var trust = 0.7
    /// Also query the other available providers in the background, for the scoreboard only.
    var shadowEvaluate = true
}

/// The probabilistic layout: every clickable element near the gaze is a hypothesis.
///
///     P(target | gaze, context)  ∝  P(gaze | target)  ×  P(target | context)
///                                    └ eye tracker ┘     └ semantic model × click habits ┘
///
/// The gaze term updates every frame (cheap maths). The context term changes only when the
/// layout changes, so a 100–500 ms model call never sits in the 30 fps loop.
@MainActor @Observable
final class TargetEngine {
    struct Ranked: Identifiable {
        let target: Target
        let probability: Double
        let semantic: Double?
        var id: String { target.id }
    }

    private(set) var ranked: [Ranked] = []
    private(set) var semanticStatus = "Off"
    private(set) var layoutSummary = "No layout yet"
    private(set) var scoreboard = PriorScoreboard()
    private(set) var learnedCount = 0

    @ObservationIgnored var settings = TargetSettings() {
        didSet {
            if settings.provider != oldValue.provider {
                semantic = [:]
                lastSemanticKey = [:]
                semanticBackoffUntil = [:]
                semanticStatus = settings.provider == "none" ? "Off" : "Waiting for a layout…"
            }
        }
    }

    @ObservationIgnored private let scanner = LayoutScanner()
    @ObservationIgnored private var predictor = TargetPredictor()
    @ObservationIgnored private var priors = TargetPriors()
    @ObservationIgnored private var layout: WindowLayout?
    @ObservationIgnored private var local: [String: (target: Target, seen: Double)] = [:]
    /// Active provider's prediction, keyed by target id.
    @ObservationIgnored private var semantic: [String: Double] = [:]
    @ObservationIgnored private var semanticChoices = 0
    /// Latest prediction per provider, kept to score against the next real click.
    @ObservationIgnored private var lastPredictions: [String: (candidates: Set<String>, probabilities: [String: Double])] = [:]
    @ObservationIgnored private var recentClicks: [(description: String, bundle: String, time: Date)] = []
    @ObservationIgnored private var syntheticClicks: [(point: CGPoint, time: Double)] = []

    @ObservationIgnored private var layoutBusy = false
    @ObservationIgnored private var localBusy = false
    @ObservationIgnored private var lastLayoutScan = -100.0
    @ObservationIgnored private var lastLocalScan = -100.0
    @ObservationIgnored private var lastLocalPoint: CGPoint?
    @ObservationIgnored private var lastRankedPublish = 0.0
    @ObservationIgnored private var semanticBusy: Set<String> = []
    @ObservationIgnored private var lastSemanticKey: [String: Int] = [:]
    @ObservationIgnored private var semanticBackoffUntil: [String: Date] = [:]
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init() {
        if let data = try? Data(contentsOf: Self.url("click-history.json")),
           let saved = try? JSONDecoder().decode(TargetPriors.self, from: data) {
            priors = saved
        }
        if let data = try? Data(contentsOf: Self.url("prior-scoreboard.json")),
           let saved = try? JSONDecoder().decode(PriorScoreboard.self, from: data) {
            scoreboard = saved
        }
        learnedCount = priors.count
    }

    func start() {
        guard clickMonitor == nil else { return }
        // Every real click teaches the habit prior and scores the semantic models.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = CursorController.location
            MainActor.assumeIsolated { self?.handleClick(at: point) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastLayoutScan = -100 }
        }
    }

    // MARK: Per-frame update

    /// - Parameters:
    ///   - raw: this frame's unfiltered gaze estimate (fresh evidence).
    ///   - filtered: the fixation-filtered gaze (stable anchor for scanning).
    ///   - sigma: gaze uncertainty in points.
    func update(raw: CGPoint, filtered: CGPoint, sigma: Double, now: Double) -> (target: Target, probability: Double)? {
        scheduleScans(around: filtered, sigma: sigma, now: now)

        let reach = 3.5 * sigma + 20
        var candidates: [Target] = []
        var seen = Set<String>()
        let fresh = local.values.filter { now - $0.seen < 3 }.map(\.target)
        for t in (layout?.targets ?? []) + fresh where !seen.contains(t.id) && distance(filtered, t.frame) <= reach {
            candidates.append(t)
            seen.insert(t.id)
        }
        predictor.setTargets(candidates)

        var weights: [String: Double] = [:]
        for t in candidates {
            weights[t.id] = priors.weight(for: t)
                * PriorBlend.factor(probability: semantic[t.id], choices: semanticChoices, trust: settings.trust)
        }
        predictor.update(gaze: raw, sigma: sigma, priors: weights)

        if now - lastRankedPublish > 0.1 {
            lastRankedPublish = now
            ranked = predictor.ranked.prefix(4).map { Ranked(target: $0.target, probability: $0.probability,
                                                             semantic: semantic[$0.target.id]) }
        }
        return predictor.best
    }

    func reset() {
        predictor.reset()
        if !ranked.isEmpty { ranked = [] }
    }

    /// Lets the engine tell its own gaze clicks apart from real mouse clicks.
    func noteSyntheticClick(at p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        syntheticClicks = syntheticClicks.filter { now - $0.time < 1 } + [(p, now)]
    }

    func forgetHistory() {
        priors = TargetPriors()
        scoreboard.reset()
        learnedCount = 0
        recentClicks = []
        save()
    }

    // MARK: Scanning

    private func scheduleScans(around p: CGPoint, sigma: Double, now: Double) {
        if !layoutBusy, now - lastLayoutScan > 2,
           let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != getpid() {
            layoutBusy = true
            lastLayoutScan = now
            scanner.scanWindow(of: app) { layout in
                Task { @MainActor in self.applyLayout(layout) }
            }
        }

        let moved = lastLocalPoint.map { hypot($0.x - p.x, $0.y - p.y) > max(40, sigma) } ?? true
        if !localBusy, moved || now - lastLocalScan > 0.6 {
            localBusy = true
            lastLocalScan = now
            lastLocalPoint = p
            scanner.scanNear(p, radius: min(max(2.5 * sigma, 40), 220)) { targets in
                Task { @MainActor in
                    let t = ProcessInfo.processInfo.systemUptime
                    self.localBusy = false
                    for target in targets { self.local[target.id] = (target, t) }
                    self.local = self.local.filter { t - $0.value.seen < 5 }
                }
            }
        }
    }

    private func applyLayout(_ new: WindowLayout?) {
        layoutBusy = false
        layout = new
        if let new {
            layoutSummary = "\(new.appName) · \(new.targets.count) clickable elements"
        }
        requestSemanticPriors()
    }

    // MARK: Semantic priors

    private func requestSemanticPriors() {
        guard let layout, layout.targets.count >= 2 else { return }
        var ids = [settings.provider]
        if settings.shadowEvaluate { ids += ["apple"].filter { $0 != settings.provider } }
        let providers = ids.compactMap { SemanticProviders.make(id: $0) }
        guard !providers.isEmpty else {
            if settings.provider == "apple" { semanticStatus = "Apple Intelligence isn't available on this Mac" }
            return
        }

        // Most plausible elements first (by habit), capped, then in reading order for the model.
        let chosen = layout.targets
            .sorted { priors.weight(for: $0) > priors.weight(for: $1) }
            .prefix(60)
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        let clicks = recentClicks.filter { $0.bundle == layout.bundleID }.suffix(5).map {
            "\($0.description) (\(Int(Date().timeIntervalSince($0.time))) s ago)"
        }
        let context = ClickContext(app: layout.appName, window: layout.windowTitle,
                                   focusedElement: layout.focusedElement, recentClicks: Array(clicks))
        let query = SemanticQuery(context: context, targets: Array(chosen), window: layout.windowFrame)

        var hasher = Hasher()
        hasher.combine(layout.bundleID)
        hasher.combine(layout.windowTitle)
        hasher.combine(chosen.map(\.signature))
        hasher.combine(clicks)
        let key = hasher.finalize()

        for provider in providers {
            let pid = provider.id
            guard lastSemanticKey[pid] != key, !semanticBusy.contains(pid),
                  Date() >= semanticBackoffUntil[pid, default: .distantPast]
            else { continue }
            lastSemanticKey[pid] = key
            semanticBusy.insert(pid)
            let active = pid == settings.provider
            Task {
                do {
                    let prediction = try await provider.predict(query)
                    semanticBusy.remove(pid)
                    scoreboard.recordLatency(pid, prediction.latency)
                    lastPredictions[pid] = (Set(query.labelToTarget.values), prediction.probabilities)
                    if active, pid == settings.provider {
                        semantic = prediction.probabilities
                        semanticChoices = query.labelToTarget.count
                        let top = prediction.probabilities.max { $0.value < $1.value }
                        let topLabel = top.flatMap { id in chosen.first { $0.id == id.key } }?.label ?? "–"
                        semanticStatus = "\(provider.displayName) · \(Int(prediction.latency * 1000)) ms · "
                            + "top: \(topLabel.isEmpty ? "unlabeled" : topLabel) \(Int((top?.value ?? 0) * 100))%"
                    }
                } catch {
                    semanticBusy.remove(pid)
                    semanticBackoffUntil[pid] = Date().addingTimeInterval(15)
                    lastSemanticKey[pid] = nil
                    if active { semanticStatus = "\(provider.displayName): \(error.localizedDescription)" }
                }
            }
        }
    }

    // MARK: Learning from clicks

    private func handleClick(at p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let synthetic = syntheticClicks.contains { now - $0.time < 0.5 && hypot($0.point.x - p.x, $0.point.y - p.y) < 4 }
        scanner.identify(at: p) { target in
            Task { @MainActor in self.recordClick(target, synthetic: synthetic) }
        }
    }

    private func recordClick(_ target: Target?, synthetic: Bool) {
        guard let target else { return }
        if !synthetic {
            for (pid, p) in lastPredictions {
                scoreboard.record(pid, probabilities: p.probabilities, candidates: p.candidates, clicked: target.id)
            }
            // Baseline: click habits alone. A semantic model must beat this to earn its place.
            if let layout {
                let ids = Set(layout.targets.map(\.id))
                var habits: [String: Double] = [:]
                for t in layout.targets { habits[t.id] = priors.weight(for: t) }
                scoreboard.record("habits", probabilities: habits, candidates: ids, clicked: target.id)
            }
        }
        if settings.learnFromClicks {
            priors.recordClick(target.signature)
            learnedCount = priors.count
        }
        let bundle = String(target.signature.split(separator: "|").first ?? "")
        recentClicks.append((SemanticQuery.describe(target, in: nil), bundle, Date()))
        if recentClicks.count > 20 { recentClicks.removeFirst() }
        lastPredictions = [:]
        lastLayoutScan = ProcessInfo.processInfo.systemUptime - 1.6 // rescan shortly: clicks change layouts
        save()
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(priors) {
            try? data.write(to: Self.url("click-history.json"), options: .atomic)
        }
        if let data = try? JSONEncoder().encode(scoreboard) {
            try? data.write(to: Self.url("prior-scoreboard.json"), options: .atomic)
        }
    }

    private static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenHeadPointer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> Double {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(Double(dx), Double(dy))
    }
}
