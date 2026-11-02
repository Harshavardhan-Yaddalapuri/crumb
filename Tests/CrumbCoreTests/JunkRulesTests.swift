import Testing
@testable import CrumbCore
import Foundation

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func daysAgo(_ d: Double) -> Date { now - d * 86_400 }

private func file(
    _ name: String, ageDays: Double = 30, _ tweak: (inout FileFacts) -> Void = { _ in }
) -> FileFacts {
    var f = FileFacts(name: name, modified: daysAgo(ageDays))
    tweak(&f)
    return f
}

@Test func junkRulesTable() {
    let table: [(FileFacts, Verdict, String)] = [
        (file("Screenshot 2026-10-01 at 9.41.12.png", ageDays: 8), .junk(.screenshot), "old screenshot"),
        (file("Screenshot 2026-10-30.png", ageDays: 2), .keep, "young screenshot"),
        (file("IMG_2231.png", ageDays: 8) { $0.isScreenCapture = true }, .junk(.screenshot), "Spotlight screen-capture flag"),
        (file("Screen Recording 2026-10-01.mov", ageDays: 10), .junk(.screenshot), "screen recording"),
        (file("Screenshot.png", ageDays: 30) { $0.lastUsed = daysAgo(1) }, .keep, "recently opened beats old modified date"),
        (file("Figma.dmg", ageDays: 4) { $0.containedAppInstalled = true }, .junk(.installer), "installer whose app is installed"),
        (file("Figma.dmg", ageDays: 4), .keep, "installer whose app is not installed"),
        (file("Figma.dmg", ageDays: 2) { $0.containedAppInstalled = true }, .keep, "young installer"),
        (file("Report (1).pdf", ageDays: 0) { $0.identicalOriginalExists = true }, .junk(.duplicate), "duplicate is immediate"),
        (file("Report copy.pdf", ageDays: 0) { $0.identicalOriginalExists = true }, .junk(.duplicate), "'copy' duplicate"),
        (file("Report (1).pdf", ageDays: 30), .keep, "duplicate name but contents differ"),
        (file("movie.mp4.crdownload", ageDays: 2), .junk(.partialDownload), "stale .crdownload"),
        (file("movie.mp4.part", ageDays: 0.5), .keep, "fresh .part"),
        (file("big.zip.download", ageDays: 2) { $0.isDirectory = true }, .junk(.partialDownload), "Safari .download bundle (a folder)"),
        (file("cache.tmp", ageDays: 2), .junk(.temp), ".tmp"),
        (file("~$Budget.xlsx", ageDays: 2), .junk(.temp), "Office lock file"),
        (file("Untitled Folder", ageDays: 2) { $0.isDirectory = true; $0.isEmptyDirectory = true }, .junk(.temp), "empty folder"),
        (file("Projects", ageDays: 90) { $0.isDirectory = true }, .keep, "non-empty folder"),
        (file("Screenshot.png", ageDays: 30) { $0.tags = ["Red"] }, .keep, "tagged file is never touched"),
        (file("Screenshot.png", ageDays: 30) { $0.neverAsk = true }, .keep, "'never ask' file"),
        (file("notes.txt", ageDays: 400), .keep, "ordinary old file"),
    ]
    for (facts, expected, what) in table {
        #expect(classify(facts, now: now) == expected, "\(what)")
    }
    #expect(classify(file("Screenshot.png"), now: now, enabled: [.temp]) == .keep, "disabled rule never matches")

    #expect(originalName(forDuplicate: "Report (1).pdf") == "Report.pdf", "dup name (1)")
    #expect(originalName(forDuplicate: "Report copy.pdf") == "Report.pdf", "dup name copy")
    #expect(originalName(forDuplicate: "Report copy 2.pdf") == "Report.pdf", "dup name copy 2")
    #expect(originalName(forDuplicate: "notes (12)") == "notes", "dup name without extension")
    #expect(originalName(forDuplicate: "Report.pdf") == nil, "not a dup name")
    #expect(originalName(forDuplicate: "(1).pdf") == nil, "dup marker with no base name")

    let old = file("a", ageDays: 10)
    let oldBig = file("b", ageDays: 10) { $0.size = 500 }
    let young = file("c", ageDays: 1)
    #expect(candidateOrder([young, old, oldBig]).map(\.name) == ["b", "a", "c"], "oldest first, then largest")
}
