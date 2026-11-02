# Crumb Core (Plan 1 of 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove Finder icon positioning works (the spike), and build Crumb's UI-free core — junk rules, bite count, gap planner, belly — as a tested Swift library.

**Architecture:** One Swift package at the repo root. `CrumbCore` is a library of pure logic plus the `Belly` file mover; it never talks to Finder or draws anything. `CrumbCoreTests` tests it with Swift Testing. Plan 2 (written after the spike) adds the app target: PetOverlay, PetSprite, PetBrain, FolderWatcher, FinderBridge, and the scanner that fills in `FileFacts`.

**Tech Stack:** Swift 6 (language mode 6), Swift Package Manager, Swift Testing, Foundation only, macOS 14+, Xcode 27.2. Spike uses `osascript` (Apple Events — same path `NSAppleScript` uses).

**Spec:** `docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md`

---

## Read this first

- **Tests need Xcode, not the Command Line Tools.** Under the CLT alone, `import Testing` / `import XCTest` fail to build. Check with `xcode-select -p`: it must print `/Applications/Xcode.app/Contents/Developer`. If it prints `/Library/Developer/CommandLineTools`, either run `sudo xcode-select -s /Applications/Xcode.app` once, or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **"Red" in TDD here means a compile error.** Tests call functions that don't exist yet, so the first run fails with `cannot find '<name>' in scope`. That is the expected failing state.
- **One `@Test` per core file**, each a table or scenario full of `#expect`s with a message, so a failure names the case (e.g. `Expectation failed: … "Safari .download bundle (a folder)"`).
- **Grid model.** Finder fills the desktop top-to-bottom starting at the right edge. `Cell(col: 0, row: 0)` is the top-right slot; slot index = `col * rows + row`. Converting Finder's pixel positions to cells is Plan 2's job, using numbers measured in the spike.
- **Deviation from spec:** Belly uses `FileManager.trashItem(at:resultingItemURL:)` instead of `NSWorkspace.recycle`. It's synchronous and returns the Trash URL, which undo needs.

## File structure

| Path | Responsibility |
|---|---|
| `spike/finder_positions.sh` | Manual spike tool: read desktop layout, list icon positions, move one icon |
| `spike/FINDINGS.md` | Spike results and go/no-go decision; input to Plan 2 |
| `Package.swift` | Package with `CrumbCore` library + `CrumbCoreTests` test target |
| `.gitignore` | Ignore `.build/` and `.DS_Store` |
| `Sources/CrumbCore/BiteCount.swift` | File size → number of bites |
| `Sources/CrumbCore/JunkRules.swift` | `FileFacts` → `Verdict`; duplicate-name parsing; candidate order |
| `Sources/CrumbCore/GapPlanner.swift` | Icons on a grid + sort mode → ordered moves |
| `Sources/CrumbCore/Belly.swift` | Staging, per-file digest timers, Trash, undo ledger |
| `Tests/CrumbCoreTests/*Tests.swift` | One test file per core file |

---

### Task 1: FinderBridge spike (needs a human at the Mac)

This is the spec's core risk: can Crumb set a desktop icon's position through Finder and have it stick? A subagent can write the script, but a person must run it, approve the Automation prompt, and watch the desktop. Tasks 2–5 don't depend on this task and can run in parallel.

**Files:**
- Create: `spike/finder_positions.sh`
- Create: `spike/FINDINGS.md`

- [ ] **Step 1: Write the spike script**

`spike/finder_positions.sh`:

