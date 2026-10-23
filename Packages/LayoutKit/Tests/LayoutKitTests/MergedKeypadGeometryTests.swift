import XCTest

@testable import LayoutKit

final class MergedKeypadGeometryTests: XCTestCase {
    private func weights(_ definition: LayoutDefinition) -> [[Double]] {
        CompactSpellingLayout.mainRows(in: definition).map { $0.keys.map(\.widthWeight) }
    }

    /// 18-key singles weigh 1.3 and pairs 1.7 in every row, so row 2 sits 0.65 units
    /// (half a single key) in from each side of row 1.
    func testEighteenKeyRowUnits() {
        let units = weights(BuiltinLayouts.merged18).map(MergedKeypadGeometry.units)
        XCTAssertEqual(units[0], 10.3, accuracy: 0.0001)
        XCTAssertEqual(units[1], 9.0, accuracy: 0.0001)
        XCTAssertEqual(units[2], 7.3, accuracy: 0.0001)
        XCTAssertEqual(weights(BuiltinLayouts.qwerty26).map(MergedKeypadGeometry.units), [10, 9, 7])
    }

    /// On real phone widths (keypad = screen minus the panel's 4 pt side padding; side keys
    /// from `sharedDeleteWidth`), pairs give 8–16 pt back to the single keys and stay wider.
    func testEighteenKeyCapWidthsOnPhones() {
        let rowsKeys = CompactSpellingLayout.mainRows(in: BuiltinLayouts.merged18).map(\.keys)
        for (screen, side) in [(420.0, 68.4), (375.0, 60.3)] {
            let width = screen - 8
            let rows = MergedKeypadGeometry.rows(
                weights: weights(BuiltinLayouts.merged18), width: width, spacing: 4, sideWidth: side)
            let letterWidth = (width - 9 * 4) / 10
            let twoUnitPair = 2 * letterWidth + 4
            for (index, row) in rows.enumerated() {
                let caps = zip(rowsKeys[index], row.keyWidths)
                let singles = caps.filter { $0.0.label.count == 1 }.map(\.1)
                let pairs = caps.filter { $0.0.label.count == 2 }.map(\.1)
                XCTAssertEqual(Set(singles.map { ($0 * 1000).rounded() }).count, 1)
                XCTAssertEqual(Set(pairs.map { ($0 * 1000).rounded() }).count, 1)
                XCTAssertGreaterThan(pairs[0], singles[0] * 1.25, "\(screen) pairs stay wider")
                guard index < 2 else { continue }
                XCTAssertGreaterThan(singles[0], letterWidth + 6, "\(screen) singles grow")
                XCTAssertTrue((8.0...16.0).contains(twoUnitPair - pairs[0]), "\(screen) pairs give back 8-16 pt")
            }
            XCTAssertEqual(rows[0].leadingInset, 0, accuracy: 0.001)
            XCTAssertEqual(rows[1].leadingInset, 0.65 * (width + 4) / 10.3, accuracy: 0.001)
            let last = rows[2].keyWidths.reduce(0, +) + Double(rows[2].keyWidths.count - 1) * 4
            XCTAssertEqual(last, width - 2 * (side + 4), accuracy: 0.001)
        }
    }

    /// 14-key keeps equal caps in every row.
    func testFourteenKeyCapsStayEqual() {
        let rows = MergedKeypadGeometry.rows(
            weights: weights(BuiltinLayouts.merged14),
            width: 390, spacing: 4, sideWidth: 60)
        XCTAssertEqual(rows.map(\.keyWidths.count), [5, 5, 4])
        for row in rows { XCTAssertEqual(Set(row.keyWidths.map { ($0 * 1000).rounded() }).count, 1) }
        XCTAssertEqual(rows[0].keyWidths[0], (390 - 4 * 4) / 5, accuracy: 0.001)
        XCTAssertEqual(rows[1].keyWidths[0], rows[0].keyWidths[0], accuracy: 0.001)
        XCTAssertEqual(rows[2].keyWidths[0], (390 - 2 * 64 - 3 * 4) / 4, accuracy: 0.001)
    }
}
