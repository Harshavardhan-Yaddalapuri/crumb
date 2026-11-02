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
