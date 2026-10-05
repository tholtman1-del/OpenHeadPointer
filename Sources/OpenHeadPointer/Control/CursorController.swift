import AppKit
import ApplicationServices

/// Moves and clicks the system cursor by posting HID events.
/// Posting events requires the Accessibility permission.
enum CursorController {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow accessibility" prompt (once per launch at most).
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Marks events this app posts, so its own cursor moves can be told apart from the touchpad or mouse.
    static let eventTag: Int64 = 0x4741_5A45 // "GAZE"

    /// True if `event` was posted by this app.
    static func isOwnEvent(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == eventTag
    }

    /// Current cursor position in global CoreGraphics coordinates (top-left origin).
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func move(to p: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
        event?.post(tap: .cghidEventTap)
    }

    static func click(at p: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event?.post(tap: .cghidEventTap)
        }
    }
}
