import Foundation

/// Independently authored layout data, also available as editable JSON in Resources/Layouts.
public enum BuiltinLayouts {
    public static let all: [LayoutDefinition] = [qwerty26, merged14, merged18, phone9]

    public static let qwerty26 = LayoutDefinition(
        id: "qwerty26", name: "26 键", input: .init(builtinLayout: .qwerty26),
        rows: alphabetRows() + [controls])

    public static let merged14 = LayoutDefinition(
        id: "merged14", name: "14 键", input: .init(builtinLayout: .merged14),
        rows: mergedRows([
            ["qw", "er", "ty", "ui", "op"], ["as", "df", "gh", "jk", "l"],
            ["zx", "cv", "bn", "m"],
        ]) + [controls],
        note: "两个字母合用一个键，轻点输入。输入方案支持时，向左或向右滑动可只输入左边或右边的字母。",
        // Wide surfaces split by default so both thumbs reach the merged pairs; a saved split,
        // including an explicit off, stays authoritative and is never migrated back on.
        split: LayoutSplitConfiguration())

    /// Every key must be easy to hit, single letters included. Two-unit pairs would leave
    /// the singles as the narrowest caps on the pad (about 38 pt on a 420 pt phone), so pairs
    /// give width back: 1.7 units against 1.3, caps about 1.33 : 1, close to the widely shared
    /// 18-key skin for Baidu's keyboard (stock Chinese keyboards ship no 18-key pad). Pairs
    /// stay wider because one cap carries two letters and the sideways swipe. All upper-row
    /// singles and pairs share one width each, so row 2 (9.0 units) sits centered under row 1
    /// (10.3) half a single key in from each side, the same stagger as 26-key A under Q.
    public static let merged18 = LayoutDefinition(
        id: "merged18", name: "18 键", input: .init(builtinLayout: .merged18),
        rows: mergedRows(
            [
                ["q", "we", "rt", "y", "u", "io", "p"], ["a", "sd", "fg", "h", "jk", "l"],
                ["z", "xc", "v", "bn", "m"],
            ], singleWidth: 1.3, pairWidth: 1.7) + [controls],
        note: "部分键由两个字母合用，轻点输入。输入方案支持时，向左或向右滑动可只输入左边或右边的字母。",
        // Same wide-surface default as 14-key; qwerty26 and phone9 keep their layout default.
        split: LayoutSplitConfiguration())

    public static let phone9 = LayoutDefinition(
        id: "phone9", name: "9 键", input: .init(builtinLayout: .phone9),
        rows: [
            // Corner badge 1 + long-press 1 (like 2-9), so editors show the key that really runs.
            LayoutRow(keys: [
                LayoutKey(
                    label: "，。？", secondaryLabel: t9DigitOne,
                    action: .init(.literal, value: "，"),
                    longPress: [literalOption(t9DigitOne)]),
                phone("ABC", "2"), phone("DEF", "3"),
            ]),
            LayoutRow(keys: [phone("GHI", "4"), phone("JKL", "5"), phone("MNO", "6")]),
            LayoutRow(keys: [phone("PQRS", "7"), phone("TUV", "8"), phone("WXYZ", "9")]),
            LayoutRow(keys: [
                LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
                LayoutKey(label: "空格", width: 4, action: .init(.space)),
                LayoutKey(label: "🌐", action: .init(.globe)),
            ]),
        ],
        auxiliaryAreas: [
            .init(
                position: .trailing, role: .editing,
                keys: [
                    LayoutKey(label: "⌫", action: .init(.backspace)),
                    LayoutKey(label: "分词", action: .init(.code, value: "'")),
                    LayoutKey(label: "⏎", action: .init(.enter)),
                ]),
            .init(position: .leading, role: .disambiguation),
        ], note: phone9Note)

    /// Shown to users (resource inspector, layout manager), so it must match real behavior.
    private static let phone9Note = "2–9 键按所选的输入方案输入。输入中轻点首键可分词；未输入时，左栏前三个符号可直接输入，连续点按首键可轮换其余符号。长按首键输入 1，长按 2–9 输入对应数字。"

