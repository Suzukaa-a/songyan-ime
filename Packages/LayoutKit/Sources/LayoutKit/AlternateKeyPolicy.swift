import Foundation

/// Pure long-press alternate policy for physical keycaps.
///
/// Builtin 26-key and ABC letters share `defaultLetterLiterals(for:)`: top-row
/// digits, sentence punctuation, address marks and paired brackets. Layout-declared
/// DIY literals remain explicit choices; no letter gets automatic accent variants.
/// The policy handles field width and English shift, and emits either a verbatim
/// literal or a valid schema-backed code. Merged 14-key partners remain codes only
/// when the live speller alphabet includes them; unknown capabilities fail closed.
/// Numeric/symbol pages use curated per-key lists for each punctuation width.
public enum AlternateKeyPolicy {

    /// The engine mode the long press will dispatch into.
    public enum Language: Sendable, Equatable {
        /// Composition mode: only spelling codes may reach the engine.
        case chinese
        /// Direct-text mode: literals insert verbatim.
        case english
    }

    /// The keyboard page the physical key belongs to.
    public enum Page: Sendable, Equatable {
        case letters, numeric, symbols
    }

    /// Explicit dispatch semantics. `code` is exactly one printable ASCII key
    /// handed to the engine as a spelling code; `literal` is text inserted
    /// verbatim. Nothing else is representable.
    public enum Payload: Sendable, Equatable {
        case code(String)
        case literal(String)
    }

    /// One ordered long-press option.
    public struct Option: Sendable, Equatable {
        /// The label drawn on the option cell.
        public let label: String
        public let payload: Payload

        public init(label: String, payload: Payload) {
            self.label = label
            self.payload = payload
        }
    }

    /// Every input the policy reads, as plain values. `schemaAlphabet` is the
    /// live `speller/alphabet`; empty means “unknown”, which fails closed (no
    /// partner is offered).
    public struct Request: Sendable, Equatable {
        /// The physical key's label, e.g. `"a"`, `"1"`, `"。"`, `"ABC"`.
        public let keyLabel: String
        /// For a 14-key merged key, the full merged group (e.g. `"qw"`). The
        /// first character is the representative the main key sends; the rest are
        /// the partners.
        public let mergedGroup: String?
        /// The key's declared, ordered secondary literals, supplied by the layout
        /// data (e.g. the 26-key letter's digit and 123-page symbol). The policy
        /// never invents pinyin-style secondaries; it emits exactly what it is
        /// given, in order, and the **first emitted option is the key-face hint**.
        public let secondaryLiterals: [String]
        public let page: Page
        public let language: Language
        /// Shift is active, so letter variants render (and insert) uppercase.
        public let isUppercase: Bool
        /// The host field / language requires ASCII punctuation. In an ASCII field
        /// (`URL`/`email`/`number`) full-width/CJK punctuation is **filtered out**,
        /// not merely ordered.
        public let usesASCIIPunctuation: Bool
        /// The active schema's `speller/alphabet` (any case). Empty = unknown.
        public let schemaAlphabet: String
        /// Labels already shown as keys of the same page. A symbol page never
        /// offers them, so a corner hint never repeats a visible key.
        public let visibleKeys: Set<String>

        public init(
            keyLabel: String,
            mergedGroup: String? = nil,
            secondaryLiterals: [String] = [],
            page: Page,
            language: Language,
            isUppercase: Bool = false,
            usesASCIIPunctuation: Bool = false,
            schemaAlphabet: String = "",
            visibleKeys: Set<String> = []
        ) {
            self.keyLabel = keyLabel
            self.mergedGroup = mergedGroup
            self.secondaryLiterals = secondaryLiterals
            self.page = page
            self.language = language
            self.isUppercase = isUppercase
            self.usesASCIIPunctuation = usesASCIIPunctuation
            self.schemaAlphabet = schemaAlphabet
            self.visibleKeys = visibleKeys
        }
    }

