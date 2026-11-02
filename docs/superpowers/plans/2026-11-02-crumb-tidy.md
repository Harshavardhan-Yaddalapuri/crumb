# Crumb Tidies the Desktop (Plan 3 of 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Crumb keeps the desktop packed. When a file leaves the desktop, or you pick Sort by Name, Kind or Date from its menu, the puppy trots over and carries the real icons to their new slots one at a time. It says so in a speech bubble, with a sad face, when it can't tidy: Finder permission denied, Finder sorting the desktop, icons hidden, or an unknown grid.

**Architecture:**
- **CrumbCore** gets two pure, tested pieces:
  - `DesktopGrid`: Finder points ↔ grid cells, using the spike's measurements.
  - `FinderLayout`: decides whether Crumb may arrange the desktop.
  - It also gains two poses (`shrug`, `sad`) and an adjustable walking `pace`.
- **The app** gains:
  - `FinderBridge`: the only code that talks to Finder. One compiled AppleScript runs on a serial queue, and file names are passed as data.
  - `FolderWatcher`: a debounced watch on `~/Desktop`.
  - `Bubble` and other small closure-based controls.
  - `Hauler`: survey → `planMoves` → haul one icon → re-plan.
  - Job moves on `Pet`: walk until the mouth is over a point, then hold the icon there each frame.

**The carried icon is the real icon:** Finder moves it about 20 times a second, so you never see two copies. **Plan 4** adds eating: the junk scanner, the ask bubble, bites, the belly and the rest.

**Tech Stack:** Swift 6, SPM, Swift Testing, AppKit, RealityKit, Apple Events via `NSAppleScript`, `DispatchSource` file watching. macOS 15+, Xcode 27.2.

