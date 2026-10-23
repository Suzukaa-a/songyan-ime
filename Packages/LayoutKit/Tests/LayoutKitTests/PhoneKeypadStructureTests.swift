import XCTest

@testable import LayoutKit

/// Coverage for `PhoneKeypadStructure`: the phone shell must serve the bundled T9
/// **and** a provably-standard imported telephone keypad, while rejecting every
/// ambiguous shape (duplicate / missing / misordered digits, wrong first slot,
/// plain calculator grids, custom 3×3 numeric pads) and never matching 14/26.
final class PhoneKeypadStructureTests: XCTestCase {
    private func digit(_ value: String, label: String? = nil) -> LayoutKey {
        LayoutKey(label: label ?? value, secondaryLabel: value, action: .init(.code, value: value))
    }

    private func oneKey(label: String = "，。？") -> LayoutKey {
        LayoutKey(
            label: label, secondaryLabel: "1", action: .init(.literal, value: "，"),
            longPress: [.init(label: "1", action: .init(.literal, value: "1"))])
    }

    private func controls() -> LayoutRow {
        LayoutRow(keys: [
            LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
            LayoutKey(label: "空格", width: 4, action: .init(.space)),
        ])
    }

    /// A canonical 3×3 telephone pad. `first` overrides the row-0 col-0 slot;
    /// `digits` overrides the eight digit-bearing positions in row-major order
    /// (defaults to the canonical 2...9).
    private func phoneRows(
        first: LayoutKey? = nil,
        digits: [LayoutKey]? = nil,
        trailingControls: Bool = false
    ) -> [LayoutRow] {
        let values = digits ?? ["2", "3", "4", "5", "6", "7", "8", "9"].map { digit($0) }
        let flat: [LayoutKey] = [first ?? oneKey()] + values
        var rows: [LayoutRow] = []
        for index in 0..<3 {
            rows.append(LayoutRow(keys: Array(flat[(index * 3)..<(index * 3 + 3)])))
        }
        if trailingControls { rows.append(controls()) }
        return rows
    }

