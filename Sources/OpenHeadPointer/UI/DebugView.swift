import AVFoundation
import GazeCore
import SwiftUI

/// Live camera with the landmarks the tracker sees, plus the raw numbers it produces.
/// Use it to check lighting, framing and how steady the iris signal is.
struct DebugView: View {
    let model: AppModel
    @State private var showIrisPixels = true
    @State private var showRawLandmarks = false

    var body: some View {
        ScrollView {
            content.padding()
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            let size = model.debug?.imageSize ?? CGSize(width: 16, height: 9)
            ZStack {
                CameraPreview(sink: model.preview)
                LandmarkCanvas(debug: model.debug,
                               showRaw: showRawLandmarks || model.settings.pointerMode == "gaze")
            }
            .aspectRatio(size.width / size.height, contentMode: .fit)
            .frame(maxHeight: 380)
            .scaleEffect(x: -1, y: 1) // mirror, like a selfie
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)

            if model.settings.pointerMode == "gaze" {
                eyes
            } else {
                face
            }

            HStack(alignment: .top, spacing: 20) {
                IrisPad(sample: model.lastSample)
                stats
            }

            // Target prediction is off in minimal mode, so its lists would only be empty.
            if !AppModel.minimal {
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    predictions
                    scoreboard
                }
            }
        }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What the tracker sees").font(.title3.bold())
            HStack(spacing: 14) {
                if model.settings.faceInput == "turn" {
                    legend(.green, "cheek band")
                    legend(.yellow, "nose patch: turning moves it relative to the cheeks")
                } else {
                    legend(.green, "nose patch and its centre: this drives the pointer")
                }
                Spacer()
                Toggle("Show Vision's raw landmarks", isOn: $showRawLandmarks).toggleStyle(.checkbox)
            }
            .font(.caption)
            Text(model.settings.faceInput == "turn"
                 ? "Both patches are tracked to a fraction of a pixel. Turning your head moves the nose patch more "
                   + "than the cheek band (the nose sticks out), and that difference is your head turn. Sliding or "
                   + "leaning moves both together, so it doesn't count. Vision's raw landmarks (checkbox) bubble by "
                   + "1–3 px every frame; they only place the patches."
                 : "The pixels inside the green square are tracked to a fraction of a pixel. Vision's nose landmarks "
                   + "(checkbox) bubble by 1–3 px every frame; they only place the square and, while you move, keep it "
                   + "from sliding off the middle of your nose.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Cursor control")
                    Text(controlState.text).bold().foregroundStyle(controlState.color)
                }
                GridRow {
                    Text("Image registration")
                    Text(model.anchorLockRate.map {
                        String(format: "locked %.0f%% · residual %.1f", $0 * 100, model.anchorResidual ?? 0)
                    } ?? "–")
                    .foregroundStyle((model.anchorLockRate ?? 1) < 0.9 ? Color.orange : Color.primary)
                }
                if let s = model.lastSample, model.settings.faceInput == "turn" {
                    GridRow {
                        Text("Head turn (relative)")
                        Text(String(format: "%+.1f° sideways  %+.1f° up/down%@", s.turnX, s.turnY,
                                    s.turnValid ? "" : " (re-locking)"))
                    }
                }
                if model.settings.tiltPivot != 0 || model.calibratingTilt, let s = model.lastSample {
                    GridRow {
                        Text("Head tilt")
                        Text(String(format: "%+.1f° (compensation pivot %.1f)", s.faceRoll * 180 / .pi,
                                    model.settings.tiltPivot))
                    }
                }
                if let d = model.driftOffset, model.settings.faceConsistency > 0 {
                    GridRow {
                        Text("Cursor vs. head position")
                        Text(String(format: "%.0f pt from its usual spot for this head position", d))
                            .foregroundStyle(d > 150 ? Color.orange : Color.primary)
                    }
                }
                if let v = model.headSpeed {
                    let turn = model.settings.faceInput == "turn"
                    let threshold = 0.02 * (turn ? 75 : 1)
                    GridRow {
                        Text("Head speed")
                        Text(turn ? String(format: "%.1f°/s (ignored below %.1f)", v, threshold)
                                  : String(format: "%.1f mm/s (ignored below %.1f)", v * 63, threshold * 63))
                            .foregroundStyle(v > threshold ? Color.primary : Color.secondary)
                    }
                }
                GridRow {
                    Text("Latency")
                    Text(model.processingLatency.map {
                        String(format: "%.0f ms from camera frame to cursor", $0)
                    } ?? "–")
                }
                if let b = model.latencyBreakdown {
                    GridRow {
                        Text("  where it goes")
                        Text(String(format: "camera→app %.0f · tracking %.1f · main thread %.1f ms · Vision in the frame path on %.0f%% of frames (rest: background)",
                                    b.delivery, b.tracking, b.mainWait, b.visionShare * 100))
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Blinks")
                    Text(String(format: "%d detected%@ · triple-blink series %d/3 · %d triple blinks%@",
                                model.blinkCount,
                                model.lastBlinkDuration.map { String(format: " (last %.2f s)", $0) } ?? "",
                                model.blinkSeries, model.tripleBlinkCount,
                                model.controlEnabled ? "" : " · control is OFF, so recentre won't act"))
                }
                GridRow {
                    Text("Dead zone / snapping")
                    Text(String(format: "%@ · %@",
                                model.leashRadius.map { String(format: "%.1f pt", $0) } ?? "–",
                                model.snappingNow ? "snapped to a target" : "not snapped"))
                }
                GridRow {
                    Text("Mouth opening")
                    Text(String(format: "%.2f (click at %.2f)", model.mouthOpenness, model.settings.mouthThreshold))
                }
                GridRow {
                    Text("Eye distance (face scale)")
                    Text(model.lastSample.map { String(format: "%.0f px", $0.eyeDistance) } ?? "–")
                }
            }
            .font(.callout.monospacedDigit())
            HStack {
                Button("Record 10 s trace  ⌃⌥⌘T") { model.startTrace() }
                if let status = model.traceStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    /// Whether the app is really moving the system cursor, or only drawing the overlay dot.
    private var controlState: (text: String, color: Color) {
        if !model.controlEnabled { return ("OFF: only the grey dot moves (⌃⌥⌘G to turn on)", .orange) }
        if !model.accessibilityGranted {
            return ("BLOCKED: grant Accessibility (needed again after every rebuild)", .red)
        }
        if model.pausedForMouse { return ("paused while you use the mouse", .secondary) }
        return ("ON: moving the real cursor", .green)
    }

    /// Native-resolution close-ups of each eye: what the iris detector actually works with.
    private var eyes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("What the tracker sees").font(.title3.bold())
                Spacer()
                Toggle("Tint pixels counted as iris", isOn: $showIrisPixels).toggleStyle(.checkbox)
            }
            // Mirrored view: the eye further right in the camera image appears on the left.
            let patches = (model.debug?.eyePatches ?? []).sorted { $0.sourceX > $1.sourceX }
            if patches.count == 2 {
                HStack(alignment: .top, spacing: 16) {
                    EyePatchView(patch: patches[0], title: "Left eye", showMask: showIrisPixels)
                    EyePatchView(patch: patches[1], title: "Right eye", showMask: showIrisPixels)
                }
            } else {
                Text(model.faceDetected ? "Locating eyes…" : "No face in view. Look at the camera.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack(spacing: 14) {
                legend(.cyan, "eye outline (Vision)")
                legend(.pink, "eye corners: the reference axis")
                legend(.yellow, "Vision's pupil guess")
                legend(.green, "iris centre used for gaze")
                legend(.red, "dark pixels counted as iris")
            }
            .font(.caption)
            Text("Dashed line: the iris search area. The green cross should sit on your pupil and follow your eye smoothly. "
                 + "If red spreads onto lashes, brows or shadows, the light is uneven.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The probabilistic layout around the gaze, as the engine currently believes it.
    private var predictions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Likely targets").font(.headline)
            if model.targets.ranked.isEmpty {
                Text("None near the gaze").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.targets.ranked) { r in
                HStack {
                    Text(r.target.label.isEmpty ? "(unlabeled)" : r.target.label).lineLimit(1)
                    Text(r.target.role.replacingOccurrences(of: "AX", with: "")).foregroundStyle(.secondary)
                    Spacer()
                    if let p = r.semantic {
                        Text(String(format: "ctx %.0f%%", p * 100)).foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.0f%%", r.probability * 100)).bold()
                }
                .font(.callout.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How well each prior predicts real mouse clicks. Bits gained over a uniform guess: higher is better.
    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Prior scoreboard").font(.headline)
            let stats = model.targets.scoreboard.stats.filter { $0.value.clicks > 0 }.sorted { $0.key < $1.key }
            if stats.isEmpty {
                Text("Click around with the mouse to collect evidence.").font(.callout).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                if !stats.isEmpty {
                    GridRow {
                        Text("prior"); Text("clicks"); Text("bits/click"); Text("top-1"); Text("latency")
                    }
                    .foregroundStyle(.secondary)
                }
                ForEach(stats, id: \.key) { name, s in
                    GridRow {
                        Text(name)
                        Text("\(s.clicks)")
                        Text(String(format: "%+.2f", s.bitsGained))
                        Text(String(format: "%.0f%%", s.top1Accuracy * 100))
                        Text(s.meanLatency.map { String(format: "%.0f ms", $0 * 1000) } ?? "–")
                    }
                }
            }
            .font(.callout.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stats: some View {
        let s = model.lastSample
        func f(_ v: Double?, _ fmt: String = "%+.3f") -> String { v.map { String(format: fmt, $0) } ?? "–" }
        func deg(_ v: Double?) -> String { v.map { String(format: "%+.1f°", $0 * 180 / .pi) } ?? "–" }
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow { Text("Iris X / Y"); Text("\(f(s?.eyeX))  \(f(s?.eyeY))") }
            GridRow { Text("Yaw / Pitch / Roll"); Text("\(deg(s?.yaw))  \(deg(s?.pitch))  \(deg(s?.roll))") }
            GridRow { Text("Face centre / width"); Text("\(f(s?.faceX, "%.2f")), \(f(s?.faceY, "%.2f"))  \(f(s?.faceSize, "%.2f"))") }
            GridRow { Text("Eye openness L / R"); Text("\(f(s?.leftOpenness, "%.2f"))  \(f(s?.rightOpenness, "%.2f"))") }
            GridRow { Text("Frame rate"); Text(String(format: "%.0f fps", model.fps)) }
        }
        .font(.callout.monospacedDigit())
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(text) }
    }
}

/// Plots the normalized iris offset. When you look around the screen, the dot should
/// move smoothly and consistently. A dot that jumps around points to poor lighting or framing.
private struct IrisPad: View {
    let sample: GazeSample?
    private let range = 0.15

    var body: some View {
        Canvas { ctx, size in
            ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.4)))
            var cross = Path()
            cross.move(to: CGPoint(x: size.width / 2, y: 0)); cross.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            cross.move(to: CGPoint(x: 0, y: size.height / 2)); cross.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(cross, with: .color(.secondary.opacity(0.25)))
            guard let s = sample else { return }
            // Mirrored horizontally to match the preview.
            let x = (0.5 - s.eyeX / (2 * range)) * size.width
            let y = (0.5 - s.eyeY / (2 * range)) * size.height
            ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10)), with: .color(.green))
        }
        .frame(width: 110, height: 110)
    }
}

