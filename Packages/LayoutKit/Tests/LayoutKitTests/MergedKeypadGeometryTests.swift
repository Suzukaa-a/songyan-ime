import XCTest

@testable import LayoutKit

final class MergedKeypadGeometryTests: XCTestCase {
    private func weights(_ definition: LayoutDefinition) -> [[Double]] {
        CompactSpellingLayout.mainRows(in: definition).map { $0.keys.map(\.widthWeight) }
    }

    /// 18-key rows span the same units as the 26-key letter rows.
    func testEighteenKeyRowsMatchTwentySixKeyUnits() {
        XCTAssertEqual(weights(BuiltinLayouts.merged18).map(MergedKeypadGeometry.units), [10, 9, 7])
        XCTAssertEqual(weights(BuiltinLayouts.qwerty26).map(MergedKeypadGeometry.units), [10, 9, 7])
    }

    /// A pair covers exactly the two 26-key letters it replaces, gap included.
    func testPairSpansTwoLettersAndTheGapBetween() throws {
        let rows = MergedKeypadGeometry.rows(
            weights: weights(BuiltinLayouts.merged18),
            width: 390, spacing: 4, sideWidth: 60)
        let unit = (390.0 - 9 * 4) / 10
        XCTAssertEqual(rows[0].keyWidths[0], unit, accuracy: 0.001)
        XCTAssertEqual(rows[0].keyWidths[1], 2 * unit + 4, accuracy: 0.001)
        XCTAssertEqual(rows[0].leadingInset, 0, accuracy: 0.001)
        // Nine units centred under ten: half a key plus half a gap on each side, like 26-key.
        XCTAssertEqual(rows[1].leadingInset, (unit + 4) / 2, accuracy: 0.001)
        let last = rows[2].keyWidths.reduce(0, +) + Double(rows[2].keyWidths.count - 1) * 4
        XCTAssertEqual(last, 390 - 2 * (60 + 4), accuracy: 0.001)
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
