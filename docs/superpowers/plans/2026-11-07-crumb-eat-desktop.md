# Crumb Eats Desktop Junk (Plan 4a of 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crumb finds junk on the Desktop (old screenshots, installers whose app is installed, exact copies, unfinished downloads, temp files). It asks before eating any of it. On **Yum** it bites the icon away, holds the file in its belly for 15 minutes, then burps it into the Trash. You can spit any file back out from the Belly menu until the Trash is emptied. **Clean up now** asks about one file after another. With 5 files in its belly Crumb is stuffed: round, slow, and asleep until a slot frees.

**Architecture:**
- **CrumbCore** gets three pure, tested pieces:
  - `AskPolicy`: when Crumb may interrupt.
  - `biteHoles`: the bite pattern taken out of an icon.
  - `installerMatchesInstalledApp`: "Figma-124.dmg" ↔ "Figma.app".
  - `Belly`, `biteCount`, `classify` and `candidateOrder` already exist and are tested; this plan wires them in.
- **The app** gains:
  - `Scanner`: file system and Spotlight reads → `FileFacts`.
  - `MealView` and `IconPicture`: a same-size picture of the icon, with bite holes.
  - `Eater`: sniff → ask → eat → digest → burp → spit out.
  - `BellyMenu`.
  - Small hooks: `Hauler.paused`, and `Pet.fullness` / `digestNap`.

**The real icon is never shrunk or copied while visible.** At Yum, a picture of exactly the same size is laid exactly over the real icon. The file moves into the belly before the first bite, so the real icon vanishes underneath and only one icon is ever on screen. The name label disappears at that moment.

