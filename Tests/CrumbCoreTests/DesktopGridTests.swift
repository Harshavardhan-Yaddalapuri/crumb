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