    /// Ordered quick symbols: saved order first, missing items filled from the default sequence, full-width
    /// mapped to half-width in ASCII mode, then de-duplicated after mapping (first occurrence decides rank),
    /// with the original first-key address/URL marks appended as a low-frequency tail.
    ///
    /// This is the single ordering source for both the leading rail (first three) and the first-key cycle
    /// (4th item on), so titles, accessibility hints and actual insertion order cannot disagree; the two
    /// partition the list with no overlap or gap.
    ///
    /// The tail keeps `@ / . : _ -` reachable from the first key: they are not in the default
    /// quick-bar set and would otherwise lose their entry point; de-duplication keeps them from repeating
    /// earlier items.
    public static func t9QuickSymbolValues(saved: String, ascii: Bool) -> [String] {
        let userOrdered = (saved + T9QuickSymbolStore.defaultSymbols).map { character -> String in
            let value = String(character)
            guard ascii else { return value }
            return t9ASCIIPunctuation[value] ?? value
        }
        var seen = Set<String>()
        return (userOrdered + t9PunctuationSymbols()).filter { seen.insert($0).inserted }
    }

    /// The first three items typed directly by the leading rail, top to bottom.
    public static func t9QuickRailValues(saved: String, ascii: Bool) -> [String] {
        Array(t9QuickSymbolValues(saved: saved, ascii: ascii).prefix(3))
    }

    /// From the 4th item on: cycled by repeated taps on the first key of the main area.
    public static func t9QuickCycleValues(saved: String, ascii: Bool) -> [String] {
        Array(t9QuickSymbolValues(saved: saved, ascii: ascii).dropFirst(3))
    }

    /// Full-width to half-width punctuation. Used only in ASCII mode; Chinese mode keeps the user's characters.
    ///
    /// Covers every full-width mark the quick bar can hold (including `：；【】`); a missing mapping would put
    /// full-width characters into ASCII fields, and the manager's default sequence is `，。？！、…：；（）【】`.
    private static let t9ASCIIPunctuation: [String: String] = [
        "，": ",", "、": ",", "。": ".", "？": "?", "！": "!", "…": "...",
        "（": "(", "）": ")", "：": ":", "；": ";", "【": "[", "】": "]",
    ]

    /// Whether a builtin 9-key digit key (2-9) should take the layout's declared alternates (long-press types the digit).
    ///
    /// A digit key is `label:"ABC"` (cap) + `.code("2")` (tap sends the digit code) + `longPress:[literal "2"]`.
    /// `AlternateKeyPolicy` follows letter-page semantics and returns empty when `keyLabel` is not a single
    /// letter (neither `"2"` nor `"ABC"` qualifies), which would drop the declared long-press, so these keys
    /// must take the declared path.
    ///
    /// Only digit-code keys qualify: control keys, auxiliary keys, letter keys and DIY definitions do not,
    /// and the fixed letter menu stays closed.
    public static func t9DigitKeyUsesDeclaredAlternates(_ key: LayoutKey) -> Bool {
        guard key.action.type == .code, let value = key.action.value,
            value.count == 1, ("2"..."9").contains(value)
        else { return false }
        // Without declared long-press alternates, fall back to the generic policy.
        return !(key.longPress ?? []).isEmpty
    }

    /// The idle first key cycles the address/URL marks of the system 9-key's
    /// 「@/.」 key. Sentence punctuation lives in the leading rail; repeating it
    /// here (and in a bottom 「。」) made three copies of the same three marks.
    ///
    /// Kept as a fallback: only when the ordered list has nothing from the 4th item on (unreachable with the
    /// current default sequence) does the first key fall back to these address marks instead of becoming a dead key.
    public static func t9PunctuationSymbols() -> [String] {
        ["@", "/", ".", ":", "_", "-"]
    }

    /// Cap and action of the first key, derived from the cycle order: the label is the first three
    /// values and tap inserts the first. Returns nil for an empty array (caller decides the fallback),
    /// never a key that looks usable but is not.
    ///
    /// Long-press matches 2-9: a single `1` (corner badge + long-press input). Cycling applies to taps only.
    public static func t9CycleKey(_ values: [String]) -> LayoutKey? {
        guard let first = values.first, !first.isEmpty else { return nil }
        return LayoutKey(
            label: values.prefix(3).joined(), secondaryLabel: t9DigitOne,
            action: .init(.literal, value: first),
            longPress: [literalOption(t9DigitOne)])
    }

