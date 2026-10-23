import Foundation

/// Structural recognition of a **standard telephone keypad** definition.
///
/// The bundled T9 is matched by content equality, but an imported phone keypad
/// with the same shape under a different id/name must use the *same* shell, not
/// the generic DIY renderer with its differently aligned geometry. This matcher recognises the standard telephone mapping
/// **provably**, not by approximation:
///
///  * exactly three main rows of exactly three keys, optionally followed by one
///    non-encoding control row (the bundled T9 shape);
///  * digits `2...9` each appear **exactly once**, each at its canonical
///    telephone position — `2/3` on row 0 (columns 1–2), `4/5/6` on row 1,
///    `7/8/9` on row 2 — and each sends a `.code` digit (the letter-derivation
///    path), never a `.literal`;
///  * the remaining row-0 column-0 slot is the telephone "1"/punctuation key: a
///    key that can produce the `1` input (on tap or via a long-press alternate)
///    or whose tap is a punctuation literal. A telephone pad's `1` sits top-left;
///    the bundled T9 cycles punctuation there without long-press alternates.
///
/// Reordering is **not** accepted: only the phone arrangement (`1/标点 2 3` …) is
/// the standard telephone mapping, so a *calculator* grid (7 8 9 / 4 5 6 / 1 2 3)
/// is rejected by the position rule even though it contains 2...9 exactly once.
/// Anything ambiguous is rejected rather than guessed.
public enum PhoneKeypadStructure {
    /// Canonical telephone positions. `nil` marks the "1"/punctuation slot, which
    /// is validated by `isOneSlot` rather than by an exact digit.
    private static let canonicalDigits: [[String?]] = [
        [nil, "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
    ]

    /// The three digit rows, or `nil` when the definition is not a standard
    /// telephone keypad.
    public static func mainRows(in definition: LayoutDefinition) -> [LayoutRow]? {
        let rows: [LayoutRow]
        switch definition.rows.count {
        case 3:
            rows = definition.rows
        case 4 where isControlRow(definition.rows[3]):
            rows = Array(definition.rows.prefix(3))
        default:
            return nil
        }
        guard rows.allSatisfy({ $0.keys.count == 3 }) else { return nil }

        var seen = Set<String>()
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, key) in row.keys.enumerated() {
                if let expected = canonicalDigits[rowIndex][columnIndex] {
                    guard isTelephoneDigit(key, value: expected),
                        seen.insert(expected).inserted
                    else { return nil }
                } else {
                    guard isOneSlot(key) else { return nil }
                }
            }
        }
        // All eight telephone digits present exactly once.
        return seen.count == 8 ? rows : nil
    }

    public static func matches(_ definition: LayoutDefinition) -> Bool {
        mainRows(in: definition) != nil
    }

    /// A digit key at its canonical position must send the digit code to the
    /// engine (the standard telephone derive), not insert literal text.
    private static func isTelephoneDigit(_ key: LayoutKey, value: String) -> Bool {
        key.action.type == .code && key.action.value == value
    }

    /// The row-0 column-0 slot is the telephone "1"/punctuation key. Exactly two
    /// forms are allowed, both explicit:
    ///  * a key that can produce the `1` input on tap or via a long-press
    ///    alternate (the bundled `1`/标点 key); or
    ///  * a key whose tap inserts a **punctuation literal** (the familiar 标点
    ///    face of the telephone `1` slot).
    /// A letter key, a non-`1` digit, or any other action is rejected.
    private static func isOneSlot(_ key: LayoutKey) -> Bool {
        if emitsOne(key.action) { return true }
        if (key.longPress ?? []).contains(where: { emitsOne($0.action) }) { return true }
        return isPunctuationLiteral(key.action)
    }

    private static func emitsOne(_ action: LayoutAction) -> Bool {
        (action.type == .code || action.type == .literal) && action.value == "1"
    }

    private static func isPunctuationLiteral(_ action: LayoutAction) -> Bool {
        guard action.type == .literal, let value = action.value, value.count == 1,
            let character = value.first
        else { return false }
        return !character.isLetter && !character.isNumber
    }

    private static func isControlRow(_ row: LayoutRow) -> Bool {
        row.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal }
    }
}
