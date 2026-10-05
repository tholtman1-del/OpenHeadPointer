import Foundation
import CoreGraphics

/// Everything the gaze model knows about one camera frame.
///
/// Eye values are expressed in "eye widths" relative to the midpoint between the
/// eye corners, so they are roughly invariant to distance from the camera and to
/// head roll. Head values come straight from Vision.
public struct GazeSample: Codable, Sendable, Equatable {
    /// Horizontal iris offset along the corner-to-corner axis (both eyes, width-weighted).
    public var eyeX: Double
    /// Vertical iris offset perpendicular to that axis.
    public var eyeY: Double
    /// Head pose in radians.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Face bounding-box centre and width, normalized to the camera image (0...1).
    public var faceX: Double
    public var faceY: Double
    public var faceSize: Double
    /// Eyelid opening divided by eye width.
    public var leftOpenness: Double
    public var rightOpenness: Double
    /// Centre of the nose landmarks in camera pixels (Vision space, origin bottom-left).
    /// Drives the head pointer: many points averaged, so it's far steadier than the iris.
    public var noseX: Double
    public var noseY: Double
    /// Distance between the eye centres in camera pixels: the face's scale.
    public var eyeDistance: Double
    /// Centre of the rigid face landmarks (eyes and nose; not mouth, jaw or brows, which move
    /// with expressions) in camera pixels, Vision space. Drives the face pointer.
    public var faceAnchorX: Double = 0
    public var faceAnchorY: Double = 0
    /// Inner-lip opening divided by mouth width: ~0 closed, >0.35 wide open.
    public var mouthOpenness: Double = 0
    /// Head turn in degrees (plus a constant), from nose-vs-cheek parallax. Vision orientation:
    /// +x = nose toward image-right (unmirrored), +y = nose up. Unaffected by sliding the face.
    public var turnX: Double = 0
    public var turnY: Double = 0
    /// False on frames where tracking restarted, so the turn may have jumped.
    public var turnValid = true
    /// Eye-region pixel measurements, taken every frame directly from the camera image (0 = unknown).
    /// An open eye has strong contrast (white sclera, dark iris); a closed lid is mostly skin.
    /// `eyeSpread`: brightness spread (90th − 10th percentile); `eyeStd`: standard deviation; `eyeMean`: mean.
    public var eyeSpread: Double = 0
    public var eyeStd: Double = 0
    public var eyeMean: Double = 0
    /// Head tilt (roll) in radians, counter-clockwise in Vision space, measured by image registration.
    /// Only filled while tilt compensation is on or being calibrated.
    public var faceRoll: Double = 0

    public init(eyeX: Double, eyeY: Double, yaw: Double = 0, pitch: Double = 0, roll: Double = 0,
                faceX: Double = 0.5, faceY: Double = 0.5, faceSize: Double = 0.3,
                leftOpenness: Double = 0.3, rightOpenness: Double = 0.3,
                noseX: Double = 0, noseY: Double = 0, eyeDistance: Double = 0) {
        self.noseX = noseX
        self.noseY = noseY
        self.eyeDistance = eyeDistance
        self.eyeX = eyeX
        self.eyeY = eyeY
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.faceX = faceX
        self.faceY = faceY
        self.faceSize = faceSize
        self.leftOpenness = leftOpenness
        self.rightOpenness = rightOpenness
    }

    public var openness: Double { (leftOpenness + rightOpenness) / 2 }
}

/// A sample recorded while the user was looking at a known screen point.
public struct CalibrationPoint: Codable, Sendable {
    public var sample: GazeSample
    /// Target in global CoreGraphics coordinates (top-left origin of the primary display).
    public var target: CGPoint

    public init(sample: GazeSample, target: CGPoint) {
        self.sample = sample
        self.target = target
    }
}
