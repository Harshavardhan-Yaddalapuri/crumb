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
    var offCentre = icon("B", 0, 1)
    offCentre.snug = false
    #expect(
        planMoves([icon("A", 0, 0), offCentre], rows: 3, sort: .off) == [Move(id: "B", from: Cell(col: 0, row: 1), to: Cell(col: 0, row: 1))],
        "an off-centre icon is nudged into its own slot")

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
