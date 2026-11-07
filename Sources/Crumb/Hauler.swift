import AppKit
import CrumbCore
import QuickLookThumbnailing

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
    private let grid: DesktopGrid
    private let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    private var running = false
    private var again = false
    private var failedMoves: Set<String> = []  // moves whose drop didn't stick; skipped until the desktop is tidy
    /// The complaint currently shown, so each problem is said once rather than on every check.
    private var complaint: String?
    private var retry: Task<Void, Never>?
    /// What the carried file looks like: its icon at first, Finder's content preview once that's ready.
    private var look: NSImage?
    private var lookFetch: Task<Void, Never>?
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

    /// Picks the icon up at `from`, carries it to `to`, and verifies the drop. A small copy rides in the mouth while
    /// Finder moves the real icon along behind the puppy's body (Finder can't shrink a single icon).
    private func haul(_ name: String, from: CGPoint, to: CGPoint) async -> Bool {
        fetchLook(file(name))
        await pet.walk(toHold: from, pace: Self.trot)
        await pet.perform(.bite, for: 0.35)
        overlay.carried = look
        pet.onHold = { [finder] p in finder.drag(name, to: p) }
        await pet.walk(toHold: to, pace: Self.trot)
        pet.onHold = nil
        let placed = (try? await finder.place(name, at: to)) ?? false
        if !placed { _ = try? await finder.place(name, at: from) }  // put it back rather than leave it mid-carry
        overlay.carried = nil  // only now, so the real icon is already back in view
        lookFetch?.cancel()
        await pet.perform(placed ? .stand : .shrug, for: placed ? 0.2 : 1.2)
        return placed
    }

    // ponytail: always asks for a content preview; if the user turned off Finder's "Show icon preview", Finder
    // shows plain icons while the copy may show a preview. Read IconViewSettings.showIconPreview if that matters.
    /// Starts with the file's icon and swaps in Finder's content preview (screenshots, PDFs…) when it arrives.
    /// If no preview comes back, the icon stays.
    private func fetchLook(_ url: URL) {
        lookFetch?.cancel()
        look = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .all)
        lookFetch = Task { [weak self] in
            guard let preview = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage,
                !Task.isCancelled, let self
            else { return }
            look = preview
            if overlay.carried != nil { overlay.carried = preview }  // arrived mid-carry
        }
    }

    /// The file behind a desktop icon. Finder shows ":" in file names as "/".
    private func file(_ name: String) -> URL {
        desktop.appendingPathComponent(name.replacingOccurrences(of: "/", with: ":"))
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
            let url = file(item.name)
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
