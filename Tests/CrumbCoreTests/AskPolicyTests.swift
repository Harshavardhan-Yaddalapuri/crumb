import Testing
@testable import CrumbCore
import Foundation

@Test func askPolicy() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var p = AskPolicy()
    #expect(p.mayAsk(now: t0, bellyFull: false, napping: false), "first ask is allowed")
    p.lastAskAt = t0
    #expect(!p.mayAsk(now: t0 + 14 * 60, bellyFull: false, napping: false), "not again within 15 min")
    #expect(p.mayAsk(now: t0 + 15 * 60, bellyFull: false, napping: false), "allowed after 15 min")
    #expect(!p.mayAsk(now: t0 + 60 * 60, bellyFull: true, napping: false), "never with a full belly")
    #expect(!p.mayAsk(now: t0 + 60 * 60, bellyFull: false, napping: true), "never while napping")
    #expect(p.mayAsk(now: t0 - 3600, bellyFull: false, napping: false), "clock set backwards doesn't block")

    p.cleaningUp = true
    #expect(p.mayAsk(now: t0 + 1, bellyFull: false, napping: false), "Clean up now ignores the 15 min gap")
    #expect(!p.mayAsk(now: t0 + 1, bellyFull: true, napping: false), "Clean up now stops at a full belly")
    #expect(!p.mayAsk(now: t0 + 1, bellyFull: false, napping: true), "Clean up now doesn't wake a nap")
}
