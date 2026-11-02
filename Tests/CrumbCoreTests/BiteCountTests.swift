import Testing
@testable import CrumbCore

@Test func biteCountMatchesSpec() {
    let mb: Int64 = 1_000_000
    #expect(biteCount(bytes: 0) == 1, "empty file still takes one bite")
    #expect(biteCount(bytes: 24 * mb / 10) == 2, "2.4 MB → 2")
    #expect(biteCount(bytes: 45 * mb) == 4, "45 MB → 4")
    #expect(biteCount(bytes: 180 * mb) == 6, "180 MB → 6")
    #expect(biteCount(bytes: 1_400 * mb) == 7, "1.4 GB → 7")
    #expect(biteCount(bytes: 1_000_000 * mb) == 10, "1 TB clamps to 10")
}
