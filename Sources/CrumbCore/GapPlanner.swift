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
