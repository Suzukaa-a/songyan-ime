import Foundation

/// A visual overlay never changes a layout's input actions or custom annotations.
/// Hints are kept per letter, so one preset serves the 26-key keys and the merged
/// keys that carry several letters.
public enum ShuangpinHintOverlay {
    /// The letters on each encoding key, or nil when the definition's letter keys do
    /// not split a–z cleanly (phone keys, symbol pads, mislabelled keys).
    public static func letterGroups(for definition: LayoutDefinition?) -> [[Character]]? {
        LetterGroupLayout.groups(in: definition)
    }

    /// One hint per letter on the key, in label order; nil where the preset has no
    /// hint for that letter. Empty for keys that are not letter keys. An imported
    /// key's own secondary label wins over the overlay.
    public static func hints(
        for key: LayoutKey, labels: [String: String],
        preservingSecondaryLabel: Bool
    ) -> [String?] {
        guard let group = LetterGroupLayout.group(of: key) else { return [] }
        if preservingSecondaryLabel, let existing = key.secondaryLabel, !existing.isEmpty {
            return group.map { _ in nil }
        }
        return group.map { letter in
            guard let hint = labels[String(letter)],
                !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return hint
        }
    }
}
