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
