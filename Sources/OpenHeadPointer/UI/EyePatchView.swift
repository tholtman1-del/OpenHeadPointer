import AppKit
import SwiftUI

/// One eye at the camera's native resolution, blown up with hard pixel edges, so you see
/// exactly what the tracker sees, with everything it derived drawn on top.
struct EyePatchView: View {
    let patch: EyePatch
    let title: String
    var showMask: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ZStack {
                if let image = Self.render(patch, mask: showMask) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                }
                Canvas { ctx, size in
                    let sx = size.width / CGFloat(patch.width), sy = size.height / CGFloat(patch.height)
                    func p(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x * sx, y: v.y * sy) }
                    func closed(_ pts: [CGPoint]) -> Path {
                        var path = Path()
                        path.addLines(pts.map(p))
                        path.closeSubpath()
                        return path
                    }
                    if patch.outline.count > 2 {
                        ctx.stroke(closed(patch.outline), with: .color(.cyan), lineWidth: 1.5)
                    }
                    if patch.searchArea.count > 2 {
                        ctx.stroke(closed(patch.searchArea), with: .color(.white.opacity(0.6)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    if patch.corners.count == 2 {
                        var axis = Path()
                        axis.move(to: p(patch.corners[0]))
                        axis.addLine(to: p(patch.corners[1]))
                        ctx.stroke(axis, with: .color(.pink.opacity(0.6)), lineWidth: 1)
                        for c in patch.corners {
                            let q = p(c)
                            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 4, y: q.y - 4, width: 8, height: 8)), with: .color(.pink))
                        }
                    }
                    if let v = patch.visionPupil {
                        let q = p(v)
                        ctx.stroke(Path(ellipseIn: CGRect(x: q.x - 7, y: q.y - 7, width: 14, height: 14)),
                                   with: .color(.yellow), lineWidth: 2)
                    }
                    let q = p(patch.iris)
                    var cross = Path()
                    cross.move(to: CGPoint(x: q.x - 10, y: q.y)); cross.addLine(to: CGPoint(x: q.x + 10, y: q.y))
                    cross.move(to: CGPoint(x: q.x, y: q.y - 10)); cross.addLine(to: CGPoint(x: q.x, y: q.y + 10))
                    ctx.stroke(cross, with: .color(.green), lineWidth: 2.5)
                }
            }
            .aspectRatio(CGFloat(patch.width) / CGFloat(patch.height), contentMode: .fit)
            .scaleEffect(x: -1, y: 1) // mirrored, like the camera view
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(String(format: "%d×%d px · eye %.0f px wide · openness %.2f",
                        patch.width, patch.height, patch.eyeWidth, patch.openness))
            Text(String(format: "iris offset x %+.3f  y %+.3f · brightness %.0f · contrast %.0f",
                        patch.irisOffset.x, patch.irisOffset.y, patch.brightness, patch.contrast))
            if let j = patch.irisJitter {
                Text(String(format: "iris steadiness ±%.2f px over the last second%@", j,
                            j < 0.6 ? " (good)" : (j < 1.5 ? "" : ": unsteady")))
                    .foregroundStyle(j < 1.5 ? Color.secondary : Color.orange)
            }
            ForEach(warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
    }

    /// Plain-language hints for the most common reasons tracking is poor.
    private var warnings: [String] {
        var out: [String] = []
        if patch.eyeWidth > 0, patch.eyeWidth < 28 {
            out.append("Eye is only \(Int(patch.eyeWidth)) px wide. Sit closer to the camera.")
        }
        if patch.brightness < 45 { out.append("Too dark. Add light in front of you.") }
        if patch.brightness > 200 { out.append("Overexposed. Reduce direct light on your face.") }
        if patch.contrast < 35 { out.append("Low contrast: flat light or a bright window behind you.") }
        if patch.openness > 0, patch.openness < 0.15 { out.append("Eye looks closed or very narrow.") }
        if let v = patch.visionPupil, patch.eyeWidth > 0,
           hypot(v.x - patch.iris.x, v.y - patch.iris.y) > patch.eyeWidth * 0.25 {
            out.append("Dark-pixel iris and Vision's pupil disagree. Shadows or lashes may be fooling the detector.")
        }
        return out
    }

    /// Grayscale pixels, with the pixels counted as iris tinted red.
    static func render(_ patch: EyePatch, mask: Bool) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: patch.width * patch.height * 4)
        for i in 0..<patch.pixels.count {
            let v = patch.pixels[i]
            if mask, patch.irisMask[i] {
                rgba[i * 4] = UInt8(min(255, Int(v) / 2 + 140))
                rgba[i * 4 + 1] = v / 3
                rgba[i * 4 + 2] = v / 3
            } else {
                rgba[i * 4] = v
                rgba[i * 4 + 1] = v
                rgba[i * 4 + 2] = v
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: patch.width, height: patch.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: patch.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Hosts the debug view in a plain AppKit window, so it can be opened from a hotkey or at launch.
@MainActor
final class DebugWindowController: NSObject, NSWindowDelegate {
    static let shared = DebugWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "OpenHeadPointer · Camera Debug"
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 640, height: 480)
            w.contentView = NSHostingView(rootView: DebugView(model: AppModel.shared))
            w.delegate = self
            if let visible = NSScreen.main?.visibleFrame, visible.height < 900 {
                w.setContentSize(NSSize(width: 880, height: visible.height - 40))
            }
            w.center()
            window = w
        }
        AppModel.shared.setDebugWindowOpen(true)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.setDebugWindowOpen(false)
    }
}
