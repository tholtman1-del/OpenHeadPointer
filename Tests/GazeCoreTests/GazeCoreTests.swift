import Foundation
import Testing
import CoreGraphics
@testable import GazeCore

@Suite struct RegressionTests {
    @Test func solvesLinearSystem() throws {
        let x = try #require(RidgeRegression.solve([[2, 1], [1, 3]], [3, 5]))
        #expect(abs(x[0] - 0.8) < 1e-9)
        #expect(abs(x[1] - 1.4) < 1e-9)
    }

    @Test func ridgeRecoversLinearFunction() throws {
        var X: [[Double]] = [], y: [Double] = []
        for i in 0..<50 {
            let a = Double(i % 7) - 3, b = Double(i % 5) * 0.5
            X.append([a, b])
            y.append(4 + 2 * a - 3 * b)
        }
        let m = try #require(RidgeRegression.fit(features: X, targets: y, lambda: 1e-8))
        #expect(abs(m.predict([1, 1]) - 3) < 1e-4)
    }

    @Test func mapperFitsSyntheticGaze() throws {
        // Screen point is a smooth function of iris offset plus a little head yaw.
        func target(_ u: Double, _ v: Double, _ yaw: Double) -> CGPoint {
            CGPoint(x: 720 + 6000 * u + 400 * u * u + 300 * yaw, y: 450 + 7000 * v)
        }
        var groups: [[CalibrationPoint]] = []
        var seed: UInt64 = 42
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 33) / Double(1 << 31) - 0.5) * 0.002
        }
        for gx in [-0.1, 0.0, 0.1] {
            for gy in [-0.05, 0.0, 0.05] {
                let t = target(gx, gy, 0)
                groups.append((0..<20).map { i in
                    let yaw = Double(i % 5 - 2) * 0.02
                    let s = GazeSample(eyeX: gx - 300 * yaw / 6000 + noise(), eyeY: gy + noise(), yaw: yaw)
                    return CalibrationPoint(sample: s, target: t)
                })
            }
        }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let m = try #require(GazeMapper.fit(groups.flatMap { $0 }, screenFrame: screen))
        #expect(m.meanTargetError(groups) < 15)
        let cv = try #require(GazeMapper.crossValidatedError(groups, screenFrame: screen))
        #expect(cv < 60)
    }

    @Test func robustFilterDropsGlances() {
        var s = (0..<20).map { i in GazeSample(eyeX: 0.01 * Double(i % 3), eyeY: 0) }
        s.append(GazeSample(eyeX: 0.5, eyeY: 0.4))
        let kept = CalibrationFilter.robust(s)
        #expect(kept.count == 20)
    }
}

@Suite struct GeometryTests {
    let eye = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 2), CGPoint(x: 10, y: 0), CGPoint(x: 5, y: -2)]

    @Test func centredIris() throws {
        let m = try #require(EyeGeometry.measure(contour: eye, iris: CGPoint(x: 5, y: 0)))
        #expect(abs(m.irisOffsetX) < 1e-9)
        #expect(abs(m.irisOffsetY) < 1e-9)
        #expect(abs(m.openness - 0.4) < 1e-9)
        #expect(abs(m.width - 10) < 1e-9)
    }

    @Test func shiftedIris() throws {
        let m = try #require(EyeGeometry.measure(contour: eye, iris: CGPoint(x: 7, y: 1)))
        #expect(abs(m.irisOffsetX - 0.2) < 1e-9)
        #expect(abs(m.irisOffsetY - 0.1) < 1e-9)
    }

    @Test func locatesDarkDisk() throws {
        let w = 60, h = 30
        var pixels = [UInt8](repeating: 200, count: w * h)
        let cx = 37.0, cy = 14.0
        for y in 0..<h {
            for x in 0..<w where hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy) < 6 {
                pixels[y * w + x] = 30
            }
        }
        let outline = [CGPoint(x: 2, y: 15), CGPoint(x: 30, y: 2), CGPoint(x: 58, y: 15), CGPoint(x: 30, y: 28)]
        let p = try #require(pixels.withUnsafeBufferPointer { buf in
            IrisLocator.locate(in: GrayImage(base: buf.baseAddress!, width: w, height: h, bytesPerRow: w),
                               polygon: outline)
        })
        #expect(abs(p.x - cx) < 1)
        #expect(abs(p.y - cy) < 1)
    }
}

