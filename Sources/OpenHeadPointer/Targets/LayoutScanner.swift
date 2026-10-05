import AppKit
import ApplicationServices
import GazeCore

/// The clickable elements of the frontmost window plus the context the semantic model needs.
struct WindowLayout: Sendable {
    var pid: pid_t
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var windowFrame: CGRect?
    var focusedElement: String?
    var targets: [Target]
}

/// Reads on-screen UI through the Accessibility API. AX calls are synchronous IPC into other
/// apps (and an unresponsive app can stall them), so everything runs on a private queue
/// with a short messaging timeout.
final class LayoutScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "gaze.accessibility", qos: .userInitiated)
    private let systemWide = AXUIElementCreateSystemWide()
    private let ownPID = getpid()
    private var appElements: [pid_t: AXUIElement] = [:]
    private var bundleIDs: [pid_t: String] = [:]

    static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXComboBox", "AXTextField", "AXTextArea", "AXSearchField",
        "AXDisclosureTriangle", "AXDockItem", "AXSlider", "AXIncrementor", "AXColorWell",
    ]
    /// Clickable only if they expose a press action (common for web content).
    static let maybeClickableRoles: Set<String> = ["AXGroup", "AXImage", "AXStaticText", "AXCell", "AXRow"]
    /// Clickable roles whose children can also be clickable (e.g. buttons inside list rows).
    static let descendInto: Set<String> = ["AXRow", "AXCell", "AXGroup"]
    static let stopRoles: Set<String> = ["AXWindow", "AXApplication", "AXWebArea", "AXScrollArea", "AXSplitGroup"]

    init() {
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
    }

    // MARK: Public API (completions run on the scanner queue)

    func scanWindow(of app: NSRunningApplication, completion: @escaping @Sendable (WindowLayout?) -> Void) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "App"
        let bundle = app.bundleIdentifier ?? name
        queue.async { [self] in
            bundleIDs[pid] = bundle
            completion(windowLayout(pid: pid, appName: name, bundleID: bundle))
        }
    }

    func scanNear(_ centre: CGPoint, radius: Double, completion: @escaping @Sendable ([Target]) -> Void) {
        queue.async { [self] in
            let windows = windowsFrontToBack()
            var found: [String: Target] = [:]
            let steps: [Double] = [0, -0.5, 0.5, -1, 1]
            for dy in steps {
                for dx in steps where dx * dx + dy * dy <= 1.01 {
                    let p = CGPoint(x: centre.x + dx * radius, y: centre.y + dy * radius)
                    if let t = target(at: p, windows: windows) { found[t.id] = t }
                }
            }
            completion(Array(found.values))
        }
    }

    func identify(at point: CGPoint, completion: @escaping @Sendable (Target?) -> Void) {
        queue.async { [self] in
            completion(target(at: point, windows: windowsFrontToBack()))
        }
    }

    // MARK: Whole-window scan

    private func windowLayout(pid: pid_t, appName: String, bundleID: String) -> WindowLayout? {
        guard pid != ownPID else { return nil }
        let app = appElement(pid)
        guard let window = AX.element(app, "AXFocusedWindow") ?? AX.element(app, "AXMainWindow") else {
            return nil
        }
        let windowInfo = AX.info(window)
        let windowFrame = windowInfo?.frame
        let visible = windowFrame ?? .infinite

        var targets: [Target] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var head = 0
        let deadline = Date().addingTimeInterval(0.3)
        while head < queue.count, head < 2500, targets.count < 200, Date() < deadline {
            let (element, depth) = queue[head]
            head += 1
            guard let info = AX.info(element) else { continue }
            if let frame = info.frame, !frame.intersects(visible) || frame.width < 2 || frame.height < 2 {
                continue // scrolled out of view: skip the whole subtree
            }
            if depth > 0, let t = makeTarget(element, info, pid: pid, bundleID: bundleID, limitArea: visible.area * 0.25) {
                targets.append(t)
                if !Self.descendInto.contains(info.role) { continue }
            }
            if depth < 40 {
                for child in info.children { queue.append((child, depth + 1)) }
            }
        }

        var focused: String?
        if let f = AX.element(app, "AXFocusedUIElement"), let info = AX.info(f) {
            focused = SemanticQuery.describe(Target(id: "", frame: .zero, role: info.role,
                                                    label: info.label, signature: ""), in: nil)
        }
        return WindowLayout(pid: pid, appName: appName, bundleID: bundleID, windowTitle: windowInfo?.title,
                            windowFrame: windowFrame, focusedElement: focused, targets: targets)
    }

    // MARK: Point hit-testing

    /// Our own overlay covers the screen, so a system-wide hit test could return it. Instead,
    /// find the topmost *other* window under the point and hit-test inside that app.
    private func target(at p: CGPoint, windows: [(pid: pid_t, bounds: CGRect)]) -> Target? {
        var hit: AXUIElement?
        var pid: pid_t = 0
        if let w = windows.first(where: { $0.bounds.contains(p) }) {
            pid = w.pid
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(appElement(w.pid), Float(p.x), Float(p.y), &element) == .success {
                hit = element
            }
        }
        if hit == nil {
            var element: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &element) == .success,
               let element {
                AXUIElementGetPid(element, &pid)
                hit = element
            }
        }
        guard var element = hit, pid != ownPID else { return nil }
        let bundle = bundleID(pid)
        let screenArea = (NSScreen.screens.first?.frame.area ?? 1_300_000)

        // Walk up to the nearest clickable ancestor (the hit is often a label inside a button).
        for _ in 0..<8 {
            guard let info = AX.info(element) else { return nil }
            if Self.stopRoles.contains(info.role) { return nil }
            if let t = makeTarget(element, info, pid: pid, bundleID: bundle, limitArea: screenArea * 0.25) {
                return t
            }
            guard let parent = AX.element(element, "AXParent") else { return nil }
            element = parent
        }
        return nil
    }

    private func windowsFrontToBack() -> [(pid: pid_t, bounds: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return nil }
            return (pid, bounds)
        }
    }

    // MARK: Helpers

    private func makeTarget(_ element: AXUIElement, _ info: AX.Info, pid: pid_t, bundleID: String,
                            limitArea: CGFloat) -> Target? {
        guard let frame = info.frame, frame.width >= 3, frame.height >= 3, frame.area <= limitArea else { return nil }
        let clickable = Self.clickableRoles.contains(info.role)
            || (Self.maybeClickableRoles.contains(info.role) && AX.actions(element).contains("AXPress"))
        guard clickable else { return nil }
        let label = String(info.label.prefix(80))
        return Target(id: "\(pid)-\(CFHash(element))", frame: frame, role: info.role, label: label,
                      signature: "\(bundleID)|\(info.role)|\(label)")
    }

    private func appElement(_ pid: pid_t) -> AXUIElement {
        if let e = appElements[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, 0.1)
        appElements[pid] = e
        return e
    }

    private func bundleID(_ pid: pid_t) -> String {
        if let b = bundleIDs[pid] { return b }
        let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid\(pid)"
        bundleIDs[pid] = b
        return b
    }
}

