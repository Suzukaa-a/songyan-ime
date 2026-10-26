import Foundation

/// Indexed by UserKeyboard.id (input method × layout capability) in LayoutRegistry.
public struct KeyboardComposition: Codable, Equatable, Sendable {
    public var mainLayoutID: String
    public var symbolPageID: String
    public var numericPageID: String
    public var englishPageID: String

    /// The defaults keep today's behaviour: the symbol page follows the configured presentation
    /// and the 123 page follows the live keyboard (marks and keypad shape), so saving a pairing
    /// without touching a page never changes what those pages show.
    public init(
        mainLayoutID: String, symbolPageID: String = KeyboardPagePresets.symbolsSystem.id,
        numericPageID: String = KeyboardPagePresets.numericAutomatic.id,
        englishPageID: String = KeyboardPagePresets.englishQwerty.id
    ) {
        self.mainLayoutID = mainLayoutID
        self.symbolPageID = symbolPageID
        self.numericPageID = numericPageID
        self.englishPageID = englishPageID
    }

    public func pageID(for kind: KeyboardPageKind) -> String {
        switch kind {
        case .symbols: return symbolPageID
        case .numeric: return numericPageID
        case .english: return englishPageID
        }
    }

    public mutating func setPageID(_ id: String, for kind: KeyboardPageKind) {
        switch kind {
        case .symbols: symbolPageID = id
        case .numeric: numericPageID = id
        case .english: englishPageID = id
        }
    }
}
