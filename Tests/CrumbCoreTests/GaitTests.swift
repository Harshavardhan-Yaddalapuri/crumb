import Testing
@testable import CrumbCore

@Test func gaitIsDistanceLocked() {
    var g = Gait(at: SIMD2(100, 500))
    #expect(!g.isWalking && g.step(1) == 0 && g.phase == 0, "standing still doesn't advance the walk cycle")

    g.target = SIMD2(100 + Gait.stride * 2.25, 500)
    var walked = 0.0
    for _ in 0..<600 { walked += g.step(1.0 / 60) }
    #expect(g.position == g.target && !g.isWalking, "arrives exactly, no overshoot")
    #expect(abs(walked - Gait.stride * 2.25) < 1e-9, "distance walked is the distance to the target")
    #expect(abs(g.phase - 0.25) < 1e-9, "2.25 strides leave the cycle a quarter through")
    #expect(g.facing == 1, "walked right, faces right")

    g.target = SIMD2(0, 500)
    _ = g.step(0.1)
    #expect(g.facing == -1, "turns to face left")
    #expect(abs(g.position.x - (100 + Gait.stride * 2.25 - Gait.speed * 0.1)) < 1e-9, "moves at walking speed")

    g.target = g.position + SIMD2(0, 50)
    _ = g.step(0.1)
    #expect(g.facing == -1, "straight up or down keeps the last facing")
}
