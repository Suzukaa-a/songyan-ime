import XCTest

@testable import LayoutKit

final class KeyboardPageGeometryTests: XCTestCase {
    func testAlphabetPreviewUsesTheRuntimeTenColumnGridAndControls() {
        let page = KeyboardPagePresets.englishQwerty
        for width in [320.0, 466, 834, 1194] {
            let split = LayoutSplitConfiguration()
            let rows = page.rows.indices.map {
                KeyboardPageRowGeometry(width: width, page: page, row: $0, split: split)
            }
            XCTAssertFalse(rows[0].showsShift)
            XCTAssertTrue(rows[2].showsShift)
            XCTAssertTrue(rows[2].showsDelete)
            for row in rows {
                XCTAssertTrue(row.keyWidths.allSatisfy { abs($0 - rows[0].keyWidths[0]) < 0.001 })
            }
            XCTAssertEqual(rows[2].rowWidth + rows[2].sideWidth * 2 + 8, width, accuracy: 0.001)
        }
    }

    func testNumericAndSymbolThirdRowsIncludeTheTenthDeleteColumn() {
        for page in [
            KeyboardPagePresets.numericChinese, KeyboardPagePresets.numericEnglish, KeyboardPagePresets.symbolsChinese,
            KeyboardPagePresets.symbolsEnglish,
        ] {
            let first = KeyboardPageRowGeometry(width: 834, page: page, row: 0, split: LayoutSplitConfiguration())
            let third = KeyboardPageRowGeometry(width: 834, page: page, row: 2, split: LayoutSplitConfiguration())
            XCTAssertTrue(third.showsDelete)
            XCTAssertEqual(third.keyWidths.count, 9)
            XCTAssertEqual(third.sideWidth, first.keyWidths[0], accuracy: 0.001)
            XCTAssertEqual(third.rowWidth + third.sideWidth + 4, 834, accuracy: 0.001)
        }
    }

    func testAuthoredWidthsAndDeclaredDeleteAreNotReplacedByAutomaticChrome() {
        let page = KeyboardPageDefinition(
            id: "custom", name: "数字", kind: .numeric,
            rows: [
                .init(keys: [
                    .init(label: "1", width: 2, action: .init(.literal, value: "1")),
                    .init(label: "2", action: .init(.literal, value: "2")),
                    .init(label: "⌫", action: .init(.backspace)),
                ])
            ])
        let geometry = KeyboardPageRowGeometry(width: 600, page: page, row: 0, split: nil)
        XCTAssertFalse(geometry.showsDelete)
        XCTAssertEqual(geometry.keyWidths[0], geometry.keyWidths[1] * 2, accuracy: 0.001)
    }

    func testCategoryTailRowsKeepTheWidthsOfTheirFullRowCounterparts() {
        for weights in [[2.0, 1, 1, 1], [2, 2, 2, 2], [3, 1, 3, 1]] {
            for split in [nil, LayoutSplitConfiguration()] {
                let full = KeyboardCategoryRowGeometry(width: 650, columns: 4, weights: weights, row: 0, split: split)
                for count in 1...3 {
                    let tail = KeyboardCategoryRowGeometry(
                        width: 650, columns: 4, weights: Array(weights.prefix(count)), row: 1, split: split,
                        referenceWeights: weights)
                    XCTAssertEqual(tail.keyWidths, Array(full.keyWidths.prefix(count)))
                    XCTAssertLessThan(tail.usedWidth, 650)
                }
            }
        }
    }

    func testShortCategoryIsInvariantToUniformRelativeWeightScaling() {
        let baseline = KeyboardCategoryRowGeometry(width: 650, columns: 4, weights: [1, 1], row: 0, split: nil)
        for weights in [[2.0, 2], [3, 3]] {
            let scaled = KeyboardCategoryRowGeometry(width: 650, columns: 4, weights: weights, row: 0, split: nil)
            XCTAssertEqual(scaled.keyWidths, baseline.keyWidths)
        }
        let uneven = KeyboardCategoryRowGeometry(width: 650, columns: 4, weights: [3, 1], row: 0, split: nil)
        let scaled = KeyboardCategoryRowGeometry(width: 650, columns: 4, weights: [6, 2], row: 0, split: nil)
        XCTAssertEqual(scaled.keyWidths, uneven.keyWidths)
        XCTAssertEqual(uneven.keyWidths[0], uneven.keyWidths[1] * 3, accuracy: 0.001)
    }

    // MARK: - Authored chrome geometry