```bash
#!/bin/bash
# FinderBridge spike: can we read and set desktop icon positions, and do they stick?
#   spike/finder_positions.sh view                    # desktop bounds, icon size, arrangement, grid spacing
#   spike/finder_positions.sh list                    # every desktop item: name<TAB>x,y
#   spike/finder_positions.sh move "<name>" <x> <y>   # set one item's position, print it back after 1s
set -euo pipefail

case "${1:-}" in
view)
    osascript -e 'tell application "Finder" to get bounds of window of desktop'
    osascript -e 'tell application "Finder" to get {icon size, arrangement} of icon view options of window of desktop'
    defaults read com.apple.finder DesktopViewSettings 2>/dev/null || echo "(no DesktopViewSettings in com.apple.finder)"
    ;;
list)
    osascript <<'EOF'
tell application "Finder"
    set out to ""
    -- Fetch into a variable first: looping over "every item of desktop" directly runs zero times.
    set desktopItems to every item of desktop
    repeat with i in desktopItems
        set p to desktop position of i
        set out to out & (name of i) & tab & (item 1 of p) & "," & (item 2 of p) & linefeed
    end repeat
    return out
end tell
EOF
    ;;
move)
    [ $# -eq 4 ] || { echo "usage: $0 move \"<name>\" <x> <y>" >&2; exit 2; }
    osascript - "$2" "$3" "$4" <<'EOF'
on run argv
    set {n, x, y} to argv
    tell application "Finder"
        set desktop position of item n of desktop to {x as integer, y as integer}
        delay 1
        return desktop position of item n of desktop
    end tell
end run
EOF
    ;;
*)
    sed -n '2,5p' "$0"
    exit 2
    ;;
esac
```

Run: `chmod +x spike/finder_positions.sh && bash -n spike/finder_positions.sh && echo ok`
Expected: `ok`

- [ ] **Step 2: Record the desktop layout**

Run: `spike/finder_positions.sh view`
Expected: the first run triggers "Terminal wants to control Finder" — click **Allow**. Output has three parts: desktop bounds like `0, 0, 1512, 982`; `{64, not arranged}` (icon size, arrangement); and a plist dump that should include `IconViewSettings` → `gridSpacing`. If the arrangement isn't `not arranged`, right-click the desktop → **Sort By → None**, and turn off **Use Stacks**, then re-run. Paste all output into FINDINGS.md.

- [ ] **Step 3: Read positions**

Run: `touch ~/Desktop/crumb-spike.txt && spike/finder_positions.sh list`
Expected: one line per desktop item, e.g. `crumb-spike.txt	1440,620`. Paste into FINDINGS.md.

- [ ] **Step 4: Set a position and verify it**

Pick an empty spot (e.g. 200 px left of the rightmost column, same y as the top icon). Run:
`spike/finder_positions.sh move "crumb-spike.txt" <x> <y>`
Expected (success): prints `<x>, <y>` (or the nearest grid point) and the icon visibly jumps there. Record the printed value and whether you saw the move.

- [ ] **Step 5: Check it sticks**

Wait 10 s and run `spike/finder_positions.sh list` again. Then run `killall Finder`, wait for the desktop to come back, and run `list` again.
Expected (success): `crumb-spike.txt` reports the moved position all three times.

- [ ] **Step 6: Check snapping and timing**

Run `move` with an off-grid point (target x + 17, y + 9). Record whether the printed value snapped to the grid. Then time 10 moves:
`time (for i in 1 2 3 4 5 6 7 8 9 10; do spike/finder_positions.sh move "crumb-spike.txt" <x> <y> >/dev/null; done)`
Subtract 10 s for the built-in 1 s delays to get per-move latency.

- [ ] **Step 7: Check the failure modes**

1. Desktop **Sort By → Name**, then `move` → record whether it's refused, ignored, or works.
2. **Use Stacks** on, then `move` → record.
3. Set both back to off/None.

- [ ] **Step 8: Measure the grid**

Right-click the desktop → **Clean Up**, put ≥ 4 icons in the first column and ≥ 1 in the second, run `list`. Record:
- column x spacing (x difference between columns)
- row y spacing (y difference between rows)
- x of the rightmost column, y of the top row
- rows per column for the current screen height

- [ ] **Step 9: Write FINDINGS.md and decide**

`spike/FINDINGS.md`:

```markdown
# FinderBridge Spike — Findings

Date: <date>  ·  macOS: <sw_vers -productVersion>

## Raw output
<paste output from steps 2, 3, 8>

## Results
| Question | Result |
|---|---|
| Set position works (Sort By None) | yes / no |
| Read-back matches target | yes / no (got …) |
| Survives 10 s | yes / no |
| Survives `killall Finder` | yes / no |
| Off-grid target snaps | yes / no |
| Per-move latency | … ms |
| With Sort By = Name | refused / ignored / works |
| With Use Stacks | refused / ignored / works |

## Grid
column spacing … px · row spacing … px · rightmost column x … · top row y … · rows per column …

## Decision
GO: set-and-verify is reliable → Plan 2 builds FinderBridge on per-icon positioning.
or NO-GO: → Plan 2 uses the spec fallback (set Finder's "Sort By" via Apple Events; pet animation is visual only).
```

GO requires all of: set works, read-back matches, survives 10 s, survives `killall Finder`.

- [ ] **Step 10: Clean up and commit**

```bash
rm ~/Desktop/crumb-spike.txt
git add spike/
git commit -m "Spike: Finder desktop icon positioning findings"
```

---

### Task 2: Package scaffold and bite count

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Sources/CrumbCore/BiteCount.swift`
- Test: `Tests/CrumbCoreTests/BiteCountTests.swift`

- [ ] **Step 1: Create the package and ignore file**

`Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Crumb",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CrumbCore"),
        .testTarget(name: "CrumbCoreTests", dependencies: ["CrumbCore"]),
    ]
)
```

`.gitignore`:

```
.build/
.DS_Store
```

- [ ] **Step 2: Write the failing test**

Spec: N = round(1 + 2 × log10(sizeMB + 1)), clamped 1…10; 2.4 MB → 2, 45 MB → 4, 180 MB → 6, 1.4 GB → 7. MB = 1,000,000 bytes.

`Tests/CrumbCoreTests/BiteCountTests.swift`:

```swift
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
```

`Sources/CrumbCore/BiteCount.swift` (empty for now; SwiftPM needs at least one file in the target):

```swift
import Foundation
```

- [ ] **Step 3: Run to see it fail**

Run: `swift test`
Expected: build error `cannot find 'biteCount' in scope`.

- [ ] **Step 4: Implement**

`Sources/CrumbCore/BiteCount.swift`:

```swift
import Foundation

/// How many bites Crumb takes to eat a file: round(1 + 2 × log10(sizeMB + 1)), clamped to 1…10.
public func biteCount(bytes: Int64) -> Int {
    let mb = Double(bytes) / 1_000_000
    return min(10, max(1, Int((1 + 2 * log10(mb + 1)).rounded())))
}
```

- [ ] **Step 5: Run to see it pass**

Run: `swift test`
Expected: `✔ Test biteCountMatchesSpec() passed` and `Test run with 1 test … passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources/ Tests/
git commit -m "Add Swift package and bite count"
```

---

### Task 3: JunkRules

Pure classification. A scanner (Plan 2) gathers `FileFacts` from Spotlight/FileManager, including the two IO-heavy flags (`containedAppInstalled`, `identicalOriginalExists`). The scanner uses `originalName(forDuplicate:)` to find which original to byte-compare. This is the main file-safety gate, so the table covers every rule plus every "never touch" case.

**Files:**
- Create: `Sources/CrumbCore/JunkRules.swift`
- Test: `Tests/CrumbCoreTests/JunkRulesTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/CrumbCoreTests/JunkRulesTests.swift`:

```swift
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
```

Note: the message is `"\(what)"`, not `what`. `#expect` takes a `Comment`, which a string literal converts to but a `String` variable doesn't.

- [ ] **Step 2: Run to see it fail**

Run: `swift test`
Expected: build errors `cannot find type 'FileFacts' in scope` / `cannot find 'classify' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrumbCore/JunkRules.swift`:

```swift
import Foundation

private let day: TimeInterval = 86_400

public enum JunkReason: String, CaseIterable, Codable, Sendable {
    case screenshot, installer, duplicate, partialDownload, temp

    /// How long since last use before a file of this kind counts as junk.
    public var minAge: TimeInterval {
        switch self {
        case .screenshot: 7 * day
        case .installer: 3 * day
        case .duplicate: 0
        case .partialDownload, .temp: 1 * day
        }
    }
}

public enum Verdict: Equatable, Sendable {
    case junk(JunkReason)
    case keep
}

/// Everything the rules need to know about one file. A scanner gathers these (IO); the rules stay pure.
public struct FileFacts: Sendable {
    public var name: String
    public var modified: Date
    public var lastUsed: Date? = nil
    public var size: Int64 = 0
    public var isDirectory = false
    public var isEmptyDirectory = false
    public var tags: [String] = []
    public var isScreenCapture = false
    public var neverAsk = false
    /// .dmg / .pkg / .zip only: the app inside already exists in /Applications.
    public var containedAppInstalled = false
    /// "x (1).ext" / "x copy.ext" only: a byte-identical original sits in the same folder.
    public var identicalOriginalExists = false

    public init(name: String, modified: Date) {
        self.name = name
        self.modified = modified
    }
}

/// Decide whether one file is junk. Tagged and "never ask" files are always kept.
public func classify(
    _ f: FileFacts, now: Date, enabled: Set<JunkReason> = Set(JunkReason.allCases)
) -> Verdict {
    if !f.tags.isEmpty || f.neverAsk { return .keep }
    guard let reason = reason(for: f), enabled.contains(reason) else { return .keep }
    let age = now.timeIntervalSince(f.lastUsed ?? f.modified)
    return age >= reason.minAge ? .junk(reason) : .keep
}

private func reason(for f: FileFacts) -> JunkReason? {
    let ext = (f.name as NSString).pathExtension.lowercased()
    // Before the folder check: Safari's .download is a folder bundle.
    if ["crdownload", "part", "download"].contains(ext) { return .partialDownload }
    if f.isDirectory { return f.isEmptyDirectory ? .temp : nil }
    if f.isScreenCapture || f.name.hasPrefix("Screenshot") || f.name.hasPrefix("Screen Recording") {
        return .screenshot
    }
    if ext == "tmp" || f.name.hasPrefix("~$") { return .temp }
    if ["dmg", "pkg", "zip"].contains(ext) && f.containedAppInstalled { return .installer }
    if f.identicalOriginalExists && originalName(forDuplicate: f.name) != nil { return .duplicate }
    return nil
}

/// "Report (1).pdf" / "Report copy.pdf" / "Report copy 2.pdf" → "Report.pdf". Nil if not a duplicate name.
public func originalName(forDuplicate name: String) -> String? {
    let ext = (name as NSString).pathExtension
    let stem = (name as NSString).deletingPathExtension
    guard let r = stem.range(of: #" (\(\d+\)|copy( \d+)?)$"#, options: .regularExpression) else { return nil }
    let base = String(stem[..<r.lowerBound])
    guard !base.isEmpty else { return nil }
    return ext.isEmpty ? base : "\(base).\(ext)"
}

/// Ask about the oldest junk first; ties go to the biggest file.
public func candidateOrder(_ files: [FileFacts]) -> [FileFacts] {
    files.sorted { a, b in
        let ad = a.lastUsed ?? a.modified, bd = b.lastUsed ?? b.modified
        return ad != bd ? ad < bd : a.size > b.size
    }
}
```

Notes:
- The partial-download check runs before the folder check, because Safari's `.download` is a folder bundle and would otherwise be kept as a non-empty folder.
- Non-empty folders fall through to `nil` → `.keep`.
- Age is `lastUsed ?? modified`, for every rule (spec §2).

- [ ] **Step 4: Run to see it pass**

Run: `swift test`
Expected: `Test run with 2 tests … passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ Tests/
git commit -m "Add JunkRules with table-driven tests"
```

---

### Task 4: GapPlanner

**Files:**
- Create: `Sources/CrumbCore/GapPlanner.swift`
- Test: `Tests/CrumbCoreTests/GapPlannerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/CrumbCoreTests/GapPlannerTests.swift`:

