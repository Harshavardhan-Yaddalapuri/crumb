/// Walking in screen points. The walk cycle advances with distance covered, not time, so feet never slide.
public struct Gait: Sendable {
    public static let speed = 70.0  // strolling, points per second
    public static let stride = 36.0  // points per full leg cycle

    public var position: SIMD2<Double>
    public var target: SIMD2<Double>
    /// 0..<1 through the leg cycle.
    public private(set) var phase = 0.0
    /// +1 facing right, -1 facing left; the last horizontal direction walked.
    public private(set) var facing = 1
    /// Points per second; jobs trot faster than strolls. The legs keep up because the cycle follows distance.
    public var pace = Gait.speed

    public init(at p: SIMD2<Double>) {
        position = p
        target = p
    }

    public var isWalking: Bool { position != target }

    /// Moves toward the target; returns the distance covered.
    public mutating func step(_ dt: Double) -> Double {
        let delta = target - position
        let dist = (delta * delta).sum().squareRoot()
        guard dist > 0 else { return 0 }
        let move = min(dist, pace * dt)
        position = move == dist ? target : position + delta * (move / dist)
        if abs(delta.x) > 0.5 { facing = delta.x > 0 ? 1 : -1 }  // ignore sub-point drift so it doesn't flip as it arrives
        phase = (phase + move / Self.stride).truncatingRemainder(dividingBy: 1)
        return move
    }
}
