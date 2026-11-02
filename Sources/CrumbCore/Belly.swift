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

public struct BurpResult: Equatable, Sendable {
    /// Moved to the Trash.
    public var burped: [BellyEntry] = []
    /// Couldn't be trashed, so put back at their original path (play "Spit out").
    public var returned: [BellyEntry] = []
}

/// Holds eaten files in a staging folder for 15 minutes each, then moves them to the Trash.
/// Keeps an undo ledger (belly.json) so any file can be spat back out, before or after its burp.
///
/// Layout: `<directory>/belly.json` and `<directory>/<uuid>/<original name>`.
/// The ledger is written before a file moves in, and reconciled with the folder at launch,
/// so a crash at any point leaves every file either in place, in staging with a record, or in the Trash.
public final class Belly {
    public private(set) var history: [BellyEntry] = []
    private let dir: URL
    private let now: () -> Date
    private let trash: (URL) throws -> URL
    private let fm = FileManager.default
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
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try loadLedger()
        try reconcile()
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
        let slot = dir.appendingPathComponent(id.uuidString)
        let staged = slot.appendingPathComponent(file.lastPathComponent)
        let entry = BellyEntry(
            id: id, originalPath: file.path, desktopCell: cell, eatenAt: now(), location: staged.path, burped: false)
        // Record first: a crash after this but before the move leaves a dangling entry that reconcile() drops.
        history.append(entry)
        try save()
        do {
            try fm.createDirectory(at: slot, withIntermediateDirectories: false)
            try fm.moveItem(at: file, to: staged)
        } catch {
            history.removeLast()
            try? fm.removeItem(at: slot)
            try? save()
            throw error
        }
        return entry
    }

    /// Trash every file whose digest timer has ended (or ends within `burpGroupWindow`).
    /// Call when `nextBurpAt` arrives, and once at launch to recover from a crash.
    /// One stubborn file never blocks the rest: if it can't be trashed it goes back where it came from.
    @discardableResult
    public func burp() throws -> BurpResult {
        let cutoff = now() + burpGroupWindow
        var result = BurpResult()
        var drop: Set<UUID> = []
        for i in history.indices where !history[i].burped && history[i].digestEndsAt <= cutoff {
            let entry = history[i]
            let staged = URL(fileURLWithPath: entry.location)
            guard fm.fileExists(atPath: staged.path) else {
                drop.insert(entry.id)
                continue
            }
            if let trashed = try? trash(staged) {
                history[i].location = trashed.path
                history[i].burped = true
                removeSlot(of: staged)
                result.burped.append(history[i])
            } else if !fm.fileExists(atPath: entry.originalPath),
                (try? fm.moveItem(atPath: entry.location, toPath: entry.originalPath)) != nil
            {
                removeSlot(of: staged)
                drop.insert(entry.id)
                result.returned.append(entry)
            }
            // Else: can't trash and can't return it; it stays digesting and is retried next burp.
        }
        history.removeAll { drop.contains($0.id) }
        if !result.burped.isEmpty || !drop.isEmpty { try save() }
        return result
    }

    /// Undo: put the file back at its original path, from staging or from the Trash.
    @discardableResult
    public func spitOut(_ id: UUID) throws -> BellyEntry {
        guard let i = history.firstIndex(where: { $0.id == id }) else { throw BellyError.notFound }
        let entry = history[i]
        guard fm.fileExists(atPath: entry.location) else { throw BellyError.notFound }  // e.g. Trash emptied
        guard !fm.fileExists(atPath: entry.originalPath) else {
            throw BellyError.destinationExists(entry.originalPath)
        }
        try fm.moveItem(atPath: entry.location, toPath: entry.originalPath)
        if !entry.burped { removeSlot(of: URL(fileURLWithPath: entry.location)) }
        history.remove(at: i)
        try save()  // If this fails, reconcile() drops the entry at next launch (its file is gone).
        return entry
    }

    // MARK: - Ledger

    private func loadLedger() throws {
        guard fm.fileExists(atPath: ledger.path) else { return }
        do {
            history = try JSONDecoder().decode([BellyEntry].self, from: Data(contentsOf: ledger))
        } catch {
            // Keep the bad file for inspection; reconcile() then rescues whatever is in staging.
            let aside = dir.appendingPathComponent("belly.json.corrupt-\(Int(now().timeIntervalSince1970))")
            try fm.moveItem(at: ledger, to: aside)
            history = []
        }
    }

    /// Make the ledger and the staging folder agree after a crash or a corrupt ledger.
    private func reconcile() throws {
        let before = history.count
        // Entries whose file is gone (crash mid-eat, spit out whose save failed, Trash emptied).
        history.removeAll { !fm.fileExists(atPath: $0.location) }
        // Staged files with no entry: their original path is unknown, so send them to the Trash (still recoverable).
        let known = Set(history.map { URL(fileURLWithPath: $0.location).deletingLastPathComponent().lastPathComponent })
        let slots = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && !known.contains($0.lastPathComponent) }
        for slot in slots {
            for file in try fm.contentsOfDirectory(at: slot, includingPropertiesForKeys: nil) {
                _ = try? trash(file)
            }
            try? fm.removeItem(at: slot)  // Only succeeds once empty.
        }
        if history.count != before { try save() }
    }

    private func removeSlot(of staged: URL) {
        try? fm.removeItem(at: staged.deletingLastPathComponent())
    }

    // ponytail: history keeps every burped entry until its Trash file disappears; fine for a few hundred entries.
    private func save() throws {
        try JSONEncoder().encode(history).write(to: ledger, options: .atomic)
    }
}