    /// Long-press digit shared by the first key and 2-9.
    public static let t9DigitOne = "1"

    /// Last-resort first key built from the address-mark fallback: label is the first three marks, tap inserts the first.
    public static func t9PunctuationKey() -> LayoutKey {
        let marks = t9PunctuationSymbols()
        return LayoutKey(label: marks.prefix(3).joined(), action: .init(.literal, value: marks[0]))
    }

    /// First key while composing: tap still separates syllables (sends apostrophe); long-press types `1` like 2-9.
    /// It is a plain literal action, so it commits the composition first, then inserts the digit,
    /// and never triggers cycling or separation.
    public static func t9SeparatorKey() -> LayoutKey {
        LayoutKey(
            label: "分词", secondaryLabel: t9DigitOne,
            action: .init(.code, value: "'"),
            longPress: [literalOption(t9DigitOne)])
    }

    /// Idle-only, ordered defaults. The live builtin lets users replace each slot;
    /// composing uses provenance-checked candidate reading choices instead.
    public static func t9LeadingShortcuts(ascii: Bool) -> [LayoutKey] {
        Array(ascii ? "@/-()_" : "@/-()…").map { character in
            let value = String(character)
            return LayoutKey(label: value, action: .init(.literal, value: value))
        }
    }

    // MARK: - 123 / symbol page bilingual pairs

    /// The Chinese/ASCII branch pair for one page slot. It is the same *position* in the two
    /// existing key tables, not a punctuation translation: `、`/`?` and `@`/`&` stay the two
    /// explicitly authored versions of that slot.
    struct BilingualPageMark: Equatable, Sendable {
        let chinese: String
        let ascii: String
    }

    /// Numeric 123 slots paired by position across the two existing canonical tables.
    static func numericPageBilingualRows() -> [[BilingualPageMark]] {
        pairRows(numericPageRows(ascii: false), numericPageRows(ascii: true))
    }

    /// Row-shaped symbol slots paired by position across the two existing canonical tables.
    static func symbolPageBilingualRows() -> [[BilingualPageMark]] {
        pairRows(symbolPageRows(ascii: false), symbolPageRows(ascii: true))
    }

    private static func pairRows(_ chinese: [[String]], _ ascii: [[String]]) -> [[BilingualPageMark]] {
        guard chinese.count == ascii.count else { return [] }
        return zip(chinese, ascii).map { chineseRow, asciiRow in
            zip(chineseRow, asciiRow).map { BilingualPageMark(chinese: $0, ascii: $1) }
        }
    }

    /// The real 123 punctuation rail order: period/question/exclamation first, then the last and
    /// second numeric rows, de-duplicated by the branch's actual strings (first occurrence wins).
    /// The shared runtime rail and a copied digit pad both read this single source.
    public static func phoneNumericRailValues(ascii: Bool) -> [String] {
        let priority = ascii ? [".", "?", "!"] : [".", "？", "！"]
        let rows = numericPageRows(ascii: ascii)
        // The row pages type the comma from the bottom row; the digit pad has none, so the rail
        // keeps it right after the period as before.
        var last = rows.last ?? []
        last.insert(ascii ? "," : "，", at: min(1, last.count))
        let rest = last + (rows.count > 1 ? rows[1] : [])
        var seen = Set<String>()
        return (priority + rest).filter { seen.insert($0).inserted }
    }

    // MARK: - 123 / symbol page rows

    /// The 123 page's marks. The first two rows fill the ten letter columns; the
    /// third row holds seven marks between the 123/symbol switch and Delete, the
    /// same shape as the ABC page's Shift row. The comma lives in the bottom row on
    /// every page, so the third row carries a mark the page otherwise lacks instead.
    public static func numericPageRows(ascii: Bool) -> [[String]] {
        ascii
            ? [
                Array("1234567890").map(String.init),
                Array("-/:;()$&@\"").map(String.init),
                [".", "#", "?", "!", "'", "%", "+"],
            ]
            : [
                Array("1234567890").map(String.init),
                ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"],
                ["。", "%", "、", "？", "！", ".", "…"],
            ]
    }