    private func definition(
        id: String = "custom-phone", rows: [LayoutRow],
        areas: [LayoutAuxiliaryArea]? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: "导入九键", input: .init(schemaID: "imported_t9"),
            rows: rows, auxiliaryAreas: areas)
    }

    // MARK: Accepted

    func testBundledT9MatchesThePhoneStructure() {
        XCTAssertTrue(PhoneKeypadStructure.matches(BuiltinLayouts.phone9))
        XCTAssertEqual(PhoneKeypadStructure.mainRows(in: BuiltinLayouts.phone9)?.count, 3)
    }

    func testCanonicalImportedPhoneKeypadMatches() {
        let imported = definition(id: "canonical", rows: phoneRows())
        XCTAssertTrue(PhoneKeypadStructure.matches(imported))
        XCTAssertEqual(PhoneKeypadStructure.mainRows(in: imported)?.count, 3)
    }

    func testImportedKeypadWithDeclaredControlRowMatches() {
        XCTAssertTrue(PhoneKeypadStructure.matches(definition(rows: phoneRows(trailingControls: true))))
    }

    func testFirstSlotMayBePunctuationWithLongPressOneOrPlainCodeOne() {
        // A punctuation first key whose long-press provides `1`.
        XCTAssertTrue(PhoneKeypadStructure.matches(definition(rows: phoneRows(first: oneKey()))))
        // Or a first key that directly emits the `1` code.
        let directOne = LayoutKey(label: "1", action: .init(.code, value: "1"))
        XCTAssertTrue(PhoneKeypadStructure.matches(definition(rows: phoneRows(first: directOne))))
        // Or a literal "1".
        let literalOne = LayoutKey(label: "1", action: .init(.literal, value: "1"))
        XCTAssertTrue(PhoneKeypadStructure.matches(definition(rows: phoneRows(first: literalOne))))
    }

    // MARK: Rejected: digit-set and position

    func testDuplicateDigitIsRejected() {
        // 9 duplicated, 8 missing: no longer a provably standard map.
        let keys = ["2", "3", "4", "5", "6", "7", "8", "9"].map { digit($0) }
        var mutated = keys
        mutated[6] = digit("9")  // row 2 col 1 becomes 9 instead of 8
        XCTAssertNil(PhoneKeypadStructure.mainRows(in: definition(rows: phoneRows(digits: mutated))))
    }

    func testMissingDigitIsRejected() {
        // Row 2 col 2 holds a punctuation key instead of 9.
        let keys =
            ["2", "3", "4", "5", "6", "7", "8"].map { digit($0) }
            + [LayoutKey(label: "，", action: .init(.literal, value: "，"))]
        XCTAssertNil(PhoneKeypadStructure.mainRows(in: definition(rows: phoneRows(digits: keys))))
    }

    func testMisorderedDigitsAreRejected() {
        // Swap 2 and 3 (both present exactly once, but at the wrong positions).
        let keys = ["3", "2", "4", "5", "6", "7", "8", "9"].map { digit($0) }
        XCTAssertNil(
            PhoneKeypadStructure.mainRows(in: definition(rows: phoneRows(digits: keys))),
            "a permuted key map is not the standard telephone mapping")
    }

    func testWrongFirstSlotIsRejected() {
        // First slot sends a letter / punctuation without any `1` capability.
        let wrongFirst = LayoutKey(label: "abc", action: .init(.code, value: "a"))
        XCTAssertNil(PhoneKeypadStructure.mainRows(in: definition(rows: phoneRows(first: wrongFirst))))
    }

    // MARK: Rejected: other keypads

    func testQWERTYAndMergedLayoutsNeverMatch() {
        for definition in BuiltinLayouts.all where definition.id != "phone9" {
            XCTAssertNil(
                PhoneKeypadStructure.mainRows(in: definition),
                "\(definition.id) must never take the phone shell")
            XCTAssertFalse(PhoneKeypadStructure.matches(definition), definition.id)
        }
    }

    func testThreeByThreeLetterGridIsNotAPhoneKeypad() {
        // Same 3×3 shape but sends letters: must not match.
        let rows: [LayoutRow] = (0..<3).map { row in
            LayoutRow(
                keys: (0..<3).map { column in
                    let letters = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
                    let value = letters[row * 3 + column]
                    return LayoutKey(label: value, action: .init(.code, value: value))
                })
        }
        XCTAssertFalse(PhoneKeypadStructure.matches(definition(rows: rows + [controls()])))
    }

    /// A plain calculator / numpad 3×3 numeric grid (7 8 9 / 4 5 6 / 1 2 3).
    /// It contains each of 2...9 exactly once, so only the *position* requirement
    /// rejects it: 7 sits where the telephone `2` belongs, 8 where `3` belongs, and
    /// so on. This is the reason reordering cannot be accepted.
    func testCalculatorNumericGridIsRejected() {
        let layout = ["7", "8", "9", "4", "5", "6", "1", "2", "3"]
        let rows: [LayoutRow] = (0..<3).map { row in
            LayoutRow(
                keys: (0..<3).map { column in
                    let value = layout[row * 3 + column]
                    return LayoutKey(label: value, action: .init(.code, value: value))
                })
        }
        XCTAssertFalse(
            PhoneKeypadStructure.matches(definition(id: "calc", rows: rows + [controls()])),
            "a calculator numeric grid is not a telephone keypad")
    }

    func testCustomThreeByThreeNumericPadWithoutDigitsIsRejected() {
        // A custom pad of symbols / actions, not telephone digits.
        let symbols = ["@", "#", "-", "+", "(", ")", "/", "*", "="]
        let rows: [LayoutRow] = (0..<3).map { row in
            LayoutRow(
                keys: (0..<3).map { column in
                    let value = symbols[row * 3 + column]
                    return LayoutKey(label: value, action: .init(.literal, value: value))
                })
        }
        XCTAssertFalse(PhoneKeypadStructure.matches(definition(id: "symbols9", rows: rows + [controls()])))
    }

    func testRowsWithWrongKeyCountAreRejected() {
        let rows = [
            LayoutRow(keys: [digit("2"), digit("3")]),
            LayoutRow(keys: [digit("4"), digit("5")]),
            LayoutRow(keys: [digit("6"), digit("7")]),
            LayoutRow(keys: [LayoutKey(label: "空格", action: .init(.space))]),
        ]
        XCTAssertFalse(PhoneKeypadStructure.matches(definition(id: "twoCol", rows: rows)))
    }

    func testThreeRowPadWithoutControlRowIsAccepted() {
        // `[3,3,3]` with no control row: the shell supplies the shared bottom row.
        XCTAssertTrue(PhoneKeypadStructure.matches(definition(rows: phoneRows())))
    }
}
