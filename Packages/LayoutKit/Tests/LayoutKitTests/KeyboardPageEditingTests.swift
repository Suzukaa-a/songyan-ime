import XCTest

@testable import LayoutKit

final class KeyboardPageEditingTests: XCTestCase {
    private func key(_ label: String) -> LayoutKey {
        LayoutKey(label: label, action: .init(.literal, value: label))
    }

    private func page(
        rows: [[String]], bottom: [String] = [], trailing: [String] = [],
        split: LayoutSplitConfiguration? = nil, categorized: Bool = false
    ) -> KeyboardPageDefinition {
        KeyboardPageDefinition(
            id: "page", name: "页面", kind: .symbols,
            rows: rows.map { LayoutRow(keys: $0.map(key)) }, split: split,
            symbolPresentation: categorized ? .categorized : .rows,
            chrome: KeyboardPageChrome(bottom: bottom.map(key), trailing: trailing.map(key)))
    }

    func testMovingARowKeyToTheFooterAppendsItAndReclampsTheCuts() throws {
        let source = page(
            rows: [["a", "b", "c"], ["d", "e"]], bottom: ["空格"],
            split: LayoutSplitConfiguration(activation: .always, rowBreaks: [2, 1]))
        let moved = try XCTUnwrap(source.movingKey(at: .row(0, key: 2), to: .chrome(.bottom)))
        XCTAssertEqual(moved.page.rows[0].keys.map(\.label), ["a", "b"])
        XCTAssertEqual(moved.page.chrome?.bottom.map(\.label), ["空格", "c"])
        XCTAssertEqual(moved.path, .chrome(.bottom, key: 1))
        // Two key rows plus the footer row, each cut inside its row.
        XCTAssertEqual(moved.page.split?.rowBreaks, [1, 1, 1])
    }

    func testMovingTheLastKeyOfARowRemovesTheRow() throws {
        let source = page(rows: [["a"], ["b", "c"]], trailing: ["⌫"])
        let moved = try XCTUnwrap(source.movingKey(at: .row(0, key: 0), to: .chrome(.trailing)))
        XCTAssertEqual(moved.page.rows.map { $0.keys.map(\.label) }, [["b", "c"]])
        XCTAssertEqual(moved.page.chrome?.trailing.map(\.label), ["⌫", "a"])
    }

    func testThePagesOnlyKeyCannotLeaveButCanBeCopied() throws {
        let source = page(rows: [["a"]])
        XCTAssertFalse(source.canMoveKey(at: .row(0, key: 0), to: .chrome(.bottom)))
        XCTAssertNil(source.movingKey(at: .row(0, key: 0), to: .chrome(.bottom)))
        XCTAssertNil(source.removingKey(at: .row(0, key: 0)))
        let copied = try XCTUnwrap(source.copyingKey(at: .row(0, key: 0), to: .chrome(.bottom)))
        XCTAssertEqual(copied.page.rows[0].keys.map(\.label), ["a"])
        XCTAssertEqual(copied.page.chrome?.bottom.map(\.label), ["a"])
    }

    func testAFullTargetRejectsTheMoveWithoutLosingTheKey() {
        let full = Array(repeating: "x", count: LayoutResourceBudget.keysPerRegion)
        let source = page(rows: [["a", "b"]], bottom: full)
        XCTAssertFalse(source.canAppendKey(to: .chrome(.bottom)))
        XCTAssertNil(source.movingKey(at: .row(0, key: 0), to: .chrome(.bottom)))
        XCTAssertNil(source.copyingKey(at: .row(0, key: 0), to: .chrome(.bottom)))
    }

    func testMovingToItsOwnAreaIsRejected() {
        let source = page(rows: [["a", "b"]], bottom: ["空格"])
        XCTAssertFalse(source.canMoveKey(at: .chrome(.bottom, key: 0), to: .chrome(.bottom)))
        XCTAssertFalse(source.canCopyKey(at: .row(0, key: 0), to: .rows))
    }

    func testFunctionKeysReorderDuplicateAndRemoveInsideTheirArea() throws {
        let source = page(rows: [["a", "b"]], bottom: ["1", "2", "3"])
        let reordered = try XCTUnwrap(source.reorderingChromeKey(at: .chrome(.bottom, key: 0), by: 1))
        XCTAssertEqual(reordered.page.chrome?.bottom.map(\.label), ["2", "1", "3"])
        XCTAssertEqual(reordered.path, .chrome(.bottom, key: 1))
        XCTAssertNil(source.reorderingChromeKey(at: .chrome(.bottom, key: 2), by: 1))
        XCTAssertNil(source.reorderingChromeKey(at: .row(0, key: 0), by: 1))

        let duplicated = try XCTUnwrap(source.duplicatingChromeKey(at: .chrome(.bottom, key: 1)))
        XCTAssertEqual(duplicated.page.chrome?.bottom.map(\.label), ["1", "2", "2", "3"])
        XCTAssertEqual(duplicated.path, .chrome(.bottom, key: 2))

        let removed = try XCTUnwrap(source.removingKey(at: .chrome(.bottom, key: 2)))
        XCTAssertEqual(removed.chrome?.bottom.map(\.label), ["1", "2"])
        XCTAssertEqual(removed.selectionAfterRemoving(.chrome(.bottom, key: 2)), .chrome(.bottom, key: 1))
    }

    func testRemovingTheLastFunctionKeyFallsBackToTheFirstKey() throws {
        let source = page(rows: [["a", "b"]], trailing: ["⌫"])
        let removed = try XCTUnwrap(source.removingKey(at: .chrome(.trailing, key: 0)))
        XCTAssertEqual(removed.chrome?.trailing, [])
        XCTAssertEqual(removed.selectionAfterRemoving(.chrome(.trailing, key: 0)), .row(0, key: 0))
    }

    func testCategorizedPagesOnlyOfferTheFooterAndTheRightRail() {
        let categorized = page(rows: [], bottom: ["空格"], categorized: true)
        XCTAssertEqual(categorized.editableKeyRegions, [.chrome(.bottom), .chrome(.trailing)])
        XCTAssertEqual(categorized.firstKeyPath, .chrome(.bottom, key: 0))
        XCTAssertEqual(
            page(rows: [["a"]]).editableKeyRegions,
            [.rows, .chrome(.bottom), .chrome(.leading), .chrome(.trailing)])
    }

    func testSplitRowsIncludeTheAuthoredFooter() {
        XCTAssertEqual(page(rows: [["a"]], bottom: ["空格"]).splitRows.count, 2)
        XCTAssertEqual(page(rows: [["a"]]).splitRows.count, 1)
    }
}
