import Foundation

// MARK: - Syllable to per-scheme code projection (demo engine; mirrors the built-in speller/algebra key mapping)
//
// DemoEngine needs to reproduce the layout input code locally. This implements the same
// mapping as the built-in schemes in Resources/BuiltinPackages/Basic and their generated layouts:
//   full pinyin = canonical pinyin itself; Xiaohe = initial key + final key; a compact layout
//   folds that code through its `CompactFold` (14 / 18 letter groups, 9-key keypad digits).
// These are public key-layout facts (Xiaohe layout, phone keypad), written from the
// built-in algebra rather than copied from upstream files. The demo vocabulary
// contains only original words from the songyan_basic dictionary; the reference is
// Tests/EngineFixtures/Builtin/encodings.tsv (checked in unit tests).
//
// In the real runtime, how a layout code produces candidates is decided by librime's
// prism; the front end only converts physical keys to logical codes for the engine.
// This file serves only the demo engine and tests.

public enum LayoutCodeProjector {
    /// The input code a built-in scheme expects on a layout: the scheme's own code, folded
    /// by the layout. Keyed by engine schema, because both schemes share every layout.
    public struct Encoding: Equatable, Sendable {
        public enum Base: Sendable { case fullPinyin, xiaohe }
        public let base: Base
        /// nil on 26 keys.
        public let fold: CompactFold?

        public init(base: Base, fold: CompactFold?) {
            self.base = base
            self.fold = fold
        }

        public static let fullPinyin = Encoding(base: .fullPinyin, fold: nil)
        public static let xiaohe26 = Encoding(base: .xiaohe, fold: nil)
        public static let xiaohe14 = Encoding(base: .xiaohe, fold: .merged14)
        public static let phoneDigits = Encoding(base: .fullPinyin, fold: .phone9)

        /// Any built-in scheme or bundled companion; nil for other schemas.
        public init?(schemaID: String) {
            let schemes = BuiltinTemplateSchemas.self
            guard let layout = schemes.layout(forSchemaID: schemaID) else { return nil }
            let source = schemes.adapters.first { $0.schemaID == schemaID }?.sourceSchemaID ?? schemaID
            self.init(base: source == schemes.flypy ? .xiaohe : .fullPinyin, fold: layout.compactFold)
        }

        /// The keys this encoding accepts into a composition.
        public func accepts(_ key: Character) -> Bool {
            fold.map { $0.keysSent.contains(key) } ?? ("a"..."z").contains(key)
        }
    }

    /// Projects canonical pinyin syllables to the full input code (continuous, no separator).
    /// For example fullPinyin("你好") = "nihao", xiaohe26("你好") = "nihc",
    /// xiaohe14("你好") = "bugc", phoneDigits("你好") = "64426".
    public static func composeCode(syllables: [String], for encoding: Encoding) -> String {
        let codes = syllables.compactMap { codeForSyllable($0, encoding: encoding) }
        return codes.joined()
    }

    /// Code of a single syllable under an encoding.
    public static func codeForSyllable(_ syllable: String, encoding: Encoding) -> String? {
        let code: String
        switch encoding.base {
        case .fullPinyin: code = syllable.lowercased()
        case .xiaohe:
            guard let flypy = flypyCode(of: syllable) else { return nil }
            code = flypy
        }
        guard let fold = encoding.fold?.map else { return code }
        return String(code.map { fold[$0] ?? $0 })
    }

    // MARK: Xiaohe 26-key (songyan_flypy algebra)

    private static let initialZh = "zh"
    private static let initialCh = "ch"
    private static let initialSh = "sh"

    /// Final key positions (Xiaohe): final -> key.
    private static let finalKeys: [String: Character] = [
        "iu": "q", "ei": "w", "uan": "r", "ue": "t", "ve": "t", "un": "y",
        "uo": "o", "ie": "p", "iong": "s", "ong": "s", "ing": "k", "uai": "k",
        "ai": "d", "en": "f", "eng": "g", "iang": "l", "uang": "l", "ang": "h",
        "ian": "m", "an": "j", "ou": "z", "ia": "x", "ua": "x", "iao": "n",
        "ao": "c", "ui": "v", "in": "b",
    ]

    private static let singleLetterFinals: Set<Character> = ["a", "e", "i", "o", "u", "v"]
    private static let singleConsonants: Set<Character> =
        ["b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]

    /// Zero-initial syllables (ending in a/o/e/ng; 2 letters kept, 3-letter ang/eng/ong special-cased).
    private static let zeroInitialCodes: [String: String] = [
        "a": "aa", "o": "oo", "e": "ee",
        "ai": "ai", "ei": "ei", "ao": "ao", "ou": "ou",
        "an": "an", "en": "en", "er": "er",
        "ang": "ah", "eng": "eg", "ong": "os",
    ]

    static func flypyCode(of syllable: String) -> String? {
        let s = String(syllable).lowercased()
        if s.isEmpty { return nil }
        if let zero = zeroInitialCodes[s] { return zero }

        var initial: String
        var rest: Substring
        if s.hasPrefix(initialZh) {
            initial = initialZh
            rest = s.dropFirst(2)
        } else if s.hasPrefix(initialCh) {
            initial = initialCh
            rest = s.dropFirst(2)
        } else if s.hasPrefix(initialSh) {
            initial = initialSh
            rest = s.dropFirst(2)
        } else if let first = s.first, singleConsonants.contains(first) {
            initial = String(first)
            rest = s.dropFirst()
        } else {
            // Uncovered zero-initial: conservative code (first letter as is, rest by single-letter rules).
            initial = ""
            rest = s[...]
        }

        let initialCode: String
        switch initial {
        case initialZh: initialCode = "v"
        case initialCh: initialCode = "i"
        case initialSh: initialCode = "u"
        default: initialCode = initial
        }

        let final = String(rest)
        let finalCode: String
        if ["j", "q", "x", "y"].contains(initial) && final == "u" {
            // ju/qu/xu/yu -> jv/qv/xv/yv (the dictionary writes ju...; the engine derives them)
            finalCode = "v"
        } else if let key = finalKeys[final] {
            finalCode = String(key)
        } else if final.count == 1, let c = final.first, singleLetterFinals.contains(c) {
            finalCode = final
        } else {
            // Outside the demo vocabulary: return empty; callers skip the word, never generate a fake code.
            return nil
        }
        return initialCode + finalCode
    }
}