**Spec:** `docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md` (Task 7 updates it). **Spike data:** `spike/FINDINGS.md` (Task 3 adds today's findings).

---

## Read this first

- **The code here was built and run before the plan was written.**
  - All 11 tests pass.
  - `FinderBridge` was run against the real Finder: read, place with read-back, a refused off-screen move, and an injection attempt that was safely rejected.
  - A full haul was run on the real desktop: `crumb-probe2.txt` was carried from slot 4 to slot 3 (`1854, 294`) and the user's PDF wasn't touched.
  - The `shrug` and `sad` snapshots were checked by eye.
- **Tests need Xcode** (`xcode-select -p` → `/Applications/Xcode.app/Contents/Developer`). "Red" means a compile error or a failed `#expect`. Keep one `@Test` per test file.
- **Finder facts found while writing this plan:**
  - `{name, desktop position} of every item of desktop` returns everything in one call, in about 0.1 s.
  - One in-process move takes about 6–11 ms, so carrying the real icon at about 20 moves/s is cheap.
  - **Off-screen positions are silently ignored.** No error comes back and the icon stays put. Only a read-back proves a move.
  - **Compile the `NSAppleScript` on the main thread.** If it's compiled on a background thread while the main run loop runs, the first Finder call hangs forever. Compiled on main, it runs fine on a background queue afterwards.
  - Finder's prefs (`com.apple.finder` → `DesktopViewSettings`) can be read with `UserDefaults(suiteName:)` without any permission.
  - Finder shows `:` in file names as `/`. The PDF on the desktop has `/` in its Finder name.
- **No frames while the screen is locked.** RealityKit stops sending `SceneEvents.Update`, so a haul in progress pauses and resumes on unlock. For any visual check, the screen must be unlocked.
- **Safety:**
  - Crumb only moves icons and never touches file contents here.
  - Tests that move icons use throwaway files made by Finder (`crumb-probe*.txt`). Files made with `touch` on this iCloud desktop can't be trashed by Finder (-8013); Finder-made ones sometimes can't either. Reuse an existing probe instead of making a new one (the commands below do).
  - The human deletes the probes afterwards by dragging them to the Trash.

## File structure

| Path | Responsibility |
|---|---|
| `Sources/CrumbCore/DesktopGrid.swift` | Create: `DesktopGrid` (cells ↔ points) and `FinderLayout` (may Crumb arrange?) |
| `Sources/CrumbCore/Pose.swift`, `Gait.swift` | Modify: `shrug` and `sad` poses; adjustable `pace` |
| `Tests/CrumbCoreTests/DesktopGridTests.swift`, `FinderLayoutTests.swift` | Create |
| `Tests/CrumbCoreTests/PoseTests.swift`, `GaitTests.swift` | Modify |
| `Sources/Crumb/FinderBridge.swift` | Create: the only Finder code |
| `Sources/Crumb/Controls.swift` | Create: `Bubble`, `ActionButton`, `ActionItem` |
| `Sources/Crumb/FolderWatcher.swift` | Create: debounced folder watch |
| `Sources/Crumb/Pet.swift` | Modify: job moves (`walk(toHold:)`, `perform`, `onHold`, `goHome`) |
| `Sources/Crumb/Hauler.swift` | Create: survey, plan, haul, complain |
| `Sources/Crumb/PetOverlay.swift`, `main.swift` | Modify: speech bubble, click area, menu with Sort by, wiring |
| `spike/FINDINGS.md`, the spec | Modify: findings and design updates |

---

### Task 1: DesktopGrid and FinderLayout

**Files:**
- Create: `Sources/CrumbCore/DesktopGrid.swift`
- Test: `Tests/CrumbCoreTests/DesktopGridTests.swift`, `Tests/CrumbCoreTests/FinderLayoutTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import CoreGraphics
import Testing
@testable import CrumbCore

@Test func desktopGridMatchesFinder() {
    // Measured in the Finder spike on a 1920×1080 screen: rightmost column x = 1854, top row y = 70, pitch 124×112, 8 rows.
    let grid = DesktopGrid.measured(screen: CGSize(width: 1920, height: 1080))
    #expect(grid.rows == 8, "8 rows fit on a 1080-pt-tall screen")
    #expect(grid.center(of: Cell(col: 0, row: 0)) == CGPoint(x: 1854, y: 70), "top-right slot")
    #expect(grid.center(of: Cell(col: 2, row: 7)) == CGPoint(x: 1606, y: 854), "third column, bottom row")
    #expect(grid.cell(nearest: CGPoint(x: 1854, y: 182)) == Cell(col: 0, row: 1), "an icon exactly on the grid")
    #expect(grid.cell(nearest: CGPoint(x: 1790, y: 240)) == Cell(col: 1, row: 2), "off-grid icons snap to the nearest slot")
    #expect(grid.cell(nearest: CGPoint(x: 1950, y: -40)) == Cell(col: 0, row: 0), "never a negative column or row")
    #expect(grid.cell(nearest: CGPoint(x: 1854, y: 1060)) == Cell(col: 0, row: 7), "never past the last row")
}
```

```swift
import Testing
@testable import CrumbCore

@Test func finderLayoutProblems() {
    let measured = FinderLayout(iconSize: 64, gridSpacing: 54, textSize: 12, labelOnBottom: true, arrangeBy: "none", groupBy: "None")
    #expect(measured.problem == nil, "the layout from the spike is supported")
    var sorted = measured
    sorted.arrangeBy = "name"
    #expect(sorted.problem == .sorted, "Finder's Sort By owns the layout")
    var stacks = measured
    stacks.groupBy = "Kind"
    #expect(stacks.problem == .sorted, "Use Stacks / Group By counts as sorted")
    var bigIcons = measured
    bigIcons.iconSize = 80
    #expect(bigIcons.problem == .unknownGrid, "a grid we never measured")
    var labelRight = measured
    labelRight.labelOnBottom = false
    #expect(labelRight.problem == .unknownGrid, "labels on the right change the grid")
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter "desktopGridMatchesFinder|finderLayoutProblems"`
Expected: build error `cannot find 'DesktopGrid' in scope`.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// Finder's desktop icon grid in screen points (top-left origin, same as Finder's `desktop position`).
/// `Cell(col: 0, row: 0)` is the top-right slot; columns grow leftward, rows downward.
public struct DesktopGrid: Equatable, Sendable {
    public var firstCenter: CGPoint
    public var pitch: CGSize
    public var rows: Int

    public init(firstCenter: CGPoint, pitch: CGSize, rows: Int) {
        self.firstCenter = firstCenter
        self.pitch = pitch
        self.rows = rows
    }

    /// The grid measured in the Finder spike (icon size 64, grid spacing 54, text 12, labels below).
    /// ponytail: margins and pitch are the measured values; the row count is fitted to one screen height (1080 → 8).
    /// Other layouts are refused by `FinderLayout.problem`; measure them at first launch if v2 supports them.
    public static func measured(screen: CGSize) -> DesktopGrid {
        DesktopGrid(
            firstCenter: CGPoint(x: screen.width - 66, y: 70),
            pitch: CGSize(width: 124, height: 112),
            rows: max(1, Int((screen.height - 228) / 112) + 1))
    }

    public func center(of cell: Cell) -> CGPoint {
        CGPoint(x: firstCenter.x - Double(cell.col) * pitch.width, y: firstCenter.y + Double(cell.row) * pitch.height)
    }

    public func cell(nearest p: CGPoint) -> Cell {
        let col = Int(((firstCenter.x - p.x) / pitch.width).rounded())
        let row = Int(((p.y - firstCenter.y) / pitch.height).rounded())
        return Cell(col: max(0, col), row: min(rows - 1, max(0, row)))
    }
}

/// Finder's desktop view settings that decide whether Crumb may arrange icons.
public struct FinderLayout: Equatable, Sendable {
    public var iconSize: Double
    public var gridSpacing: Double
    public var textSize: Double
    public var labelOnBottom: Bool
    /// `DesktopViewSettings.IconViewSettings.arrangeBy`: "none" unless Sort By is set.
    public var arrangeBy: String
    /// `DesktopViewSettings.GroupBy`: "None" unless Use Stacks / Group By is on.
    public var groupBy: String

    public init(
        iconSize: Double, gridSpacing: Double, textSize: Double, labelOnBottom: Bool, arrangeBy: String, groupBy: String
    ) {
        self.iconSize = iconSize
        self.gridSpacing = gridSpacing
        self.textSize = textSize
        self.labelOnBottom = labelOnBottom
        self.arrangeBy = arrangeBy
        self.groupBy = groupBy
    }

    public enum Problem: Equatable, Sendable {
        /// Finder's Sort By or stacks own the layout.
        case sorted
        /// A grid that `DesktopGrid.measured` doesn't describe.
        case unknownGrid
    }

    public var problem: Problem? {
        if arrangeBy != "none" || groupBy != "None" { return .sorted }
        if iconSize != 64 || gridSpacing != 54 || textSize != 12 || !labelOnBottom { return .unknownGrid }
        return nil
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -1`
Expected: `✔ Test run with 11 tests in 0 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrumbCore/DesktopGrid.swift Tests/CrumbCoreTests/DesktopGridTests.swift Tests/CrumbCoreTests/FinderLayoutTests.swift
git commit -m "Add DesktopGrid and FinderLayout from the Finder spike measurements"
```

### Task 2: Shrug and sad poses, adjustable pace

**Files:**
- Modify: `Sources/CrumbCore/Pose.swift`, `Sources/CrumbCore/Gait.swift`
- Test: `Tests/CrumbCoreTests/PoseTests.swift`, `Tests/CrumbCoreTests/GaitTests.swift`

- [ ] **Step 1: Write the failing tests.** In `PoseTests.swift`, add this as the last line of `poseBlending()`:

```swift
    #expect(PoseName.sad.pose.headPitch > 0 && PoseName.shrug.pose.headTilt != 0, "sad hangs its head, shrug tilts it")
```

In `GaitTests.swift`, insert this right before the line `g.target = g.position + SIMD2(0, 50)`:

```swift
    g.pace = Gait.speed * 2
    let before = g.position.x
    _ = g.step(0.1)
    #expect(abs(before - g.position.x - Gait.speed * 0.2) < 1e-9, "a faster pace covers more ground")

```

- [ ] **Step 2: Run them**

Run: `swift test --filter "poseBlending|gaitIsDistanceLocked"`
Expected: build errors `type 'PoseName' has no member 'sad'` and `value of type 'Gait' has no member 'pace'`.

- [ ] **Step 3: Implement.** `Pose.swift` in full:

```swift
/// Joint angles (radians) added to the model's rest pose. Axes are each pivot's local axes
/// from Blender (Z up, dog faces -Y), checked in RealityKit:
/// - X (pitch): + opens the jaw, + nods the head down, + swings a foot backward, - tips the body's front up.
/// - Y (roll): + tilts the head.
/// - Z (yaw): + turns the head, wags the tail.
public struct Pose: Hashable, Sendable {
    public var bodyPitch: Float = 0  // BodyPivot X; pivots at the rear feet
    public var bodyDrop: Float = 0  // BodyPivot moved down, metres (lying down)
    public var headPitch: Float = 0  // HeadPivot X
    public var headTilt: Float = 0  // HeadPivot Y
    public var headTurn: Float = 0  // HeadPivot Z
    public var jaw: Float = 0  // JawPivot X
    public var tail: Float = 0  // TailPivot Z
    public var legFront: Float = 0  // LegFL/LegFR X
    public var legBack: Float = 0  // LegBL/LegBR X
    public var eyeOpen: Float = 1  // EyeL/EyeR Z scale

    public init() {}

    static var joints: [WritableKeyPath<Pose, Float>] {
        [\.bodyPitch, \.bodyDrop, \.headPitch, \.headTilt, \.headTurn, \.jaw, \.tail, \.legFront, \.legBack, \.eyeOpen]
    }

    public static func mix(_ a: Pose, _ b: Pose, _ t: Float) -> Pose {
        var out = a
        for k in joints { out[keyPath: k] = a[keyPath: k] + (b[keyPath: k] - a[keyPath: k]) * t }
        return out
    }
}

public enum PoseName: String, CaseIterable, Sendable {
    case stand, sit, sitTilt, sniff, bite, carry, sleep, burp, shrug, sad

    // Starting values; tune by eye with `CRUMB_SNAPSHOT` (see scripts/snapshot-poses.sh).
    public var pose: Pose {
        var p = Pose()
        switch self {
        case .stand:
            break
        case .sit, .sitTilt:
            // Tipping the front up lifts the front paws; dropping the body puts them back down and sinks the hips.
            p.bodyPitch = -0.3
            p.bodyDrop = 0.14
            p.legFront = 0.3
            p.legBack = -1.2
            p.headPitch = 0.25
            p.headTilt = self == .sitTilt ? 0.35 : 0
        case .sniff:
            p.headPitch = 0.55
            p.legFront = -0.15
            p.tail = 0.2
        case .bite:
            p.headPitch = 0.45
            p.jaw = 0.55
        case .carry:
            p.headPitch = -0.1
            p.jaw = 0.15
        case .sleep:
            p.bodyDrop = 0.12
            p.legFront = -1.3
            p.legBack = 1.3
            p.headPitch = 0.45
            p.eyeOpen = 0.1
        case .shrug:  // a job failed or was skipped
            p.headTilt = -0.35
            p.headPitch = -0.15
            p.jaw = 0.1
            p.eyeOpen = 0.8
        case .sad:  // missing permission, can't see the icons
            p.headPitch = 0.5
            p.legFront = -0.1
            p.eyeOpen = 0.55
        case .burp:
            p.headPitch = -0.35
            p.jaw = 0.45
            p.eyeOpen = 0.4
        }
        return p
    }
}
```

`Gait.swift` in full. It differs from before in the `pace` property, its use in `step`, and the `speed` comment:

```swift
/// Walking in screen points. The walk cycle advances with distance covered, not time, so feet never slide.
public struct Gait: Sendable {
    public static let speed = 70.0  // strolling, points per second
    public static let stride = 36.0  // points per full leg cycle

    public var position: SIMD2<Double>
    public var target: SIMD2<Double>
    /// 0..<1 through the leg cycle.
    public private(set) var phase = 0.0
    /// +1 facing right, -1 facing left; the last horizontal direction walked.
    public private(set) var facing = 1
    /// Points per second; jobs trot faster than strolls. The legs keep up because the cycle follows distance.
    public var pace = Gait.speed

    public init(at p: SIMD2<Double>) {
        position = p
        target = p
    }

    public var isWalking: Bool { position != target }

    /// Moves toward the target; returns the distance covered.
    public mutating func step(_ dt: Double) -> Double {
        let delta = target - position
        let dist = (delta * delta).sum().squareRoot()
        guard dist > 0 else { return 0 }
        let move = min(dist, pace * dt)
        position = move == dist ? target : position + delta * (move / dist)
        if abs(delta.x) > 0.5 { facing = delta.x > 0 ? 1 : -1 }  // ignore sub-point drift so it doesn't flip as it arrives
        phase = (phase + move / Self.stride).truncatingRemainder(dividingBy: 1)
        return move
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | tail -1`
Expected: 11 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrumbCore/Pose.swift Sources/CrumbCore/Gait.swift Tests/CrumbCoreTests/PoseTests.swift Tests/CrumbCoreTests/GaitTests.swift
git commit -m "Add shrug and sad poses and an adjustable walking pace"
```

### Task 3: FinderBridge

**Files:**
- Create: `Sources/Crumb/FinderBridge.swift`
- Modify: `spike/FINDINGS.md` (append a section)

- [ ] **Step 1: Create `Sources/Crumb/FinderBridge.swift`**

```swift
import CoreServices
import CrumbCore
import Foundation

/// The only code that talks to Finder. One compiled AppleScript runs on a private serial queue.
/// File names travel as Apple Event parameters, never pasted into script source, so a crafted
/// file name can't inject script.
final class FinderBridge: @unchecked Sendable {  // mutable state is only touched on `queue`
    struct Icon: Sendable {
        let name: String
        let position: CGPoint
    }

    enum Failure: Error, Equatable {
        /// Automation permission for Finder was denied (-1743).
        case notAuthorized
        case script(Int, String)
    }

    private let queue = DispatchQueue(label: "crumb.finder")
    private let script: NSAppleScript
    private var pendingDrag: (name: String, to: CGPoint)?

    /// Compiles on the main thread. Compiling on a background thread while the main run loop runs makes the
    /// first Finder call hang forever (found while writing Plan 3); running it on `queue` afterwards is fine.
    @MainActor
    init() {
        script = NSAppleScript(source: Self.source)!
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        precondition(compiled, "FinderBridge script doesn't compile: \(error ?? [:])")
    }

    private static let source = """
        on icons()
            tell application "Finder" to return {name, desktop position} of every item of desktop
        end icons
        on moveIcon(n, x, y)
            tell application "Finder"
                set desktop position of item n of desktop to {x, y}
                return desktop position of item n of desktop
            end tell
        end moveIcon
        """

    /// Every desktop icon's name and position. The first call triggers macOS's "wants to control Finder" prompt.
    func icons() async throws -> [Icon] {
        try await onQueue { [self] in
            let result = try call("icons")
            guard let names = result.atIndex(1), let points = result.atIndex(2), names.numberOfItems > 0 else { return [] }
            return (1...names.numberOfItems).compactMap { i in
                guard let name = names.atIndex(i)?.stringValue, let p = points.atIndex(i) else { return nil }
                return Icon(name: name, position: Self.point(p))
            }
        }
    }

    /// Moves an icon and reads its position back; retries once. Finder silently ignores some positions
    /// (anything off-screen), so only a read-back proves the move. Returns false if it didn't stick.
    func place(_ name: String, at p: CGPoint) async throws -> Bool {
        try await onQueue { [self] in
            for _ in 0..<2 {
                if Self.close(Self.point(try call("moveIcon", name, p)), p) { return true }
            }
            return false
        }
    }

    /// Streams an icon along while the puppy carries it. Latest wins: if Finder is still busy with the
    /// previous move, only the newest point is sent next. Errors are ignored; `place` verifies the drop.
    func drag(_ name: String, to p: CGPoint) {
        queue.async { [self] in
            let flushQueued = pendingDrag != nil
            pendingDrag = (name, p)
            guard !flushQueued else { return }
            queue.async { [self] in
                guard let next = pendingDrag else { return }
                pendingDrag = nil
                _ = try? call("moveIcon", next.name, next.to)
            }
        }
    }

    /// Finder's desktop view settings (readable without any permission).
    static func layout() -> FinderLayout {
        let desktop = UserDefaults(suiteName: "com.apple.finder")?.dictionary(forKey: "DesktopViewSettings") ?? [:]
        let icons = desktop["IconViewSettings"] as? [String: Any] ?? [:]
        func number(_ key: String, _ fallback: Double) -> Double { (icons[key] as? NSNumber)?.doubleValue ?? fallback }
        return FinderLayout(
            iconSize: number("iconSize", 64),
            gridSpacing: number("gridSpacing", 54),
            textSize: number("textSize", 12),
            labelOnBottom: number("labelOnBottom", 1) != 0,
            arrangeBy: icons["arrangeBy"] as? String ?? "none",
            groupBy: desktop["GroupBy"] as? String ?? "None")
    }

    // MARK: - Apple Events

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { done in queue.async { done.resume(with: Result { try work() }) } }
    }

    /// Calls a handler in `source` with string / point arguments. Must run on `queue`.
    private func call(_ handler: String, _ name: String? = nil, _ p: CGPoint? = nil) throws -> NSAppleEventDescriptor {
        let args = NSAppleEventDescriptor.list()
        if let name { args.insert(NSAppleEventDescriptor(string: name), at: 1) }
        if let p {
            args.insert(NSAppleEventDescriptor(int32: Int32(p.x.rounded())), at: 2)
            args.insert(NSAppleEventDescriptor(int32: Int32(p.y.rounded())), at: 3)
        }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: Self.code("ascr"), eventID: Self.code("psbr"),  // AppleScript "call subroutine"
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: Self.code("snam"))
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error { throw Self.failure(error) }
        return result
    }

    private static func failure(_ info: NSDictionary?) -> Failure {
        let number = info?[NSAppleScript.errorNumber] as? Int ?? 0
        if number == -1743 { return .notAuthorized }
        return .script(number, info?[NSAppleScript.errorMessage] as? String ?? "unknown error")
    }

    private static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private static func point(_ d: NSAppleEventDescriptor) -> CGPoint {
        CGPoint(x: Double(d.atIndex(1)?.int32Value ?? .min), y: Double(d.atIndex(2)?.int32Value ?? .min))
    }

    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | grep -E "error|warning: |Build complete"`
Expected: `Build complete!` and nothing else.

- [ ] **Step 3: Check it against the real Finder** with a throwaway harness outside the repo. It needs a file named `crumb-probe.txt` in the top-right desktop slot. Make one through Finder (not `touch`):

```bash
osascript -e 'tell application "Finder"' \
  -e 'if not (exists item "crumb-probe.txt" of desktop) then make new file at desktop with properties {name:"crumb-probe.txt"}' \
  -e 'set desktop position of item "crumb-probe.txt" of desktop to {1854, 70}' -e 'end tell'
```

Save this as `/tmp/fbcheck/main.swift`:

```swift
import AppKit
// Same shape as the app: AppKit run loop, bridge created on the main thread, calls from a Task.
@MainActor final class D: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let fb = FinderBridge()
        Task {
            do {
                for i in try await fb.icons() { print("icon", i.name, i.position) }
                print("layout problem", FinderBridge.layout().problem as Any)
                print("place left", try await fb.place("crumb-probe.txt", at: CGPoint(x: 1730, y: 70)))
                for k in 0..<20 {
                    fb.drag("crumb-probe.txt", to: CGPoint(x: 1730 - k * 10, y: 70 + k * 5))
                    try await Task.sleep(for: .milliseconds(40))
                }
                print("place back", try await fb.place("crumb-probe.txt", at: CGPoint(x: 1854, y: 70)))
                print("offscreen refused ->", try await fb.place("crumb-probe.txt", at: CGPoint(x: -300, y: -300)))
                do {
                    _ = try await fb.place("x\" of desktop\ndo shell script \"touch /tmp/crumb-pwned\"\n--", at: CGPoint(x: 10, y: 10))
                } catch { print("injection name ->", error) }
                print("pwned file exists:", FileManager.default.fileExists(atPath: "/tmp/crumb-pwned"))
            } catch { print("ERROR", error) }
            exit(0)
        }
    }
}
let app = NSApplication.shared
let d = D()
app.delegate = d
app.run()
```

Then run:

```bash
mkdir -p /tmp/fbcheck && cd /tmp/fbcheck
sed '/^import CrumbCore/d' ~/Projects/crumb/Sources/Crumb/FinderBridge.swift > FinderBridge.swift
cp ~/Projects/crumb/Sources/CrumbCore/DesktopGrid.swift ~/Projects/crumb/Sources/CrumbCore/GapPlanner.swift .
swiftc -swift-version 6 -O -o fbcheck FinderBridge.swift DesktopGrid.swift GapPlanner.swift main.swift && ./fbcheck
cd ~/Projects/crumb
```

Expected:
- one `icon …` line per desktop item;
- `layout problem nil`, `place left true`, `place back true`, `offscreen refused -> false`;
- `injection name -> script(-10006, …)`;
- `pwned file exists: false`.

If the run hangs, the script was compiled off the main thread. Check that `init` is `@MainActor` and is called from the main thread.

- [ ] **Step 4: Append to `spike/FINDINGS.md`**

```markdown

## Plan 3 additions (2026-11-02)

- Bulk read: `{name, desktop position} of every item of desktop` returns everything in one call, about 0.1 s (0.12 s for the first call in a process).
- In-process moves take about 6 ms (11 ms when the script is re-created each time), so Crumb carries the **real** icon by moving it about 20×/s and never draws a copy.
- **Off-screen positions are silently ignored** (`-300,-300` and `2400,500` leave the icon where it was, with no error). Always read back.
- **`NSAppleScript` must be compiled on the main thread.** Compiled on a background thread while the main run loop runs, the first Finder call hangs forever. Compiled on main, it executes fine on a background queue.
- Finder's and Stage Manager's prefs can be read via `UserDefaults(suiteName:)` without permission. `HideDesktop = 1` with Stage Manager off doesn't hide icons. Crumb therefore detects hidden icons empirically: Finder reports no items while `~/Desktop` has files.
- Finder shows `:` in file names as `/`. Convert back before building a path.
- RealityKit sends no frame updates while the screen is locked, so a job in progress pauses until unlock.
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Crumb/FinderBridge.swift spike/FINDINGS.md
git commit -m "Add FinderBridge: bulk icon read, verified place, streamed drag, layout prefs"
```

### Task 4: Small controls and the folder watcher

**Files:**
- Create: `Sources/Crumb/Controls.swift`, `Sources/Crumb/FolderWatcher.swift`

- [ ] **Step 1: Create `Sources/Crumb/Controls.swift`**

```swift
import AppKit

/// A speech bubble above the puppy: a short message and optional buttons. Always light, like a comic bubble.
final class Bubble: NSView {
    init(_ text: String, buttons: [(String, () -> Void)]) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .aqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .black
        label.preferredMaxLayoutWidth = 220
        var rows: [NSView] = [label]
        if !buttons.isEmpty { rows.append(NSStackView(views: buttons.map { ActionButton($0.0, $0.1) })) }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(fittingSize)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSButton that runs a closure. Takes the first click even though Crumb is never the active app.
final class ActionButton: NSButton {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
```

- [ ] **Step 2: Create `Sources/Crumb/FolderWatcher.swift`**

```swift
import Foundation

/// Calls back, debounced, when entries are added to, removed from, or renamed in a folder (top level only).
@MainActor
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pending: Task<Void, Never>?

    init?(_ folder: URL, debounce: Duration = .seconds(1.5), onChange: @escaping @MainActor () -> Void) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pending?.cancel()
                self?.pending = Task {
                    try? await Task.sleep(for: debounce)
                    if !Task.isCancelled { onChange() }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E "error|warning: |Build complete"`
Expected: `Build complete!` only.

- [ ] **Step 4: Commit**

```bash
git add Sources/Crumb/Controls.swift Sources/Crumb/FolderWatcher.swift
git commit -m "Add speech bubble, closure buttons and menu items, and a debounced folder watcher"
```

### Task 5: Job moves for the puppy

**Files:**
- Modify: `Sources/Crumb/Pet.swift`

- [ ] **Step 1: Replace `Sources/Crumb/Pet.swift` with:**

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

    /// Spec: naps after 10 min with nothing to do.
    static let napAfter = 600.0
    /// Strolls stay over the middle of the screen, where the Dock is.
    static let strollBand = 0.3...0.7

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
            breath: 0.015 * sin(Float(clock) * 2.2))
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
        autopilot = false
        onJob = true
        let side: Double = p.x >= gait.position.x ? 1 : -1
        gait.pace = pace
        gait.target = SIMD2(p.x - Self.hold.ahead * side, p.y + Self.hold.up)
        await withCheckedContinuation { arrival = $0 }  // resumed by update() once it stops
    }

    /// Holds a pose for a while.
    func perform(_ p: PoseName, for seconds: Double) async {
        goal = p
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Job done: stroll back to the Dock line and go back to idle life.
    func goHome() {
        onJob = false
        onHold = nil
        goal = .stand
        gait.pace = Gait.speed
        let band = Self.strollBand.lowerBound * map.width...Self.strollBand.upperBound * map.width
        gait.target = SIMD2(min(max(gait.position.x, band.lowerBound), band.upperBound), groundY)
        autopilot = true
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

What changed from Plan 2:
- `onJob`, `onHold`, `arrival`, and `hold` (where the carried icon sits);
- `update` resumes `arrival` when the puppy stops, uses the `carry` pose while holding, keeps the three-quarter turn all through a job, and reports the hold point each frame;
- a new "Jobs" section: `walk(toHold:pace:)`, `perform(_:for:)`, `goHome()`.

The icon is held **ahead of the snout** because Finder draws icons under Crumb's window, so the head would otherwise hide it.

- [ ] **Step 2: Build, and check the idle behaviour is unchanged**

Run: `swift build 2>&1 | grep -E "error|warning: |Build complete"`, then `scripts/snapshot-poses.sh`. The screen must be unlocked.
Expected: `Build complete!`, then 11 PNGs, which now include `shrug.png` and `sad.png`. Open `sad.png` and `shrug.png` with Read:
- sad: head hanging, eyes half-closed;
- shrug: head tilted, mouth slightly open.

If the run never exits, the screen is probably locked.

- [ ] **Step 3: Commit**

```bash
git add Sources/Crumb/Pet.swift
git commit -m "Pet: walk to hold a point, perform a pose, carry with onHold, go home"
```

### Task 6: Hauler, speech bubble, Sort by menu

**Files:**
- Create: `Sources/Crumb/Hauler.swift`
- Modify: `Sources/Crumb/PetOverlay.swift`, `Sources/Crumb/main.swift`

- [ ] **Step 1: Create `Sources/Crumb/Hauler.swift`**

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

    private let finder: FinderBridge
    private let overlay: PetOverlay
    private let grid: DesktopGrid
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private var running = false
    private var again = false
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

    /// Asks for a tidy. Calls while one is running fold into it.
    func tidy() {
        again = true
        guard !running else { return }
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
            guard let move = planMoves(icons.map(\.icon), rows: grid.rows, sort: sort).first else { continue }
            let from = icons.first { $0.icon.id == move.id }!.position
            hauls += 1
            guard await haul(move.id, from: from, to: grid.center(of: move.to)) else { break }
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
        return found.map { item in
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

- [ ] **Step 2: Replace `Sources/Crumb/PetOverlay.swift` with:**

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
    func say(_ text: String?, buttons: [(String, () -> Void)] = []) {
        bubble?.removeFromSuperview()
        bubble = text.map { Bubble($0, buttons: buttons) }
        if let bubble { view.addSubview(bubble) }
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

/// Shows the pet menu on click.
final class PetView: ARView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // Crumb is never the active app; the first click should open the menu

    override func mouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}
```

What changed:
- The menu moved out of `PetOverlay` into `main.swift`.
- It has a `bubble` that follows the puppy, and clicks are taken over the bubble too.
- New `say(_:buttons:)`.

- [ ] **Step 3: Replace `Sources/Crumb/main.swift` with:**

```swift
import AppKit
import CrumbCore
import RealityKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var overlay: PetOverlay?
    var hauler: Hauler?
    var watcher: FolderWatcher?

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
                let hauler = Hauler(finder: FinderBridge(), overlay: overlay)
                self.hauler = hauler
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                watcher = FolderWatcher(desktop) { hauler.tidy() }
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

Run: `swift build 2>&1 | grep -E "error|warning: |Build complete" && swift test 2>&1 | tail -1`
Expected: `Build complete!` and 11 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/Crumb/Hauler.swift Sources/Crumb/PetOverlay.swift Sources/Crumb/main.swift
git commit -m "Add Hauler: tidy the desktop by carrying real icons; speech bubble and Sort by menu"
```

### Task 7: End-to-end check, live check, spec

The screen must be unlocked for every step here.

- [ ] **Step 1: Haul check with throwaway files (agent).** Make a gap: keep `crumb-probe.txt` from Task 3 in the top-right slot (make it again with the Task 3 command if it's gone), and add a second probe in row 4, leaving row 3 empty:

```bash
osascript -e 'tell application "Finder"' \
  -e 'if not (exists item "crumb-probe2.txt" of desktop) then make new file at desktop with properties {name:"crumb-probe2.txt"}' \
  -e 'set desktop position of item "crumb-probe2.txt" of desktop to {1854, 406}' -e 'end tell'
osascript -e 'tell application "Finder" to return {name, desktop position} of every item of desktop'
```

Then run the app for 40 s, which is enough for one haul:

```bash
(.build/debug/Crumb & A=$!; sleep 40; kill $A)
osascript -e 'tell application "Finder" to return {name, desktop position} of every item of desktop'
```

Expected: only `crumb-probe2.txt` moved, to `1854, 294`, which is the third slot. **Note:** if the user's own desktop has a gap, their icons are packed too. That's the feature working, but tell the user beforehand.

- [ ] **Step 2: Live check (human).** Run `scripts/make-app.sh && open build/Crumb.app`. The first Finder call shows "Crumb wants to control Finder": click **Allow**. Ad-hoc signing changes with every build, so expect the prompt again after each rebuild. Ask the human to check:
  1. Drag `crumb-probe.txt` to the Trash. Within a few seconds the puppy trots over, picks up the icon below the gap, and carries it up into the gap. The real icon travels in its mouth smoothly, not jumping, and with no second copy. Then it strolls back to the Dock.
  2. Click the puppy → **Sort by ▸ Name**. It re-orders the desktop icon by icon. **Sort by ▸ Off** stops re-sorting.
  3. In Finder, choose View ▸ Sort By ▸ Name on the desktop. The puppy looks sad, and a bubble asks you to set Sort By to None; **OK** closes it. Set Sort By back to None afterwards.
  4. The bubble's buttons work on the first click.

  If the carried icon looks wrong (hidden behind the head, too far away, jumpy), tune `Pet.hold` (ahead/up). If moving the real icon is jumpy, report it: the fallback is carrying a picture (option B).

- [ ] **Step 3: Update the spec.** In `docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md`:
  - **Haul row:** replace the last cell `Walks to icon, grabs it, drags it to its new spot` with `Trots to the icon, picks it up, and carries the real icon (Finder moves it along ~20×/s) to its new spot; strolls back to the Dock after`.
  - **FinderBridge row:** replace the middle cell with `Only component that talks to Finder: read all desktop icons and positions in one call, place an icon and read it back, stream an icon along while carried; reads Finder's layout prefs`.
  - **Data-flow step 3:** replace the line starting `3. One Haul job per move.` with `3. Hauler plans the moves and hauls one at a time: the puppy walks to the icon, bites, and carries the real icon while FinderBridge moves it along; at the drop FinderBridge places it and reads it back. After each haul it re-plans from fresh positions.`
  - **Risk and spike:** replace the paragraph under `### Risk and spike` with `Resolved: the spike (spike/FINDINGS.md) showed per-icon positioning works and reads back exactly. Off-screen positions are silently ignored, so every move is verified by reading back.`
  - **Error-handling table:** add these rows at the end:
    - `| Finder is sorting the desktop (Sort By / stacks) | Sad face, bubble asking to set Sort By to None; hauling paused, rechecked every minute. |`
    - `| Icon size / spacing other than Finder's defaults | Bubble: leaves icons alone (grid not measured yet); v2 measures other grids. |`

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-11-02-crumb-desktop-pet-design.md
git commit -m "Spec: carry the real icon, verified moves, sorted-desktop handling"
```

---

## Self-review notes

- **Spec coverage:**
  - Haul on gap (Tasks 3–6), plus the Sort by menu.
  - Error handling:
    - Automation denied → sad face plus a Settings button.
    - Position doesn't stick → retry once, then shrug and stop.
    - Icons rearranged mid-haul → re-plan after each haul.
    - Icons hidden → bubble, checked again every minute.
    - Sorted desktop → bubble.
- **Deferred to Plan 4 (eating):**
  - Clean up now, Belly, Nap, Settings menu items.
  - Ask bubble with Yum / Keep / Never, bites, belly and burp.
  - The "don't nag" rules and staying quiet in full-screen and Focus.
  - Burrow.
- **Known ceilings** (`ponytail:`):
  - Only Finder's default grid (64 / 54 / 12, labels below) is supported. The row count is fitted to one screen height.
  - Ad-hoc signing re-prompts for Automation after each rebuild. A stable self-signed identity would fix that if it gets annoying.
  - 24% CPU while rendering, as before.