private extension CGRect {
    var area: CGFloat { isInfinite || isNull ? .greatestFiniteMagnitude : width * height }
}

/// Thin wrappers over the C Accessibility API.
enum AX {
    struct Info {
        var role: String
        var title: String?
        var frame: CGRect?
        var children: [AXUIElement]
        var label: String
    }

    private static let infoAttributes = [
        "AXRole", "AXTitle", "AXDescription", "AXPlaceholderValue", "AXHelp",
        "AXPosition", "AXSize", "AXChildren",
    ] as CFArray

    /// Fetches the common attributes in a single IPC round trip.
    static func info(_ e: AXUIElement) -> Info? {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, infoAttributes, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let array = values as? [AnyObject], array.count == 8,
              let role = clean(array[0]) as? String
        else { return nil }

        let title = clean(array[1]) as? String
        let label = [title, clean(array[2]) as? String, clean(array[3]) as? String, clean(array[4]) as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        var frame: CGRect?
        if let pos = clean(array[5]), let size = clean(array[6]),
           CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var p = CGPoint.zero, s = CGSize.zero
            if AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) {
                frame = CGRect(origin: p, size: s)
            }
        }
        let children = (clean(array[7]) as? [AXUIElement]) ?? []
        return Info(role: role, title: title, frame: frame, children: children, label: label)
    }

    static func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// Missing attributes come back as an AXValue of type `.axError` (or NSNull).
    private static func clean(_ v: AnyObject) -> AnyObject? {
        if v is NSNull { return nil }
        if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
        return v
    }
}
