/// Damped spring for floppy parts (ears). Sub-steps so long frames stay stable.
public struct Spring: Sendable {
    public var value: Float = 0
    public var velocity: Float = 0
    public var stiffness: Float = 140
    public var damping: Float = 9

    public init() {}

    public mutating func step(toward target: Float, dt: Double) {
        var left = Float(min(dt, 2))  // the spring settles well within 2 s; also bounds the substep count
        while left > 0 {
            let h = min(left, 1.0 / 120)
            velocity += ((target - value) * stiffness - velocity * damping) * h
            value += velocity * h
            left -= h
        }
    }
}
