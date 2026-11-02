import Testing
@testable import CrumbCore

@Test func springSettles() {
    var s = Spring()
    for _ in 0..<120 { s.step(toward: 1, dt: 1.0 / 60) }
    #expect(abs(s.value - 1) < 0.02, "settles on the target within 2 s")
    var big = Spring()
    big.step(toward: 1, dt: 5)  // e.g. the Mac woke from sleep
    #expect(abs(big.value - 1) < 0.02, "a huge time step stays stable")
    var bouncy = Spring()
    var peak: Float = 0
    for _ in 0..<60 { bouncy.step(toward: 1, dt: 1.0 / 60); peak = max(peak, bouncy.value) }
    #expect(peak > 1.05, "overshoots a little: ears flop")
}
