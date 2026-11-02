import Testing
@testable import CrumbCore

@Test func poseBlending() {
    let stand = PoseName.stand.pose, bite = PoseName.bite.pose
    #expect(Pose.mix(stand, bite, 0) == stand, "t=0 is the first pose")
    #expect(Pose.mix(stand, bite, 1) == bite, "t=1 is the second pose")
    let half = Pose.mix(stand, bite, 0.5)
    #expect(half.jaw == (stand.jaw + bite.jaw) / 2, "every joint moves halfway")
    #expect(half.eyeOpen == (stand.eyeOpen + bite.eyeOpen) / 2, "eyes too")
    #expect(Set(PoseName.allCases.map(\.pose)).count == PoseName.allCases.count, "every pose is distinct")
    #expect(PoseName.bite.pose.jaw > PoseName.carry.pose.jaw, "biting opens wider than carrying")
}
