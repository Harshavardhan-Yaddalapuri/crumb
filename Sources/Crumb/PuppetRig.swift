import CrumbCore
import RealityKit

/// Drives the joints of crumb.usdz from a Pose.
@MainActor
final class PuppetRig {
    /// Place and turn this. The model's own top entity holds the Z-up → Y-up rotation, so never overwrite that one.
    let entity = Entity()
    private var joints: [String: Entity] = [:]
    private var rest: [String: Transform] = [:]

    static let names = [
        "Body", "BodyPivot", "HeadPivot", "JawPivot", "TailPivot",
        "LegFL", "LegFR", "LegBL", "LegBR", "EarL", "EarR", "EyeL", "EyeR",
    ]

    struct MissingJoint: Error { let name: String }

    init(model: Entity) throws {
        entity.addChild(model)
        for name in Self.names {
            guard let joint = model.findEntity(named: name) else { throw MissingJoint(name: name) }
            joints[name] = joint
            rest[name] = joint.transform
        }
    }

    /// - swing: walk-cycle leg angle; diagonal pairs move together.
    /// - yaw: whole-body turn; + faces screen right.
    /// - ears: + flops both ears backward.
    /// - breath: belly scale offset.
    /// - belly: how full: widens the body and makes it a little taller (0 empty). Not deeper: that hides the bib.
    func apply(_ p: Pose, swing: Float, yaw: Float, ears: Float, breath: Float, belly: Float) {
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        set("BodyPivot", turn(p.bodyPitch, x), move: [0, 0, -p.bodyDrop])
        set("HeadPivot", turn(p.headPitch, x) * turn(p.headTilt, y) * turn(p.headTurn, z))
        set("JawPivot", turn(p.jaw, x))
        set("TailPivot", turn(p.tail, z))
        set("LegFL", turn(p.legFront + swing, x))
        set("LegBR", turn(p.legBack + swing, x))
        set("LegFR", turn(p.legFront - swing, x))
        set("LegBL", turn(p.legBack - swing, x))
        set("EarL", turn(ears, x))
        set("EarR", turn(ears, x))
        set("EyeL", scale: [1, 1, p.eyeOpen])
        set("EyeR", scale: [1, 1, p.eyeOpen])
        set("Body", scale: [1 + breath + belly, 1, 1 + breath + belly * 0.4])
    }

    private let x: SIMD3<Float> = [1, 0, 0], y: SIMD3<Float> = [0, 1, 0], z: SIMD3<Float> = [0, 0, 1]

    private func turn(_ angle: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: angle, axis: axis) }

    private func set(
        _ name: String, _ rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        move: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one
    ) {
        guard let joint = joints[name], let base = rest[name] else { return }
        joint.transform = Transform(
            scale: base.scale * scale, rotation: base.rotation * rotation, translation: base.translation + move)
    }
}
