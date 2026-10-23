import Foundation

/// Compact-spelling layouts: physical key structures that need combination disambiguation.
///
/// Eligibility cannot look only at `KeyboardLayoutKind` (`.phone9` / `.merged14`), which describes input
/// method/encoding rather than physical keys: a definition with 26-key `rows` but `input.builtinLayout`
/// mislabeled `merged14` (`LayoutDefinition.validate` checks action validity, not row count vs builtin)
/// would get the disambiguation UI and send real `ambiguitySpellings()` queries to the engine.
///
/// This policy instead proves the shape from the definition's own rows/keys and rejects everything
/// except two provable shapes (fail-closed):
///
///  * standard phone 9-key: delegated to `PhoneKeypadStructure` (rows, digit positions and the `1` slot
///    are provable; calculator-style digit grids and symbol 3x3 are rejected there);
///  * merged letter keys (14-key, 18-key, ...): the key labels split a–z into groups, each key sends
///    its group's first letter, and at least one key carries more than one letter
///    (`LetterGroupLayout`).
///
/// A 26-key layout never matches: every group has one letter.
public enum CompactSpellingLayout {
    /// Whether the physical definition supports combination disambiguation. A `nil` definition does not (fail-closed).
    public static func matches(_ definition: LayoutDefinition?) -> Bool {
        guard let definition else { return false }
        if PhoneKeypadStructure.matches(definition) { return true }
        return isMergedLetterLayout(definition)
    }

    /// Main rows: drops the definition's own non-encoding control row, if any. Same criterion as
    /// `KeyboardPanelView.definitionMainRows` (`PhoneKeypadRailPolicy`).
    static func mainRows(in definition: LayoutDefinition) -> [LayoutRow] {
        guard PhoneKeypadRailPolicy.controlRowKeys(in: definition) != nil else {
            return definition.rows
        }
        return Array(definition.rows.dropLast())
    }

    /// Merged letter keys: a clean a–z partition by label with fewer keys than letters.
    static func isMergedLetterLayout(_ definition: LayoutDefinition) -> Bool {
        guard let groups = LetterGroupLayout.groups(in: definition) else { return false }
        return groups.count < LetterGroupLayout.alphabet.count
    }
}

public extension CompactSpellingLayout {
    /// Letter → key code sent by a compact encoding key, derived from the key's own
    /// label (`ABC` → `2`, `QW` → `q`). Used only to bound read-only reading choices
    /// by what was typed. Ambiguous or non-compact definitions return an empty map.
    static func readingKeyMap(for definition: LayoutDefinition?) -> [Character: Character] {
        guard let definition, matches(definition) else { return [:] }
        var map: [Character: Character] = [:]
        for key in mainRows(in: definition).flatMap(\.keys) {
            guard key.action.type == .code, let value = key.action.value, value.count == 1,
                let code = value.lowercased().first
            else { continue }
            let letters = (key.label + value).lowercased().filter { $0.isASCII && $0.isLetter }
            for letter in Set(letters) {
                if let existing = map[letter], existing != code { return [:] }
                map[letter] = code
            }
        }
        return map
    }
}
