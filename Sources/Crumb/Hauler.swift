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
    /// Planned as if past the last slot, so a loose icon always gets carried to its proper slot.
    private static let outside = Cell(col: 100_000, row: 0)

    private let finder: FinderBridge
    private let overlay: PetOverlay
    let grid: DesktopGrid
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private var running = false
    private var again = false
    private var failedMoves: Set<String> = []  // moves whose drop didn't stick; skipped until the desktop is tidy
    /// Icons to carry on the next tidy even if they sit inside their slot already (a spat-out file by the mouth).
    private var loose: Set<String> = []
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

    /// Tidies, carrying `name` to its slot from wherever it is.
    func tidy(carrying name: String) {
        loose.insert(name)
        tidy()
    }

    private func tidyLoop() async {
        var hauls = 0
        while again, hauls < Self.maxHauls {
            again = false
            guard let icons = await survey() else { break }
            let moves = planMoves(icons.map(\.icon), rows: grid.rows, sort: sort)
            if moves.isEmpty {
                failedMoves.removeAll()
                loose.removeAll()  // a loose icon always has a move, so these aren't on the desktop
            }
            guard let move = moves.first(where: { !failedMoves.contains(Self.key($0)) }) else { continue }
            let from = icons.first { $0.icon.id == move.id }!.position
            hauls += 1
            let placed = await haul(move.id, from: from, to: grid.center(of: move.to))
            loose.remove(move.id)
            guard placed else {
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
                cell: loose.contains(item.name) ? Self.outside : grid.cell(nearest: item.position))
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