@Suite struct InteractionTests {
    @Test func oneEuroHoldsStillAndConverges() {
        var f = OneEuroFilter()
        for i in 0..<30 { #expect(f.filter(5, at: Double(i) / 30) == 5) }
        var last = 5.0
        for i in 30..<120 { last = f.filter(100, at: Double(i) / 30) }
        #expect(abs(last - 100) < 1)
    }

    @Test func dwellFiresOnceThenRearms() {
        var d = DwellDetector(dwellTime: 1, radius: 30)
        var clicks = 0
        for i in 0...90 where d.update(CGPoint(x: 100, y: 100), at: Double(i) / 30) != nil { clicks += 1 }
        #expect(clicks == 1)
        _ = d.update(CGPoint(x: 400, y: 100), at: 3.1)
        for i in 0...40 where d.update(CGPoint(x: 400, y: 100), at: 3.1 + Double(i) / 30) != nil { clicks += 1 }
        #expect(clicks == 2)
    }

    @Test func blinkDetectorIgnoresShortBlinks() {
        var b = BlinkDetector()
        var t = 0.0
        func run(_ openness: Double, _ seconds: Double) -> Bool {
            var fired = false
            for _ in 0..<Int(seconds * 30) { t += 1.0 / 30; fired = b.update(openness: openness, at: t) || fired }
            return fired
        }
        #expect(!run(0.30, 1))
        #expect(!run(0.05, 0.15))
        #expect(!run(0.30, 0.5))
        _ = run(0.05, 0.7)
        #expect(run(0.30, 0.2))
    }
}

@Suite struct FixationFilterTests {
    struct Noise {
        var seed: UInt64 = 7
        mutating func gauss() -> Double {
            func uniform() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (Double(seed >> 11) + 1) / Double(1 << 53)
            }
            return (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    @Test func steadyOnNoisyFixationAndFollowsSaccade() {
        var f = FixationFilter()
        var noise = Noise()
        var meter = JitterMeter(capacity: 60)
        var t = 0.0
        // 4 s fixation at (500, 400) with σ = 40 pt webcam-like noise.
        for i in 0..<120 {
            t += 1.0 / 30
            let out = f.filter(CGPoint(x: 500 + 40 * noise.gauss(), y: 400 + 40 * noise.gauss()), at: t)
            if i >= 60 { meter.add(out) }
        }
        let jitter = meter.rms ?? .infinity
        #expect(jitter < 10, "cursor jitter \(jitter) pt")
        #expect(abs(f.noise - 40) < 12, "noise estimate \(f.noise)")

        // Saccade to (1100, 400): the cursor should arrive within ~0.3 s.
        var arrived: Double?
        let start = t
        for _ in 0..<30 {
            t += 1.0 / 30
            let out = f.filter(CGPoint(x: 1100 + 40 * noise.gauss(), y: 400 + 40 * noise.gauss()), at: t)
            if arrived == nil, abs(out.x - 1100) < 60 { arrived = t - start }
        }
        #expect((arrived ?? 1) < 0.35, "saccade latency \(arrived ?? -1) s")
    }

    @Test func singleOutlierDoesNotMoveCursor() {
        var f = FixationFilter()
        var t = 0.0
        var out = CGPoint.zero
        for i in 0..<60 {
            t += 1.0 / 30
            let p = i == 40 ? CGPoint(x: 1500, y: 900) : CGPoint(x: 300, y: 300)
            out = f.filter(p, at: t)
            #expect(abs(out.x - 300) < 1)
        }
    }
}

@Suite struct TargetPredictionTests {
    let save = Target(id: "save", frame: CGRect(x: 100, y: 100, width: 80, height: 30),
                      role: "AXButton", label: "Save", signature: "app|AXButton|Save")
    let cancel = Target(id: "cancel", frame: CGRect(x: 200, y: 100, width: 80, height: 30),
                        role: "AXButton", label: "Cancel", signature: "app|AXButton|Cancel")

    @Test func likelihoodPeaksInsideAndFallsOff() {
        let inside = TargetPredictor.likelihood(CGPoint(x: 140, y: 115), in: save.frame, sigma: 40)
        let near = TargetPredictor.likelihood(CGPoint(x: 140, y: 175), in: save.frame, sigma: 40)
        let far = TargetPredictor.likelihood(CGPoint(x: 600, y: 600), in: save.frame, sigma: 40)
        #expect(inside > near)
        #expect(near > far * 1000)
    }

    @Test func fixationAccumulatesEvidenceForNearestTarget() throws {
        var p = TargetPredictor()
        p.setTargets([save, cancel])
        let gaze = [CGPoint(x: 165, y: 120), CGPoint(x: 150, y: 105), CGPoint(x: 175, y: 118),
                    CGPoint(x: 160, y: 112), CGPoint(x: 168, y: 125), CGPoint(x: 155, y: 110)]
        for g in gaze { p.update(gaze: g, sigma: 40) }
        let best = try #require(p.best)
        #expect(best.target.id == "save")
        #expect(best.probability > 0.5)
    }

