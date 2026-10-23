import XCTest

@testable import KeyboardCore

final class QuickContentLayoutTests: XCTestCase {
    /// Chrome is the title bar plus its divider; the rest belongs to the rail and the content.
    private func chrome(_ layout: QuickContentLayout) -> CGFloat {
        layout.titleBarHeight + layout.separatorHeight
    }

    func testPortraitPanelFitsChromeAndKeepsTheGrid() {
        for height in stride(from: CGFloat(240), through: 320, by: 2) {
            let layout = QuickContentLayout.resolve(height: height, railItemCount: 8)
            XCTAssertEqual(
                chrome(layout) + layout.contentHeight, height, accuracy: 0.01,
                "panel height \(height) must be fully accounted for")
            XCTAssertEqual(layout.density, .regular)
            XCTAssertGreaterThanOrEqual(layout.contentHeight, 150)
            XCTAssertTrue(layout.showsRecents)
        }
    }

    func testShortPanelNeverOverflowsItsBands() {
        // Landscape phones give the whole keyboard far less height than a portrait panel.
        for height in stride(from: CGFloat(0), through: 240, by: 1) {
            let layout = QuickContentLayout.resolve(height: height, railItemCount: 8)
            XCTAssertLessThanOrEqual(
                chrome(layout), height + 0.01,
                "chrome must never exceed the panel at height \(height)")
            XCTAssertEqual(chrome(layout) + layout.contentHeight, height, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(layout.contentHeight, 0)
            XCTAssertGreaterThan(layout.railWidth, 0)
        }
    }

    func testRailSlotsStayTouchableHoweverManyChoicesThereAre() {
        // The column scrolls instead of shrinking its rows: every slot keeps a real touch target.
        for count in [3, 5, 9, 20] {
            for height in stride(from: CGFloat(120), through: 320, by: 4) {
                let layout = QuickContentLayout.resolve(height: height, railItemCount: count)
                XCTAssertGreaterThanOrEqual(
                    layout.railSlotHeight, 34,
                    "a slot must stay tappable (\(count) choices at \(height)pt)")
                XCTAssertLessThanOrEqual(
                    layout.railSlotHeight, 50,
                    "a slot must not grow into a billboard")
            }
        }
    }

    func testFewChoicesShareTheColumnInsteadOfLeavingItEmpty() {
        let few = QuickContentLayout.resolve(height: 288, railItemCount: 3)
        let many = QuickContentLayout.resolve(height: 288, railItemCount: 12)
        XCTAssertGreaterThan(
            few.railSlotHeight, many.railSlotHeight,
            "fewer choices can afford taller slots")
        XCTAssertEqual(many.railSlotHeight, 34, "many choices sit at the touch-target floor")
    }

    func testSearchGivesTheRailSpaceBackToTheResults() {
        // Searching hides the column, so the results get the width it used, not less height.
        let layout = QuickContentLayout.resolve(height: 288, railItemCount: 8)
        XCTAssertGreaterThan(layout.contentHeight, 150)
        XCTAssertGreaterThan(layout.railWidth, 0)
    }

    func testDensityShrinksCellsWithTheHeight() {
        let regular = QuickContentLayout.resolve(height: 288, railItemCount: 8)
        let compact = QuickContentLayout.resolve(height: 200, railItemCount: 8)
        let minimal = QuickContentLayout.resolve(height: 160, railItemCount: 8)
        XCTAssertEqual(regular.density, .regular)
        XCTAssertEqual(compact.density, .compact)
        XCTAssertEqual(minimal.density, .minimal)
        XCTAssertGreaterThan(regular.symbolCellMinHeight, compact.symbolCellMinHeight)
        XCTAssertGreaterThan(compact.symbolColumnMinWidth, minimal.symbolColumnMinWidth)
        // The phrase cell width is fixed: three equal columns at every density.
        XCTAssertEqual(regular.kaomojiColumnMinWidth, minimal.kaomojiColumnMinWidth)
    }

    func testKaomojiUseThreeEqualColumns() {
        for height in [CGFloat(150), 200, 288, 320] {
            let layout = QuickContentLayout.resolve(height: height, railItemCount: 8)
            XCTAssertEqual(layout.kaomojiColumnCount, 3)
        }
    }

    func testRailKeepsOneNarrowWidthAtEveryDensity() {
        // The column fits three characters at the category-rail size and no more, so the grid
        // gets the rest; it does not grow with the panel, because the choices are short words.
        for height in [CGFloat(150), 200, 240, 288, 320] {
            let layout = QuickContentLayout.resolve(height: height, railItemCount: 8)
            XCTAssertEqual(layout.railWidth, 60, accuracy: 0.01)
        }
    }

    func testDegenerateHeightStillAccountsForEveryPoint() {
        for height in [CGFloat(0), 1, 12, 36, 37] {
            let layout = QuickContentLayout.resolve(height: height, railItemCount: 8)
            XCTAssertGreaterThanOrEqual(layout.contentHeight, 0)
            XCTAssertLessThanOrEqual(chrome(layout), height + 0.01)
        }
    }
}
