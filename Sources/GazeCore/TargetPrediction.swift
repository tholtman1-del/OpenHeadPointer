import Foundation
import CoreGraphics

/// A clickable on-screen element (button, link, menu item, …), in global CoreGraphics coordinates.
public struct Target: Sendable, Hashable {
    /// Identifies this element instance while it stays on screen.
    public var id: String
    public var frame: CGRect
    /// Accessibility role, e.g. "AXButton".
    public var role: String
    public var label: String
    /// Stable description used to learn click habits across sessions: app + role + label.
    public var signature: String

    public init(id: String, frame: CGRect, role: String, label: String, signature: String) {
        self.id = id
        self.frame = frame
        self.role = role
        self.label = label
        self.signature = signature
    }

    public var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// Infers which target the user intends to click, as a hidden Markov model:
///
/// - **Hidden state:** the intended target, or "none" (looking at nothing clickable).
/// - **Transition:** the user keeps their intent with probability `stay`. Otherwise they
///   switch to target *j* with probability proportional to its prior weight (element
///   type × learned click habits).
/// - **Emission:** how likely this gaze sample is, if the user is looking somewhere
///   inside target *j* and our estimate carries Gaussian error σ.
///
/// Evidence builds up over several frames, so a fixation on a small button beats a
/// single lucky frame near a big one, and the prediction doesn't flicker.
public struct TargetPredictor: Sendable {
    public var stay: Double
    /// Prior weight of the "none" state relative to a typical button (weight 1).
    public var noneWeight: Double
    /// Gaze density when looking at nothing in particular: uniform over the screen.
    public var backgroundDensity: Double

    public private(set) var targets: [Target] = []
    public private(set) var probabilities: [String: Double] = [:]
    public private(set) var noneProbability = 1.0

    public init(stay: Double = 0.9, noneWeight: Double = 1.0, screenArea: Double = 1440 * 900) {
        self.stay = stay
        self.noneWeight = noneWeight
        self.backgroundDensity = 1 / max(screenArea, 1)
    }

    /// Replaces the candidate set, keeping the belief for targets that are still present.
    public mutating func setTargets(_ new: [Target]) {
        var kept: [String: Double] = [:]
        for t in new { kept[t.id] = probabilities[t.id] ?? 0 }
        targets = new
        probabilities = kept
        normalize()
    }

    /// One forward step of the HMM.
    /// - Parameters:
    ///   - gaze: a raw (unfiltered) gaze estimate.
    ///   - sigma: its uncertainty in points (noise + calibration error).
    ///   - priors: prior weight per target id. Missing ids default to 1.
    public mutating func update(gaze: CGPoint, sigma: Double, priors: [String: Double] = [:]) {
        let weights = targets.map { priors[$0.id] ?? 1 }
        let totalWeight = weights.reduce(noneWeight, +)
        let jump = 1 - stay

        var post: [String: Double] = [:]
        var total = 0.0
        for (t, w) in zip(targets, weights) {
            let predicted = stay * (probabilities[t.id] ?? 0) + jump * w / totalWeight
            let p = predicted * Self.likelihood(gaze, in: t.frame, sigma: sigma)
            post[t.id] = p
            total += p
        }
        var none = (stay * noneProbability + jump * noneWeight / totalWeight) * backgroundDensity
        total += none

        guard total > 0, total.isFinite else {
            reset()
            return
        }
        for k in post.keys { post[k]! /= total }
        none /= total
        probabilities = post
        noneProbability = none
    }

    public var ranked: [(target: Target, probability: Double)] {
        targets.map { ($0, probabilities[$0.id] ?? 0) }.sorted { $0.1 > $1.1 }
    }

    public var best: (target: Target, probability: Double)? { ranked.first }

    public mutating func reset() {
        targets = []
        probabilities = [:]
        noneProbability = 1
    }

    private mutating func normalize() {
        let total = probabilities.values.reduce(noneProbability, +)
        guard total > 0 else { noneProbability = 1; return }
        for k in probabilities.keys { probabilities[k]! /= total }
        noneProbability /= total
    }

    /// Density of observing `g` when the true gaze is uniform over `rect` and our estimate
    /// adds isotropic Gaussian error σ:  ∏ₐₓᵢₛ [Φ((hi−g)/σ) − Φ((lo−g)/σ)] / (hi−lo).
    /// Small targets have a sharp, tall peak and large targets a broad, low one, so area is accounted for.
    public static func likelihood(_ g: CGPoint, in rect: CGRect, sigma: Double) -> Double {
        func axis(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
            let width = max(hi - lo, 1)
            return max(phi((hi - v) / sigma) - phi((lo - v) / sigma), 0) / width
        }
        return axis(Double(g.x), Double(rect.minX), Double(rect.maxX))
            * axis(Double(g.y), Double(rect.minY), Double(rect.maxY))
    }

    static func phi(_ z: Double) -> Double { 0.5 * (1 + erf(z / 2.0.squareRoot())) }
}

/// Prior over targets: element type × how often this user clicks this element.
public struct TargetPriors: Codable, Sendable {
    struct Entry: Codable, Sendable {
        var count: Double
        var last: Date
    }

    private var history: [String: Entry] = [:]
    public static let halfLifeDays = 30.0
    static let maxEntries = 3000

    public init() {}

    public static func roleWeight(_ role: String) -> Double {
        switch role {
        case "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXDockItem", "AXTab": 1.0
        case "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXComboBox",
             "AXDisclosureTriangle": 0.9
        case "AXTextField", "AXTextArea", "AXSearchField": 0.7
        case "AXCell", "AXRow", "AXOutlineRow", "AXImage": 0.5
        default: 0.4
        }
    }

    /// Clicks decay with a 30-day half-life, so old habits fade.
    public func clickCount(_ signature: String, now: Date = Date()) -> Double {
        guard let e = history[signature] else { return 0 }
        let days = now.timeIntervalSince(e.last) / 86_400
        return e.count * pow(0.5, days / Self.halfLifeDays)
    }

    public func weight(for target: Target, now: Date = Date()) -> Double {
        Self.roleWeight(target.role) * (1 + log1p(clickCount(target.signature, now: now)))
    }

    public mutating func recordClick(_ signature: String, now: Date = Date()) {
        history[signature] = Entry(count: clickCount(signature, now: now) + 1, last: now)
        if history.count > Self.maxEntries {
            // Forget the least recently used half.
            let keep = history.sorted { $0.value.last > $1.value.last }.prefix(Self.maxEntries / 2)
            history = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    public var count: Int { history.count }
}
