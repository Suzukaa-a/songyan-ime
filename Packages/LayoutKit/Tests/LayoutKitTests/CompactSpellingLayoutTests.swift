import XCTest

@testable import LayoutKit

/// Physical-structure predicate for disambiguation eligibility: only two provable shapes (standard phone 9-key /
/// merged letter keys) count as compact-spelling layouts; everything else fails closed.
///
/// Key regression: a definition with 26-key `rows` but `input.builtinLayout` mislabeled `merged14` (or `phone9`)
/// must be `false`. The old implementation only looked at `KeyboardLayoutKind`, so such a definition got the
/// disambiguation UI and sent real `ambiguitySpellings()` queries to the engine.
final class CompactSpellingLayoutTests: XCTestCase {

    // MARK: Definition builders

    private func code(_ value: String) -> LayoutKey {
        LayoutKey(label: value, secondaryLabel: value, action: .init(.code, value: value))
    }

    private func literal(_ value: String) -> LayoutKey {
        LayoutKey(label: value, action: .init(.literal, value: value))
    }

    private func oneKey() -> LayoutKey {
        LayoutKey(
            label: "，。？", secondaryLabel: "1", action: .init(.literal, value: "，"),
            longPress: [.init(label: "1", action: .init(.literal, value: "1"))])
    }

    private func controls() -> LayoutRow {
        LayoutRow(keys: [
            LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
            LayoutKey(label: "空格", width: 4, action: .init(.space)),
            LayoutKey(label: "⌫", action: .init(.backspace)),
            LayoutKey(label: "⏎", action: .init(.enter)),
        ])
    }

