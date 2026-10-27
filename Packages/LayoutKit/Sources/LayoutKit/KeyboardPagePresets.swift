import Foundation

public enum KeyboardPagePresets {
    /// English QWERTY letters: each key carries one fixed letter, independent of the symbol branch.
    private static func letterRows(_ values: [[String]]) -> [LayoutRow] {
        values.map { row in
            LayoutRow(
                keys: row.map { value in
                    let options = AlternateKeyPolicy.options(
                        for: .init(
                            keyLabel: value, secondaryLiterals: AlternateKeyPolicy.defaultLetterLiterals(for: value),
                            page: .letters, language: .english, usesASCIIPunctuation: true, visibleKeys: [])
                    )
                    .map { option -> LayoutOption in
                        let text: String
                        switch option.payload {
                        case .code(let value), .literal(let value): text = value
                        }
                        return LayoutOption(label: option.label, action: .init(.literal, value: text))
                    }
                    return LayoutKey(
                        label: value, secondaryLabel: options.first?.label,
                        action: .init(.literal, value: value), longPress: options.isEmpty ? nil : options)
                })
        }
    }

    /// 123 / row-shaped symbol marks pair the two existing key tables by slot. The stored action
    /// keeps the Chinese branch in `value` and the ASCII branch in `asciiValue`; the label and the
    /// long-press list follow the branch the page opens in, so a copy shows a real symbol switch
    /// without translating anything for an ordinary author literal.
    private static func markRows(
        _ marks: [[BuiltinLayouts.BilingualPageMark]], kind: KeyboardPageKind, ascii: Bool
    ) -> [LayoutRow] {
        let policyPage: AlternateKeyPolicy.Page = kind == .numeric ? .numeric : .symbols
        let visible = Set(marks.flatMap { $0.map { ascii ? $0.ascii : $0.chinese } })
        return marks.map { row in
            LayoutRow(
                keys: row.map { mark in
                    let initial = ascii ? mark.ascii : mark.chinese
                    let options = AlternateKeyPolicy.options(
                        for: .init(
                            keyLabel: initial, secondaryLiterals: [], page: policyPage,
                            language: ascii ? .english : .chinese, usesASCIIPunctuation: ascii,
                            visibleKeys: visible)
                    )
                    .map { option -> LayoutOption in
                        let text: String
                        switch option.payload {
                        case .code(let value), .literal(let value): text = value
                        }
                        return LayoutOption(label: option.label, action: .init(.literal, value: text))
                    }
                    return LayoutKey(
                        label: initial, secondaryLabel: options.first?.label,
                        action: .init(
                            .literal, value: mark.chinese,
                            asciiValue: mark.ascii == mark.chinese ? nil : mark.ascii),
                        longPress: options.isEmpty ? nil : options,
                        titleMode: .automatic)
                })
        }
    }

    /// The default 123 page: its marks follow the running language and its shape follows the
    /// running main layout, so pairing a keyboard never freezes the other punctuation width and
    /// never turns a phone keypad's digit pad into a ten-column page.
    public static let numericAutomatic = KeyboardPageDefinition(
        id: "page.numeric.automatic", name: "自动 123", kind: .numeric, rows: [],
        numericPresentation: .automatic)
    /// An authored digit pad: the ten-key phone shape (1–9 grid, 0 in the footer) as editable
    /// data, usable with any main layout. Copying the automatic phone digit pad lands here.
    public static let numericKeypad: KeyboardPageDefinition = {
        var page = numericAutomatic.materialized(numericForm: .phoneDigitPad)
        page.id = "page.numeric.keypad"
        page.name = "数字九宫格"
        return page
    }()
    public static let numericChinese = KeyboardPageDefinition(
        id: "page.numeric.chinese", name: "中文 123", kind: .numeric,
        rows: markRows(BuiltinLayouts.numericPageBilingualRows(), kind: .numeric, ascii: false),
        defaultSymbolMarks: .chinese)
    public static let numericEnglish = KeyboardPageDefinition(
        id: "page.numeric.english", name: "英文 123", kind: .numeric,
        rows: markRows(BuiltinLayouts.numericPageBilingualRows(), kind: .numeric, ascii: true),
        defaultSymbolMarks: .ascii)
    public static let symbolsChinese = KeyboardPageDefinition(
        id: "page.symbols.chinese", name: "中文符号", kind: .symbols,
        rows: markRows(BuiltinLayouts.symbolPageBilingualRows(), kind: .symbols, ascii: false),
        defaultSymbolMarks: .chinese)
    public static let symbolsEnglish = KeyboardPageDefinition(
        id: "page.symbols.english", name: "英文符号", kind: .symbols,
        rows: markRows(BuiltinLayouts.symbolPageBilingualRows(), kind: .symbols, ascii: true),
        defaultSymbolMarks: .ascii)
    public static let englishQwerty = KeyboardPageDefinition(
        id: "page.english.qwerty", name: "英文 QWERTY", kind: .english,
        rows: letterRows([
            Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init),
            Array("zxcvbnm").map(String.init),
        ]))
    public static let symbolsSystem = KeyboardPageDefinition(
        id: "page.symbols.system", name: "默认符号页", kind: .symbols,
        rows: symbolsChinese.rows, symbolPresentation: .automatic)
    public static let symbolsCategorized = KeyboardPageDefinition(
        id: "page.symbols.categorized", name: "分类符号", kind: .symbols,
        rows: [], symbolPresentation: .categorized)

    public static let all = [
        symbolsSystem, symbolsCategorized, symbolsChinese, symbolsEnglish, numericAutomatic, numericKeypad,
        numericChinese, numericEnglish, englishQwerty,
    ]

    public static func preset(id: String) -> KeyboardPageDefinition? {
        all.first { $0.id == id }
    }

    /// A stored page with a preset ID may be a user-modified preset; only an unchanged one is left
    /// out of the saved catalog and of the catalog totals, because loading restores it from code.
    public static func isUnmodifiedPreset(_ page: KeyboardPageDefinition) -> Bool {
        preset(id: page.id) == page
    }

    /// Adds the built-in pages a stored catalog does not carry: saves leave unchanged ones out, and
    /// a release may add one. A stored page with the same ID stays untouched (it may be the user's
    /// edited preset); missing ones append in `all` order.
    public static func mergingInto(_ pages: [KeyboardPageDefinition]) -> [KeyboardPageDefinition] {
        var merged = pages
        var known = Set(pages.map(\.id))
        for preset in all where known.insert(preset.id).inserted { merged.append(preset) }
        return merged
    }
}