    /// The one entry point.
    public static func options(for request: Request) -> [Option] {
        switch request.page {
        case .letters:
            return letterOptions(request)
        case .numeric, .symbols:
            return symbolOptions(request)
        }
    }

    /// `code` payloads must be exactly one printable ASCII character, matching
    /// `LayoutAction.validate()` for `.code`. Exposed so callers and tests can
    /// assert the contract on any produced option.
    public static func isValidCode(_ value: String) -> Bool {
        guard value.utf8.count == 1, let byte = value.utf8.first else { return false }
        return (33...126).contains(byte)
    }

    /// True when the option obeys the payload contract (a valid code, or a
    /// nonempty literal).
    public static func isValid(_ option: Option) -> Bool {
        switch option.payload {
        case .code(let value): return isValidCode(value)
        case .literal(let value): return !value.isEmpty
        }
    }

    // MARK: Letters

    /// Ordered builtin defaults only. Callers must pass DIY declarations instead
    /// of using this as a fallback for custom keys with deliberately empty options.
    public static func defaultLetterLiterals(for letter: String) -> [String] {
        defaultLetters[letter.lowercased()] ?? []
    }

    /// Each full-width mark is paired with the ASCII key a desktop Chinese IME types it
    /// from, so English mode and ASCII fields (which drop the full-width form) still show a
    /// distinct mark: 、 comes from `\`, as on Sogou and Microsoft Pinyin. No two letters
    /// may offer the same symbol in either mode, or the ABC page shows it twice.
    private static let defaultLetters: [String: [String]] = [
        "q": ["1"], "w": ["2"], "e": ["3"], "r": ["4"], "t": ["5"],
        "y": ["6"], "u": ["7"], "i": ["8"], "o": ["9"], "p": ["0"],
        "a": ["，", ","], "s": ["。", ".", "…"], "d": ["？", "?"], "f": ["！", "!"],
        "g": ["、", "\\"], "h": ["：", ":"], "j": ["；", ";"],
        "k": ["（", "("], "l": ["）", ")"],
        "z": ["@"], "x": ["-", "_"], "c": ["“", "”", "\""], "v": ["‘", "’", "'"],
        "b": ["【", "[", "《", "<"], "n": ["】", "]", "》", ">"], "m": ["/"],
    ]

    private static func letterOptions(_ request: Request) -> [Option] {
        guard request.keyLabel.count == 1,
            let base = request.keyLabel.first, base.isLetter
        else {
            // A letter group (T9 “ABC”), a digit key or a symbol key on the letter
            // page has no letter alternates.
            return []
        }
        let secondary = literalOptions(request.secondaryLiterals, request: request)
        switch request.language {
        case .chinese:
            return secondary + mergedPartnerOptions(request)
        case .english:
            return secondary
        }
    }

    /// Keep explicit layout choices, applying English shift and the field-width
    /// policy. Accents remain possible through DIY, never automatically appended.
    private static func literalOptions(_ literals: [String], request: Request) -> [Option] {
        let usable = deduplicated(
            literals.filter { !$0.isEmpty && $0 != request.keyLabel }
                .map { cased($0, uppercase: request.language == .english && request.isUppercase) })
        return orderedByFieldWidth(usable, asciiFirst: request.usesASCIIPunctuation)
            .map { Option(label: $0, payload: .literal($0)) }
    }