    private func definition(
        id: String, rows: [LayoutRow],
        builtin: LayoutInput.Builtin? = nil,
        schemaID: String? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: id,
            input: .init(schemaID: schemaID, builtinLayout: builtin),
            rows: rows)
    }

    /// Standard phone 3x3 (digit positions and `1` slot are valid).
    private func telephoneRows(trailingControls: Bool = false) -> [LayoutRow] {
        let flat: [LayoutKey] = [oneKey()] + ["2", "3", "4", "5", "6", "7", "8", "9"].map(code)
        var rows = (0..<3).map { LayoutRow(keys: Array(flat[($0 * 3)..<($0 * 3 + 3)])) }
        if trailingControls { rows.append(controls()) }
        return rows
    }

    /// 26-key QWERTY (10/9/7, 26 encoding keys) + control row.
    private func qwerty26Rows() -> [LayoutRow] {
        ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { row in
            LayoutRow(keys: row.map(String.init).map(code))
        } + [controls()]
    }

    /// A merged key labelled with its letters, sending the first.
    private func group(_ letters: String) -> LayoutKey {
        LayoutKey(label: letters.uppercased(), action: .init(.code, value: String(letters.prefix(1))))
    }

    /// Merged 14-key (cluster representative letters).
    private func merged14Rows(trailingControls: Bool = true) -> [LayoutRow] {
        let groups = [["qw", "er", "ty", "ui", "op"], ["as", "df", "gh", "jk"], ["l", "zx", "cv", "bn", "m"]]
        let rows = groups.map { LayoutRow(keys: $0.map(group)) }
        return trailingControls ? rows + [controls()] : rows
    }

    // MARK: Accepted

    func testBundledCompactLayoutsMatch() {
        XCTAssertTrue(CompactSpellingLayout.matches(BuiltinLayouts.phone9))
        XCTAssertTrue(CompactSpellingLayout.matches(BuiltinLayouts.merged14))
        XCTAssertTrue(CompactSpellingLayout.matches(BuiltinLayouts.merged18))
    }

    /// Any row arrangement qualifies as long as the labels split a–z and each key sends its first letter.
    func testLetterGroupsAreReadFromLabels() {
        let rows = [
            LayoutRow(keys: ["qwe", "rty", "uio", "p"].map(group)),
            LayoutRow(keys: ["asd", "fgh", "jkl"].map(group)),
            LayoutRow(keys: ["zxc", "vbn", "m"].map(group)),
        ]
        XCTAssertTrue(CompactSpellingLayout.matches(definition(id: "triples", rows: rows + [controls()])))
    }

    func testMislabelledOrIncompleteGroupsAreRejected() {
        var rows = merged14Rows(trailingControls: false)
        // QW sending w: the key would not send its group's first letter.
        rows[0] = LayoutRow(keys: [LayoutKey(label: "QW", action: .init(.code, value: "w"))] + rows[0].keys.dropFirst())
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "wrongSent", rows: rows)))
        // A letter on two keys.
        rows = merged14Rows(trailingControls: false)
        rows[1] = LayoutRow(keys: rows[1].keys + [group("aq")])
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "overlap", rows: rows)))
        // A letter missing.
        rows = merged14Rows(trailingControls: false)
        rows[2] = LayoutRow(keys: Array(rows[2].keys.dropLast()))
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "missing", rows: rows)))
    }

    /// Legitimately imported 9-key / 14-key (including the form declaring only three rows, with the shell adding the bottom row) must not be hurt.
    func testImportedNineKeyAndFourteenKeyStillMatch() {
        XCTAssertTrue(
            CompactSpellingLayout.matches(
                definition(id: "imp9", rows: telephoneRows(), schemaID: "imported_t9")))
        XCTAssertTrue(
            CompactSpellingLayout.matches(
                definition(id: "imp9c", rows: telephoneRows(trailingControls: true), schemaID: "imported_t9")))
        XCTAssertTrue(
            CompactSpellingLayout.matches(
                definition(id: "imp14", rows: merged14Rows(), schemaID: "imported_14")))
        XCTAssertTrue(
            CompactSpellingLayout.matches(
                definition(
                    id: "imp14bare", rows: merged14Rows(trailingControls: false),
                    schemaID: "imported_14")))
    }

    // MARK: Rejected

    func testBundledTwentySixKeyLayoutNeverMatches() {
        XCTAssertFalse(CompactSpellingLayout.matches(BuiltinLayouts.qwerty26))
    }

    /// Core regression: 26-key rows with a mislabeled builtinLayout.
    /// The old predicate (`layout == .phone9 || layout == .merged14`) accepted this.
    func testTwentySixKeyRowsNeverMatchEvenWhenBuiltinIsMislabeled() {
        XCTAssertFalse(
            CompactSpellingLayout.matches(
                definition(id: "bogus14", rows: qwerty26Rows(), builtin: .merged14)),
            "a 26-key definition mislabeled merged14 must not get disambiguation eligibility")
        XCTAssertFalse(
            CompactSpellingLayout.matches(
                definition(id: "bogus9", rows: qwerty26Rows(), builtin: .phone9)),
            "a 26-key definition mislabeled phone9 must not get disambiguation eligibility")
        XCTAssertFalse(
            CompactSpellingLayout.matches(
                definition(id: "bogusSchema", rows: qwerty26Rows(), schemaID: "imported_14")),
            "the schema-only form also looks only at physical rows")
    }

    func testNilDefinitionIsNotCompact() {
        XCTAssertFalse(CompactSpellingLayout.matches(nil))
    }

    /// Calculator digit grid and symbol 3x3: nine keys, but not the phone structure.
    func testNineKeyShapesThatAreNotTelephonePadsAreRejected() {
        let calculator = ["7", "8", "9", "4", "5", "6", "1", "2", "3"]
        let calculatorRows =
            (0..<3).map { row in
                LayoutRow(keys: (0..<3).map { column in code(calculator[row * 3 + column]) })
            } + [controls()]
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "calc", rows: calculatorRows)))

        let symbols = ["@", "#", "-", "+", "(", ")", "/", "*", "="]
        let symbolRows =
            (0..<3).map { row in
                LayoutRow(keys: (0..<3).map { column in literal(symbols[row * 3 + column]) })
            } + [controls()]
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "symbols", rows: symbolRows)))

        let letters = "abcdefghi".map(String.init)
        let letterRows =
            (0..<3).map { row in
                LayoutRow(keys: (0..<3).map { column in code(letters[row * 3 + column]) })
            } + [controls()]
        XCTAssertFalse(CompactSpellingLayout.matches(definition(id: "letters3x3", rows: letterRows)))
    }

    /// Fourteen single-letter keys cover only fourteen letters, whatever the row shape.
    func testFourteenKeyRowsThatAreNotTheMergedShapeAreRejected() {
        let fourRows = [
            LayoutRow(keys: ["q", "w", "e", "r"].map(code)),
            LayoutRow(keys: ["t", "y", "u", "i"].map(code)),
            LayoutRow(keys: ["o", "p", "a", "s"].map(code)),
            LayoutRow(keys: ["d", "f"].map(code)),
        ]
        XCTAssertFalse(
            CompactSpellingLayout.matches(
                definition(id: "fourRow14", rows: fourRows + [controls()])))

        let fiveFourSix = [
            LayoutRow(keys: ["q", "w", "e", "r", "t"].map(code)),
            LayoutRow(keys: ["y", "u", "i", "o"].map(code)),
            LayoutRow(keys: ["p", "a", "s", "d", "f", "g"].map(code)),
        ]
        XCTAssertFalse(
            CompactSpellingLayout.matches(
                definition(id: "fiveFourSix", rows: fiveFourSix + [controls()])))
    }

    // MARK: Letter groups

    func testLetterGroupsOfBundledLayouts() throws {
        XCTAssertEqual(LetterGroupLayout.groups(in: BuiltinLayouts.qwerty26)?.count, 26)
        let fourteen = try XCTUnwrap(LetterGroupLayout.groups(in: BuiltinLayouts.merged14))
        XCTAssertEqual(
            fourteen.map { String($0) },
            ["qw", "er", "ty", "ui", "op", "as", "df", "gh", "jk", "l", "zx", "cv", "bn", "m"])
        let eighteen = try XCTUnwrap(LetterGroupLayout.groups(in: BuiltinLayouts.merged18))
        XCTAssertEqual(
            eighteen.map { String($0) },
            [
                "q", "we", "rt", "y", "u", "io", "p", "a", "sd", "fg", "h", "jk", "l",
                "z", "xc", "v", "bn", "m",
            ])
        XCTAssertEqual(String(eighteen.compactMap(\.first)), "qwryuipasfhjlzxvbm")
        XCTAssertNil(LetterGroupLayout.groups(in: BuiltinLayouts.phone9))
        XCTAssertNil(LetterGroupLayout.groups(in: nil))
    }

    func testReadingKeyMapComesFromCompactKeyLabels() {
        let t9 = CompactSpellingLayout.readingKeyMap(for: BuiltinLayouts.phone9)
        XCTAssertEqual(t9["n"], "6")
        XCTAssertEqual(t9["h"], "4")
        XCTAssertEqual(t9["z"], "9")
        let merged = CompactSpellingLayout.readingKeyMap(for: BuiltinLayouts.merged14)
        XCTAssertEqual(merged["w"], "q")
        XCTAssertEqual(merged["n"], "b")
        let eighteen = CompactSpellingLayout.readingKeyMap(for: BuiltinLayouts.merged18)
        XCTAssertEqual(
            eighteen,
            [
                "q": "q", "w": "w", "e": "w", "r": "r", "t": "r", "y": "y", "u": "u",
                "i": "i", "o": "i", "p": "p", "a": "a", "s": "s", "d": "s", "f": "f",
                "g": "f", "h": "h", "j": "j", "k": "j", "l": "l", "z": "z", "x": "x",
                "c": "x", "v": "v", "b": "b", "n": "b", "m": "m",
            ])
        XCTAssertTrue(CompactSpellingLayout.readingKeyMap(for: BuiltinLayouts.qwerty26).isEmpty)
        XCTAssertTrue(CompactSpellingLayout.readingKeyMap(for: nil).isEmpty)
    }
}
