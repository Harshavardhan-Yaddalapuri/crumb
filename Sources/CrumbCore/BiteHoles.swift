/// A round bite out of an icon, in unit coordinates: 0…1 across the icon, y down, radius `r`.
public struct BiteHole: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var r: Double

    public init(x: Double, y: Double, r: Double) {
        self.x = x
        self.y = y
        self.r = r
    }

    public func covers(x px: Double, y py: Double) -> Bool {
        (px - x) * (px - x) + (py - y) * (py - y) <= r * r
    }
}

/// The holes in an icon after `bite` of `count` bites, eaten from the left (mirror x when eating from the right).
/// Bite k leaves a scalloped edge at x = k / count with everything behind it gone; the last bite takes it all.
/// Holes only ever grow from one bite to the next.
/// `count` is 1…10 (the range of `biteCount`); above about 13 the 0.12 minimum radius would let holes shrink.
public func biteHoles(after bite: Int, of count: Int) -> [BiteHole] {
    precondition((1...10).contains(count) && (0...count).contains(bite), "bite \(bite) of \(count)")
    if bite == 0 { return [] }
    if bite == count { return [BiteHole(x: 0.5, y: 0.5, r: 0.75)] }  // reaches the corners (0.707 away)
    let r = max(0.12, 0.6 / Double(count))
    var holes: [BiteHole] = []
    // Everything behind the latest edge: a square grid of spacing r covers the whole area it spans.
    let edge = Double(bite) / Double(count)
    var x = edge - r
    while x > -r {
        var y = 0.0
        while y <= 1 + r / 2 {
            holes.append(BiteHole(x: x, y: y, r: r))
            y += r
        }
        x -= r
    }
    // The edge: spaced-out circles, centred just behind it, carve round bite marks into what's left.
    // The next bite's fill covers them, so holes only grow.
    let n = max(2, Int((1 / (2.2 * r)).rounded()))
    for i in 0...n { holes.append(BiteHole(x: edge - r / 2, y: Double(i) / Double(n), r: r)) }
    return holes
}