```swift
import Testing
@testable import CrumbCore
import Foundation

private func icon(_ id: String, _ col: Int, _ row: Int, kind: String = "pdf", age: Double = 0) -> DesktopIcon {
    DesktopIcon(id: id, name: id, kind: kind, date: Date(timeIntervalSince1970: age), cell: Cell(col: col, row: row))
}

/// Apply the planned moves and read the desktop back in reading order.
private func arrangement(_ icons: [DesktopIcon], rows: Int, _ sort: SortMode) -> [String] {
    let moved = Dictionary(uniqueKeysWithValues: planMoves(icons, rows: rows, sort: sort).map { ($0.id, $0.to) })
    return icons
        .map { (id: $0.id, cell: moved[$0.id] ?? $0.cell) }
        .sorted { $0.cell.col * rows + $0.cell.row < $1.cell.col * rows + $1.cell.row }
        .map(\.id)
}

@Test func gapPlannerMoves() {
    // Column 0: A, B, (gap)   Column 1: D
    let oneGap = [icon("A", 0, 0), icon("B", 0, 1), icon("D", 1, 0)]
    #expect(
        planMoves(oneGap, rows: 3, sort: .off) == [Move(id: "D", from: Cell(col: 1, row: 0), to: Cell(col: 0, row: 2))],
        "closes a single gap with one move")
    #expect(planMoves([icon("A", 0, 0), icon("B", 0, 1)], rows: 3, sort: .off).isEmpty, "no gaps, no moves")

    // Column 0: (gap), A, (gap)   Column 1: B, C
    let holes = [icon("A", 0, 1), icon("B", 1, 0), icon("C", 1, 1)]
    let moves = planMoves(holes, rows: 3, sort: .off)
    #expect(moves.map(\.id) == ["A", "B", "C"], "shifts icons up in reading order")
    #expect(moves.map(\.to) == [Cell(col: 0, row: 0), Cell(col: 0, row: 1), Cell(col: 0, row: 2)], "targets are the first slots")

    let mixed = [
        icon("Apple.png", 0, 0, kind: "png", age: 1),
        icon("Alpha.pdf", 0, 1, kind: "pdf", age: 3),
        icon("beta 10.pdf", 0, 2, kind: "pdf", age: 2),
        icon("beta 9.pdf", 1, 0, kind: "pdf", age: 0),
    ]
    #expect(arrangement(mixed, rows: 3, .name) == ["Alpha.pdf", "Apple.png", "beta 9.pdf", "beta 10.pdf"], "name sort is Finder-like")
    #expect(arrangement(mixed, rows: 3, .kind) == ["Alpha.pdf", "beta 9.pdf", "beta 10.pdf", "Apple.png"], "kind sort groups by type")
    #expect(arrangement(mixed, rows: 3, .date) == ["Alpha.pdf", "beta 10.pdf", "Apple.png", "beta 9.pdf"], "date sort is newest first")
    for mode in SortMode.allCases {
        let targets = planMoves(mixed, rows: 3, sort: mode).map(\.to)
        #expect(Set(targets).count == targets.count, "\(mode): every target cell is distinct")
    }
}
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test`
Expected: build errors `cannot find type 'DesktopIcon' in scope` / `cannot find 'planMoves' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrumbCore/GapPlanner.swift`:

