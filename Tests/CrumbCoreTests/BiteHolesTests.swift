import Testing
@testable import CrumbCore

@Test func biteHolesSweep() {
    let samples = (0...60).flatMap { i in (0...60).map { j in (x: Double(i) / 60, y: Double(j) / 60) } }
    func eaten(_ holes: [BiteHole]) -> Set<Int> {
        Set(samples.indices.filter { s in holes.contains { $0.covers(x: samples[s].x, y: samples[s].y) } })
    }
    for count in 1...10 {
        #expect(biteHoles(after: 0, of: count).isEmpty, "nothing eaten before the first bite (\(count))")
        #expect(eaten(biteHoles(after: count, of: count)).count == samples.count, "last bite eats it all (\(count))")
        var before = Set<Int>()
        for bite in 1...count {
            let holes = biteHoles(after: bite, of: count)
            let now = eaten(holes)
            #expect(now.isSuperset(of: before), "holes only grow (bite \(bite) of \(count))")
            before = now
            guard bite < count else { continue }
            let r = holes[0].r
            let edge = Double(bite) / Double(count)
            #expect(
                samples.indices.filter { samples[$0].x <= edge - r }.allSatisfy(now.contains),
                "everything behind the edge is gone (bite \(bite) of \(count))")
            #expect(now.count < samples.count, "some icon is left before the last bite (bite \(bite) of \(count))")
        }
    }
    #expect(!eaten(biteHoles(after: 1, of: 3)).contains(samples.firstIndex { $0.x == 1 && $0.y == 0.5 }!), "first bite leaves the far side")
}
