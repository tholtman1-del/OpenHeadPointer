import AppKit
import GazeCore
import Observation
import SwiftUI

/// Drives one calibration run: shows targets in turn and collects samples while the user looks at each.
@MainActor @Observable
final class CalibrationSession {
    enum Mode { case full, recenter }

    enum Phase: Equatable {
        case intro
        case moving
        case settling
        case collecting
        case result(message: String, success: Bool)
    }

    static let moveDuration = 0.45
    static let settleDuration = 0.55
    static let collectDuration = 1.0
    static let resultDuration = 3.0

    let mode: Mode
    /// The screen being calibrated, in global CoreGraphics coordinates.
    let screenFrame: CGRect
    /// Targets in normalized screen coordinates (top-left origin).
    let targets: [CGPoint]

    private(set) var index = 0
    private(set) var phase: Phase = .intro
    private(set) var progress = 0.0
    private(set) var faceVisible = false

    /// Called once all targets are done. Returns the message shown to the user.
    @ObservationIgnored var onCollected: (([[GazeSample]]) -> (message: String, success: Bool))?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored private(set) var samples: [[GazeSample]]
    @ObservationIgnored private var phaseStart = 0.0

    init(mode: Mode, screenFrame: CGRect) {
        self.mode = mode
        self.screenFrame = screenFrame
        switch mode {
        case .full:
            // 3×3 outer grid plus 4 inner points, in a snake order to keep eye movements short.
            let lo = 0.08, mid = 0.5, hi = 0.92, a = 0.29, b = 0.71
            targets = [
                CGPoint(x: lo, y: lo), CGPoint(x: mid, y: lo), CGPoint(x: hi, y: lo),
                CGPoint(x: b, y: a), CGPoint(x: a, y: a),
                CGPoint(x: lo, y: mid), CGPoint(x: mid, y: mid), CGPoint(x: hi, y: mid),
                CGPoint(x: b, y: b), CGPoint(x: a, y: b),
                CGPoint(x: lo, y: hi), CGPoint(x: mid, y: hi), CGPoint(x: hi, y: hi),
            ]
        case .recenter:
            targets = [CGPoint(x: 0.5, y: 0.5)]
        }
        samples = Array(repeating: [], count: targets.count)
    }

    func targetCG(_ i: Int) -> CGPoint {
        CGPoint(x: screenFrame.minX + targets[i].x * screenFrame.width,
                y: screenFrame.minY + targets[i].y * screenFrame.height)
    }

    var previousTarget: CGPoint { index > 0 ? targets[index - 1] : CGPoint(x: 0.5, y: 0.5) }

    func begin() {
        guard phase == .intro else { return }
        index = 0
        enter(.moving)
    }

    func cancel() {
        onClose?()
    }

    func noteFace(_ visible: Bool) {
        if faceVisible != visible { faceVisible = visible }
    }

    func add(_ sample: GazeSample, eyesClosed: Bool) {
        noteFace(true)
        guard phase == .collecting, !eyesClosed else { return }
        samples[index].append(sample)
    }

    func tick() {
        let elapsed = now - phaseStart
        switch phase {
        case .intro:
            break
        case .moving:
            progress = min(1, elapsed / Self.moveDuration)
            if elapsed >= Self.moveDuration { enter(.settling) }
        case .settling:
            progress = min(1, elapsed / Self.settleDuration)
            if elapsed >= Self.settleDuration { enter(.collecting) }
        case .collecting:
            progress = min(1, elapsed / Self.collectDuration)
            // If tracking dropped out, wait (up to 3×) for enough samples.
            let enough = samples[index].count >= 10 || elapsed >= Self.collectDuration * 3
            guard elapsed >= Self.collectDuration, enough else { return }
            if index + 1 < targets.count {
                index += 1
                enter(.moving)
            } else {
                let result = onCollected?(samples) ?? (message: "", success: false)
                enter(.result(message: result.message, success: result.success))
            }
        case .result:
            if elapsed >= Self.resultDuration { onClose?() }
        }
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    private func enter(_ next: Phase) {
        phase = next
        phaseStart = now
        progress = 0
    }
}

// MARK: - Window

private final class KeyWindow: NSWindow {
    var onKeyDown: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKeyDown?(event) }
}

@MainActor
final class CalibrationWindowController {
    private var window: KeyWindow?
    private var timer: Timer?

    func present(_ session: CalibrationSession, on screen: NSScreen) {
        close()
        let window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(white: 0.18, alpha: 1)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CalibrationView(session: session))
        window.setFrame(screen.frame, display: true)
        window.onKeyDown = { event in
            switch Int(event.keyCode) {
            case 53: session.cancel()            // Esc
            case 49, 36: session.begin()         // Space, Return
            default: break
            }
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSCursor.hide()
        self.window = window

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { session.tick() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if window != nil { NSCursor.unhide() }
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - View

private struct CalibrationView: View {
    let session: CalibrationSession

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(white: 0.18)
                switch session.phase {
                case .intro:
                    intro
                case .result(let message, let success):
                    VStack(spacing: 14) {
                        Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(success ? .green : .orange)
                        Text(message).font(.title2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: 560)
                default:
                    target(in: geo.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Text(session.mode == .full ? "Calibration" : "Recenter")
                .font(.largeTitle.bold())
            Text(session.mode == .full
                 ? "Follow the dot with your eyes and look at its centre until it shrinks away.\nKeep your head in its usual position. Moving only your eyes works best."
                 : "Look at the centre of the dot until it disappears.")
                .font(.title3)
                .multilineTextAlignment(.center)
            Label(session.faceVisible ? "Face detected" : "No face detected. Check the camera and lighting.",
                  systemImage: session.faceVisible ? "face.smiling" : "exclamationmark.triangle")
                .foregroundStyle(session.faceVisible ? .green : .orange)
            Text("Press Space to start · Esc to cancel")
                .font(.headline)
                .padding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 640)
    }

    private func target(in size: CGSize) -> some View {
        let to = session.targets[session.index]
        let from = session.previousTarget
        let t: Double = session.phase == .moving ? easeInOut(session.progress) : 1
        let p = CGPoint(x: (from.x + (to.x - from.x) * t) * size.width,
                        y: (from.y + (to.y - from.y) * t) * size.height)
        let radius: Double = switch session.phase {
        case .collecting: 18 - 12 * session.progress
        default: 18
        }
        return ZStack {
            Circle().fill(Color.white).frame(width: radius * 2, height: radius * 2)
            Circle().fill(Color.red).frame(width: 5, height: 5)
            if session.mode == .full {
                Text("\(session.index + 1)/\(session.targets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .offset(y: 34)
            }
        }
        .position(p)
    }

    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
}