    @Test func learnedHabitTipsAnAmbiguousGaze() throws {
        var priors = TargetPriors()
        for _ in 0..<20 { priors.recordClick(cancel.signature) }
        var p = TargetPredictor()
        p.setTargets([save, cancel])
        let weights = [save.id: priors.weight(for: save), cancel.id: priors.weight(for: cancel)]
        for _ in 0..<10 { p.update(gaze: CGPoint(x: 190, y: 115), sigma: 40, priors: weights) }
        #expect(try #require(p.best).target.id == "cancel")
    }

    @Test func semanticPriorTipsAnAmbiguousGaze() throws {
        // The context model says "Save" is far more likely next; gaze sits exactly between the buttons.
        let query = SemanticQuery(context: ClickContext(app: "TextEdit", window: "Untitled", focusedElement: nil,
                                                        recentClicks: []),
                                  targets: [save, cancel], window: CGRect(x: 0, y: 0, width: 400, height: 200))
        let probs = query.targetProbabilities(["e1": 0.85, "e2": 0.05, "other": 0.10])
        let weights = [save.id: PriorBlend.factor(probability: probs[save.id], choices: 2, trust: 0.8),
                       cancel.id: PriorBlend.factor(probability: probs[cancel.id], choices: 2, trust: 0.8)]
        var p = TargetPredictor()
        p.setTargets([save, cancel])
        for _ in 0..<10 { p.update(gaze: CGPoint(x: 190, y: 115), sigma: 40, priors: weights) }
        #expect(try #require(p.best).target.id == "save")
    }

    @Test func emptyAreaMeansNoTarget() {
        var p = TargetPredictor()
        p.setTargets([save])
        for _ in 0..<10 { p.update(gaze: CGPoint(x: 900, y: 700), sigma: 40) }
        #expect(p.noneProbability > 0.95)
    }

    @Test func uniformSemanticAnswerIsNeutral() {
        #expect(abs(PriorBlend.factor(probability: 0.25, choices: 4, trust: 1) - 1) < 1e-9)
        #expect(PriorBlend.factor(probability: nil, choices: 4, trust: 1) == 1)
    }
}

@Suite struct ScoreboardTests {
    @Test func rewardsInformativePriorsOverUniform() {
        var board = PriorScoreboard()
        let ids: Set<String> = ["a", "b", "c", "d"]
        for _ in 0..<10 {
            board.record("good", probabilities: ["a": 0.7, "b": 0.1, "c": 0.1, "d": 0.1], candidates: ids, clicked: "a")
            board.record("uniform", probabilities: ["a": 0.25, "b": 0.25, "c": 0.25, "d": 0.25], candidates: ids, clicked: "a")
            board.record("wrong", probabilities: ["b": 0.97, "a": 0.01, "c": 0.01, "d": 0.01], candidates: ids, clicked: "a")
        }
        #expect(board.stats["good"]!.bitsGained > 1)
        #expect(abs(board.stats["uniform"]!.bitsGained) < 1e-9)
        #expect(board.stats["wrong"]!.bitsGained < 0)
        #expect(board.stats["good"]!.top1Accuracy == 1)
        #expect(board.stats["wrong"]!.top1Accuracy == 0)
    }

    @Test func skipsClicksOutsideTheLayout() {
        var board = PriorScoreboard()
        board.record("x", probabilities: ["a": 1], candidates: ["a", "b"], clicked: "zzz")
        #expect(board.stats["x"] == nil)
    }
}

@Suite struct StabilityTests {
    /// Two outline points nearly tied for "farthest from the other corner": a tiny wobble
    /// used to flip which one was picked and jump the reference frame. Now it must not.
    @Test func referenceFrameIsContinuousWhenCornersTie() throws {
        func outline(_ wobble: CGFloat) -> [CGPoint] {
            [CGPoint(x: 0, y: 0), CGPoint(x: wobble, y: 0.6), CGPoint(x: 3, y: 2), CGPoint(x: 7, y: 2),
             CGPoint(x: 10, y: 0), CGPoint(x: 7, y: -1.5), CGPoint(x: 3, y: -1.5)]
        }
        let iris = CGPoint(x: 5.5, y: 0.4)
        let a = try #require(EyeGeometry.measure(contour: outline(0.05), iris: iris))
        let b = try #require(EyeGeometry.measure(contour: outline(-0.05), iris: iris))
        #expect(abs(a.irisOffsetX - b.irisOffsetX) < 0.005)
        #expect(abs(a.irisOffsetY - b.irisOffsetY) < 0.005)
    }