**Plan 4b** adds Downloads (off by default; macOS asks for folder access only when it's turned on), the burrow, a Settings window (rules on/off, the never-ask list), Nap for 1h, and quiet while a full-screen app is in front.

**Tech Stack:** Swift 6, SPM, Swift Testing, AppKit, RealityKit, Core Animation (`CAEmitterLayer`), Quick Look Thumbnailing, Spotlight `MDItem`. macOS 15+, Xcode 27.2. **No new macOS permissions.**

**Spec:** `docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md` (Task 8 updates it). **Findings:** `spike/FINDINGS.md` (Task 8 adds today's).

---

## Read this first

- **The code here was built and run before the plan was written.**
  - All 14 tests pass.
  - The scanner was dry-run, read-only, on the real Desktop. Today it flags nothing; pretending 8 days have passed, it flags the 4 screenshots oldest first and leaves the PDF alone.
  - A live end-to-end run used a throwaway duplicate `crumb-eat-probe copy.txt` (3 MB), with a temporary auto-Yum hook and a 60 s digest. The sequence was: Clean up now → ask → Yum → the file moved into `~/Library/Application Support/Crumb/Belly/<uuid>/` and left the Desktop → 2 bites → burp into `~/.Trash` → spit out brought it back.
  - The bitten picture was rendered offscreen from a real screenshot. The full belly was checked on snapshots.
  - None of the temporary hooks are in this plan.
- **Tests need Xcode** (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`). "Red" means a compile error or a failed `#expect`. Keep one `@Test` per test file.
- **The Desktop is in iCloud, and most files are placeholders** ("Optimize Mac Storage": `ls -lO ~/Desktop` shows `dataless`).
  - Metadata reads (dates, size, tags, Spotlight) don't download anything.
  - Moving a placeholder out of the Desktop *does* download it, and `moveItem` blocks until the download finishes (about 1 s for 3 MB; minutes for big files, and it fails offline). So `Eater` starts the download after Yum and waits without blocking, giving up after a minute. Only then does it eat.
  - Duplicates are only compared when both files are local and the same size, so scanning never downloads anything.
  - Moving the file back (spit out) re-uploads it.
  - While a file is in the belly it's gone from iCloud Drive on other devices too.
- **Spotlight facts:**
  - There's no Swift constant for the screenshot flag. Use `"kMDItemIsScreenCapture" as CFString`.
  - macOS screenshot names contain a narrow no-break space (U+202F) before "AM"/"PM". Never type such a name; take URLs from `contentsOfDirectory`.
- **Quick Look** with `iconMode = true` draws previews the way Finder does (rounded border), so the picture matches the real icon. `IconPicture.load` gives up after 2 s and falls back to the plain icon, so a stuck Quick Look can't stall Crumb.
- **Finder positions are icon-image centres.** The picture is drawn at `iconSize` (64) centred on that point.
- **No frames while the screen is locked.** RealityKit stops updating, so jobs pause. Visual checks need an unlocked screen.
- **Safety:**
  - Crumb only eats after **Yum**, re-checks the file right before eating (same size, same modified date, still junk), and keeps every eaten file recoverable (belly, then Trash).
  - Tagged files, "Keep" files and spat-out files are never asked about again.
  - Tests use throwaway files only. Never answer Yum for the user's own files.

## File structure

| Path | Responsibility |
|---|---|
| `Sources/CrumbCore/AskPolicy.swift` | Create: when an Ask may happen |
| `Sources/CrumbCore/BiteHoles.swift` | Create: bite pattern per bite |
| `Sources/CrumbCore/JunkRules.swift` | Modify: append `installerMatchesInstalledApp` |
| `Tests/CrumbCoreTests/AskPolicyTests.swift`, `BiteHolesTests.swift`, `InstallerMatchTests.swift` | Create |
| `Sources/Crumb/Scanner.swift` | Create: `FileFacts` from the file system and Spotlight |
| `Sources/Crumb/Hauler.swift` | Modify: `paused`, `isBusy`, `grid` visible |
| `Sources/Crumb/PuppetRig.swift`, `Pet.swift` | Modify: belly roundness, waddle, digest nap |
| `Sources/Crumb/Meal.swift` | Create: `MealView`, `IconPicture`, `Once` |
| `Sources/Crumb/PetOverlay.swift` | Modify: meals, crumbs, self-hiding bubbles |
| `Sources/Crumb/Eater.swift` | Create: the eating job |
| `Sources/Crumb/Controls.swift`, `main.swift` | Modify: `BellyMenu`, wiring, menu items |
| Spec, `spike/FINDINGS.md` | Modify |

---

### Task 1: AskPolicy

**Files:**
- Create: `Tests/CrumbCoreTests/AskPolicyTests.swift`
- Create: `Sources/CrumbCore/AskPolicy.swift`

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run it**

Run: `swift test --filter askPolicy`
Expected: compile error `cannot find 'AskPolicy' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// When Crumb may interrupt with "Eat …?". At most one Ask per 15 minutes; "Clean up now" asks back-to-back
/// until the belly is full or nothing is left; never while napping or with a full belly.
public struct AskPolicy: Equatable, Sendable {
    public static let gap: TimeInterval = 15 * 60

    public var lastAskAt: Date?
    /// Set by "Clean up now"; cleared when the belly fills or no candidates remain.
    public var cleaningUp = false

    public init(lastAskAt: Date? = nil) {
        self.lastAskAt = lastAskAt
    }

    public func mayAsk(now: Date, bellyFull: Bool, napping: Bool) -> Bool {
        if bellyFull || napping { return false }
        if cleaningUp { return true }
        guard let last = lastAskAt, last <= now else { return true }  // a clock set backwards doesn't block asks forever
        return now.timeIntervalSince(last) >= Self.gap
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: `Test run with 12 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrumbCore/AskPolicy.swift Tests/CrumbCoreTests/AskPolicyTests.swift
git commit -m "Add AskPolicy: one ask per 15 minutes, Clean up now, never while full or napping"
```

---

### Task 2: Bite holes

**Files:**
- Create: `Tests/CrumbCoreTests/BiteHolesTests.swift`
- Create: `Sources/CrumbCore/BiteHoles.swift`

The spec's "pre-drawn bite masks" become a pattern drawn in code: no art files, and any number of bites from 1 to 10 works. Bite k leaves round bite marks at x = k/n with everything behind gone, and the last bite takes it all.

- [ ] **Step 1: Write the failing test.** It samples a 61×61 grid of points. For every count 1…10 it checks four things: nothing is eaten before the first bite; everything is eaten after the last; holes only grow; behind each edge everything is gone while some icon is left before the last bite.

```swift
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
```

- [ ] **Step 2: Run it**

Run: `swift test --filter biteHolesSweep`
Expected: compile error `cannot find 'biteHoles' in scope`.

- [ ] **Step 3: Implement**

```swift
/// A round bite out of an icon, in unit coordinates: 0…1 across the icon, y down, radius `r`.
public struct BiteHole: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var r: Double

    public init(x: Double, y: Double, r: Double) {
        self.x = x
        self.y = y
        self.r = r
    }

    public func covers(x px: Double, y py: Double) -> Bool {
        (px - x) * (px - x) + (py - y) * (py - y) <= r * r
    }
}

/// The holes in an icon after `bite` of `count` bites, eaten from the left (mirror x when eating from the right).
/// Bite k leaves a scalloped edge at x = k / count with everything behind it gone; the last bite takes it all.
/// Holes only ever grow from one bite to the next.
/// `count` is 1…10 (the range of `biteCount`); above about 13 the 0.12 minimum radius would let holes shrink.
public func biteHoles(after bite: Int, of count: Int) -> [BiteHole] {
    precondition((1...10).contains(count) && (0...count).contains(bite), "bite \(bite) of \(count)")
    if bite == 0 { return [] }
    if bite == count { return [BiteHole(x: 0.5, y: 0.5, r: 0.75)] }  // reaches the corners (0.707 away)
    let r = max(0.12, 0.6 / Double(count))
    var holes: [BiteHole] = []
    // Everything behind the latest edge: a square grid of spacing r covers the whole area it spans.
    let edge = Double(bite) / Double(count)
    var x = edge - r
    while x > -r {
        var y = 0.0
        while y <= 1 + r / 2 {
            holes.append(BiteHole(x: x, y: y, r: r))
            y += r
        }
        x -= r
    }
    // The edge: spaced-out circles, centred just behind it, carve round bite marks into what's left.
    // The next bite's fill covers them, so holes only grow.
    let n = max(2, Int((1 / (2.2 * r)).rounded()))
    for i in 0...n { holes.append(BiteHole(x: edge - r / 2, y: Double(i) / Double(n), r: r)) }
    return holes
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: `Test run with 13 tests in 0 suites passed` (the bite test takes about 0.3 s).

- [ ] **Step 5: Commit**

```bash
git add Sources/CrumbCore/BiteHoles.swift Tests/CrumbCoreTests/BiteHolesTests.swift
git commit -m "Add bite holes: round bite marks sweeping across an icon"
```

---

### Task 3: Installer ↔ installed app

**Files:**
- Create: `Tests/CrumbCoreTests/InstallerMatchTests.swift`
- Modify: `Sources/CrumbCore/JunkRules.swift` (append at the end)

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import CrumbCore

@Test func installerMatch() {
    let apps = ["Figma", "Google Chrome", "zoom.us", "Arc", "Visual Studio Code"]
    let table: [(String, Bool, String)] = [
        ("Figma.dmg", true, "exact name"),
        ("Figma-124.5-arm64.dmg", true, "version and arch suffix"),
        ("googlechrome.dmg", true, "spaces and case ignored"),
        ("GoogleChrome_universal.pkg", true, "underscore suffix"),
        ("zoomusInstallerFull.pkg", true, "dots ignored"),
        ("Figma-124.5.zip", true, "zip with a version number"),
        ("Figma export.zip", false, "zip that's the user's own archive"),
        ("Arc.dmg", true, "short app name, whole-name match"),
        ("archive.zip", false, "short app name doesn't prefix-match"),
        ("VSCode-darwin-universal.zip", false, "abbreviation isn't recognised"),
        ("Slack.dmg", false, "app not installed"),
        (".dmg", false, "no name"),
    ]
    for (name, expected, what) in table {
        #expect(installerMatchesInstalledApp(name, apps: apps) == expected, "\(what)")
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter installerMatch`
Expected: compile error `cannot find 'installerMatchesInstalledApp' in scope`.

- [ ] **Step 3: Implement.** Append to the end of `Sources/CrumbCore/JunkRules.swift`, after `candidateOrder`:

```swift
// ponytail: matches by name only ("Figma-124.5-arm64.dmg" ↔ "Figma.app"); looking inside the .dmg/.zip would
// need mounting or unpacking it. Every match still goes through an Ask, so a false match only costs a question.
/// Whether an installer's name starts with the name of an app in `apps` (names of installed `.app` bundles,
/// without the extension). Compares letters and digits only, ignoring case; app names under 4 characters must
/// match the installer's whole name so "Arc" doesn't match "archive.zip".
/// For .zip, the rest of the name must start with a digit (a version), so "Figma export.zip" isn't an installer.
public func installerMatchesInstalledApp(_ installer: String, apps: [String]) -> Bool {
    func key(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)) }
    let stem = key((installer as NSString).deletingPathExtension)
    let isZip = (installer as NSString).pathExtension.lowercased() == "zip"
    guard !stem.isEmpty else { return false }
    return apps.map(key).contains { app in
        guard !app.isEmpty else { return false }
        if app == stem { return true }
        guard app.count >= 4, stem.hasPrefix(app) else { return false }
        // A .zip is often the user's own archive ("Slack export.zip"): only a version number may follow the name.
        return !isZip || stem.dropFirst(app.count).first?.isNumber == true
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: `Test run with 14 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrumbCore/JunkRules.swift Tests/CrumbCoreTests/InstallerMatchTests.swift
git commit -m "Match installers to installed apps by name"
```

---

### Task 4: Scanner

**Files:**
- Create: `Sources/Crumb/Scanner.swift`

- [ ] **Step 1: Create `Sources/Crumb/Scanner.swift`**

```swift
import CoreServices
import CrumbCore
import Foundation

/// Gathers `FileFacts` for the top level of a folder (file system and Spotlight reads); `classify` decides.
enum Scanner {
    struct Candidate {
        let url: URL
        let facts: FileFacts
        let reason: JunkReason
    }

    private static let keys: [URLResourceKey] = [
        .contentModificationDateKey, .addedToDirectoryDateKey, .fileSizeKey, .isDirectoryKey, .isPackageKey,
        .tagNamesKey, .isHiddenKey,
    ]

    /// Junk in `folder`, oldest first (ties: biggest first).
    static func candidates(
        in folder: URL, neverAsk: Set<String>, enabled: Set<JunkReason>, now: Date = .now
    ) -> [Candidate] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        let apps = installedApps()
        var found: [String: Candidate] = [:]
        for url in urls {
            guard var facts = facts(for: url, apps: apps) else { continue }
            facts.neverAsk = neverAsk.contains(url.path)
            if case .junk(let reason) = classify(facts, now: now, enabled: enabled) {
                found[facts.name] = Candidate(url: url, facts: facts, reason: reason)
            }
        }
        return candidateOrder(found.values.map(\.facts)).compactMap { found[$0.name] }
    }

    /// Facts for one file, or nil for hidden files. Reads only metadata, so iCloud placeholders stay in the cloud.
    static func facts(for url: URL, apps: [String]? = nil) -> FileFacts? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isHidden != true,
            !url.lastPathComponent.hasPrefix(".")
        else { return nil }
        var f = FileFacts(name: url.lastPathComponent, modified: v.contentModificationDate ?? .distantPast)
        f.dateAdded = v.addedToDirectoryDate
        f.size = Int64(v.fileSize ?? 0)
        f.tags = v.tagNames ?? []
        // Apps and other packages are folders on disk but single items to the user: never "empty folders".
        // Folders that live only in iCloud aren't listed (that would fetch them), so they count as not empty.
        f.isDirectory = v.isDirectory == true
        if f.isDirectory, v.isPackage != true, !isDataless(url) {
            let inside = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? ["?"]
            f.isEmptyDirectory = inside.allSatisfy { [".DS_Store", ".localized"].contains($0) }
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            f.lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            f.isScreenCapture = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool) ?? false
        }
        let ext = url.pathExtension.lowercased()
        if ["dmg", "pkg", "zip"].contains(ext) {
            f.containedAppInstalled = installerMatchesInstalledApp(f.name, apps: apps ?? installedApps())
        }
        // ponytail: copies whose contents live only in iCloud are never compared, so never flagged. Comparing
        // would download both files on every scan. Upgrade path: compare iCloud's content hashes if exposed.
        if !f.isDirectory, let original = originalName(forDuplicate: f.name) {
            let other = url.deletingLastPathComponent().appendingPathComponent(original)
            let otherSize = (try? other.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            f.identicalOriginalExists = otherSize.map(Int64.init) == f.size && !isDataless(url) && !isDataless(other)
                && FileManager.default.contentsEqual(atPath: url.path, andPath: other.path)
        }
        return f
    }

    /// An iCloud placeholder: the name is here, the contents are in the cloud ("Optimize Mac Storage").
    static func isDataless(_ url: URL) -> Bool {
        var s = stat()
        return stat(url.path, &s) == 0 && s.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Names (without ".app") of the apps in /Applications and ~/Applications.
    static func installedApps() -> [String] {
        let dirs = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { String($0.dropLast(4)) }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!` with no warnings.

- [ ] **Step 3: Dry-run it on the real Desktop (read-only).** This compiles a throwaway harness outside the repo. It only reads.

```bash
H=$(mktemp -d) && cd "$H"
for f in ~-/Sources/CrumbCore/*.swift ~-/Sources/Crumb/Scanner.swift; do sed '/^import CrumbCore$/d' "$f" > "$(basename "$f")"; done
cat > main.swift <<'EOF'
import Foundation
let desk = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
let ahead = Double(CommandLine.arguments.dropFirst().first ?? "0")!  // days to pretend have passed
for c in Scanner.candidates(in: desk, neverAsk: [], enabled: Set(JunkReason.allCases), now: .now + ahead * 86400) {
    print("JUNK \(c.reason): \(c.facts.name)")
}
EOF
swiftc -O *.swift -o scan && ./scan 0; echo "-- in 8 days:"; ./scan 8; cd ~-
```

Expected: no junk today unless the Desktop really has some. In 8 days every screenshot now on the Desktop shows up, oldest first; the PDF never does. Afterwards `ls -lO ~/Desktop` still shows the same files as `dataless` (nothing was downloaded).

- [ ] **Step 4: Commit**

```bash
git add Sources/Crumb/Scanner.swift
git commit -m "Add Scanner: Desktop file facts from the file system and Spotlight, without downloading"
```

---

### Task 5: Hauler pause, belly roundness, digest nap

**Files:**
- Modify: `Sources/Crumb/Hauler.swift`
- Modify: `Sources/Crumb/PuppetRig.swift`
- Modify: `Sources/Crumb/Pet.swift`

- [ ] **Step 1: Replace `Sources/Crumb/Hauler.swift` with:**

What changed: `grid` is visible, plus `paused` (tidies asked for meanwhile run once it's cleared) and `isBusy`.

```swift
import AppKit
import CrumbCore

/// Keeps the desktop packed. When asked to tidy (a file left the desktop, the sort mode changed) it reads the
/// icons from Finder, plans the moves, and has the puppy carry one icon at a time, re-planning from fresh
/// positions after each one so icons the user moves meanwhile are taken into account.
@MainActor
final class Hauler {
    static let trot = Gait.speed * 2.5
    /// Safety stop for one tidy, in case a plan never settles.
    static let maxHauls = 60
    private static func key(_ m: Move) -> String { "\(m.id)→\(m.to.col),\(m.to.row)" }

    private let finder: FinderBridge
    private let overlay: PetOverlay
    let grid: DesktopGrid
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private var running = false
    private var again = false
    private var failedMoves: Set<String> = []  // moves whose drop didn't stick; skipped until the desktop is tidy
    /// The complaint currently shown, so each problem is said once rather than on every check.
    private var complaint: String?
    private var retry: Task<Void, Never>?
    private var pet: Pet { overlay.pet }

    init(finder: FinderBridge, overlay: PetOverlay) {
        self.finder = finder
        self.overlay = overlay
        grid = .measured(screen: CGSize(width: overlay.pet.map.width, height: overlay.pet.map.height))
    }

    var sort: SortMode {
        get { SortMode(rawValue: UserDefaults.standard.string(forKey: "sortMode") ?? "") ?? .off }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "sortMode")
            tidy()
        }
    }

    /// While true no tidy starts (Crumb is eating or napping); tidies asked for meanwhile run once it's cleared.
    var paused = false {
        didSet {
            if !paused, again, !running { tidy() }
        }
    }

    /// A tidy is running: the puppy may be on its way to an icon.
    var isBusy: Bool { running }

    /// Showing a problem (sad face and bubble). Eating waits meanwhile so its bubbles don't replace this one.
    var isComplaining: Bool { complaint != nil }

    /// Asks for a tidy. Calls while one is running fold into it; calls while paused wait.
    func tidy() {
        again = true
        guard !running, !paused else { return }
        running = true
        Task {
            await tidyLoop()
            running = false
        }
    }

    private func tidyLoop() async {
        var hauls = 0
        while again, hauls < Self.maxHauls {
            again = false
            guard let icons = await survey() else { break }
            let moves = planMoves(icons.map(\.icon), rows: grid.rows, sort: sort)
            if moves.isEmpty { failedMoves.removeAll() }
            guard let move = moves.first(where: { !failedMoves.contains(Self.key($0)) }) else { continue }
            let from = icons.first { $0.icon.id == move.id }!.position
            hauls += 1
            guard await haul(move.id, from: from, to: grid.center(of: move.to)) else {
                failedMoves.insert(Self.key(move))
                break
            }
            again = true  // re-plan from fresh positions
        }
        if pet.onJob { pet.goHome() }
    }

    /// Picks the icon up at `from`, carries the real icon to `to` (Finder moves it along), and verifies the drop.
    private func haul(_ name: String, from: CGPoint, to: CGPoint) async -> Bool {
        await pet.walk(toHold: from, pace: Self.trot)
        await pet.perform(.bite, for: 0.35)
        pet.onHold = { [finder] p in finder.drag(name, to: p) }
        await pet.walk(toHold: to, pace: Self.trot)
        pet.onHold = nil
        let placed = (try? await finder.place(name, at: to)) ?? false
        if !placed { _ = try? await finder.place(name, at: from) }  // put it back rather than leave it mid-carry
        await pet.perform(placed ? .stand : .shrug, for: placed ? 0.2 : 1.2)
        return placed
    }

    /// Current icons with their grid cells, or nil (after saying why) when tidying isn't possible right now.
    private func survey() async -> [(icon: DesktopIcon, position: CGPoint)]? {
        switch FinderBridge.layout().problem {
        case .sorted?:
            return complain("Finder is sorting your desktop. Choose View ▸ Sort By ▸ None and I'll keep it tidy.")
        case .unknownGrid?:
            return complain("I only know Finder's standard icon size and spacing so far, so I'll leave your icons be.")
        case nil:
            break
        }
        let found: [FinderBridge.Icon]
        do {
            found = try await finder.icons()
        } catch FinderBridge.Failure.notAuthorized {
            return complain(
                "I need permission to tidy your desktop.",
                ("Open Settings", {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }))
        } catch {
            return complain("Finder didn't answer me (\(error)).")
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: desktop.path)) ?? []
        if found.isEmpty, files.contains(where: { !$0.hasPrefix(".") }) {
            return complain("I can't see your desktop icons. Is Stage Manager hiding them?")
        }
        dismissComplaint()
        // Only icons on this screen with a readable position and a unique name; others are left alone.
        let screen = CGRect(x: 0, y: 0, width: overlay.pet.map.width, height: overlay.pet.map.height)
        let names = Dictionary(grouping: found, by: \.name)
        let usable = found.filter { screen.contains($0.position) && names[$0.name]?.count == 1 }
        return usable.map { item in
            // Finder shows ":" in file names as "/".
            let url = desktop.appendingPathComponent(item.name.replacingOccurrences(of: "/", with: ":"))
            let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate
            let icon = DesktopIcon(
                id: item.name, name: item.name, kind: url.pathExtension.lowercased(), date: added ?? .distantPast,
                cell: grid.cell(nearest: item.position))
            return (icon, item.position)
        }
    }

    /// Says what's wrong once (sad face, bubble) and checks again in a minute. Returns nil for `survey`.
    private func complain(
        _ text: String, _ button: (String, () -> Void)? = nil
    ) -> [(icon: DesktopIcon, position: CGPoint)]? {
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { tidy() }
        }
        guard text != complaint else { return nil }
        complaint = text
        overlay.say(text, buttons: (button.map { [$0] } ?? []) + [("OK", { [weak overlay] in overlay?.say(nil) })])
        Task {
            guard !pet.onJob else { return }  // don't interrupt a haul
            pet.autopilot = false
            await pet.perform(.sad, for: 3)
            if !pet.onJob { pet.autopilot = true }
        }
        return nil
    }

    private func dismissComplaint() {
        retry?.cancel()
        if complaint != nil { overlay.say(nil) }
        complaint = nil
    }
}
```

- [ ] **Step 2: Replace `Sources/Crumb/PuppetRig.swift` with:**

What changed: `apply` takes `belly`. It widens the body and makes it a little taller, but not deeper, because that hides the bib (checked on snapshots).

```swift
import CrumbCore
import RealityKit

/// Drives the joints of crumb.usdz from a Pose.
@MainActor
final class PuppetRig {
    /// Place and turn this. The model's own top entity holds the Z-up → Y-up rotation, so never overwrite that one.
    let entity = Entity()
    private var joints: [String: Entity] = [:]
    private var rest: [String: Transform] = [:]

    static let names = [
        "Body", "BodyPivot", "HeadPivot", "JawPivot", "TailPivot",
        "LegFL", "LegFR", "LegBL", "LegBR", "EarL", "EarR", "EyeL", "EyeR",
    ]

    struct MissingJoint: Error { let name: String }

    init(model: Entity) throws {
        entity.addChild(model)
        for name in Self.names {
            guard let joint = model.findEntity(named: name) else { throw MissingJoint(name: name) }
            joints[name] = joint
            rest[name] = joint.transform
        }
    }

    /// - swing: walk-cycle leg angle; diagonal pairs move together.
    /// - yaw: whole-body turn; + faces screen right.
    /// - ears: + flops both ears backward.
    /// - breath: belly scale offset.
    /// - belly: how full: widens the body and makes it a little taller (0 empty). Not deeper: that hides the bib.
    func apply(_ p: Pose, swing: Float, yaw: Float, ears: Float, breath: Float, belly: Float) {
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        set("BodyPivot", turn(p.bodyPitch, x), move: [0, 0, -p.bodyDrop])
        set("HeadPivot", turn(p.headPitch, x) * turn(p.headTilt, y) * turn(p.headTurn, z))
        set("JawPivot", turn(p.jaw, x))
        set("TailPivot", turn(p.tail, z))
        set("LegFL", turn(p.legFront + swing, x))
        set("LegBR", turn(p.legBack + swing, x))
        set("LegFR", turn(p.legFront - swing, x))
        set("LegBL", turn(p.legBack - swing, x))
        set("EarL", turn(ears, x))
        set("EarR", turn(ears, x))
        set("EyeL", scale: [1, 1, p.eyeOpen])
        set("EyeR", scale: [1, 1, p.eyeOpen])
        set("Body", scale: [1 + breath + belly, 1, 1 + breath + belly * 0.4])
    }

    private let x: SIMD3<Float> = [1, 0, 0], y: SIMD3<Float> = [0, 1, 0], z: SIMD3<Float> = [0, 0, 1]

    private func turn(_ angle: Float, _ axis: SIMD3<Float>) -> simd_quatf { simd_quatf(angle: angle, axis: axis) }

    private func set(
        _ name: String, _ rotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        move: SIMD3<Float> = .zero, scale: SIMD3<Float> = .one
    ) {
        guard let joint = joints[name], let base = rest[name] else { return }
        joint.transform = Transform(
            scale: base.scale * scale, rotation: base.rotation * rotation, translation: base.translation + move)
    }
}
```

- [ ] **Step 3: Replace `Sources/Crumb/Pet.swift` with:**

What changed: `fullness`, smoothed `bellyShown`, the `waddle` pace (0.6× when stuffed), and `digestNap(_:)`.

```swift
import CrumbCore
import Foundation

/// Per-frame puppy behaviour: idle life (sitting, looking around, wagging, short strolls near the Dock, naps)
/// plus the moves jobs need (`walk(toHold:)`, `perform`, carrying through `onHold`).
@MainActor
final class Pet {
    let rig: PuppetRig
    let map: ScreenMap
    /// Screen y of the feet line: just above the Dock.
    let groundY: Double
    var gait: Gait
    /// The pose it is easing toward while standing still.
    var goal = PoseName.stand
    /// false freezes wander decisions and idle extras (snapshot mode, jobs, complaints).
    var autopilot = true
    /// On a job it keeps facing the way it walks instead of turning to the viewer when it stops.
    private(set) var onJob = false
    /// While set, called every frame with the screen point a carried icon should be at.
    var onHold: ((CGPoint) -> Void)?
    /// Files digesting (0…bellyCapacity). The belly rounds out with each one; when stuffed it waddles slowly.
    var fullness = 0
    private var arrival: CheckedContinuation<Void, Never>?

    private var pose = Pose()
    private var yaw: Float = 0
    private var stepAmount: Float = 0
    private var ears = Spring()
    private var clock = 0.0
    private var nextDecision = 2.0
    private var nextBlink = 3.0
    private var wasWalking = false
    private var awakeSince = 0.0
    private var look: Float = 0, lookTarget: Float = 0, nextLook = 3.0
    private var wag: Float = 0, wagUntil = 0.0, nextWag = 4.0
    private var bellyShown: Float = 0

    /// Spec: naps after 10 min with nothing to do.
    static let napAfter = 600.0
    /// Strolls stay over the middle of the screen, where the Dock is.
    static let strollBand = 0.3...0.7
    /// Body widening per file in the belly (5 files → 25% rounder).
    static let bellyPerFile: Float = 0.05

    /// Pace multiplier: a stuffed puppy waddles.
    private var waddle: Double { fullness >= bellyCapacity ? 0.6 : 1 }

    /// The model is about 0.92 m wide and 1.2 m tall with its feet at the origin.
    static let size = (width: 0.92, height: 1.2)
    /// Where a carried icon's centre sits relative to the feet, in points, when facing right (x flips when facing left).
    /// Ahead of the snout so the head doesn't hide it: the real icon is drawn by Finder, under the puppy.
    static let hold = (ahead: 58.0, up: 52.0)

    init(rig: PuppetRig, map: ScreenMap, groundY: Double) {
        self.rig = rig
        self.map = map
        self.groundY = groundY
        gait = Gait(at: SIMD2(map.width * 0.5, groundY))
    }

    /// Screen rect (top-left origin) the puppy occupies; clicks inside it reach the pet.
    var frame: CGRect {
        let w = Self.size.width * map.pointsPerMeter, h = Self.size.height * map.pointsPerMeter
        return CGRect(x: gait.position.x - w / 2, y: gait.position.y - h, width: w, height: h)
    }

    func update(dt: Double) {
        clock += dt
        _ = gait.step(dt)
        // Just arrived: stand and look around for a bit before deciding again.
        if wasWalking, !gait.isWalking { nextDecision = clock + .random(in: 3...6) }
        wasWalking = gait.isWalking
        if autopilot, !gait.isWalking, clock >= nextDecision { wander() }
        if !gait.isWalking, let done = arrival {
            arrival = nil
            done.resume()
        }

        let ease = { (rate: Double) in Float(1 - exp(-dt * rate)) }
        let walkPose = onHold == nil ? PoseName.stand : .carry
        pose = Pose.mix(pose, gait.isWalking ? walkPose.pose : goal.pose, ease(6))
        // Three-quarter view while walking (and all through a job), face the viewer when still.
        yaw += ((gait.isWalking || onJob ? Float(gait.facing) * 0.6 : 0) - yaw) * ease(8)
        stepAmount += ((gait.isWalking ? 0.45 : 0) - stepAmount) * ease(10)
        bellyShown += (Self.bellyPerFile * Float(fullness) - bellyShown) * ease(3)
        ears.step(toward: gait.isWalking ? 0.35 : 0, dt: dt)

        var shown = pose
        if autopilot { fidget(&shown, dt: dt, ease: ease) }
        if clock >= nextBlink {
            shown.eyeOpen = min(shown.eyeOpen, 0.1)
            if clock >= nextBlink + 0.15 { nextBlink = clock + .random(in: 2.5...6) }
        }
        rig.apply(
            shown,
            swing: stepAmount * sin(Float(gait.phase) * 2 * .pi),
            yaw: yaw,
            ears: ears.value,
            breath: 0.015 * sin(Float(clock) * 2.2),
            belly: bellyShown)
        let feet = map.world(CGPoint(x: gait.position.x, y: gait.position.y))
        rig.entity.position = SIMD3(feet.x, feet.y, 0)
        if let onHold {
            let turn = Double(sin(yaw) / sin(0.6))  // -1 facing left ... 1 facing right, smooth while it turns
            onHold(CGPoint(x: gait.position.x + Self.hold.ahead * turn, y: gait.position.y - Self.hold.up))
        }
    }

    // MARK: - Jobs

    /// Walks (at `pace`) until its mouth is over `p`, approaching from the side it's coming from.
    func walk(toHold p: CGPoint, pace: Double) async {
        precondition(arrival == nil, "walk(toHold:) already pending")
        autopilot = false
        onJob = true
        awakeSince = clock
        let side: Double = p.x >= gait.position.x ? 1 : -1
        gait.pace = pace * waddle
        gait.target = SIMD2(p.x - Self.hold.ahead * side, p.y + Self.hold.up)
        await withCheckedContinuation { arrival = $0 }  // resumed by update() once it stops
        gait.facing = Int(side)  // face the icon even if the last steps went the other way
    }

    /// Holds a pose for a while.
    func perform(_ p: PoseName, for seconds: Double) async {
        awakeSince = clock  // a job or complaint wakes it up
        goal = p
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Job done: stroll back to the Dock line and go back to idle life.
    func goHome() {
        onJob = false
        onHold = nil
        goal = .stand
        gait.pace = Gait.speed * waddle
        let band = Self.strollBand.lowerBound * map.width...Self.strollBand.upperBound * map.width
        gait.target = SIMD2(min(max(gait.position.x, band.lowerBound), band.upperBound), groundY)
        autopilot = true
    }

    /// Full belly: curl up and sleep until called with `false`. No wandering or idle extras meanwhile.
    func digestNap(_ on: Bool) {
        autopilot = !on
        goal = on ? .sleep : .stand
        if !on {
            awakeSince = clock
            nextDecision = clock + 2
        }
    }

    /// Idle life on top of the pose: glance left and right, wag in bursts. Still while walking or asleep.
    private func fidget(_ shown: inout Pose, dt: Double, ease: (Double) -> Float) {
        let idle = !gait.isWalking && goal != .sleep
        if clock >= nextLook {
            lookTarget = idle ? [-0.55, -0.3, 0, 0, 0.3, 0.55].randomElement()! : 0
            nextLook = clock + .random(in: 1.5...4)
        }
        if clock >= nextWag {
            wagUntil = clock + .random(in: 1.5...3)
            nextWag = wagUntil + .random(in: 4...10)
        }
        look += ((idle ? lookTarget : 0) - look) * ease(4)
        wag += ((idle && clock < wagUntil ? 0.4 : 0) - wag) * ease(6)
        shown.headTurn += look
        shown.tail += wag * sin(Float(clock) * 14)
    }

    // ponytail: weighted random idle choices; PetBrain (Plan 3) interrupts these with real jobs.
    private func wander() {
        if goal == .sleep { awakeSince = clock }  // just woke up
        if clock - awakeSince >= Self.napAfter {
            goal = .sleep
            nextDecision = clock + .random(in: 180...360)
            return
        }
        switch Double.random(in: 0..<1) {
        case ..<0.2:
            goal = .stand
            gait.pace = Gait.speed * waddle
            let band = Self.strollBand.lowerBound * map.width...Self.strollBand.upperBound * map.width
            let d = Double.random(in: 80...260) * (Bool.random() ? 1 : -1)
            let x = band.contains(gait.position.x + d) ? gait.position.x + d : gait.position.x - d  // turn back at the band's edge
            gait.target = SIMD2(min(max(x, band.lowerBound), band.upperBound), groundY)
        case ..<0.55:
            goal = .sit  // sit and watch the user
            nextDecision = clock + .random(in: 8...20)
        case ..<0.7:
            goal = .sitTilt
            nextDecision = clock + .random(in: 3...6)
        case ..<0.8:
            goal = .sniff
            nextDecision = clock + .random(in: 2...4)
        default:
            goal = .stand
            nextDecision = clock + .random(in: 4...8)
        }
    }

    /// Snap straight to a pose (snapshot mode). "walk" starts a stroll to the right instead.
    func show(_ name: String) {
        nextBlink = .infinity  // snapshots stay repeatable: no blink mid-capture
        if let p = PoseName(rawValue: name) {
            gait.target = gait.position
            goal = p
            pose = p.pose
        } else {
            goal = .stand
            gait.target = gait.position + SIMD2(400, 0)
        }
    }
}
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` and `Test run with 14 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Crumb/Hauler.swift Sources/Crumb/PuppetRig.swift Sources/Crumb/Pet.swift
git commit -m "Hauler can pause; puppy gets a belly that rounds out, a waddle and a digest nap"
```

---

### Task 6: The meal picture and crumbs

**Files:**
- Create: `Sources/Crumb/Meal.swift`
- Modify: `Sources/Crumb/PetOverlay.swift`

- [ ] **Step 1: Create `Sources/Crumb/Meal.swift`**

```swift
import AppKit
import CrumbCore
import QuickLookThumbnailing

/// A same-size picture of a file's icon, laid exactly over the real one while Crumb eats it. Bites cut holes.
/// Only one icon is ever visible: the file moves into the belly right after the picture appears, before the
/// first bite, so the real icon is gone from under the picture before any hole shows.
final class MealView: NSView {
    private let image: NSImage
    /// Eaten from the right (puppy facing left): holes are mirrored.
    private let mirrored: Bool
    var holes: [BiteHole] = [] {
        didSet { needsDisplay = true }
    }

    init(image: NSImage, frame: NSRect, mirrored: Bool) {
        self.image = image
        self.mirrored = mirrored
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }  // y down, like BiteHole
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // clicks go to the puppy

    override func draw(_ dirtyRect: NSRect) {
        // Fit the picture in the icon square, centred, like Finder does with wide previews.
        let s = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * s, height: image.size.height * s)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let ctx = NSGraphicsContext.current?.cgContext, !holes.isEmpty else { return }
        ctx.setBlendMode(.clear)
        for h in holes {
            let x = mirrored ? 1 - h.x : h.x
            ctx.fillEllipse(in: CGRect(
                x: (x - h.r) * bounds.width, y: (h.y - h.r) * bounds.height,
                width: 2 * h.r * bounds.width, height: 2 * h.r * bounds.height))
        }
    }
}

enum IconPicture {
    /// Finder's look for a file: its content preview drawn as an icon (screenshots, PDFs…), else its icon.
    /// Gives up on the preview after 2 s so a stuck Quick Look can't stall Crumb. Call it while the file is
    /// still in place.
    static func load(_ url: URL, size: Double) async -> NSImage {
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .all)
        request.iconMode = true
        let once = Once()
        let cg: CGImage? = await withCheckedContinuation { done in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                if once.claim() { done.resume(returning: rep?.cgImage) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if once.claim() { done.resume(returning: nil) }
            }
        }
        guard let cg else { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / scale, height: Double(cg.height) / scale))
    }
}

/// Lets exactly one of several racing callbacks through.
final class Once: @unchecked Sendable {  // `done` is only touched under `lock`
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
```

- [ ] **Step 2: Replace `Sources/Crumb/PetOverlay.swift` with:**

What changed:
- an `effects` layer for crumb bursts,
- `showMeal`, `biteMeal` and `hideMeal`,
- `say(_:buttons:hideAfter:)`, whose bubble hides itself unless something else was said meanwhile,
- `ClickThroughView`.

```swift
import AppKit
import Combine
import CrumbCore
import RealityKit

// ponytail: full-screen ARView renders every frame, ~24% CPU measured while wandering (Plan 2, Task 7). Upgrade path: a pet-sized window that moves with the puppy, or a lower frame rate when idle.
/// The puppy's window: borderless, transparent, covering the main screen just above the desktop icons.
/// Clicks pass through everywhere except on the puppy and its speech bubble.
@MainActor
final class PetOverlay {
    /// Points per metre: the 1.2 m model ends up about 110 pt tall.
    static let pointsPerMeter = 92.0

    let window: NSWindow
    let view: PetView
    let pet: Pet
    private var updates: Cancellable?
    private var bubble: Bubble?
    private var bubbleID = 0
    /// Holds the crumb bursts, above meals and below bubbles.
    private let effects = ClickThroughView()
    private var meal: (view: MealView, center: CGPoint, size: Double, mirrored: Bool)?

    init(screen: NSScreen, model: Entity) throws {
        let size = screen.frame.size
        let map = ScreenMap(width: size.width, height: size.height, pointsPerMeter: Self.pointsPerMeter)
        // visibleFrame.minY is the Dock's height when the Dock is at the bottom (AppKit's y points up).
        let groundY = size.height - (screen.visibleFrame.minY - screen.frame.minY) - 6

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        view = PetView(frame: NSRect(origin: .zero, size: size))
        view.environment.background = .color(.clear)
        window.contentView = view
        effects.frame = view.bounds
        effects.wantsLayer = true
        view.addSubview(effects)

        let anchor = AnchorEntity(world: .zero)
        view.scene.addAnchor(anchor)
        let camera = Entity()
        var lens = OrthographicCameraComponent()
        lens.scale = map.cameraScale
        camera.components.set(lens)
        camera.position = [0, 0, 10]
        anchor.addChild(camera)
        let light = DirectionalLight()
        light.light.intensity = 3000
        light.look(at: .zero, from: [1, 2, 2], relativeTo: nil)
        anchor.addChild(light)

        let rig = try PuppetRig(model: model)
        anchor.addChild(rig.entity)
        pet = Pet(rig: rig, map: map, groundY: groundY)

        updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.tick(dt: event.deltaTime) }
        }
        window.orderFrontRegardless()
    }

    private func tick(dt: Double) {
        pet.update(dt: dt)
        // The bubble rides above the puppy's head. Views use AppKit's y-up coordinates; the pet's frame is top-left.
        if let bubble {
            let size = bubble.frame.size
            let top = max(4, pet.frame.minY - size.height - 6)
            let x = min(max(4, pet.frame.midX - size.width / 2), view.bounds.width - size.width - 4)
            bubble.setFrameOrigin(NSPoint(x: x, y: view.bounds.height - top - size.height))
        }
        // Take clicks only while the mouse is over the puppy or its bubble.
        let mouse = NSEvent.mouseLocation
        let topLeft = CGPoint(x: mouse.x - window.frame.minX, y: window.frame.maxY - mouse.y)
        let overBubble = bubble.map { b in
            CGRect(x: b.frame.minX, y: view.bounds.height - b.frame.maxY, width: b.frame.width, height: b.frame.height)
                .contains(topLeft)
        } ?? false
        window.ignoresMouseEvents = !(pet.frame.contains(topLeft) || overBubble)
    }

    /// Shows a speech bubble above the puppy, replacing any current one; nil hides it.
    /// With `hideAfter`, it goes away by itself unless something else was said meanwhile.
    func say(_ text: String?, buttons: [(String, () -> Void)] = [], hideAfter: Duration? = nil) {
        bubble?.removeFromSuperview()
        bubble = text.map { Bubble($0, buttons: buttons) }
        if let bubble { view.addSubview(bubble) }
        bubbleID += 1
        guard let hideAfter else { return }
        let id = bubbleID
        Task {
            try? await Task.sleep(for: hideAfter)
            if bubbleID == id { say(nil) }
        }
    }

    // MARK: - Eating

    /// Lays a same-size picture of an icon exactly over the real one. `center` is in Finder points (top-left).
    func showMeal(_ image: NSImage, at center: CGPoint, size: Double, mirrored: Bool) {
        hideMeal()
        let frame = NSRect(x: center.x - size / 2, y: view.bounds.height - center.y - size / 2, width: size, height: size)
        let v = MealView(image: image, frame: frame, mirrored: mirrored)
        view.addSubview(v, positioned: .below, relativeTo: effects)
        meal = (v, center, size, mirrored)
    }

    /// Takes bite `k` of `n` out of the meal, with a burst of crumbs at the new edge.
    func biteMeal(_ k: Int, of n: Int) {
        guard let meal else { return }
        meal.view.holes = biteHoles(after: k, of: n)
        let edge = (Double(k) / Double(n) - 0.5) * meal.size * (meal.mirrored ? -1 : 1)
        crumbs(at: CGPoint(x: meal.center.x + edge, y: meal.center.y))
    }

    func hideMeal() {
        meal?.view.removeFromSuperview()
        meal = nil
    }

    private static let crumb: CGImage = {
        let dot = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { r in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: r).fill()
            return true
        }
        return dot.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }()

    /// A short burst of falling crumbs at a screen point (top-left origin).
    private func crumbs(at p: CGPoint) {
        let cell = CAEmitterCell()
        cell.contents = Self.crumb
        cell.color = NSColor(calibratedRed: 0.8, green: 0.6, blue: 0.38, alpha: 1).cgColor
        cell.redRange = 0.15
        cell.greenRange = 0.15
        cell.birthRate = 160
        cell.lifetime = 0.7
        cell.velocity = 110
        cell.velocityRange = 50
        cell.emissionLongitude = .pi / 2  // up: layer coordinates point up
        cell.emissionRange = .pi * 0.8
        cell.yAcceleration = -500  // gravity
        cell.scale = 0.7
        cell.scaleRange = 0.4
        cell.alphaSpeed = -1.2
        let emitter = CAEmitterLayer()
        emitter.frame = effects.bounds
        emitter.emitterPosition = CGPoint(x: p.x, y: effects.bounds.height - p.y)
        emitter.emitterShape = .point
        emitter.beginTime = CACurrentMediaTime()
        emitter.emitterCells = [cell]
        effects.layer?.addSublayer(emitter)
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            emitter.birthRate = 0
            try? await Task.sleep(for: .seconds(1))
            emitter.removeFromSuperlayer()
        }
    }

    /// Writes one PNG per pose (plus "walk") into `dir`, cropped around the puppy, then quits.
    func snapshotPoses(to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pet.autopilot = false
        for name in PoseName.allCases.map(\.rawValue) + ["walk"] {
            pet.show(name)
            try await Task.sleep(for: .milliseconds(name == "walk" ? 900 : 600))
            let image: NSImage? = await withCheckedContinuation { done in
                view.snapshot(saveToHDR: false) { done.resume(returning: $0) }
            }
            guard let image, var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let px = Double(cg.width) / pet.map.width
            let r = pet.frame.insetBy(dx: -30, dy: -30)
            if let crop = cg.cropping(to: CGRect(x: r.minX * px, y: r.minY * px, width: r.width * px, height: r.height * px)) {
                cg = crop
            }
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            try png?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        NSApp.terminate(nil)
    }
}

/// A view that never takes clicks.
final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Shows the pet menu on click.
final class PetView: ARView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // Crumb is never the active app; the first click should open the menu

    override func mouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!` with no warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/Crumb/Meal.swift Sources/Crumb/PetOverlay.swift
git commit -m "Add the meal picture with bite holes, crumb bursts and self-hiding bubbles"
```

---

### Task 7: Eater, Belly menu, wiring

**Files:**
- Create: `Sources/Crumb/Eater.swift`
- Modify: `Sources/Crumb/Controls.swift` (append at the end)
- Modify: `Sources/Crumb/main.swift`

How the pieces fit:
- **One job at a time.** `Eater.lookForJunk` runs only when no tidy or job is running and `AskPolicy` allows it. It pauses the hauler for the whole job. The tidy that closes the gap runs right after.
- **When stuffed,** it waits for that tidy, then naps. Tidies wait until it wakes, which happens when a burp or spit out frees a slot.
- **Burp timers** use `Task.sleep`, which counts time while the Mac sleeps, so overdue files burp on wake. Attempts are at least 30 s apart, so a file that can't be trashed doesn't spin in a loop.
- **"Never ask about screenshots"** turns that rule off. Plan 4b's Settings turns it back on. **Keep** and spit out mark that one file "never ask".

- [ ] **Step 1: Create `Sources/Crumb/Eater.swift`**

```swift
import AppKit
import CrumbCore

/// Finds junk on the desktop, asks before eating it, and eats it: bites come out of a same-size picture laid over
/// the real icon while the file moves into the belly. Each file burps into the Trash 15 minutes later; until the
/// Trash is emptied, `spitOut` puts it back. Only one job (sniff, ask, eat) runs at a time, and never during a tidy.
@MainActor
final class Eater {
    static let checkEvery: Duration = .seconds(30)
    static let answerTimeout: Duration = .seconds(60)
    /// A file that can't be trashed (or a ledger that can't be saved) stays overdue; retry this often, not in a loop.
    static let burpRetry: TimeInterval = 30

    let belly: Belly
    /// A sniff/ask/eat job is running.
    private(set) var isBusy = false
    /// Stuffed and asleep until a slot frees.
    private(set) var napping = false
    /// Called when the belly changes, so the menu can follow.
    var onChange: () -> Void = {}

    private let overlay: PetOverlay
    private let finder: FinderBridge
    private let hauler: Hauler
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private let defaults = UserDefaults.standard
    private var policy: AskPolicy
    private var burpTimer: Task<Void, Never>?
    private var lastBurpAttempt = Date.distantPast
    private var loop: Task<Void, Never>?
    private var pet: Pet { overlay.pet }

    init(belly: Belly, overlay: PetOverlay, finder: FinderBridge, hauler: Hauler) {
        self.belly = belly
        self.overlay = overlay
        self.finder = finder
        self.hauler = hauler
        let last = UserDefaults.standard.double(forKey: "lastAskAt")
        policy = AskPolicy(lastAskAt: last > 0 ? Date(timeIntervalSince1970: last) : nil)
    }

    /// Burps anything overdue (Crumb was quit meanwhile), then looks for junk every 30 s.
    func start() {
        Task { await burp() }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.lookForJunk()
                try? await Task.sleep(for: Self.checkEvery)
            }
        }
    }

    /// "Clean up now": ask about one file after another, ignoring the 15-minute gap, until the belly is full or
    /// nothing is left.
    func cleanUpNow() {
        guard !belly.isFull else {
            overlay.say("I'm stuffed! Give me a few minutes to digest.", hideAfter: .seconds(4))
            return
        }
        policy.cleaningUp = true
        Task {
            await whenIdle()
            await lookForJunk()
        }
    }

    /// Undo: put a file back on the desktop, from the belly or from the Trash.
    func spitOut(_ id: UUID) {
        guard !isBusy else { return }
        do {
            let entry = try belly.spitOut(id)
            neverAsk.insert(entry.originalPath)  // taking it back means "keep it": don't ask about it again
            afterBellyChange()
            overlay.say("Here's “\(Self.name(entry))” back.", hideAfter: .seconds(3))
            if !pet.onJob, !napping {
                Task {
                    await pet.perform(.burp, for: 0.8)
                    if !pet.onJob { pet.goal = .stand }
                }
            }
            hauler.tidy()
        } catch BellyError.destinationExists(let path) {
            overlay.say(
                "There's already a file called “\((path as NSString).lastPathComponent)” there.", hideAfter: .seconds(4))
        } catch {
            overlay.say("I can't find that one any more. Was the Trash emptied?", hideAfter: .seconds(4))
        }
    }

    static func name(_ entry: BellyEntry) -> String { (entry.originalPath as NSString).lastPathComponent }

    // MARK: - Asking

    private var neverAsk: Set<String> {
        get { Set(defaults.stringArray(forKey: "neverAsk") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "neverAsk") }
    }

    private var disabledRules: Set<String> {
        get { Set(defaults.stringArray(forKey: "disabledRules") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "disabledRules") }
    }

    private var enabledRules: Set<JunkReason> { Set(JunkReason.allCases.filter { !disabledRules.contains($0.rawValue) }) }

    private func lookForJunk() async {
        guard !isBusy, !hauler.isBusy, !hauler.isComplaining, !pet.onJob, NSEvent.pressedMouseButtons == 0,
            policy.mayAsk(now: .now, bellyFull: belly.isFull, napping: napping)
        else { return }
        isBusy = true
        hauler.paused = true
        defer {
            isBusy = false
            hauler.paused = napping
        }
        // Off the main thread: comparing a big local copy with its original reads both files.
        let (folder, skip, rules) = (desktop, neverAsk, enabledRules)
        let found = await Task.detached { Scanner.candidates(in: folder, neverAsk: skip, enabled: rules) }.value
        guard !found.isEmpty else { return finishCleanUp() }
        guard let icons = try? await finder.icons() else {
            if policy.cleaningUp {
                overlay.say("Finder isn't answering, so I can't find the files.", hideAfter: .seconds(4))
            }
            policy.cleaningUp = false
            return
        }
        // Finder shows ":" in file names as "/". Only icons on this screen with a unique name.
        let screen = CGRect(x: 0, y: 0, width: pet.map.width, height: pet.map.height)
        let positions = Dictionary(grouping: icons, by: \.name)
            .compactMapValues { $0.count == 1 && screen.contains($0[0].position) ? $0[0].position : nil }
        let next = found.lazy.compactMap { c in
            positions[c.facts.name.replacingOccurrences(of: ":", with: "/")].map { (c, $0) }
        }.first
        guard let (candidate, position) = next else { return finishCleanUp() }
        await meal(candidate, at: position)
    }

    private func finishCleanUp() {
        guard policy.cleaningUp else { return }
        policy.cleaningUp = false
        overlay.say("All clean! Nothing left to eat.", hideAfter: .seconds(3))
    }

    private enum Answer { case yum, keep, neverAskRule, noAnswer }

    /// Walk over, sniff, ask, and act on the answer.
    private func meal(_ c: Scanner.Candidate, at p: CGPoint) async {
        policy.lastAskAt = .now
        defaults.set(Date.now.timeIntervalSince1970, forKey: "lastAskAt")
        await pet.walk(toHold: p, pace: Hauler.trot)
        await pet.perform(.sniff, for: 1.2)
        overlay.say("?")
        try? await Task.sleep(for: .seconds(0.8))
        pet.goal = .sitTilt
        switch await ask(c) {
        case .yum:
            await eat(c, at: p)
        case .keep:
            neverAsk.insert(c.url.path)
        case .neverAskRule:
            disabledRules.insert(c.reason.rawValue)
        case .noAnswer:
            policy.cleaningUp = false  // nobody's there: don't keep asking
        }
        if !napping { pet.goHome() }
        if policy.cleaningUp {
            Task {
                await whenIdle()  // let the tidy close the gap first
                await lookForJunk()
            }
        }
    }

    private func ask(_ c: Scanner.Candidate) async -> Answer {
        let once = Once()
        let answer: Answer = await withCheckedContinuation { done in
            func reply(_ a: Answer) -> () -> Void { { if once.claim() { done.resume(returning: a) } } }
            overlay.say(
                "Eat “\(c.facts.name)”? \(c.reason.why)",
                buttons: [("Yum", reply(.yum)), ("Keep", reply(.keep)), ("Never ask about \(c.reason.plural)", reply(.neverAskRule))])
            Task {
                try? await Task.sleep(for: Self.answerTimeout)
                reply(.noAnswer)()
            }
        }
        overlay.say(nil)
        return answer
    }

    // MARK: - Eating

    private func eat(_ c: Scanner.Candidate, at p: CGPoint) async {
        guard await download(c.url) else { return await giveUp() }
        let size = FinderBridge.layout().iconSize
        let picture = await IconPicture.load(c.url, size: size)  // while the file is still in place
        // The answer, download and picture may have taken a while: only eat the file that was asked about,
        // unchanged and still junk. Checked last so nothing else happens between this and the move.
        let url = c.url
        let fresh = await Task.detached { Scanner.facts(for: url) }.value
        guard let fresh, fresh.modified == c.facts.modified, fresh.size == c.facts.size,
            classify(fresh, now: .now, enabled: enabledRules) != .keep
        else { return await giveUp("It changed, so I'll leave it.") }
        overlay.showMeal(picture, at: p, size: size, mirrored: pet.gait.facing < 0)  // eat from the snout's side
        do {
            try belly.eat(c.url, cell: hauler.grid.cell(nearest: p))
        } catch {
            overlay.hideMeal()
            return await giveUp("Couldn't eat that one.")
        }
        afterBellyChange()
        let bites = biteCount(bytes: c.facts.size)
        let beat = bites > 5 ? 0.35 : 0.5
        for k in 1...bites {
            await pet.perform(.bite, for: beat / 2)
            overlay.biteMeal(k, of: bites)
            await pet.perform(.stand, for: beat / 2)
        }
        overlay.hideMeal()
        hauler.tidy()  // runs once this job ends
        if belly.isFull {
            policy.cleaningUp = false
            Task {
                await whenIdle()  // close the last gap, then sleep
                startNap()
            }
        }
    }

    /// Eating didn't happen: say why (if there's anything to say), shrug, and end a Clean up so the same file
    /// isn't asked about again right away.
    private func giveUp(_ text: String? = nil) async {
        policy.cleaningUp = false
        if let text { overlay.say(text, hideAfter: .seconds(3)) }
        await pet.perform(.shrug, for: 1.2)
    }

    /// iCloud may keep only a placeholder on the Mac. Moving it into the belly downloads it and blocks until done,
    /// so fetch it first without blocking. Gives up after a minute (offline, or a huge file).
    private func download(_ url: URL) async -> Bool {
        guard Scanner.isDataless(url) else { return true }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        overlay.say("Fetching it from iCloud…")
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(500))
            if !Scanner.isDataless(url) {
                overlay.say(nil)
                return true
            }
        }
        overlay.say("It's still downloading from iCloud. Maybe later.", hideAfter: .seconds(4))
        return false
    }

    /// Waits until no job or tidy is running.
    private func whenIdle() async {
        while isBusy || hauler.isBusy || pet.onJob {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func startNap() {
        guard belly.isFull, !napping else { return }
        napping = true
        hauler.paused = true  // tidies wait until it wakes
        pet.digestNap(true)
        overlay.say("zzz")
    }

    private func wake() {
        napping = false
        pet.digestNap(false)
        overlay.say(nil)
        hauler.paused = isBusy
    }

    // MARK: - Digesting

    private func afterBellyChange() {
        pet.fullness = belly.digesting.count
        onChange()
        scheduleBurp()
        if napping, !belly.isFull { wake() }
    }

    private func scheduleBurp() {
        burpTimer?.cancel()
        guard let next = belly.nextBurpAt else { return }
        let at = max(next, lastBurpAttempt + Self.burpRetry)
        burpTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            burpTimer = nil  // so rescheduling inside burp() doesn't cancel this task mid-burp
            await burp()
        }
    }

    private func burp() async {
        lastBurpAttempt = .now
        let result: BurpResult
        do {
            result = try belly.burp()
        } catch {
            NSLog("Crumb: burp failed: \(error)")  // the ledger couldn't be saved; files stay safe and it retries
            afterBellyChange()
            return
        }
        afterBellyChange()
        if !result.returned.isEmpty {
            let names = result.returned.map { "“\(Self.name($0))”" }.joined(separator: ", ")
            overlay.say("Couldn't digest \(names), so I put it back.", hideAfter: .seconds(5))
            hauler.tidy()
        }
        guard !result.burped.isEmpty, !isBusy, !pet.onJob, !napping else { return }
        overlay.say("*burp*", hideAfter: .seconds(1.5))
        await pet.perform(.burp, for: 1)
        if !pet.onJob { pet.goal = .stand }
    }
}

extension JunkReason {
    /// Why it looks like junk, for the Ask bubble.
    var why: String {
        switch self {
        case .screenshot: "It's an old screenshot."
        case .installer: "The app is already installed."
        case .duplicate: "It's an exact copy of another file."
        case .partialDownload: "It's an unfinished download."
        case .temp: "It looks like a leftover temp file."
        }
    }

    var plural: String {
        switch self {
        case .screenshot: "screenshots"
        case .installer: "installers"
        case .duplicate: "copies"
        case .partialDownload: "unfinished downloads"
        case .temp: "temp files"
        }
    }
}
```

- [ ] **Step 2: Append to the end of `Sources/Crumb/Controls.swift`:**

```swift
/// The Belly submenu: what Crumb has eaten, newest first, each with Spit out. Rebuilt every time it opens so
/// the minutes stay current.
@MainActor
final class BellyMenu: NSMenu, NSMenuDelegate {
    static let shown = 20
    private let eater: Eater

    init(eater: Eater) {
        self.eater = eater
        super.init(title: "Belly")
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        let entries = eater.belly.history.suffix(Self.shown).reversed()
        if entries.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            addItem(empty)
        }
        for e in entries {
            let minutes = max(1, Int((e.digestEndsAt.timeIntervalSinceNow / 60).rounded(.up)))
            let when = e.burped ? "in the Trash" : "burps in \(minutes) min"
            let item = ActionItem("Spit out “\(Eater.name(e))” (\(when))") { [eater] in eater.spitOut(e.id) }
            item.isEnabled = !eater.isBusy
            addItem(item)
        }
    }
}
```

- [ ] **Step 3: Replace `Sources/Crumb/main.swift` with:**

What changed: one shared `FinderBridge`, `startEating`, and the **Clean up now** and **Belly** menu items.

```swift
import AppKit
import CrumbCore
import RealityKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: PetOverlay?
    var hauler: Hauler?
    var watcher: FolderWatcher?
    var iconCheck: Timer?
    var eater: Eater?

    func applicationDidFinishLaunching(_ note: Notification) {
        Task {
            do {
                // Inside Crumb.app the model is a bundle resource; `swift run Crumb` from the repo root finds it in art/.
                let url = Bundle.main.url(forResource: "crumb", withExtension: "usdz")
                    ?? URL(fileURLWithPath: "art/crumb.usdz")
                let overlay = try PetOverlay(screen: NSScreen.screens[0], model: try await Entity(contentsOf: url))  // the menu-bar display; NSScreen.main follows keyboard focus
                self.overlay = overlay
                if let dir = ProcessInfo.processInfo.environment["CRUMB_SNAPSHOT"] {
                    try await overlay.snapshotPoses(to: URL(fileURLWithPath: dir))
                    return
                }
                let finder = FinderBridge()
                let hauler = Hauler(finder: finder, overlay: overlay)
                self.hauler = hauler
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                watcher = FolderWatcher(desktop) { hauler.tidy() }
                // ponytail: polls Finder every 5 s (one ~0.1 s Apple Event; a tidy with no gaps does nothing). Finder
                // has no notification for icon moves; Accessibility could give one but needs another permission.
                // Moving icons around doesn't change the folder, so look for new gaps regularly. Not while a mouse
                // button is down: the user may be mid-drag.
                iconCheck = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        if NSEvent.pressedMouseButtons == 0 { hauler.tidy() }
                    }
                }
                startEating(finder: finder, overlay: overlay, hauler: hauler)
                buildMenu()
                hauler.tidy()
            } catch {
                NSApp.activate()
                NSAlert(error: error).runModal()
                NSApp.terminate(nil)
            }
        }
    }
}