```swift
import Foundation

/// A desktop grid slot. Finder fills the desktop top-to-bottom starting at the right edge,
/// so col 0 is the rightmost column and row 0 the top row.
public struct Cell: Hashable, Codable, Sendable {
    public var col: Int
    public var row: Int
    public init(col: Int, row: Int) {
        self.col = col
        self.row = row
    }
}

public struct DesktopIcon: Sendable {
    public var id: String  // file path
    public var name: String
    public var kind: String  // file extension, lowercased
    public var date: Date  // date added
    public var cell: Cell
    public init(id: String, name: String, kind: String, date: Date, cell: Cell) {
        self.id = id
        self.name = name
        self.kind = kind
        self.date = date
        self.cell = cell
    }
}

public enum SortMode: String, CaseIterable, Codable, Sendable {
    case off, kind, date, name
}

public struct Move: Equatable, Sendable {
    public var id: String
    public var from: Cell
    public var to: Cell
    public init(id: String, from: Cell, to: Cell) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// Pack icons into the first slots with no gaps. `.off` keeps the current reading order;
/// other modes sort first. Moves come in target-slot order, so in `.off` each target is already free.
/// ponytail: sort modes can briefly stack two icons on one cell mid-haul; add swap-aware ordering if it looks bad.
public func planMoves(_ icons: [DesktopIcon], rows: Int, sort: SortMode) -> [Move] {
    precondition(rows > 0, "grid needs at least one row")
    func slot(_ c: Cell) -> Int { c.col * rows + c.row }
    func byName(_ a: DesktopIcon, _ b: DesktopIcon) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    let ordered: [DesktopIcon] =
        switch sort {
        case .off: icons.sorted { slot($0.cell) < slot($1.cell) }
        case .name: icons.sorted(by: byName)
        case .kind: icons.sorted { $0.kind != $1.kind ? $0.kind < $1.kind : byName($0, $1) }
        case .date: icons.sorted { $0.date != $1.date ? $0.date > $1.date : byName($0, $1) }
        }
    return ordered.enumerated().compactMap { i, icon in
        let to = Cell(col: i / rows, row: i % rows)
        return to == icon.cell ? nil : Move(id: icon.id, from: icon.cell, to: to)
    }
}
```

Why `.off` never collides: an icon at slot `s` gets target rank `r ≤ s`. The icon currently at target slot `k` has rank `≤ k`, so either it's the same icon (no move) or it already moved earlier in the list.

- [ ] **Step 4: Run to see it pass**

Run: `swift test`
Expected: `Test run with 3 tests … passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ Tests/
git commit -m "Add GapPlanner with gap and sort-mode tests"
```

---

### Task 5: Belly

Holds eaten files in a staging folder, gives each its own 15-min timer, moves them to the Trash on burp, and keeps an undo ledger (`belly.json`) that survives relaunch. The clock and the Trash are injected so tests run instantly in a temp folder and never touch the real Trash.

Production location: `~/Library/Application Support/Crumb/Belly/` (Plan 2 passes this in).

**Files:**
- Create: `Sources/CrumbCore/Belly.swift`
- Test: `Tests/CrumbCoreTests/BellyTests.swift`

- [ ] **Step 1: Write the failing test**

Covers the spec's test list: eat → digest → Trash, per-file timers (3 at t=0 and 1 at t=10 → 3 burp at t=15, 1 at t=25), capacity cap at 5, spit out mid-digest, spit out after burp, crash-recovery sweep. Also checks that spit out never overwrites a new file.

`Tests/CrumbCoreTests/BellyTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to see it fail**

Run: `swift test`
Expected: build errors `cannot find 'Belly' in scope` / `cannot find 'bellyCapacity' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrumbCore/Belly.swift`:

```swift
import Foundation

public let bellyCapacity = 5
public let digestDuration: TimeInterval = 15 * 60
/// Files whose digest timers end within this many seconds burp together.
public let burpGroupWindow: TimeInterval = 3

public struct BellyEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let originalPath: String
    public let desktopCell: Cell?
    public let eatenAt: Date
    /// Staging path while digesting; Trash path after the burp.
    public var location: String
    public var burped: Bool

    public var digestEndsAt: Date { eatenAt + digestDuration }
}

public enum BellyError: Error, Equatable {
    case full
    case notFound
    case destinationExists(String)
}

/// Holds eaten files in a staging folder for 15 minutes each, then moves them to the Trash.
/// Keeps an undo ledger (belly.json) so any file can be spat back out, before or after its burp.
public final class Belly {
    public private(set) var history: [BellyEntry] = []
    private let dir: URL
    private let now: () -> Date
    private let trash: (URL) throws -> URL
    private var ledger: URL { dir.appendingPathComponent("belly.json") }