    @Test func smoothedThresholdIsUsed() throws {
        let w = 40, h = 20
        var pixels = [UInt8](repeating: 200, count: w * h)
        for y in 6..<14 { for x in 16..<24 { pixels[y * w + x] = 40 } }
        let outline = [CGPoint(x: 1, y: 10), CGPoint(x: 20, y: 1), CGPoint(x: 39, y: 10), CGPoint(x: 20, y: 19)]
        let r = try #require(pixels.withUnsafeBufferPointer {
            IrisLocator.locateDetailed(in: GrayImage(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w),
                                       polygon: outline, threshold: 90)
        })
        #expect(r.threshold == 90)
        #expect(abs(r.centre.x - 20) < 0.5)
    }
}

@Suite struct HeadPointerTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func startsCentredAndFollowsTheNose() {
        var h = HeadPointer(span: 0.6, screen: screen)
        let start = h.point(nose: CGPoint(x: 640, y: 360), eyeDistance: 100)
        #expect(start == CGPoint(x: 720, y: 450))
        // Turning right: nose moves to image-left → cursor moves right.
        #expect(h.point(nose: CGPoint(x: 625, y: 360), eyeDistance: 100).x > 720)
        // Tilting up: nose moves up in Vision space (larger y) → cursor moves up (smaller y).
        #expect(h.point(nose: CGPoint(x: 640, y: 370), eyeDistance: 100).y < 450)
        // 0.3 eye-distances of travel = half the span = half the screen width.
        #expect(abs(h.point(nose: CGPoint(x: 610, y: 360), eyeDistance: 100).x - 1440) <= 1)
    }

    @Test func pushingPastAnEdgeReanchors() {
        var h = HeadPointer(span: 0.6, screen: screen)
        h.pushNeutralAtEdges = true
        _ = h.point(nose: CGPoint(x: 640, y: 360), eyeDistance: 100)
        _ = h.point(nose: CGPoint(x: 580, y: 360), eyeDistance: 100) // far past the right edge
        // Turning back a little moves the cursor off the edge immediately.
        let back = h.point(nose: CGPoint(x: 585, y: 360), eyeDistance: 100)
        #expect(back.x < 1439 && back.x > 1000)
    }
}

@Suite struct GestureTests {
    @Test func firesOnceAfterHoldThenNeedsRelease() {
        var g = HoldGesture(hold: 0.3)
        var fired = 0
        for i in 0..<30 where g.update(active: true, at: Double(i) / 30) { fired += 1 }
        #expect(fired == 1)
        _ = g.update(active: false, at: 1.1)
        for i in 0..<12 where g.update(active: true, at: 1.2 + Double(i) / 30) { fired += 1 }
        #expect(fired == 2)
    }

    @Test func shortGestureDoesNotFire() {
        var g = HoldGesture(hold: 0.3)
        var fired = false
        for i in 0..<5 { fired = g.update(active: true, at: Double(i) / 30) || fired }
        fired = g.update(active: false, at: 0.2) || fired
        #expect(!fired)
    }
}

@Suite struct RegistrationTests {
    /// A smooth, textured scene that can be rendered at any sub-pixel offset.
    func scene(_ x: Double, _ y: Double) -> Float {
        Float(128 + 50 * sin(x * 0.21) * cos(y * 0.17) + 30 * cos(x * 0.07 + y * 0.11)
              + 25 * exp(-((x - 70) * (x - 70) + (y - 60) * (y - 60)) / 200))
    }

    func render(width: Int, height: Int, originX: Double, originY: Double, shift: (Double, Double) = (0, 0)) -> FloatImage {
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // Content moved by `shift`: the value now at p was at p - shift before.
                px[y * width + x] = scene(originX + Double(x) - shift.0, originY + Double(y) - shift.1)
            }
        }
        return FloatImage(width: width, height: height, pixels: px)
    }

    @Test(arguments: [(0.0, 0.0), (0.37, -0.21), (2.6, 1.9), (-5.3, 4.4)])
    func recoversSubpixelShift(_ shift: (Double, Double)) throws {
        let template = render(width: 64, height: 64, originX: 40, originY: 30)
        let region = render(width: 64 + 48, height: 64 + 48, originX: 16, originY: 6, shift: shift)
        let r = try #require(PatchRegistration.align(template: template, templateOrigin: CGPoint(x: 40, y: 30),
                                                     image: region, imageOrigin: CGPoint(x: 16, y: 6)))
        #expect(abs(Double(r.shift.dx) - shift.0) < 0.03, "dx \(r.shift.dx) vs \(shift.0)")
        #expect(abs(Double(r.shift.dy) - shift.1) < 0.03, "dy \(r.shift.dy) vs \(shift.1)")
    }

    @Test func ignoresExposureChange() throws {
        let template = render(width: 64, height: 64, originX: 40, originY: 30)
        var region = render(width: 112, height: 112, originX: 16, originY: 6, shift: (1.2, -0.8))
        region.pixels = region.pixels.map { $0 + 15 } // camera brightened
        let r = try #require(PatchRegistration.align(template: template, templateOrigin: CGPoint(x: 40, y: 30),
                                                     image: region, imageOrigin: CGPoint(x: 16, y: 6)))
        #expect(abs(Double(r.shift.dx) - 1.2) < 0.05)
        #expect(abs(Double(r.shift.dy) + 0.8) < 0.05)
    }
}

