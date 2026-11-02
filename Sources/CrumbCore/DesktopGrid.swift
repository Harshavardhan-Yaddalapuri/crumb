import CoreGraphics

/// Finder's desktop icon grid in screen points (top-left origin, same as Finder's `desktop position`).
/// `Cell(col: 0, row: 0)` is the top-right slot; columns grow leftward, rows downward.
public struct DesktopGrid: Equatable, Sendable {
    public var firstCenter: CGPoint
    public var pitch: CGSize
    public var rows: Int

    public init(firstCenter: CGPoint, pitch: CGSize, rows: Int) {
        precondition(rows > 0, "grid needs at least one row")
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
        // Clamp before converting so a wild position can't trap in Int(_:) or overflow slot maths downstream.
        let col = ((firstCenter.x - p.x) / pitch.width).rounded()
        let row = ((p.y - firstCenter.y) / pitch.height).rounded()
        return Cell(col: Int(min(max(col, 0), 10_000)), row: Int(min(max(row, 0), Double(rows - 1))))
    }
}

/// Finder's desktop view settings that decide whether Crumb may arrange icons.
public struct FinderLayout: Equatable, Sendable {
    public var iconSize: Double
    public var gridSpacing: Double
    public var textSize: Double
    public var labelOnBottom: Bool
    /// DesktopViewSettings.IconViewSettings.arrangeBy: "none", or "grid" for Snap to Grid; anything else is a Sort By.
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
        if !["none", "grid"].contains(arrangeBy) || groupBy != "None" { return .sorted }
        if iconSize != 64 || gridSpacing != 54 || textSize != 12 || !labelOnBottom { return .unknownGrid }
        return nil
    }
}