    func testAuthoredStandardAlphabetKeepsEqualColumnsAndRealSideWidths() {
        let page = KeyboardPagePresets.englishQwerty.materialized()
        for width in [320.0, 466, 834] {
            let split = LayoutSplitConfiguration()
            let standard = StandardKeyRowGeometry(width: width, split: split)
            let first = KeyboardPageRowGeometry(width: width, page: page, row: 0, split: split)
            let second = KeyboardPageRowGeometry(width: width, page: page, row: 1, split: split)
            let third = KeyboardPageRowGeometry(width: width, page: page, row: 2, split: split)
            XCTAssertTrue(first.usesStandardAlphabet)
            XCTAssertTrue(third.usesStandardAlphabet)
            XCTAssertFalse(first.showsShift)
            XCTAssertFalse(third.showsDelete)
            XCTAssertEqual(first.keyIndices.count, 10)
            XCTAssertEqual(third.keyIndices.count, 9)
            XCTAssertEqual(first.keyWidths.count, first.keyIndices.count)
            XCTAssertEqual(third.keyWidths.count, third.keyIndices.count)
            for keyWidth in first.keyWidths { XCTAssertEqual(keyWidth, standard.keyWidth, accuracy: 0.001) }
            for keyWidth in second.keyWidths { XCTAssertEqual(keyWidth, standard.keyWidth, accuracy: 0.001) }
            XCTAssertEqual(third.keyWidths[0], standard.thirdRowSideWidth, accuracy: 0.001)
            XCTAssertEqual(third.keyWidths[third.keyWidths.count - 1], standard.thirdRowSideWidth, accuracy: 0.001)
            for keyWidth in third.keyWidths.dropFirst().dropLast() {
                XCTAssertEqual(keyWidth, standard.keyWidth, accuracy: 0.001)
            }
            // The row's own area plus the two sides and their gaps still sums to the keyboard width.
            XCTAssertEqual(
                third.keyWidths.dropFirst().dropLast().reduce(0, +) + standard.gap
                    + Double(6) * 4 + third.inset * 2 + standard.thirdRowSideWidth * 2 + 8, width,
                accuracy: 0.001)
        }
    }

    func testChangedSideWeightReallyGetsNarrower() {
        let materialized = KeyboardPagePresets.englishQwerty.materialized()
        let baseline = KeyboardPageRowGeometry(
            width: 834, page: materialized, row: 2, split: LayoutSplitConfiguration())
        var changed = materialized
        var lastRow = changed.rows[2].keys
        lastRow[0] = lastRow[0].settingWidth(1)
        changed.rows[2] = LayoutRow(keys: lastRow)
        let geometry = KeyboardPageRowGeometry(
            width: 834, page: changed, row: 2, split: LayoutSplitConfiguration())
        XCTAssertFalse(geometry.usesStandardAlphabet)
        XCTAssertLessThan(geometry.keyWidths[0], baseline.keyWidths[0])
        XCTAssertEqual(geometry.keyWidths[0], geometry.keyWidths[1], accuracy: 0.001)
        XCTAssertEqual(geometry.keyWidths.count, 9)
    }

    func testReplacingAStandardAlphabetLetterWithAControlLeavesTheEqualColumnGeometry() {
        let materialized = KeyboardPagePresets.englishQwerty.materialized()
        var changed = materialized
        var lastRow = changed.rows[2].keys
        lastRow[1] = lastRow[1].settingAction(.init(.space))
        changed.rows[2] = LayoutRow(keys: lastRow)
        let geometry = KeyboardPageRowGeometry(
            width: 834, page: changed, row: 2, split: LayoutSplitConfiguration())
        XCTAssertFalse(geometry.usesStandardAlphabet)

        var firstRowChanged = materialized
        var firstRow = firstRowChanged.rows[0].keys
        firstRow[0] = firstRow[0].settingAction(.init(.backspace))
        firstRowChanged.rows[0] = LayoutRow(keys: firstRow)
        XCTAssertFalse(
            KeyboardPageRowGeometry(
                width: 834, page: firstRowChanged, row: 0, split: LayoutSplitConfiguration()
            ).usesStandardAlphabet)
    }

    func testMaterialisedNumericRowKeepsTenEqualColumns() {
        let page = KeyboardPagePresets.numericChinese.materialized()
        for width in [320.0, 466, 834] {
            let split = LayoutSplitConfiguration()
            let standard = StandardKeyRowGeometry(width: width, split: split)
            for row in 0..<page.rows.count {
                let geometry = KeyboardPageRowGeometry(width: width, page: page, row: row, split: split)
                XCTAssertEqual(geometry.keyIndices.count, 10)
                XCTAssertEqual(geometry.keyWidths.count, 10)
                XCTAssertFalse(geometry.usesStandardAlphabet)
                for keyWidth in geometry.keyWidths {
                    XCTAssertEqual(keyWidth, standard.keyWidth, accuracy: 0.001)
                }
            }
        }
    }
}
