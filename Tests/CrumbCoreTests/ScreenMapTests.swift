import Testing
@testable import CrumbCore
import CoreGraphics

@Test func screenMapRoundTrips() {
    let map = ScreenMap(width: 1920, height: 1080, pointsPerMeter: 100)
    #expect(map.world(CGPoint(x: 960, y: 540)) == SIMD2(0, 0), "screen centre is the world origin")
    #expect(map.world(CGPoint(x: 1060, y: 440)) == SIMD2(1, 1), "right and up are +x and +y")
    #expect(map.screen(SIMD2(-2, -1)) == CGPoint(x: 760, y: 640), "and back again")
    // The rightmost desktop icon column measured in the Finder spike.
    let back = map.screen(map.world(CGPoint(x: 1854, y: 70)))
    #expect(abs(back.x - 1854) < 0.01 && abs(back.y - 70) < 0.01, "round trip (Float precision)")
    // RealityKit's OrthographicCameraComponent.scale is half the visible height (measured in the render spike).
    #expect(abs(map.cameraScale - 5.4) < 1e-6, "1080 pt tall at 100 pt/m is 10.8 m, half of it is 5.4")
}