    /// The row-shaped symbol page: the 123 page's geometry with the two mark rows
    /// swapped for the second page's set and a seven-mark sentence row (the comma
    /// is in the bottom row); no character repeats within the page.
    public static func symbolPageRows(ascii: Bool) -> [[String]] {
        ascii
            ? [
                Array("[]{}#%^*+=").map(String.init),
                ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
                [".", "@", "?", "!", "'", "\"", "/"],
            ]
            : [
                ["【", "】", "{", "}", "#", "%", "^", "*", "+", "="],
                ["_", "——", "\\", "|", "～", "《", "》", "$", "&", "·"],
                ["。", "@", "、", "？", "！", ".", "…"],
            ]
    }

    private static let controls = LayoutRow(keys: [
        LayoutKey(label: "布局", action: .init(.modeSwitch, value: "nextLayout")),
        LayoutKey(label: "🌐", action: .init(.globe)),
        LayoutKey(label: "空格", width: 4, action: .init(.space)),
        LayoutKey(label: "⌫", action: .init(.backspace)),
        LayoutKey(label: "⏎", action: .init(.enter)),
    ])

    private static func literalOption(_ value: String) -> LayoutOption {
        LayoutOption(label: value, action: .init(.literal, value: value))
    }

    private static func phone(_ letters: String, _ digit: String) -> LayoutKey {
        LayoutKey(
            label: letters, secondaryLabel: digit, action: .init(.code, value: digit),
            longPress: [literalOption(digit)])
    }

    private static func mergedRows(
        _ groups: [[String]], singleWidth: Double? = nil, pairWidth: Double? = nil
    ) -> [LayoutRow] {
        groups.map { row in
            LayoutRow(keys: row.map { mergedKey($0, width: $0.count > 1 ? pairWidth : singleWidth) })
        }
    }

    /// Real long-press alternates for merged keys: the main key sends the cluster representative and
    /// long-press types the rest of the cluster (the second letter of qm/er/ty/...); single-letter keys
    /// (l/m) get common punctuation. Same long-press path as the 26-key digits/symbols.
    private static func mergedKey(_ group: String, width: Double?) -> LayoutKey {
        let partnerOptions = group.dropFirst().map { literalOption(String($0)) }
        let punctuationOptions: [LayoutOption]
        if group == "l" {
            punctuationOptions = [literalOption("，")]
        } else if group == "m" {
            punctuationOptions = [literalOption("。")]
        } else {
            punctuationOptions = []
        }
        var options = partnerOptions + punctuationOptions
        if group == "qw" { options += [literalOption("1"), literalOption("!")] }
        return LayoutKey(
            label: group.uppercased(),
            secondaryLabel: group == "qw" ? "1 !" : (group.count > 1 ? "合并键" : nil),
            width: width,
            action: .init(.code, value: String(group.prefix(1))),
            longPress: options.isEmpty ? nil : options)
    }

    private static func alphabetRows() -> [LayoutRow] {
        let digits = Dictionary(uniqueKeysWithValues: zip("qwertyuiop".map(String.init), "1234567890".map(String.init)))
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { letters in
            LayoutRow(
                keys: letters.map { letter in
                    let value = String(letter)
                    return LayoutKey(
                        label: value, secondaryLabel: digits[value],
                        action: .init(.code, value: value),
                        longPress: AlternateKeyPolicy.defaultLetterLiterals(for: value).map(literalOption))
                })
        }
    }
}

// MARK: - Bundled shell identity

public extension BuiltinLayouts {
    /// The bundled layout of one keyboard shape.
    static func preset(for layout: LayoutInput.Builtin) -> LayoutDefinition {
        switch layout {
        case .qwerty26: return qwerty26
        case .merged14: return merged14
        case .merged18: return merged18
        case .phone9: return phone9
        }
    }

