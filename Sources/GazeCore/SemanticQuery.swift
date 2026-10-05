import Foundation
import CoreGraphics

/// What the semantic model sees: the app context, never the gaze. Keeping gaze out
/// means the semantic prior and the gaze likelihood are independent evidence, so the
/// engine can simply multiply them.
public struct ClickContext: Codable, Sendable, Equatable {
    public var task = "Predict which on-screen element the user will click next. The user operates the pointer with their eyes."
    public var app: String
    public var window: String?
    public var focusedElement: String?
    /// Most recent last, e.g. "button \"Compose\" (12 s ago)".
    public var recentClicks: [String]

    public init(app: String, window: String?, focusedElement: String?, recentClicks: [String]) {
        self.app = app
        self.window = window
        self.focusedElement = focusedElement
        self.recentClicks = recentClicks
    }
}

/// Turns a layout into a multiple-choice question whose labels are element ids.
public struct SemanticQuery: Sendable {
    public static let questionName = "next_click"
    public static let otherLabel = "other"

    public var context: ClickContext
    /// Choice label → description shown to the model.
    public var criteria: [String: String]
    /// Choice label → `Target.id`.
    public var labelToTarget: [String: String]

    public init(context: ClickContext, targets: [Target], window: CGRect?, limit: Int = 60) {
        self.context = context
        var criteria: [String: String] = [:]
        var map: [String: String] = [:]
        for (i, t) in targets.prefix(limit).enumerated() {
            let label = "e\(i + 1)"
            criteria[label] = Self.describe(t, in: window)
            map[label] = t.id
        }
        criteria[Self.otherLabel] = "Something not listed, or no click at all"
        self.criteria = criteria
        labelToTarget = map
    }

    public static func describe(_ t: Target, in window: CGRect?) -> String {
        let kind = roleName(t.role)
        let name = t.label.isEmpty ? "(unlabeled)" : "\"\(t.label)\""
        guard let window else { return "\(kind) \(name)" }
        return "\(kind) \(name), \(region(of: t.frame, in: window))"
    }

    /// Coarse position in the window, e.g. "bottom right". Layout position is strong semantic evidence.
    public static func region(of rect: CGRect, in window: CGRect) -> String {
        guard window.width > 0, window.height > 0 else { return "" }
        let x = (rect.midX - window.minX) / window.width
        let y = (rect.midY - window.minY) / window.height
        let v = y < 0.2 ? "top" : (y > 0.8 ? "bottom" : "middle")
        let h = x < 0.33 ? "left" : (x > 0.67 ? "right" : "centre")
        return v == "middle" && h == "centre" ? "centre" : "\(v) \(h)"
    }

    static func roleName(_ role: String) -> String {
        switch role {
        case "AXButton": "button"
        case "AXLink": "link"
        case "AXMenuItem": "menu item"
        case "AXMenuBarItem": "menu"
        case "AXCheckBox": "checkbox"
        case "AXRadioButton": "tab/option"
        case "AXPopUpButton", "AXMenuButton": "pop-up menu"
        case "AXComboBox": "combo box"
        case "AXTextField", "AXSearchField": "text field"
        case "AXTextArea": "text area"
        case "AXDisclosureTriangle": "disclosure triangle"
        case "AXRow", "AXOutlineRow": "list row"
        case "AXCell": "cell"
        case "AXDockItem": "Dock item"
        default: role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }

    /// Maps the model's distribution over labels back to target ids (dropping "other").
    public func targetProbabilities(_ labelProbabilities: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (label, p) in labelProbabilities {
            if let id = labelToTarget[label] { out[id] = p }
        }
        return out
    }
}

/// Combines priors by geometric pooling: weight = local × (n·p)^trust.
/// A uniform semantic answer (p = 1/n) leaves the local prior unchanged; trust 0 ignores the model.
public enum PriorBlend {
    public static func factor(probability p: Double?, choices n: Int, trust: Double) -> Double {
        guard let p, n > 0, trust > 0 else { return 1 }
        let floor = 0.05 / Double(n) // calibrated models still deserve a little doubt
        let f = pow(max(p, floor) * Double(n), trust)
        return min(max(f, 0.02), 50)
    }
}