@Suite struct AnchorTrackerTests {
    func scene(_ x: Double, _ y: Double) -> Double {
        128 + 50 * sin(x * 0.21) * cos(y * 0.17) + 30 * cos(x * 0.07 + y * 0.11)
            + 25 * exp(-((x - 90) * (x - 90) + (y - 80) * (y - 80)) / 200)
    }

    /// Renders a 180×160 camera frame with the scene shifted by `shift`, plus sensor noise.
    func frame(shift: (Double, Double), seed: inout UInt64) -> [UInt8] {
        func gauss() -> Double {
            func u() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return (Double(seed >> 11) + 1) / Double(1 << 53)
            }
            return (-2 * log(u())).squareRoot() * cos(2 * .pi * u())
        }
        var px = [UInt8](repeating: 0, count: 180 * 160)
        for y in 0..<160 {
            for x in 0..<180 {
                px[y * 180 + x] = UInt8(min(max(scene(Double(x) - shift.0, Double(y) - shift.1) + 4 * gauss(), 0), 255))
            }
        }
        return px
    }

    @Test func stillFaceGivesStillAnchorDespiteNoise() {
        var tracker = AnchorTracker()
        var seed: UInt64 = 11
        var xs: [Double] = [], ys: [Double] = []
        for i in 0..<120 {
            let px = frame(shift: (0, 0), seed: &seed)
            // Landmarks jitter by ±3 px, like Vision's.
            let lm = CGPoint(x: 90 + Double(i % 7) - 3, y: 80 + Double(i % 5) - 2)
            let out = px.withUnsafeBufferPointer {
                tracker.update(landmark: lm, scale: 100,
                               image: GrayImage(base: $0.baseAddress!, width: 180, height: 160, bytesPerRow: 180))
            }
            if i >= 10 { xs.append(Double(out.position.x)); ys.append(Double(out.position.y)) }
        }
        let range = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        #expect(range < 0.15, "anchor wandered \(range) px on a still face")
    }

    @Test func followsSmoothMotion() {
        var tracker = AnchorTracker()
        var seed: UInt64 = 5
        var first: CGPoint?
        var last = CGPoint.zero
        for i in 0..<60 {
            let s = Double(i) * 0.5 // 0.5 px per frame to the right
            let px = frame(shift: (s, 0), seed: &seed)
            let out = px.withUnsafeBufferPointer {
                tracker.update(landmark: CGPoint(x: 90 + s, y: 80), scale: 100,
                               image: GrayImage(base: $0.baseAddress!, width: 180, height: 160, bytesPerRow: 180))
            }
            if first == nil { first = out.position }
            last = out.position
        }
        #expect(abs(Double(last.x - first!.x) - 29.5) < 0.3)
        #expect(abs(Double(last.y - first!.y)) < 0.3)
    }

    @Test func deadZoneNeverMovesOnItsOwn() {
        var dz = DeadZoneFilter(radius: 4)
        _ = dz.filter(CGPoint(x: 100, y: 100))
        for i in 0..<50 { #expect(dz.filter(CGPoint(x: 100 + Double(i % 3), y: 100)) == CGPoint(x: 100, y: 100)) }
        #expect(dz.filter(CGPoint(x: 110, y: 100)) == CGPoint(x: 106, y: 100))
    }
}

