import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class OverlayState {
    /// Gaze point in the overlay's local coordinates (top-left origin).
    var point: CGPoint?
    var dwellProgress = 0.0
    /// True while the gaze is actually driving the cursor.
    var driving = false
    /// Predicted target in local coordinates, with its label and probability.
    var target: (frame: CGRect, label: String, probability: Double)?
    /// True when the cursor is snapped to `target`.
    var snapped = false
}

/// A click-through, always-on-top window that draws the gaze dot and dwell ring.
@MainActor
final class OverlayController {
    private let state = OverlayState()
    private var panel: NSPanel?
    private var frame: CGRect = .null

    func update(point: CGPoint, on screenFrame: CGRect, dwellProgress: Double, driving: Bool,
                target: (frame: CGRect, label: String, probability: Double)? = nil, snapped: Bool = false) {
        if panel == nil || frame != screenFrame { makePanel(screenFrame) }
        state.point = CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
        state.dwellProgress = dwellProgress
        state.driving = driving
        state.target = target.map { ($0.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), $0.label, $0.probability) }
        state.snapped = snapped
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
    }

    func hide() {
        state.point = nil
        state.target = nil
        panel?.orderOut(nil)
    }

    private func makePanel(_ screenFrame: CGRect) {
        panel?.orderOut(nil)
        let rect = ScreenGeometry.appKitRect(fromCG: screenFrame)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel.setFrame(rect, display: true)
        self.panel = panel
        frame = screenFrame
    }
}

private struct OverlayView: View {
    let state: OverlayState

    var body: some View {
        ZStack {
            Color.clear
            if let t = state.target {
                let tint: Color = state.snapped ? .green : .yellow
                RoundedRectangle(cornerRadius: 5)
                    .stroke(tint.opacity(state.snapped ? 0.9 : 0.6),
                            style: StrokeStyle(lineWidth: 2, dash: state.snapped ? [] : [5, 4]))
                    .frame(width: t.frame.width + 8, height: t.frame.height + 8)
                    .position(x: t.frame.midX, y: t.frame.midY)
                Text("\(t.label.isEmpty ? "element" : t.label) \(Int((t.probability * 100).rounded()))%")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .fixedSize()
                    .position(x: t.frame.midX, y: max(t.frame.minY - 14, 8))
            }
            if let p = state.point {
                let tint: Color = state.driving ? .blue : .gray
                ZStack {
                    Circle().fill(tint.opacity(0.18))
                    Circle().stroke(tint.opacity(0.7), lineWidth: 2)
                    if state.dwellProgress > 0.05 {
                        Circle()
                            .trim(from: 0, to: state.dwellProgress)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(-6)
                    }
                }
                .frame(width: 30, height: 30)
                .position(p)
            }
        }
        .allowsHitTesting(false)
    }
}
