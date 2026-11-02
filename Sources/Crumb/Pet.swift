import CrumbCore
import Foundation

/// Per-frame puppy behaviour. For now it just wanders along the Dock; Plan 3's PetBrain takes over the decisions.
@MainActor
final class Pet {
    let rig: PuppetRig
    let map: ScreenMap
    /// Screen y of the feet line: just above the Dock.
    let groundY: Double
    var gait: Gait
    /// The pose it is easing toward while standing still.
    var goal = PoseName.stand
    /// false freezes the wander decisions (snapshot mode, and later PetBrain).
    var autopilot = true

    private var pose = Pose()
    private var yaw: Float = 0
    private var stepAmount: Float = 0
    private var ears = Spring()
    private var clock = 0.0
    private var nextDecision = 2.0
    private var nextBlink = 3.0

    /// The model is about 0.92 m wide and 1.2 m tall with its feet at the origin.
    static let size = (width: 0.92, height: 1.2)

    init(rig: PuppetRig, map: ScreenMap, groundY: Double) {
        self.rig = rig
        self.map = map
        self.groundY = groundY
        gait = Gait(at: SIMD2(map.width * 0.3, groundY))
    }

    /// Screen rect (top-left origin) the puppy occupies; clicks inside it reach the pet.
    var frame: CGRect {
        let w = Self.size.width * map.pointsPerMeter, h = Self.size.height * map.pointsPerMeter
        return CGRect(x: gait.position.x - w / 2, y: gait.position.y - h, width: w, height: h)
    }

    func update(dt: Double) {
        clock += dt
        _ = gait.step(dt)
        if autopilot, !gait.isWalking, clock >= nextDecision { wander() }

        let ease = { (rate: Double) in Float(1 - exp(-dt * rate)) }
        pose = Pose.mix(pose, gait.isWalking ? PoseName.stand.pose : goal.pose, ease(6))
        // Three-quarter view while walking, face the viewer when still.
        yaw += ((gait.isWalking ? Float(gait.facing) * 0.6 : 0) - yaw) * ease(8)
        stepAmount += ((gait.isWalking ? 0.45 : 0) - stepAmount) * ease(10)
        ears.step(toward: gait.isWalking ? 0.35 : 0, dt: dt)

        var shown = pose
        if clock >= nextBlink {
            shown.eyeOpen = min(shown.eyeOpen, 0.1)
            if clock >= nextBlink + 0.15 { nextBlink = clock + .random(in: 2.5...6) }
        }
        rig.apply(
            shown,
            swing: stepAmount * sin(Float(gait.phase) * 2 * .pi),
            yaw: yaw,
            ears: ears.value,
            breath: 0.015 * sin(Float(clock) * 2.2))
        let feet = map.world(CGPoint(x: gait.position.x, y: gait.position.y))
        rig.entity.position = SIMD3(feet.x, feet.y, 0)
    }

    // ponytail: random stroll/sit/sniff; PetBrain (Plan 3) replaces this with real jobs.
    private func wander() {
        switch Double.random(in: 0..<1) {
        case ..<0.6:
            goal = .stand
            gait.target = SIMD2(.random(in: 80...(map.width - 80)), groundY)
            nextDecision = clock + .random(in: 1...3)  // counted from now; checked again once it arrives
        case ..<0.85:
            goal = .sitTilt
            nextDecision = clock + .random(in: 3...7)
        default:
            goal = .sniff
            nextDecision = clock + .random(in: 2...4)
        }
    }

    /// Snap straight to a pose (snapshot mode). "walk" starts a stroll to the right instead.
    func show(_ name: String) {
        nextBlink = .infinity  // snapshots stay repeatable: no blink mid-capture
        if let p = PoseName(rawValue: name) {
            gait.target = gait.position
            goal = p
            pose = p.pose
        } else {
            goal = .stand
            gait.target = gait.position + SIMD2(400, 0)
        }
    }
}
