import AVFoundation
import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = model.cameraError {
                warning(error, action: "Open Camera Settings", CursorController.openCameraSettings)
            }
            if !model.accessibilityGranted {
                warning("Cursor control needs Accessibility access.", action: "Grant Access…") {
                    CursorController.requestTrust()
                    CursorController.openAccessibilitySettings()
                }
            }
            if let message = model.message {
                Text(message).font(.callout).foregroundStyle(.orange)
            }

            Divider()
            if AppModel.minimal {
                minimal
            } else {
                if model.settings.pointerMode == "face" {
                    facePointer
                } else {
                    calibration
                }
                Divider()
                control
                Divider()
                prediction
                Divider()
                tuning
                experimental
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    /// Minimal mode: only what the face-position, speed-sensitive pointer needs.
    private var minimal: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.controlEnabled }, set: { model.setControl($0) })) {
                HStack {
                    Text("Control pointer with face").bold()
                    Spacer()
                    Text("⌃⌥⌘G").foregroundStyle(.secondary)
                }
            }
            if model.controlEnabled, model.pausedForMouse {
                Text("Paused while you use the mouse").font(.caption).foregroundStyle(.secondary)
            }
            Text("Move your face slowly for precision, quickly to cross the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            slider("Speed", value: $model.settings.faceSpeed, in: 0.1...0.7,
                   format: String(format: "%.1f×", model.settings.faceSpeed))
            HStack {
                Button("Centre pointer  ⌃⌥⌘R") { model.recenterFace() }
                    .disabled(!model.faceDetected)
                Spacer()
            }
            Toggle("Long blink to click", isOn: $model.settings.blinkClickEnabled)
            slider("Blink time to click", value: $model.settings.blinkClickTime, in: 0.2...1.0,
                   format: String(format: "%.2f s", model.settings.blinkClickTime))
            Toggle("Blink 3 times quickly to recentre", isOn: $model.settings.tripleBlinkRecenter)
            Toggle("Pause when I move the mouse", isOn: $model.settings.yieldToMouse)
            Toggle("Show pointer dot", isOn: $model.settings.showGazeDot)
            Picker("Camera", selection: $model.settings.cameraID) {
                Text("Default").tag(String?.none)
                ForEach(model.cameraDevices, id: \.id) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "face.smiling").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenHeadPointer").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.faceDetected ? Color.green : (model.cameraRunning ? .orange : .red))
                .frame(width: 9, height: 9)
                .help(model.faceDetected ? "Face tracked" : "No face")
        }
    }

    private var status: String {
        guard model.cameraRunning else { return "Camera off" }
        let face = model.faceDetected ? "face tracked" : "no face"
        return "\(model.cameraName) · \(face) · \(Int(model.fps.rounded())) fps"
    }

    private var calibration: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mapper != nil {
                Label(model.expectedError.map { "Calibrated · ±\(model.describe($0))" } ?? "Calibrated",
                      systemImage: "checkmark.seal")
                    .font(.callout)
            } else {
                Label("Not calibrated", systemImage: "scope").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Calibrate  ⌃⌥⌘C") { model.startCalibration(.full) }
                Button("Recenter  ⌃⌥⌘R") { model.startCalibration(.recenter) }
                    .disabled(model.mapper == nil)
            }
            .disabled(!model.cameraRunning)
        }
    }

    private var facePointer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Input", selection: $model.settings.faceInput) {
                Text("Face position").tag("position")
                Text("Head turn").tag("turn")
            }
            .pickerStyle(.segmented)
            Picker("Motion", selection: $model.settings.motion) {
                Text("Speed-sensitive").tag("relative")
                Text("Direct").tag("absolute")
            }
            .pickerStyle(.segmented)
            let turn = model.settings.faceInput == "turn"
            if model.settings.motion == "absolute" {
                Text(turn ? "Facing straight ahead = screen centre. Turn or nod to move; sliding your face is ignored. ⌃⌥⌘R sets the centre."
                          : "The pointer position follows your face position. ⌃⌥⌘R sets the centre.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if turn {
                    slider("Head turn for full width", value: $model.settings.turnSpan, in: 8...50,
                           format: String(format: "%.0f°", model.settings.turnSpan))
                } else {
                    slider("Face movement for full width", value: $model.settings.headSpan, in: 0.2...1.5,
                           format: String(format: "%.0f%% of eye distance", model.settings.headSpan * 100))
                    slider("Turning vs. moving", value: $model.settings.noseEmphasis, in: 0...1.5,
                           format: model.settings.noseEmphasis < 0.05 ? "whole face"
                               : String(format: "+%.0f%% nose", model.settings.noseEmphasis * 100))
                }
                slider("Smoothing", value: Binding(
                    get: { -log10(model.settings.headSmoothing) },
                    set: { model.settings.headSmoothing = pow(10, -$0) }
                ), in: -0.6...0.6, format: String(format: "%.1f Hz", model.settings.headSmoothing))
                slider("Dead zone (ignore tiny wobble)", value: $model.settings.faceDeadZone, in: 0...15,
                       format: model.settings.faceDeadZone < 0.5 ? "off"
                           : String(format: "%.0f pt", model.settings.faceDeadZone))
                Button("Set centre  ⌃⌥⌘R") { model.recenterFace() }
                    .disabled(!model.faceDetected)
            } else {
                Text("Move slowly for precision, quickly to cross the screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                slider("Speed", value: $model.settings.faceSpeed, in: 0.1...0.7,
                       format: String(format: "%.1f×", model.settings.faceSpeed))
                if model.settings.faceInput == "position" { tiltControls }
                slider("Keep cursor tied to head position", value: $model.settings.faceConsistency, in: 0...1,
                       format: model.settings.faceConsistency < 0.05 ? "off (free)"
                           : "\(Int(model.settings.faceConsistency * 100))%")
                Button("Centre pointer  ⌃⌥⌘R") { model.recenterFace() }
                    .disabled(!model.faceDetected)
            }
        }
    }

    /// Tilt compensation: off until calibrated, so it never changes the feel unless you choose it.
    private var tiltControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.settings.tiltPivot == 0 ? "Tilt compensation: off"
                     : String(format: "Tilt compensation: pivot %.1f", model.settings.tiltPivot))
                    .font(.caption)
                Spacer()
                Button(model.calibratingTilt ? "Tilting…" : "Calibrate tilt (6 s)") { model.startTiltCalibration() }
                    .controlSize(.small)
                    .disabled(model.calibratingTilt || !model.faceDetected)
                if model.settings.tiltPivot != 0 {
                    Button("Off") { model.settings.tiltPivot = 0 }.controlSize(.small)
                }
            }
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { model.controlEnabled }, set: { model.setControl($0) })) {
                HStack {
                    Text(model.settings.pointerMode == "face" ? "Control pointer with face" : "Control pointer with eyes")
                        .bold()
                    Spacer()
                    Text("⌃⌥⌘G").foregroundStyle(.secondary)
                }
            }
            .disabled(model.settings.pointerMode == "gaze" && model.mapper == nil)
            if model.controlEnabled, model.pausedForMouse {
                Text("Paused while you use the mouse").font(.caption).foregroundStyle(.secondary)
            }

            Toggle(isOn: $model.settings.dwellClickEnabled) {
                HStack { Text("Dwell to click"); Spacer(); Text("⌃⌥⌘D").foregroundStyle(.secondary) }
            }
            if model.settings.dwellClickEnabled {
                slider("Dwell time", value: $model.settings.dwellTime, in: 0.4...2.5,
                       format: String(format: "%.1f s", model.settings.dwellTime))
                slider("Dwell radius", value: $model.settings.dwellRadius, in: 25...150,
                       format: "\(Int(model.settings.dwellRadius)) pt")
            }
            Toggle("Open mouth to click", isOn: $model.settings.mouthClickEnabled)
            if model.settings.mouthClickEnabled {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Mouth").font(.caption)
                        Spacer()
                        Text(model.mouthOpenness >= model.settings.mouthThreshold ? "open" : "closed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Live meter with the threshold marked: hold above the line for 0.3 s to click.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(model.mouthOpenness >= model.settings.mouthThreshold ? Color.green : .accentColor)
                                .frame(width: geo.size.width * min(model.mouthOpenness / 0.7, 1))
                            Rectangle().fill(.primary)
                                .frame(width: 2)
                                .offset(x: geo.size.width * model.settings.mouthThreshold / 0.7 - 1)
                        }
                    }
                    .frame(height: 6)
                    Slider(value: $model.settings.mouthThreshold, in: 0.15...0.6).controlSize(.small)
                }
            }
            Toggle("Long blink to click", isOn: $model.settings.blinkClickEnabled)
            slider("Blink time to click", value: $model.settings.blinkClickTime, in: 0.2...1.0,
                   format: String(format: "%.2f s", model.settings.blinkClickTime))
            Toggle("Pause when I move the mouse", isOn: $model.settings.yieldToMouse)
            Toggle("Show pointer dot", isOn: $model.settings.showGazeDot)
        }
    }

    private var tuning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Camera", selection: $model.settings.cameraID) {
                Text("Default").tag(String?.none)
                ForEach(model.cameraDevices, id: \.id) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
        }
    }

    /// Eye tracking stays available but out of the way: face pointing is the main mode.
    private var experimental: some View {
        DisclosureGroup("Experimental: eye tracking") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Point with eyes instead of face", isOn: Binding(
                    get: { model.settings.pointerMode == "gaze" },
                    set: { model.settings.pointerMode = $0 ? "gaze" : "face" }
                ))
                if model.settings.pointerMode == "gaze" {
                    slider("Steadiness (fixation averaging)", value: $model.settings.steadiness, in: 0.2...1.5,
                           format: String(format: "%.1f s", model.settings.steadiness))
                    slider("Stickiness (jump threshold)", value: $model.settings.stickiness, in: 1.5...5,
                           format: model.jumpRadius.map { String(format: "%.1f× · %.0f pt", model.settings.stickiness, $0) }
                               ?? String(format: "%.1f×", model.settings.stickiness))
                    Toggle("Refine iris from pixels", isOn: $model.settings.refineIris)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private var prediction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Predict & snap to targets", isOn: $model.settings.predictTargets)
                .bold()
            if model.settings.predictTargets {
                slider("Snap when at least", value: $model.settings.snapThreshold, in: 0.3...0.95,
                       format: "\(Int(model.settings.snapThreshold * 100))% likely")
                Toggle("Learn from my clicks (\(model.targets.learnedCount) elements)",
                       isOn: $model.settings.learnFromClicks)
                Picker("Context model", selection: $model.settings.semanticProvider) {
                    Text("None (habits only)").tag("none")
                    Text("Apple on-device").tag("apple")
                }
                if model.settings.semanticProvider != "none" {
                    slider("Trust in context model", value: $model.settings.semanticTrust, in: 0...1,
                           format: "\(Int(model.settings.semanticTrust * 100))%")
                    Text(model.targets.semanticStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(model.targets.layoutSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Camera Debug…  ⌃⌥⌘V") { DebugWindowController.shared.show() }
            Spacer()
            if model.mapper != nil, !AppModel.minimal {
                Button("Reset Calibration") { model.clearCalibration() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(format).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    private func warning(_ text: String, action: String, _ perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Button(action, action: perform).controlSize(.small)
        }
    }
}
