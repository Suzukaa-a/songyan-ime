import Foundation

/// Letter keys read from their labels: each encoding key covers the letters on its cap
/// (`QW` covers q and w) and sends the first of them. This is the one place that decides
/// whether a definition's letter keys split a–z cleanly, for compact-spelling
/// eligibility and for per-letter hints alike.
public enum LetterGroupLayout {
    /// One group per encoding key, in row order; nil unless the main rows are all
    /// letter keys whose labels cover a–z exactly once and each key sends its
    /// group's first letter. A 26-key layout yields 26 single-letter groups.
    public static func groups(in definition: LayoutDefinition?) -> [[Character]]? {
        guard let definition else { return nil }
        let keys = CompactSpellingLayout.mainRows(in: definition).flatMap(\.keys)
        guard !keys.isEmpty else { return nil }
        var seen = Set<Character>()
        var result: [[Character]] = []
        for key in keys {
            guard let group = group(of: key), seen.isDisjoint(with: group) else { return nil }
            seen.formUnion(group)
            result.append(group)
        }
        return seen == alphabet ? result : nil
    }

    /// The letters on one key, first letter first; nil when the key does not send the
    /// first letter of its own label.
    public static func group(of key: LayoutKey) -> [Character]? {
        guard key.action.type == .code, let value = key.action.value, value.count == 1,
            let sent = value.lowercased().first, alphabet.contains(sent)
        else { return nil }
        var letters: [Character] = []
        for character in key.label.lowercased() where alphabet.contains(character) {
            if !letters.contains(character) { letters.append(character) }
        }
        guard letters.first == sent else { return nil }
        return letters
    }

    static let alphabet = Set("abcdefghijklmnopqrstuvwxyz")
}