    /// An accent/diacritic letter: alphabetic but not ASCII.
    static func containsNonASCIILetter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.isAlphabetic && !$0.isASCII }
    }

    /// 14-key partners: a code iff the schema alphabet contains the letter, else
    /// hidden. Never a literal.
    private static func mergedPartnerOptions(_ request: Request) -> [Option] {
        guard let group = request.mergedGroup, group.count > 1 else { return [] }
        let alphabet = alphabetSet(request.schemaAlphabet)
        guard !alphabet.isEmpty else { return [] }
        return group.dropFirst().compactMap { character in
            let lower = Character(String(character).lowercased())
            guard alphabet.contains(lower) else { return nil }
            let code = String(lower)
            return Option(
                label: request.isUppercase ? code.uppercased() : code,
                payload: .code(code))
        }
    }

    /// The codes a sideways swipe on a two-letter key sends, left then right; nil
    /// unless the schema accepts both exact letters (same gate as the partners above).
    public static func letterSwipeCodes(group: [Character], schemaAlphabet: String) -> [String]? {
        guard group.count == 2 else { return nil }
        let alphabet = alphabetSet(schemaAlphabet)
        let codes = group.map { String($0).lowercased() }
        guard codes.allSatisfy({ $0.count == 1 && alphabet.contains(Character($0)) }) else { return nil }
        return codes
    }

    // MARK: Numeric / symbol pages

    /// The 123 page draws each key's first option as its corner hint, so the
    /// lists are curated per key and per punctuation width rather than derived
    /// from shared families: a list stays within its key's meaning and never
    /// offers a mark that is already a key of the same 123 page. An ASCII field
    /// still filters whatever a list holds.
    private static func symbolOptions(_ request: Request) -> [Option] {
        let label = request.keyLabel
        let table = request.usesASCIIPunctuation ? asciiSymbolAlternates : chineseSymbolAlternates
        var variants = deduplicated(
            (table[label] ?? sharedSymbolAlternates[label] ?? []).filter {
                $0 != label && !request.visibleKeys.contains($0)
            })
        if request.usesASCIIPunctuation {
            variants = orderedByFieldWidth(variants, asciiFirst: true)
        }
        return variants.map { Option(label: $0, payload: .literal($0)) }
    }

    /// Full-width punctuation: digits offer the Chinese numerals the system
    /// pinyin keyboard does (一, the financial 壹, ①); marks offer their
    /// half-width form first, then related Chinese forms.
    private static let chineseSymbolAlternates: [String: [String]] = [
        "1": ["一", "壹", "①"], "2": ["二", "贰", "②"], "3": ["三", "叁", "③"],
        "4": ["四", "肆", "④"], "5": ["五", "伍", "⑤"], "6": ["六", "陆", "⑥"],
        "7": ["七", "柒", "⑦"], "8": ["八", "捌", "⑧"], "9": ["九", "玖", "⑨"],
        "0": ["零", "〇", "°"],
        "-": ["～", "—", "_"],
        "/": ["\\", "|", "÷"],
        "：": [":"], "；": [";"],
        "（": ["(", "【", "[", "{"], "）": [")", "】", "]", "}"],
        "¥": ["$", "€", "£", "￥"],
        "“": ["「", "『", "\"", "‘"], "”": ["」", "』", "\"", "’"],
        "，": [","], "、": ["·"], "？": ["?"], "！": ["!"],
    ]

    /// Half-width punctuation (English mode and ASCII fields): only what an
    /// ASCII field accepts, so the hint shown is always typeable.
    private static let asciiSymbolAlternates: [String: [String]] = [
        "0": ["°"],
        "-": ["_"],
        "/": ["\\", "|"],
        "(": ["[", "{", "<"], ")": ["]", "}", ">"],
        "$": ["¥", "€", "£"],
        "'": ["`"],
    ]

    /// Operators and the other forms a symbol key outside the 123 rows may
    /// carry, the same in either width.
    private static let sharedSymbolAlternates: [String: [String]] = [
        "*": ["×", "°"], "×": ["*", "°"], "÷": ["/"],
        "+": ["±"], "=": ["≈", "≠"], "#": ["№"], "%": ["‰"],
        "<": ["≤", "‹", "〈"], ">": ["≥", "›", "〉"],
        "·": ["•"], "•": ["·"],
        "¥": ["$", "€", "£", "￥"], "￥": ["¥", "$", "€", "£"], "$": ["€", "£", "¥"],
        "€": ["$", "¥", "£"], "£": ["$", "¥", "€"],
        "「": ["『"], "」": ["』"], "《": ["〈"], "》": ["〉"],
        "【": ["〖", "["], "】": ["〗", "]"],
    ]

    // MARK: Full/half-width field policy

    /// A value is “ASCII width” when every scalar is ASCII. CJK/fullwidth forms
    /// are the alternative half of the policy.
    public static func isASCIIWidth(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { $0.isASCII }
    }

    /// Full-width or CJK punctuation: CJK Symbols and Punctuation (U+3000–303F),
    /// CJK Compatibility Forms (U+FE30–FE4F) and Halfwidth/Fullwidth Forms
    /// (U+FF00–FFEF). This is the CJK-priority grouping predicate for a CJK field
    /// and the first thing an ASCII field drops, but on its own it is **not** the
    /// ASCII contract: `…`/`—`/`“`/`·`/`〈` live outside those blocks and must also
    /// be filtered (see `isAllowedInASCIIField`).
    public static func isFullwidthOrCJKPunctuation(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0xFE30...0xFE4F, 0xFF00...0xFFEF: return true
            default: return false
            }
        }
    }

    /// The non-ASCII currency/math symbols that are explicitly allowed in an ASCII
    /// field, one by one, because they are not width variants of an ASCII key:
    ///
    ///   - `€` U+20AC euro, `£` U+00A3 pound, `¥` U+00A5 yen (currency);
    ///   - `±` U+00B1, `÷` U+00F7, `×` U+00D7, `≈` U+2248, `≠` U+2260 (math);
    ///   - `№` U+2116 numero, `‰` U+2030 per-mille, `°` U+00B0 degree (units).
    ///
    /// Nothing else is added: every other non-ASCII symbol/punctuation (`© ® ™ § ¦
    /// ‰`-adjacent forms like `′ 〃`, `• ·` bullets, `— – …` dashes/ellipsis,
    /// `“ ” ‘ ’` smart quotes, `¿ ¡` inverted marks, `〈 〉 ‹ ›` brackets, and all
    /// full-width/CJK forms) is filtered from an ASCII field.
    public static let asciiFieldAllowedSymbols: Set<Unicode.Scalar> =
        Set("€£¥±÷×≈≠№‰°".unicodeScalars)

    /// Whether a value may be offered in an ASCII-constrained field
    /// (`URL`/`email`/`number`): pure ASCII, or a letter variant (accented Latin
    /// letters — the English letter branch keeps its accents), or made of nothing
    /// but the explicitly allowed currency/math symbols. Every other non-ASCII
    /// punctuation/symbol is rejected.
    public static func isAllowedInASCIIField(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if isASCIIWidth(value) { return true }
        if containsNonASCIILetter(value) { return true }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII || asciiFieldAllowedSymbols.contains(scalar)
        }
    }

    /// The field policy.
    ///
    ///  - ASCII field (`URL`/`email`/`number`): **filter**, not reorder. Only ASCII
    ///    characters, letter variants (accents) and the allowed currency/math
    ///    symbols survive; every other Unicode punctuation/symbol is removed, so a
    ///    URL field can never receive `。`, `…`, `—`, `“`, `¿`, `·`, `〈`, `￥`.
    ///  - CJK field: the full-width/CJK forms come first and the half-width ones
    ///    are kept as secondaries.
    ///
    /// Order is otherwise stable.
    public static func orderedByFieldWidth(_ values: [String], asciiFirst: Bool) -> [String] {
        guard !asciiFirst else {
            return values.filter(isAllowedInASCIIField)
        }
        let cjk = values.filter(isFullwidthOrCJKPunctuation)
        let rest = values.filter { !isFullwidthOrCJKPunctuation($0) }
        return cjk + rest
    }

    // MARK: Shared helpers

    private static func cased(_ value: String, uppercase: Bool) -> String {
        guard uppercase else { return value }
        let upper = value.uppercased()
        // A few forms expand to multiple characters (ß → SS); a keycap label must
        // stay one character, so those keep their base form.
        return upper.count == 1 ? upper : value
    }

    private static func alphabetSet(_ alphabet: String) -> Set<Character> {
        Set(alphabet.lowercased())
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