extension AppDelegate {
    /// Eaten files wait in ~/Library/Application Support/Crumb/Belly. Without a belly Crumb only tidies.
    func startEating(finder: FinderBridge, overlay: PetOverlay, hauler: Hauler) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            let belly = try Belly(directory: support.appendingPathComponent("Crumb/Belly"))
            let eater = Eater(belly: belly, overlay: overlay, finder: finder, hauler: hauler)
            self.eater = eater
            eater.start()
        } catch {
            NSLog("Crumb: can't open the belly, so no eating: \(error)")
        }
    }

    /// The pet menu (click the puppy). Rebuilt when a choice changes so the checkmark follows.
    func buildMenu() {
        guard let overlay, let hauler else { return }
        let sortMenu = NSMenu()
        for mode in SortMode.allCases {
            sortMenu.addItem(ActionItem(mode.rawValue.capitalized, checked: hauler.sort == mode) { [weak self] in
                hauler.sort = mode
                self?.buildMenu()
            })
        }
        let sortItem = NSMenuItem(title: "Sort by", action: nil, keyEquivalent: "")
        sortItem.submenu = sortMenu
        let menu = NSMenu()
        if let eater {
            menu.addItem(ActionItem("Clean up now") { eater.cleanUpNow() })
            let bellyItem = NSMenuItem(title: "Belly", action: nil, keyEquivalent: "")
            bellyItem.submenu = BellyMenu(eater: eater)
            menu.addItem(bellyItem)
        }
        menu.addItem(sortItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Crumb", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        overlay.view.menu = menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // no Dock icon, also when run outside the .app (LSUIElement covers the .app)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 4: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!` with no warnings, and `Test run with 14 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Crumb/Eater.swift Sources/Crumb/Controls.swift Sources/Crumb/main.swift
git commit -m "Add Eater: sniff, ask, eat, digest, burp and spit out; Clean up now and Belly menu"
```

---

### Task 8: Live check, spec, findings

- [ ] **Step 1: Live check (human).**
  1. Make a throwaway duplicate: `printf 'crumb probe\n%.0s' {1..250000} > ~/Desktop/crumb-eat-probe.txt && cp ~/Desktop/crumb-eat-probe.txt ~/Desktop/"crumb-eat-probe copy.txt"`.
  2. Run `scripts/make-app.sh && open build/Crumb.app`. Click **Allow** for Finder (expected after every rebuild).
  3. Click the puppy, then **Clean up now**.

  Check each of these:
  - Crumb trots to `crumb-eat-probe copy.txt`, sniffs, shows "?", sits with its head tilted, and asks "Eat “crumb-eat-probe copy.txt”? It's an exact copy of another file." with **Yum / Keep / Never ask about copies**.
  - **Yum**: there are two bites, eaten from the snout's side with crumbs. Only one icon is visible the whole time, and the name disappears at the first bite. Then the gap closes. The belly looks a little rounder.
  - The menu shows **Belly ▸ Spit out “crumb-eat-probe copy.txt” (burps in 15 min)**. Click it: "Here's … back.", the file returns to the Desktop, and Crumb never asks about it again.
  - **Clean up now** again says "All clean! Nothing left to eat."
  - Clicking the bubble's buttons or the puppy doesn't click through to the desktop.

  Afterwards, the human deletes both probe files by dragging them to the Trash.

- [ ] **Step 2: Update the spec** (`docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md`):
  - **Behaviors table → Eat row:** replace "Each bite removes a chunk from the icon sprite, sweeping left to right" with "A same-size picture of the icon is laid exactly over the real one; the file moves into the belly before the first bite, so only one icon is ever visible (the name goes with it). Each bite carves round bite marks from the snout's side".
  - **Bite masks paragraph:** replace it with "Bite holes: drawn in code (`biteHoles`), any count 1–10; bite k leaves round bite marks at k/N with everything behind gone; the last bite takes the rest."
  - **Fullness row:** "slow waddle, pats tummy" → "slow waddle (0.6× pace); body widens 5% per file".
  - **Spit out row:** "Coughs the file back to its original position" → "Puts the file back on the Desktop (from the belly or the Trash) and Crumb packs it into place; a spat-out file is never asked about again".
  - **Ask row:** add "**Never ask about this** turns off that rule (e.g. screenshots); Settings (Plan 4b) turns it back on."
  - **Anti-annoyance:** "or a Focus mode is on" → "(Focus status is only available to apps with a special Apple entitlement, so Focus isn't detected)".
  - **§2 Installers row:** "whose contained app already exists in `/Applications`" → "whose name starts with an app in `/Applications` or `~/Applications` (matched by name; contents aren't opened). A `.zip` must be the app's name or the name followed by a version number, so the user's own archives (\"Slack export.zip\") aren't installers".
  - **§2, after the rules table:** add "- iCloud placeholders: rules read only metadata; duplicates are compared only when both files are local. After Yum, a placeholder is downloaded first (up to a minute) so moving it never blocks."
  - **§4 Finder automation denied:** "Eating still works; hauling disabled." → "Hauling and eating pause: Crumb needs icon positions to walk to a file."

- [ ] **Step 3: Append to `spike/FINDINGS.md`:**

```markdown

## Plan 4a additions (2026-11-07)

- The Desktop's files are iCloud placeholders here (`ls -lO` shows `compressed,dataless`; `ubiquitousItemDownloadingStatus` = NotDownloaded). Metadata and Spotlight reads don't download them.
- `FileManager.moveItem` of a placeholder from the iCloud Desktop to a local folder downloads it during the move and blocks until done (≈1 s for 3 MB). Moving it back re-uploads it. Download first with `startDownloadingUbiquitousItem` and poll `SF_DATALESS`.
- `evictUbiquitousItem(at:)` makes a placeholder on demand (useful for tests); `brctl evict` no longer exists.
- `trashItem` on a file staged in Application Support lands in `~/.Trash`; `Belly.spitOut` restores from there.
- No Swift constant for `kMDItemIsScreenCapture`: use `"kMDItemIsScreenCapture" as CFString`.
- Screenshot file names contain U+202F (narrow no-break space) before AM/PM.
- `QLThumbnailGenerator` with `iconMode = true` matches Finder's desktop look for previews.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md spike/FINDINGS.md
git commit -m "Spec and findings: eating with a same-size picture, iCloud placeholders"
```

---

## Post-review fixes (applied after Tasks 1–7)

Code review asked for these, and the code blocks above already include them:
- **Scans run off the main thread.** Comparing a big local copy with its original reads both files, so `Scanner.candidates` and the pre-eat `Scanner.facts` run in `Task.detached`. `isBusy` is set before that `await`, so two scans can't overlap.
- **Stricter `.zip` installer match:** exact name, or the name followed by a version number.
- **Folders that live only in iCloud aren't listed**, because listing them would fetch them. They count as not empty.
- **`biteHoles` only accepts 1…10 bites**, the range of `biteCount`; above about 13, holes could shrink.
- **The file is re-checked last.** That happens after the iCloud download and the picture, right before it moves into the belly.
- **Any failed eat ends a Clean up** (`giveUp`), so the same file isn't asked about again at once.
- **Eating waits while Hauler is complaining** (`Hauler.isComplaining`), so its bubbles don't replace a complaint. Clean up says so when Finder doesn't answer.
- **Spit out's burp doesn't override a running tidy's pose.**

## Self-review notes

- **Spec coverage (4a):**
  - Sniff → "?" → Ask (Task 7).
  - Yum / Keep / Never ask (Task 7).
  - Re-validate before eating (Task 7).
  - Bites, N = `biteCount`, 0.5 s per bite or 0.35 s when N > 5 (Tasks 2, 6, 7).
  - Belly staging, ledger and crash sweep (already built, wired in Task 7).
  - Per-file 15-minute burp, grouped burps (`Belly`), the burp pose and bubble (Task 7).
  - Spit out from the Belly menu, before or after the burp (Task 7).
  - Fullness 1–5 roundness, waddle when stuffed, digest nap at 5/5 after the last gap closes, waking when a slot frees (Tasks 5, 7).
  - One Ask per 15 min; Clean up now asks back-to-back until full or none left; no Asks while napping; haul jobs queue during the nap (Tasks 1, 7).
  - Junk rules incl. installer matching and iCloud handling (Tasks 3, 4).
  - Error rows: file changed ("It changed, so I'll leave it."), move failed ("Couldn't eat that one."), can't trash (returned with a bubble), crash mid-digest (`Belly` sweep at launch and the first `burp()`).
- **Left for 4b:** Downloads, burrow, Settings window, Nap for 1h, quiet while full-screen.
- **Type consistency checked:**
  - `AskPolicy.mayAsk(now:bellyFull:napping:)`, `biteHoles(after:of:)` and `installerMatchesInstalledApp(_:apps:)`.
  - `Scanner.candidates(in:neverAsk:enabled:now:)`, `Scanner.facts(for:apps:)` and `Scanner.isDataless(_:)`.
  - `PetOverlay.showMeal(_:at:size:mirrored:)`, `biteMeal(_:of:)` and `say(_:buttons:hideAfter:)`.
  - `Pet.fullness`, `Pet.digestNap(_:)`, `Hauler.paused`, `isBusy` and `grid`.
  - `Eater.start()`, `cleanUpNow()`, `spitOut(_:)`, `belly`, `isBusy` and `name(_:)`.