@Suite struct RelativePointerTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let scale = 200.0 // eye distance in camera pixels

    /// Runs a head trajectory (anchor x as a function of time) and returns the pointer travel.
    func travel(_ x: (Double) -> Double, seconds: Double, consistency: Double = 0) -> CGFloat {
        var p = RelativePointer(screen: screen)
        p.consistency = consistency
        p.place(at: CGPoint(x: 720, y: 450))
        var out = CGPoint.zero
        for i in 0...Int(seconds * 30) {
            let t = Double(i) / 30
            out = p.update(anchor: CGPoint(x: 640 + x(t), y: 360), scale: scale, at: t)
        }
        return out.x - 720
    }

    @Test func ignoresBreathingSway() {
        // 0.5 mm sway at 0.25 Hz ≈ 1.6 camera px amplitude at this scale.
        let moved = travel({ 1.6 * sin(2 * .pi * 0.25 * $0) }, seconds: 8)
        #expect(abs(moved) < 1, "sway moved the pointer \(moved) pt")
    }

    @Test func ignoresSensorNoise() {
        var seed: UInt64 = 1
        let moved = travel({ _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.1 // ±0.05 px registration noise
        }, seconds: 5)
        #expect(abs(moved) < 1)
    }

    @Test func fastMovesGoFurtherThanSlowOnes() {
        // The same 20 px head movement (0.1 eye-distances), done slowly vs quickly.
        let slow = travel({ min($0 / 2.0, 1) * -20 }, seconds: 2.5)  // over 2 s
        let fast = travel({ min($0 / 0.2, 1) * -20 }, seconds: 0.5)  // over 0.2 s
        #expect(slow > 20, "slow movement should still move the pointer (moved \(slow))")
        #expect(fast > slow * 2.5, "fast \(fast) vs slow \(slow)")
        #expect(fast > 0) // turning right (anchor to image-left) moves the pointer right
    }
}

@Suite struct HeadTurnTests {
    func face(_ x: Double, _ y: Double) -> Double {
        128 + 45 * sin(x * 0.19) * cos(y * 0.23) + 30 * cos(x * 0.05 - y * 0.09)
    }
    func noseTexture(_ x: Double, _ y: Double) -> Double {
        120 + 60 * cos(x * 0.31 + 1) * sin(y * 0.27 + 2)
    }

    /// Face texture shifted by `faceShift`, with a nose disc that can move by a different amount.
    func frame(faceShift: (Double, Double), noseShift: (Double, Double)) -> [UInt8] {
        let w = 280, h = 200
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let nx = Double(x) - noseShift.0, ny = Double(y) - noseShift.1
                let v = hypot(nx - 140, ny - 110) < 24 ? noseTexture(nx, ny)
                    : face(Double(x) - faceShift.0, Double(y) - faceShift.1)
                px[y * w + x] = UInt8(min(max(v, 0), 255))
            }
        }
        return px
    }

    func run(_ steps: [((Double, Double), (Double, Double))]) -> [HeadTurnTracker.Output] {
        var tracker = HeadTurnTracker()
        return steps.map { faceShift, noseShift in
            let px = frame(faceShift: faceShift, noseShift: noseShift)
            return px.withUnsafeBufferPointer {
                tracker.update(noseLandmark: CGPoint(x: 140 + noseShift.0, y: 110 + noseShift.1), scale: 100,
                               image: GrayImage(base: $0.baseAddress!, width: 280, height: 200, bytesPerRow: 280))
            }
        }
    }

    @Test func slidingTheWholeFaceIsNotATurn() {
        // Face and nose slide 8 px together (leaning sideways).
        let out = run((0...16).map { i in let s = Double(i) * 0.5; return ((s, 0), (s, 0)) })
        let change = out.last!.turn.dx - out.first!.turn.dx
        #expect(out.dropFirst().allSatisfy { $0.valid }) // frame 0 starts from landmarks
        #expect(abs(change) < 0.3, "sliding read as \(change)° of turn")
    }

    @Test func noseParallaxIsATurn() {
        // The nose moves 3 px further than the cheeks: a turn of a few degrees.
        let out = run((0...12).map { i in let s = Double(i) * 0.25; return ((0, 0), (s, 0)) })
        let change = out.last!.turn.dx - out.first!.turn.dx
        #expect(change > 3.2 && change < 4.3, "3 px of parallax read as \(change)° (expected ≈3.75°)")
    }
}

@Suite struct ConsistencyTests {
    /// Out quickly and back slowly, five times: pure relative motion piles up an offset.
    func outFastBackSlow(_ t: Double) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 2.0)
        return cycle < 0.25 ? -24 * cycle / 0.25 : -24 * (1 - (cycle - 0.25) / 1.75)
    }

    @Test func sameHeadPositionGivesSameCursorPosition() {
        let drifted = RelativePointerTests().travel(outFastBackSlow, seconds: 10, consistency: 0)
        let corrected = RelativePointerTests().travel(outFastBackSlow, seconds: 10, consistency: 0.85)
        #expect(abs(drifted) > 150, "expected pure relative motion to drift (got \(drifted) pt)")
        #expect(abs(corrected) < abs(drifted) * 0.25, "corrected \(corrected) pt vs drifted \(drifted) pt")
        // …while staying speed-sensitive.
        let slow = RelativePointerTests().travel({ min($0 / 2.0, 1) * -20 }, seconds: 2.5, consistency: 0.85)
        let fast = RelativePointerTests().travel({ min($0 / 0.2, 1) * -20 }, seconds: 0.5, consistency: 0.85)
        #expect(fast > slow * 1.5, "fast \(fast) vs slow \(slow)")
    }

    @Test func correctionNeverMovesAStillPointer() {
        let moved = RelativePointerTests().travel({ _ in 0 }, seconds: 3, consistency: 1)
        #expect(moved == 0)
    }
}