    /// `trash` moves a file to the Trash and returns where it landed.
    public init(
        directory: URL,
        now: @escaping () -> Date = Date.init,
        trash: @escaping (URL) throws -> URL = Belly.systemTrash
    ) throws {
        self.dir = directory
        self.now = now
        self.trash = trash
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: ledger) {
            history = try JSONDecoder().decode([BellyEntry].self, from: data)
        }
    }

    public static func systemTrash(_ url: URL) throws -> URL {
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        return (out as URL?) ?? url
    }

    public var digesting: [BellyEntry] { history.filter { !$0.burped } }
    public var isFull: Bool { digesting.count >= bellyCapacity }
    /// When to call `burp()` next, or nil if the belly is empty.
    public var nextBurpAt: Date? { digesting.map(\.digestEndsAt).min() }

    @discardableResult
    public func eat(_ file: URL, cell: Cell?) throws -> BellyEntry {
        guard !isFull else { throw BellyError.full }
        let id = UUID()
        let staged = dir.appendingPathComponent("\(id.uuidString)-\(file.lastPathComponent)")
        try FileManager.default.moveItem(at: file, to: staged)
        let entry = BellyEntry(
            id: id, originalPath: file.path, desktopCell: cell, eatenAt: now(), location: staged.path, burped: false)
        history.append(entry)
        do {
            try save()
        } catch {
            // Never hold a file the ledger doesn't know about.
            history.removeLast()
            try? FileManager.default.moveItem(at: staged, to: file)
            throw error
        }
        return entry
    }

    /// Trash every file whose digest timer has ended (or ends within `burpGroupWindow`).
    /// Call when `nextBurpAt` arrives, and once at launch to recover from a crash.
    @discardableResult
    public func burp() throws -> [BellyEntry] {
        let cutoff = now() + burpGroupWindow
        var burped: [BellyEntry] = []
        for i in history.indices where !history[i].burped && history[i].digestEndsAt <= cutoff {
            do {
                history[i].location = try trash(URL(fileURLWithPath: history[i].location)).path
            } catch {
                try? save()
                throw error
            }
            history[i].burped = true
            burped.append(history[i])
        }
        if !burped.isEmpty { try save() }
        return burped
    }

    /// Undo: put the file back at its original path, from staging or from the Trash.
    @discardableResult
    public func spitOut(_ id: UUID) throws -> BellyEntry {
        guard let i = history.firstIndex(where: { $0.id == id }) else { throw BellyError.notFound }
        let entry = history[i]
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.location) else { throw BellyError.notFound }  // e.g. Trash emptied
        guard !fm.fileExists(atPath: entry.originalPath) else {
            throw BellyError.destinationExists(entry.originalPath)
        }
        try fm.moveItem(atPath: entry.location, toPath: entry.originalPath)
        history.remove(at: i)
        try save()
        return entry
    }

    // ponytail: history keeps every burped entry forever; prune ones whose Trash file is gone if the ledger grows.
    private func save() throws {
        try JSONEncoder().encode(history).write(to: ledger, options: .atomic)
    }
}
```

Data-safety notes:
- `eat` moves the file, then writes the ledger; if the write fails it moves the file back, so a file is never held without a record.
- `burp` saves after each partial failure, so the ledger matches what's actually in the Trash.
- Crash recovery is just `burp()` at launch: anything ≥ 15 min old goes to the Trash; younger files keep their original `eatenAt`.

- [ ] **Step 4: Run to see it pass**

Run: `swift test`
Expected: all four tests pass — `Test run with 4 tests … passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/ Tests/
git commit -m "Add Belly: staging, per-file digest timers, Trash, undo ledger"
```

---

## Out of scope here (Plan 2, after the spike)

PetOverlay window, PetSprite skeletal animation (bite timing 0.5 s / 0.35 s when N > 5 lives there), PetBrain state machine and anti-annoyance rules, FolderWatcher (FSEvents), the `FileFacts` scanner, FinderBridge (pixel ↔ cell conversion uses Task 1's grid numbers), Burrow, permissions UI, pet menu, Settings.
