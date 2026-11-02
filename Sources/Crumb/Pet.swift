import CrumbCore
import Foundation

/// Per-frame puppy behaviour. Idle life (sitting, looking around, wagging, short strolls near the Dock, naps)
/// is decided here for now; Plan 3's PetBrain adds the jobs.
@MainActor
final class Pet {
    let rig: PuppetRig
    let map: ScreenMap
    /// Screen y of the feet line: just above the Dock.
    let groundY: Double
    var gait: Gait
    /// The pose it is easing toward while standing still.
    var goal = PoseName.stand
    /// false freezes wander decisions and idle extras (snapshot mode, and later PetBrain).
    var autopilot = true

    private var pose = Pose()
    private var yaw: Float = 0
    private var stepAmount: Float = 0
    private var ears = Spring()
    private var clock = 0.0
    private var nextDecision = 2.0
    private var nextBlink = 3.0
    private var wasWalking = false
    private var awakeSince = 0.0
    private var look: Float = 0, lookTarget: Float = 0, nextLook = 3.0
    private var wag: Float = 0, wagUntil = 0.0, nextWag = 4.0

    /// Spec: naps after 10 min with nothing to do.
    static let napAfter = 600.0
    /// Strolls stay over the middle of the screen, where the Dock is.
    static let strollBand = 0.3...0.7

    /// The model is about 0.92 m wide and 1.2 m tall with its feet at the origin.
    static let size = (width: 0.92, height: 1.2)

    init(rig: PuppetRig, map: ScreenMap, groundY: Double) {
        self.rig = rig
        self.map = map
        self.groundY = groundY
        gait = Gait(at: SIMD2(map.width * 0.5, groundY))
    }

    /// Screen rect (top-left origin) the puppy occupies; clicks inside it reach the pet.
    var frame: CGRect {
        let w = Self.size.width * map.pointsPerMeter, h = Self.size.height * map.pointsPerMeter
        return CGRect(x: gait.position.x - w / 2, y: gait.position.y - h, width: w, height: h)
    }

    func update(dt: Double) {
        clock += dt
        _ = gait.step(dt)
        // Just arrived: stand and look around for a bit before deciding again.
        if wasWalking, !gait.isWalking { nextDecision = clock + .random(in: 3...6) }
        wasWalking = gait.isWalking
        if autopilot, !gait.isWalking, clock >= nextDecision { wander() }

        let ease = { (rate: Double) in Float(1 - exp(-dt * rate)) }
        pose = Pose.mix(pose, gait.isWalking ? PoseName.stand.pose : goal.pose, ease(6))
        // Three-quarter view while walking, face the viewer when still.
        yaw += ((gait.isWalking ? Float(gait.facing) * 0.6 : 0) - yaw) * ease(8)
        stepAmount += ((gait.isWalking ? 0.45 : 0) - stepAmount) * ease(10)
        ears.step(toward: gait.isWalking ? 0.35 : 0, dt: dt)

        var shown = pose
        if autopilot { fidget(&shown, dt: dt, ease: ease) }
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

    /// Idle life on top of the pose: glance left and right, wag in bursts. Still while walking or asleep.
    private func fidget(_ shown: inout Pose, dt: Double, ease: (Double) -> Float) {
        let idle = !gait.isWalking && goal != .sleep
        if clock >= nextLook {
            lookTarget = idle ? [-0.55, -0.3, 0, 0, 0.3, 0.55].randomElement()! : 0
            nextLook = clock + .random(in: 1.5...4)
        }
        if clock >= nextWag {
            wagUntil = clock + .random(in: 1.5...3)
            nextWag = wagUntil + .random(in: 4...10)
        }
        look += ((idle ? lookTarget : 0) - look) * ease(4)
        wag += ((idle && clock < wagUntil ? 0.4 : 0) - wag) * ease(6)
        shown.headTurn += look
        shown.tail += wag * sin(Float(clock) * 14)
    }

    // ponytail: weighted random idle choices; PetBrain (Plan 3) interrupts these with real jobs.
    private func wander() {
        if goal == .sleep { awakeSince = clock }  // just woke up
        if clock - awakeSince >= Self.napAfter {
            goal = .sleep
            nextDecision = clock + .random(in: 180...360)
            return
        }
        switch Double.random(in: 0..<1) {
        case ..<0.2:
            goal = .stand
            let band = Self.strollBand.lowerBound * map.width...Self.strollBand.upperBound * map.width
            let d = Double.random(in: 80...260) * (Bool.random() ? 1 : -1)
            let x = band.contains(gait.position.x + d) ? gait.position.x + d : gait.position.x - d  // turn back at the band's edge
            gait.target = SIMD2(min(max(x, band.lowerBound), band.upperBound), groundY)
        case ..<0.55:
            goal = .sit  // sit and watch the user
            nextDecision = clock + .random(in: 8...20)
        case ..<0.7:
            goal = .sitTilt
            nextDecision = clock + .random(in: 3...6)
        case ..<0.8:
            goal = .sniff
            nextDecision = clock + .random(in: 2...4)
        default:
            goal = .stand
            nextDecision = clock + .random(in: 4...8)
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