@Suite struct ReferenceTests {
    /// Registration slides 30 px over the face during 10 s of back-and-forth movement, while the
    /// head keeps returning to the same place. A drift-free reference keeps the cursor tied to it.
    @Test func driftFreeReferenceKeepsCursorTiedToHead() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        func run(useReference: Bool) -> CGFloat {
            var p = RelativePointer(screen: screen)
            p.place(at: CGPoint(x: 720, y: 450))
            var out = CGPoint.zero
            for i in 0...300 {
                let t = Double(i) / 30
                let head = 640 - 24 * abs(sin(.pi * t / 2))      // true head x: out and back every 2 s
                let slide = 3 * t                                 // registration drift: 30 px over 10 s
                out = p.update(anchor: CGPoint(x: head + slide, y: 360),
                               reference: useReference ? CGPoint(x: head, y: 360) : nil,
                               scale: 200, at: t)
            }
            return out.x - 720 // head is back at its start position at t = 10 s
        }
        let without = run(useReference: false), with = run(useReference: true)
        #expect(abs(with) < 40, "cursor ended \(with) pt from where this head position started (vs \(without) without)")
        #expect(abs(with) < abs(without) / 2)
    }
}

@Suite struct RigidRegistrationTests {
    func scene(_ x: Double, _ y: Double) -> Float {
        Float(128 + 50 * sin(x * 0.21) * cos(y * 0.17) + 30 * cos(x * 0.07 + y * 0.11)
              + 25 * exp(-((x - 70) * (x - 70) + (y - 60) * (y - 60)) / 200))
    }

    /// Renders the scene rotated by `angle` (radians, clockwise on screen) about `pivot`, then shifted.
    func render(width: Int, height: Int, originX: Double, originY: Double,
                angle: Double, pivot: (Double, Double), shift: (Double, Double)) -> FloatImage {
        var px = [Float](repeating: 0, count: width * height)
        let c = cos(-angle), s = sin(-angle)
        for y in 0..<height {
            for x in 0..<width {
                // Inverse map: where did this pixel come from?
                let X = originX + Double(x) - shift.0 - pivot.0, Y = originY + Double(y) - shift.1 - pivot.1
                px[y * width + x] = scene(pivot.0 + c * X - s * Y, pivot.1 + s * X + c * Y)
            }
        }
        return FloatImage(width: width, height: height, pixels: px)
    }

    @Test(arguments: [(0.0, 0.0, 0.0), (1.5, -0.8, 1.0), (-2.0, 1.2, -2.5), (0.3, 0.2, 4.0)])
    func recoversRotationAndShift(_ p: (Double, Double, Double)) throws {
        let (sx, sy, degrees) = p
        let angle = degrees * .pi / 180
        // Template 64×64 at (40,30); its centre is the rotation pivot.
        let template = render(width: 64, height: 64, originX: 40, originY: 30, angle: 0, pivot: (0, 0), shift: (0, 0))
        let region = render(width: 112, height: 112, originX: 16, originY: 6, angle: angle,
                            pivot: (40 + 31.5, 30 + 31.5), shift: (sx, sy))
        let r = try #require(RigidRegistration.align(template: template, templateOrigin: CGPoint(x: 40, y: 30),
                                                     image: region, imageOrigin: CGPoint(x: 16, y: 6)))
        #expect(abs(r.rotation * 180 / .pi - degrees) < 0.05, "rotation \(r.rotation * 180 / .pi)° vs \(degrees)°")
        #expect(abs(Double(r.shift.dx) - sx) < 0.08, "dx \(r.shift.dx) vs \(sx)")
        #expect(abs(Double(r.shift.dy) - sy) < 0.08, "dy \(r.shift.dy) vs \(sy)")
    }
}

