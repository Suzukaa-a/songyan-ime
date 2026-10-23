import Foundation

/// The host text field's keyboard type, reduced to the distinctions this keyboard's
/// presentation policy depends on. UIKit-free so it can be unit-tested on macOS; the
/// app layer maps `UIKeyboardType` onto it (`KeyboardController`).
public enum HostKeyboardTypeKind: String, CaseIterable, Sendable {
    /// `UIKeyboardType.default`, or a type this policy treats as unspecified.
    case unspecified
    case asciiCapable
    case numbersAndPunctuation
    case url
    case emailAddress
    case numberPad
    case decimalPad
    case asciiCapableNumberPad
    case phonePad
    case namePhonePad
    case twitter
    case webSearch
    /// Any keyboard type not otherwise classified.
    case other
}

/// Classifies a host field by whether its content is inherently ASCII/Latin or
/// numeric, so full-width Chinese punctuation (。，) would be wrong.
public enum HostKeyboardTypePolicy {
    public enum PreferredInput: Equatable, Sendable { case unchanged, english, numeric }
    public enum AutoCapitalization: Equatable, Sendable { case none, words, sentences, allCharacters }

    public static func preferredInput(_ kind: HostKeyboardTypeKind) -> PreferredInput {
        switch kind {
        case .numberPad, .decimalPad, .asciiCapableNumberPad, .phonePad, .numbersAndPunctuation:
            return .numeric
        case .asciiCapable, .url, .emailAddress, .namePhonePad:
            return .english
        // Search and social text fields are mostly Chinese (the system Chinese keyboard stays Chinese here too).
        case .twitter, .webSearch, .unspecified, .other:
            return .unchanged
        }
    }

    /// A nil context is unknown, not an empty field. Never infer a sentence
    /// boundary from the keyboard's own commits or a stale document snapshot.
    public static func shouldCapitalize(
        _ capitalization: AutoCapitalization,
        beforeCursor: String?, kind: HostKeyboardTypeKind
    ) -> Bool {
        switch kind {
        case .numberPad, .decimalPad, .asciiCapableNumberPad, .phonePad,
            .numbersAndPunctuation, .url, .emailAddress:
            return false
        default: break
        }
        switch capitalization {
        case .none: return false
        case .allCharacters: return true
        case .words:
            guard let beforeCursor else { return false }
            return beforeCursor.isEmpty || beforeCursor.last?.isWhitespace == true
        case .sentences:
            guard let beforeCursor else { return false }
            if beforeCursor.isEmpty || beforeCursor.last == "\n" { return true }
            guard beforeCursor.last?.isWhitespace == true else { return false }
            let trailingSpaces = beforeCursor.reversed().prefix { $0.isWhitespace && $0 != "\n" }.count
            let preceding = beforeCursor.dropLast(trailingSpaces).last
            return preceding.map { ".!?。！？".contains($0) || $0 == "\n" } ?? true
        }
    }

    /// Automatic disabling requires a host-proven empty document. The proxy's
    /// cursor prefix alone cannot establish this (the caret may be at the start).
    public static func returnEnabled(
        isSearch: Bool, enablesAutomatically: Bool?,
        documentIsEmpty: Bool?
    ) -> Bool {
        if documentIsEmpty == true && (isSearch || enablesAutomatically == true) { return false }
        return true
    }

    public static func requiresASCIIPunctuation(_ kind: HostKeyboardTypeKind) -> Bool {
        switch kind {
        case .asciiCapable, .numbersAndPunctuation, .url, .emailAddress,
            .numberPad, .decimalPad, .asciiCapableNumberPad,
            .phonePad, .namePhonePad:
            return true
        case .twitter, .webSearch, .unspecified, .other:
            return false
        }
    }
}