    /// Narrow visual-shell identity for the bundled 9-key.
    ///
    /// The native phone shell draws its own control row and side rails, so everything there must still
    /// be the preset declaration; only the three main rows keep their authored long-press menus,
    /// because the shell renders those keys from the definition. A definition that differs anywhere
    /// else falls back to the author-layout renderer instead of being silently covered up.
    static func matchesPhone9VisualShell(_ definition: LayoutDefinition) -> Bool {
        guard matchesPhone9PrimarySemantics(definition),
            definition.rows.count == phone9.rows.count,
            definition.auxiliaryAreas == phone9.auxiliaryAreas,
            // The shell injects a fixed policy control row, so its declaration must be untouched:
            // long-press edits there would be lost if this stayed true.
            definition.rows.last == phone9.rows.last
        else { return false }
        let count = PhoneKeypadMetrics.mainRowCount
        return zip(definition.rows.prefix(count), phone9.rows.prefix(count)).allSatisfy { row, presetRow in
            zip(row.keys, presetRow.keys).allSatisfy { key, presetKey in
                key.label == presetKey.label && key.secondaryLabel == presetKey.secondaryLabel
                    && key.titleMode == presetKey.titleMode
            }
        }
    }

    /// Pure primary-gesture semantics for the known bundled 9-key.
    ///
    /// Only the known input metadata, the three main rows' geometry and their primary actions are
    /// read: label/secondary/title/long-press edits are face metadata, and both the control row and
    /// the side rails are outside the gesture semantics. That keeps first-key cycling, digit
    /// up-flick and declared-alternate behavior alive after metadata edits without ever gating the
    /// injected shell chrome (the shell uses matchesPhone9VisualShell, which rejects control/rail
    /// edits). Unknown schemas and other builtin layouts stay false.
    static func matchesPhone9PrimarySemantics(_ definition: LayoutDefinition) -> Bool {
        definition.input == phone9.input && mainRowsMatch(definition, phone9)
    }

    /// Structural main-shell identity for the bundled 26/14/18-key: the three letter rows still carry
    /// the preset widths and actions, so the standard shell can synthesize Shift/Delete and
    /// equal-width columns. Faces and long-press menus are rendered from the definition, so they
    /// are ignored; the control row is checked separately by `matchesControlRowPolicy(_:as:)`.
    static func matchesMainShell(_ definition: LayoutDefinition, as layout: LayoutInput.Builtin) -> Bool {
        let preset = preset(for: layout)
        let count = PhoneKeypadMetrics.mainRowCount
        guard definition.input == preset.input, definition.auxiliaryAreas == preset.auxiliaryAreas,
            definition.rows.count == count || definition.rows.count == count + 1,
            mainRowsMatch(definition, preset)
        else { return false }
        // The standard renderers only draw the main rows (and, for merged pads, their single
        // synthesized separator/Delete row). A fourth row must still be a non-encoding control row;
        // an encoding row would be silently dropped by the shell, so fall back instead.
        return definition.rows.dropFirst(count).allSatisfy { row in
            row.keys.allSatisfy { $0.action.type != .code && $0.action.type != .literal }
        }
    }

    /// The bundled footer policy draws its own control row, so the declared control row must still
    /// be the preset (every field, including long-press menus); otherwise the author layout bar must
    /// render the edited row instead of hiding it.
    static func matchesControlRowPolicy(_ definition: LayoutDefinition, as layout: LayoutInput.Builtin) -> Bool {
        definition.rows.count == PhoneKeypadMetrics.mainRowCount + 1
            && matchesMainShell(definition, as: layout)
            && definition.rows.last == preset(for: layout).rows.last
    }

    /// The main area is the first three rows by declaration, not by inferring a control row: the
    /// key count, width and primary action of each main key must still be the preset's.
    private static func mainRowsMatch(_ definition: LayoutDefinition, _ preset: LayoutDefinition) -> Bool {
        let count = PhoneKeypadMetrics.mainRowCount
        guard definition.rows.count >= count else { return false }
        return zip(definition.rows.prefix(count), preset.rows.prefix(count)).allSatisfy { row, presetRow in
            row.keys.count == presetRow.keys.count
                && zip(row.keys, presetRow.keys).allSatisfy { $0.width == $1.width && $0.action == $1.action }
        }
    }
}