@Suite struct SlipTests {
    /// The landmarks say the anchor is 12 px right of where registration started (it slid).
    /// Moving back and forth should pull it onto the landmarks; holding still must not move it.
    @Test func patchIsPulledBackOntoTheFaceOnlyWhileMoving() {
        let t = AnchorTrackerTests()
        var tracker = AnchorTracker()
        tracker.landmarkPull = 0.1
        var seed: UInt64 = 3
        var outputs: [CGPoint] = []
        for i in 0..<240 {
            // Still for 2 s, then 6 s of moving ±8 px.
            let s = i < 60 ? 0.0 : 8 * sin(Double(i - 60) / 30 * .pi)
            let px = t.frame(shift: (s, 0), seed: &seed)
            // Landmarks: started at 90, then report 12 px further right (anatomical truth vs slipped patch).
            let lm = CGPoint(x: (i == 0 ? 90 : 102) + s, y: 80)
            let out = px.withUnsafeBufferPointer {
                tracker.update(landmark: lm, scale: 100,
                               image: GrayImage(base: $0.baseAddress!, width: 180, height: 160, bytesPerRow: 180))
            }
            outputs.append(CGPoint(x: out.position.x - CGFloat(s), y: out.position.y))
        }
        // While still (frames 1–59), no correction.
        let still = outputs[1..<60].map(\.x)
        #expect(still.max()! - still.min()! < 0.2, "moved while still")
        // After moving, the slip is mostly gone.
        #expect(abs(Double(outputs.last!.x) - 102) < 4, "still \(102 - Double(outputs.last!.x)) px off the landmarks")
    }
}

@Suite struct FastMotionTests {
    /// A fast head movement: up to 25 px per frame (≈750 px/s at 30 fps), accelerating in and out.
    @Test func keepsLockDuringFastMovement() {
        let scene = AnchorTrackerTests().scene
        let w = 420, h = 160
        var tracker = AnchorTracker()
        let offsets: [Double] = [0, 5, 15, 30, 55, 80, 105, 130, 155, 175, 190, 197, 200, 200]
        var locked: [Bool] = []
        var last = CGPoint.zero
        for s in offsets {
            var px = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { px[y * w + x] = UInt8(min(max(scene(Double(x) - s, Double(y)), 0), 255)) } }
            let out = px.withUnsafeBufferPointer {
                tracker.update(landmark: CGPoint(x: 110 + s, y: 80), scale: 100,
                               image: GrayImage(base: $0.baseAddress!, width: w, height: h, bytesPerRow: w))
            }
            locked.append(out.locked)
            last = out.position
        }
        #expect(locked.dropFirst().allSatisfy { $0 }, "lock per frame: \(locked)")
        #expect(abs(Double(last.x) - 310) < 1, "ended at \(last.x), expected 310")
    }
}

@Suite struct MultiBlinkTests {
    /// Runs openness frames at 30 fps: a list of (openness, seconds) segments.
    func run(_ segments: [(Double, Double)]) -> (recentres: Int, longBlinks: Int) {
        var blink = BlinkDetector()
        var multi = MultiBlinkDetector()
        var t = 0.0, recentres = 0, longs = 0
        for (openness, seconds) in segments {
            for _ in 0..<Int(seconds * 30) {
                t += 1.0 / 30
                if blink.update(openness: openness, at: t) { longs += 1 }
                if let d = blink.completedBlink, multi.blinked(duration: d, at: t) { recentres += 1 }
            }
        }
        return (recentres, longs)
    }

    @Test func threeQuickBlinksRecentre() {
        let r = run([(0.3, 1), (0.05, 0.15), (0.3, 0.25), (0.05, 0.15), (0.3, 0.25), (0.05, 0.15), (0.3, 0.5)])
        #expect(r.recentres == 1)
        #expect(r.longBlinks == 0)
    }

    @Test func spontaneousBlinksDoNot() {
        // Three blinks, but spread over ~6 s.
        let r = run([(0.3, 1), (0.05, 0.15), (0.3, 2.5), (0.05, 0.15), (0.3, 2.5), (0.05, 0.15), (0.3, 0.5)])
        #expect(r.recentres == 0)
    }

    @Test func aLongBlinkBreaksTheSeries() {
        let r = run([(0.3, 1), (0.05, 0.15), (0.3, 0.25), (0.05, 0.6), (0.3, 0.25), (0.05, 0.15), (0.3, 0.5)])
        #expect(r.recentres == 0)
        #expect(r.longBlinks == 1)
    }
}

@Suite struct BlinkRecoveryTests {
    /// The open-eye level was learned from one bad frame; the detector must not stay "closed" forever.
    @Test func recoversFromAWrongOpenEyeLevel() {
        var b = BlinkDetector(closedRatio: 0.9)
        _ = b.update(openness: 35, at: 0)          // bad first frame
        var t = 0.0
        for _ in 0..<90 { t += 1.0 / 30; _ = b.update(openness: 12.6, at: t) } // real open eyes, 3 s
        #expect(!b.eyesClosed, "still stuck closed after 3 s")
        // …and blinks are detected against the corrected level.
        for _ in 0..<6 { t += 1.0 / 30; _ = b.update(openness: 10.5, at: t) }
        #expect(b.eyesClosed)
    }
}