private struct LandmarkCanvas: View {
    let debug: DebugLandmarks?
    /// Vision's per-frame landmarks. They jitter by design; the pointer doesn't follow them.
    var showRaw: Bool

    var body: some View {
        Canvas { ctx, size in
            guard let d = debug else { return }
            // Vision coordinates are normalized with a bottom-left origin.
            func p(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x * size.width, y: (1 - v.y) * size.height) }

            // What actually drives the pointer: the registered patch and its centre.
            for (box, color) in [(d.anchorBox, Color.green), (d.noseBox, Color.yellow)] {
                guard let b = box else { continue }
                let rect = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height,
                                  width: b.width * size.width, height: b.height * size.height)
                ctx.stroke(Path(rect), with: .color(color), lineWidth: 2)
            }
            if let a = d.anchor {
                let c = p(a)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)), with: .color(.green))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                           with: .color(.black), lineWidth: 1)
            }
            guard showRaw else { return }

            for point in d.allPoints {
                let c = p(point)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)),
                         with: .color(.white.opacity(0.5)))
            }
            for point in d.anchorPoints {
                let c = p(point)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.cyan))
            }
            let box = d.faceBox
            let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                              width: box.width * size.width, height: box.height * size.height)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(.white.opacity(0.35)), lineWidth: 1)

            for contour in d.eyeContours where contour.count > 2 {
                var path = Path()
                path.addLines(contour.map(p))
                path.closeSubpath()
                ctx.stroke(path, with: .color(.cyan), lineWidth: 1)
            }
            for pupil in d.visionPupils {
                let c = p(pupil)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)),
                           with: .color(.yellow), lineWidth: 1)
            }
            for iris in d.irisCentres {
                let c = p(iris)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(.green))
            }
        }
    }
}

/// Live camera view, fed with the frames the app already receives (see `PreviewSink`).
private struct CameraPreview: NSViewRepresentable {
    let sink: PreviewSink

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        sink.attach(view.displayLayer.sampleBufferRenderer)
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {}

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        AppModel.shared.preview.attach(nil)
    }

    final class PreviewView: NSView {
        let displayLayer = AVSampleBufferDisplayLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            displayLayer.videoGravity = .resize
            layer = displayLayer
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
