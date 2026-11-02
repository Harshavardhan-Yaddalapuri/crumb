import Testing
@testable import CrumbCore
import Foundation

private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(minutes: Double) { now += minutes * 60 }
}

@Test func bellyLifecycle() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("crumb-checks-\(UUID().uuidString)")
    let desk = root.appendingPathComponent("Desktop")
    let trashDir = root.appendingPathComponent("Trash")
    let staging = root.appendingPathComponent("Belly")
    for d in [desk, trashDir] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
    defer { try? fm.removeItem(at: root) }

    func makeFile(_ name: String) throws -> URL {
        let url = desk.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }
    let fakeTrash: (URL) throws -> URL = { url in
        let dest = trashDir.appendingPathComponent(url.lastPathComponent)
        try fm.moveItem(at: url, to: dest)
        return dest
    }
    let clock = Clock()
    func openBelly() throws -> Belly { try Belly(directory: staging, now: { clock.now }, trash: fakeTrash) }

    var belly = try openBelly()

    // Per-file timers: eat 3 at t=0 and 1 at t=10 → 3 burp at t=15, 1 at t=25.
    let a = try belly.eat(try makeFile("a.png"), cell: Cell(col: 0, row: 0))
    try belly.eat(try makeFile("b.png"), cell: nil)
    try belly.eat(try makeFile("c.png"), cell: nil)
    #expect(!fm.fileExists(atPath: a.originalPath), "eaten file leaves the desktop")
    #expect(fm.fileExists(atPath: a.location), "eaten file is held in staging")
    clock.advance(minutes: 10)
    try belly.eat(try makeFile("d.png"), cell: nil)
    #expect(belly.nextBurpAt == a.digestEndsAt, "next burp is the oldest file's")
    #expect(try belly.burp().isEmpty, "nothing burps at t=10")
    clock.advance(minutes: 5)
    #expect(try belly.burp().count == 3, "three files burp together at t=15")
    #expect(belly.history.first { $0.id == a.id }?.location.hasPrefix(trashDir.path) == true, "burped file is in the Trash")
    #expect(belly.digesting.map(\.originalPath) == [desk.appendingPathComponent("d.png").path], "only d is still digesting")
    clock.advance(minutes: 10)
    #expect(try belly.burp().count == 1, "d burps at t=25")
    #expect(belly.nextBurpAt == nil, "empty belly has no next burp")

    // Capacity: 5 files max.
    for n in 1...bellyCapacity { try belly.eat(try makeFile("f\(n).txt"), cell: nil) }
    #expect(belly.isFull, "full at \(bellyCapacity)")
    let extra = try makeFile("extra.txt")
    #expect(throws: BellyError.full) { try belly.eat(extra, cell: nil) }
    #expect(fm.fileExists(atPath: extra.path), "refused file stays where it was")

    // Spit out mid-digest.
    let f1 = belly.digesting[0]
    try belly.spitOut(f1.id)
    #expect(fm.fileExists(atPath: f1.originalPath), "spit-out file is back at its original path")
    #expect(!belly.isFull, "spitting out frees a slot")

    // Spit out after burp: restore from Trash.
    try belly.spitOut(a.id)
    #expect(fm.fileExists(atPath: a.originalPath), "burped file restored from Trash")
    #expect(try Data(contentsOf: URL(fileURLWithPath: a.originalPath)) == Data("a.png".utf8), "restored contents intact")

    // Never overwrite something new at the original path.
    let f2 = belly.digesting[0]
    try Data().write(to: URL(fileURLWithPath: f2.originalPath))
    #expect(throws: BellyError.destinationExists(f2.originalPath)) { try belly.spitOut(f2.id) }
    try fm.removeItem(atPath: f2.originalPath)

    // Crash recovery: a fresh Belly reloads the ledger; overdue files burp at launch, young ones keep counting.
    clock.advance(minutes: 20)
    let young = try belly.eat(try makeFile("young.txt"), cell: nil)
    belly = try openBelly()
    #expect(belly.digesting.count == 5, "ledger survives relaunch")
    #expect(try belly.burp().count == 4, "overdue files burp at launch")
    #expect(belly.digesting.map(\.id) == [young.id], "younger file resumes its countdown")
}
