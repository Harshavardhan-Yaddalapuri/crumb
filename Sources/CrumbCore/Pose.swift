/// Joint angles (radians) added to the model's rest pose. Axes are each pivot's local axes
/// from Blender (Z up, dog faces -Y), checked in RealityKit:
/// - X (pitch): + opens the jaw, + nods the head down, + swings a foot backward, - tips the body's front up.
/// - Y (roll): + tilts the head.
/// - Z (yaw): + turns the head, wags the tail.
public struct Pose: Hashable, Sendable {
    public var bodyPitch: Float = 0  // BodyPivot X; pivots at the rear feet
    public var bodyDrop: Float = 0  // BodyPivot moved down, metres (lying down)
    public var headPitch: Float = 0  // HeadPivot X
    public var headTilt: Float = 0  // HeadPivot Y
    public var headTurn: Float = 0  // HeadPivot Z
    public var jaw: Float = 0  // JawPivot X
    public var tail: Float = 0  // TailPivot Z
    public var legFront: Float = 0  // LegFL/LegFR X
    public var legBack: Float = 0  // LegBL/LegBR X
    public var eyeOpen: Float = 1  // EyeL/EyeR Z scale

    public init() {}

    static var joints: [WritableKeyPath<Pose, Float>] {
        [\.bodyPitch, \.bodyDrop, \.headPitch, \.headTilt, \.headTurn, \.jaw, \.tail, \.legFront, \.legBack, \.eyeOpen]
    }

    public static func mix(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
        var out = a
        for k in joints { out[keyPath: k] = a[keyPath: k] + (b[keyPath: k] - a[keyPath: k]) * t }
        return out
    }
}

public enum PoseName: String, CaseIterable, Sendable {
    case stand, sit, sitTilt, sniff, bite, carry, sleep, burp

    // Starting values; tune by eye with `CRUMB_SNAPSHOT` (see scripts/snapshot-poses.sh).
    public var pose: Pose {
        var p = Pose()
        switch self {
        case .stand:
            break
        case .sit, .sitTilt:
            // Tipping the front up lifts the front paws; dropping the body puts them back down and sinks the hips.
            p.bodyPitch = -0.3
            p.bodyDrop = 0.14
            p.legFront = 0.3
            p.legBack = -1.2
            p.headPitch = 0.25
            p.headTilt = self == .sitTilt ? 0.35 : 0
        case .sniff:
            p.headPitch = 0.55
            p.legFront = -0.15
            p.tail = 0.2
        case .bite:
            p.headPitch = 0.45
            p.jaw = 0.55
        case .carry:
            p.headPitch = -0.1
            p.jaw = 0.15
        case .sleep:
            p.bodyDrop = 0.12
            p.legFront = -1.3
            p.legBack = 1.3
            p.headPitch = 0.45
            p.eyeOpen = 0.1
        case .burp:
            p.headPitch = -0.35
            p.jaw = 0.45
            p.eyeOpen = 0.4
        }
        return p
    }
}
