import Foundation

public enum KeyboardPageKind: String, Codable, CaseIterable, Sendable {
    case numeric, symbols, english

    public var title: String {
        switch self {
        case .numeric: return "123 页"
        case .symbols: return "符号页"
        case .english: return "ABC 页"
        }
    }
}

/// Built-in symbol browsers keep their existing categories and recent items.
public enum KeyboardSymbolPresentation: String, Codable, Sendable {
    case automatic, rows, categorized
}

/// A 123 page can follow the live keyboard instead of freezing one set of marks.
public enum KeyboardNumericPresentation: String, Codable, Sendable {
    /// The running language picks the marks (Chinese or ASCII) and the running main layout
    /// picks the shape: a phone keypad shows its digit pad, every other layout the ten-column
    /// row page. The page therefore carries no rows of its own.
    case automatic
    /// An authored digit pad: its own 1-9 grid and rails, editable like any other page and
    /// usable with any main layout.
    case keypad
}

/// Punctuation width of the automatic 123 page, taken from the live input state. It is Codable so
/// an authored page can pin the symbol branch it opens in (see `defaultSymbolMarks`).
public enum KeyboardNumericMarks: String, Codable, CaseIterable, Sendable {
    case chinese
    case ascii
}

/// The built-in 123 shape an automatic page resolves to.
public enum KeyboardNumericForm: Equatable, Sendable {
    /// The ten-column row page every non-keypad layout shows.
    case rows
    /// The running phone keypad's digit pad: 1–9 in the 3×3 grid, 0 in the bottom row.
    case phoneDigitPad
}

/// What the key area draws for the page a keyboard pairing selects.
public enum KeyboardPageResolution: Equatable, Sendable {
    /// The page carries its own rows or categories.
    case authored(KeyboardPageDefinition)
    /// The 123 page follows the live keyboard; the built-in page area draws the form with those marks.
    case automaticNumeric(form: KeyboardNumericForm, marks: KeyboardNumericMarks)
    /// The symbol page follows the configured presentation; the built-in symbol page draws it.
    case automaticSymbolPage
    /// The pairing has no page for this kind, so the built-in page area keeps drawing it.
    case builtIn

    /// The page object to render, or nil when the built-in page area owns this page.
    public var page: KeyboardPageDefinition? {
        if case .authored(let page) = self { return page }
        return nil
    }
}

/// The live facts an automatic page resolves against. Both come from the running keyboard, never
/// from the page: punctuation width and the main layout's keypad shape.
public struct KeyboardPageResolutionInput: Equatable, Sendable {
    public var usesASCIIPunctuation: Bool
    public var mainLayoutIsPhoneKeypad: Bool

    public init(usesASCIIPunctuation: Bool, mainLayoutIsPhoneKeypad: Bool) {
        self.usesASCIIPunctuation = usesASCIIPunctuation
        self.mainLayoutIsPhoneKeypad = mainLayoutIsPhoneKeypad
    }
}

/// Resolves the page a pairing selects into what the key area (or a preview) draws.
public enum KeyboardPageResolver {
    /// The single resolution rule. `page` is nil when the pairing has no page for this kind; such a
    /// pairing keeps the built-in page.
    public static func resolve(
        page: KeyboardPageDefinition?, kind: KeyboardPageKind, input: KeyboardPageResolutionInput
    ) -> KeyboardPageResolution {
        guard let page, page.kind == kind else { return builtIn(kind: kind, input: input) }
        if page.numericPresentation == .automatic {
            return .automaticNumeric(form: numericForm(input), marks: marks(input))
        }
        if page.symbolPresentation == .automatic {
            return .automaticSymbolPage
        }
        return .authored(page)
    }

    /// The built-in 123 form for the running main layout.
    public static func numericForm(_ input: KeyboardPageResolutionInput) -> KeyboardNumericForm {
        input.mainLayoutIsPhoneKeypad ? .phoneDigitPad : .rows
    }

    /// The built-in 123 marks for the running input state.
    public static func marks(_ input: KeyboardPageResolutionInput) -> KeyboardNumericMarks {
        input.usesASCIIPunctuation ? .ascii : .chinese
    }

    /// Whether the 123 page a letter page opens has its own way to the symbol page. The built-in
    /// row page (and an authored row page drawn with native controls) opens the third row with the
    /// switch; a phone digit pad has none; other authored pages only if they carry a symbol switch.
    /// `page` is the pairing's 123 page as the panel would draw it, nil for the built-in one.
    public static func numericPageReachesSymbols(
        page: KeyboardPageDefinition?, mainLayoutIsPhoneKeypad: Bool
    ) -> Bool {
        guard let page, page.kind == .numeric, page.numericPresentation != .automatic else {
            return !mainLayoutIsPhoneKeypad
        }
        guard page.chrome != nil else { return true }
        return page.containsKey { $0.action.pageSwitchTarget == .symbols }
    }

    private static func builtIn(kind: KeyboardPageKind, input: KeyboardPageResolutionInput) -> KeyboardPageResolution {
        switch kind {
        case .numeric: return .automaticNumeric(form: numericForm(input), marks: marks(input))
        case .symbols: return .automaticSymbolPage
        case .english: return .builtIn
        }
    }
}

/// A reusable page independent of the input method and main layout.
public struct KeyboardPageDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: KeyboardPageKind
    public var rows: [LayoutRow]
    public var split: LayoutSplitConfiguration?
    public var symbolPresentation: KeyboardSymbolPresentation?
    /// Set on the 123 page that follows the live keyboard (see `KeyboardNumericPresentation`).
    public var numericPresentation: KeyboardNumericPresentation?
    public var categories: [KeyboardPageCategory]?
    /// Authored function area. Nil draws the native controls around the rows (built-in pages);
    /// non-nil is drawn as data and nothing is ever synthesized for it.
    public var chrome: KeyboardPageChrome?
    /// The symbol branch this page opens in when the panel has no explicit override. Nil follows
    /// the live keyboard; authored pages keep nil unless the copy/materialization chose a branch,
    /// so a page is never guessed into one.
    public var defaultSymbolMarks: KeyboardNumericMarks?

    public var usesSymbolBrowser: Bool { symbolPresentation == .automatic || symbolPresentation == .categorized }

    /// The runtime draws this page from the live keyboard instead of these rows. An authored
    /// keypad is fully defined by its own data, so it is not a runtime-resolved page.
    public var resolvesAtRuntime: Bool {
        numericPresentation == .automatic || symbolPresentation == .automatic
    }

    /// An authored digit pad page.
    public var isKeypad: Bool { numericPresentation == .keypad }

    public init(
        id: String, name: String, kind: KeyboardPageKind, rows: [LayoutRow], split: LayoutSplitConfiguration? = nil,
        symbolPresentation: KeyboardSymbolPresentation? = nil,
        numericPresentation: KeyboardNumericPresentation? = nil,
        categories: [KeyboardPageCategory]? = nil,
        chrome: KeyboardPageChrome? = nil,
        defaultSymbolMarks: KeyboardNumericMarks? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.rows = rows
        self.split = split
        self.symbolPresentation = symbolPresentation
        self.numericPresentation = numericPresentation
        self.categories = categories
        self.chrome = chrome
        self.defaultSymbolMarks = defaultSymbolMarks
    }

    /// Reuses the same geometry, action and resource validation as main layouts.
    public var layoutDefinition: LayoutDefinition {
        LayoutDefinition(id: id, name: name, input: .init(builtinLayout: .qwerty26), rows: rows, split: split)
    }

    public func validate() throws { _ = try validatedUsage() }

    /// Validates the page once and returns what it spends, so the catalog check never walks the
    /// page a second time.
    func validatedUsage() throws -> LayoutResourceBudget.Usage {
        guard numericPresentation == nil || kind == .numeric else {
            throw LayoutError.invalid("只有 123 页可以选择「自动」或「数字九宫格」，请重新选择页面。")
        }
        guard kind == .symbols || (symbolPresentation == nil && categories == nil) else {
            throw LayoutError.invalid("分类浏览只适用于符号页，请重新选择页面。")
        }
        try Self.validateIdentity(id: id, name: name)
        // Bound the work first: every later check walks keys the budget has already counted.
        let usage = try LayoutResourceBudget.usage(self)
        if numericPresentation == .automatic {
            guard rows.isEmpty, categories == nil, symbolPresentation == nil, chrome == nil else {
                throw LayoutError.invalid("「自动 123」不能带按键或分类，请复制一份再编辑。")
            }
        } else if symbolPresentation == .categorized {
            if let chrome, !chrome.leading.isEmpty {
                throw LayoutError.invalid("分类符号页的左侧栏由分类决定，不能再放按键。")
            }
            if let categories {
                guard !categories.isEmpty else { throw LayoutError.invalid("请至少保留一个分类。") }
                guard Set(categories.map(\.id)).count == categories.count else {
                    throw LayoutError.invalid("有两个分类重复了，请删掉其中一个。")
                }
                for category in categories { try category.validate() }
            }
        } else {
            guard categories == nil else {
                throw LayoutError.invalid("只有分类符号页可以放分类，请删掉分类，或者改用分类符号页。")
            }
            if chrome == nil {
                // Native controls are drawn around these rows; authored pages (chrome != nil) may
                // keep a deliberately empty key area instead.
                guard numericPresentation == nil else {
                    throw LayoutError.invalid("这个数字九宫格没有按键，请复制「数字九宫格」页面后再编辑。")
                }
                guard !rows.isEmpty, rows.allSatisfy({ !$0.keys.isEmpty }) else {
                    throw LayoutError.invalid("请至少保留一行，每行至少保留一个按键。")
                }
            }
        }
        for key in rows.flatMap(\.keys) { try Self.validateKey(key) }
        try chrome?.validate()
        try split?.validate(rowKeyCounts: splitRowKeyCounts)
        return usage
    }

    private static func validateIdentity(id: String, name: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LayoutError.invalid("请填写页面名称。") }
        guard id.utf8.count <= 256, name.utf8.count <= 256 else {
            throw LayoutError.invalid("页面名称过长，请缩短后保存。")
        }
    }

    static func validateKey(_ key: LayoutKey) throws {
        guard !key.label.isEmpty, key.widthWeight.isFinite, key.widthWeight > 0 else {
            throw LayoutError.invalid("请填写按键标题，并把宽度设为大于 0 的数字。")
        }
        guard key.action.type != .code, (key.longPress ?? []).allSatisfy({ $0.action.type != .code }) else {
            throw LayoutError.invalid("页面上的按键请选择「输入文字」。")
        }
        try key.action.validate()
        for option in key.longPress ?? [] {
            guard !option.label.isEmpty else { throw LayoutError.invalid("请填写长按项的标题。") }
            try option.action.validate()
        }
    }

    /// Split row counts including the footer row. The footer cut lives at `rows.count`, so an
    /// authored footer keeps its own cut after the key rows.
    private var splitRowKeyCounts: [Int] {
        var counts = rows.map { $0.keys.count }
        if let bottom = chrome?.bottom, !bottom.isEmpty { counts.append(bottom.count) }
        return counts
    }

    // MARK: - Materialized drafts and copies

    /// The editable form of this page: the native controls become real data. It is idempotent: an
    /// already authored page (chrome != nil) is returned untouched, so opening the editor twice can
    /// never duplicate Shift/Delete/footer/rails or resurrect a key the user deleted.
    ///
    /// The host resolves global categories before calling this; materialization itself is pure data
    /// and never reads disk. Name and id are preserved.
    public func materialized(
        numericForm: KeyboardNumericForm = .rows,
        numericMarks: KeyboardNumericMarks = .chinese
    ) -> KeyboardPageDefinition {
        guard chrome == nil else { return self }
        var page = self
        switch numericPresentation {
        case .automatic:
            if numericForm == .phoneDigitPad {
                page.rows = Self.keypadDigitRows
                page.numericPresentation = .keypad
                page.chrome = Self.keypadChrome(marks: numericMarks)
                page.defaultSymbolMarks = numericMarks
            } else {
                page.rows =
                    (numericMarks == .ascii ? KeyboardPagePresets.numericEnglish : KeyboardPagePresets.numericChinese)
                    .rows
                page.numericPresentation = nil
                // The native row page gets its third-row switch and Delete from the renderer;
                // materialized data carries them explicitly so an authored page keeps both.
                page.rows = Self.rowsInsertingNativeControls(rows: page.rows, kind: .numeric, split: &page.split)
                page.chrome = Self.rowsChrome(kind: .numeric)
                page.defaultSymbolMarks = numericMarks
            }
        case .keypad:
            if page.rows.isEmpty { page.rows = Self.keypadDigitRows }
            page.chrome = Self.keypadChrome(marks: numericMarks)
            page.defaultSymbolMarks = numericMarks
        case nil:
            if symbolPresentation == .automatic {
                page.symbolPresentation = .rows
                // An untouched automatic symbol page still carries the built-in canonical rows, so
                // the copy can take the initial-language snapshot (labels and long-press menus).
                // Author-modified rows are never replaced by a whole preset.
                let canonical =
                    page.rows.isEmpty || page.rows == KeyboardPagePresets.symbolsChinese.rows
                    || page.rows == KeyboardPagePresets.symbolsEnglish.rows
                if canonical {
                    page.rows =
                        numericMarks == .ascii
                        ? KeyboardPagePresets.symbolsEnglish.rows : KeyboardPagePresets.symbolsChinese.rows
                }
                page.categories = nil
                page.rows = Self.rowsInsertingNativeControls(rows: page.rows, kind: .symbols, split: &page.split)
                page.chrome = Self.rowsChrome(kind: .symbols)
                page.defaultSymbolMarks = numericMarks
            } else if symbolPresentation == .categorized || categories != nil {
                page.symbolPresentation = .categorized
                page.chrome = Self.categoryChrome
            } else {
                page.rows = Self.rowsInsertingNativeControls(rows: page.rows, kind: page.kind, split: &page.split)
                page.chrome = Self.rowsChrome(kind: page.kind)
            }
        }
        return page
    }

    /// A copy is editable authored content, so an automatic page materializes into the built-in
    /// rows it stands for instead of keeping the automatic flag, and the result gets a new id.
    public func copy(
        name: String? = nil,
        numericMarks: KeyboardNumericMarks = .chinese,
        numericForm: KeyboardNumericForm = .rows
    ) -> Self {
        var copy = materialized(numericForm: numericForm, numericMarks: numericMarks)
        copy.id = UUID().uuidString.lowercased()
        copy.name = name ?? self.name + " 副本"
        return copy
    }

    private static let shiftKey = LayoutKey(
        label: "⇧", width: KeyboardPageDefaultShape.alphabetSideWidth, action: .init(.shift), titleMode: .automatic)
    private static let deleteKey = LayoutKey(
        label: "⌫", width: KeyboardPageDefaultShape.alphabetSideWidth, action: .init(.backspace),
        titleMode: .automatic)

    /// The 123 / symbol page's third-row switch in the Shift position, opening the other page.
    private static func markPageSwitchKey(kind: KeyboardPageKind) -> LayoutKey {
        let target: LayoutAction.PageTarget = kind == .numeric ? .symbols : .numeric
        return LayoutKey(
            label: pageSwitchKey(target).label, width: KeyboardPageDefaultShape.alphabetSideWidth,
            action: .pageSwitch(target), titleMode: .automatic)
    }

    /// The ABC page's comma in the utility position; long press holds the other sentence marks.
    /// Each mark keeps its Chinese/ASCII pair so the key follows the symbol branch.
    private static var commaKey: LayoutKey {
        let pairs = [("。", "."), ("？", "?"), ("！", "!"), ("、", "'"), ("…", "\"")]
        return LayoutKey(
            label: ",", action: .init(.literal, value: "，", asciiValue: ","),
            longPress: pairs.map { chinese, ascii in
                LayoutOption(label: ascii, action: .init(.literal, value: chinese, asciiValue: ascii))
            },
            titleMode: .automatic)
    }

    private static func functionKey(
        _ label: String, _ action: LayoutAction, width: Double? = nil
    ) -> LayoutKey {
        LayoutKey(label: label, width: width, action: action, titleMode: .automatic)
    }

    private static var languageSwitchKey: LayoutKey { functionKey("中英", .init(.languageSwitch)) }
    private static var returnToLettersLanguageKey: LayoutKey {
        functionKey("返回", .languageSwitch(.letters))
    }
    private static var globeKey: LayoutKey { functionKey("🌐", .init(.globe)) }
    private static var spaceKey: LayoutKey {
        functionKey("空格", .init(.space), width: KeyboardPageDefaultShape.footerSpaceWidth)
    }
    private static var enterKey: LayoutKey { functionKey("⏎", .init(.enter)) }
    private static var symbolLockKey: LayoutKey { functionKey("锁定", .init(.symbolLock)) }

    private static func pageSwitchKey(_ target: LayoutAction.PageTarget) -> LayoutKey {
        let title: String
        switch target {
        // The letters switch is a return, never an ABC/English hint.
        case .letters: title = "返回"
        case .numeric: title = "123"
        case .symbols: title = "符号"
        }
        return functionKey(title, .pageSwitch(target))
    }

    /// The digit pad's three leading rail keys are the real 123 rail's first three entries, with
    /// their explicit Chinese/ASCII branches; the stored label follows the copy's initial branch.
    private static func keypadLeadingKeys(marks: KeyboardNumericMarks) -> [LayoutKey] {
        let chinese = Array(BuiltinLayouts.phoneNumericRailValues(ascii: false).prefix(3))
        let ascii = Array(BuiltinLayouts.phoneNumericRailValues(ascii: true).prefix(3))
        return zip(chinese, ascii).map { chineseMark, asciiMark in
            LayoutKey(
                label: marks == .ascii ? asciiMark : chineseMark,
                action: .init(
                    .literal, value: chineseMark,
                    asciiValue: chineseMark == asciiMark ? nil : asciiMark),
                titleMode: .automatic)
        }
    }

    private static func railKey(
        _ label: String, _ action: LayoutAction, span: Double
    ) -> LayoutKey {
        LayoutKey(label: label, width: span, action: action, titleMode: .automatic)
    }

    /// Default slots stay physically stable — globe first, the switches at the positions the
    /// control row already budgets — so materializing a page never re-tunes the bottom row.
    /// Authored chrome is data and is never rebuilt here; only a nil chrome (native controls) is
    /// materialized by this factory.
    private static func rowsChrome(kind: KeyboardPageKind) -> KeyboardPageChrome {
        switch kind {
        case .english:
            // globe, 123, 中英, space, comma, Return
            return KeyboardPageChrome(
                bottom: [globeKey, pageSwitchKey(.numeric), languageSwitchKey, spaceKey, commaKey, enterKey])
        case .numeric, .symbols:
            // globe, 返回, 中英, space, Return; the 123/symbol switch opens the third row.
            return KeyboardPageChrome(
                bottom: [globeKey, pageSwitchKey(.letters), languageSwitchKey, spaceKey, enterKey])
        }
    }

    /// The categorized symbol page keeps its category navigation as metadata; the authored chrome
    /// only carries the footer and the full-height editing rail.
    private static var categoryChrome: KeyboardPageChrome {
        KeyboardPageChrome(
            bottom: [
                // The categorized default return keeps the native language/tools menu.
                globeKey, returnToLettersLanguageKey, pageSwitchKey(.numeric), spaceKey, symbolLockKey,
            ],
            trailing: [
                railKey("⌫", .init(.backspace), span: 1), railKey("重输", .init(.clearInput), span: 1),
                railKey("⏎", .init(.enter), span: 2),
            ],
            trailingSpansBottom: true)
    }

    private static var keypadDigitRows: [LayoutRow] {
        [[1, 2, 3], [4, 5, 6], [7, 8, 9]].map { row in
            LayoutRow(
                keys: row.map { digit in
                    let text = String(digit)
                    return LayoutKey(label: text, action: .init(.literal, value: text))
                })
        }
    }

    private static func keypadChrome(marks: KeyboardNumericMarks) -> KeyboardPageChrome {
        KeyboardPageChrome(
            bottom: [
                // globe, 返回, 中英, space, 0; Delete/重输/Return stay in the trailing rail.
                globeKey, pageSwitchKey(.letters), languageSwitchKey, spaceKey,
                LayoutKey(
                    label: KeyboardPageDefaultShape.keypadZero,
                    action: .init(.literal, value: KeyboardPageDefaultShape.keypadZero)),
            ],
            leading: keypadLeadingKeys(marks: marks),
            trailing: [
                railKey("⌫", .init(.backspace), span: 1), railKey("重输", .init(.clearInput), span: 1),
                railKey("⏎", .init(.enter), span: 2),
            ],
            trailingSpansBottom: true)
    }

    /// Native rendering synthesizes the leading control (Shift on ABC, the 123/symbol switch
    /// elsewhere) and Delete around the last row. Materializing writes them as keys instead; a
    /// stored split cut on that row moves by one because the leading key is inserted before the
    /// characters, while an appended Delete never moves a cut.
    private static func rowsInsertingNativeControls(
        rows: [LayoutRow], kind: KeyboardPageKind, split: inout LayoutSplitConfiguration?
    ) -> [LayoutRow] {
        guard !rows.isEmpty else { return rows }
        let declared = rows.flatMap(\.keys)
        let leadingType: LayoutAction.Kind = kind == .english ? .shift : .pageSwitch
        let declaresLeading = declared.contains { $0.action.type == leadingType }
        let declaresDelete = declared.contains { $0.action.type == .backspace }
        var result = rows
        var shiftRow: Int?
        if !declaresLeading {
            let index = result.count - 1
            var keys = result[index].keys
            keys.insert(kind == .english ? shiftKey : markPageSwitchKey(kind: kind), at: 0)
            result[index] = LayoutRow(keys: keys)
            shiftRow = index
        }
        if !declaresDelete {
            let index = result.count - 1
            var keys = result[index].keys
            keys.append(deleteKey)
            result[index] = LayoutRow(keys: keys)
        }
        if let shiftRow, let current = split, current.rowBreaks.indices.contains(shiftRow) {
            var updated = current
            updated.rowBreaks[shiftRow] = min(
                max(1, result[shiftRow].keys.count - 1), updated.rowBreaks[shiftRow] + 1)
            split = updated
        }
        return result
    }
}

/// The shapes materialization writes and the geometry recognizes. Recognition reads only these
/// structural facts (never an ID or label), so a default copy keeps the native widths while any
/// structural edit falls back to the authored weights.
enum KeyboardPageDefaultShape {
    static let footerSpaceWidth = 4.0
    static let alphabetSideWidth = 1.5
    static let keypadZero = "0"

    /// One letter per equal-width column. Any single letter qualifies; a control, a phrase or a
    /// changed weight does not.
    static func isLetterKey(_ key: LayoutKey) -> Bool {
        guard key.widthWeight == 1, key.action.type == .literal, let value = key.action.value,
            value.count == 1
        else { return false }
        return value.first?.isLetter == true
    }

    /// Native ABC rows: 10 / 9 / 7 letters; the renderer adds Shift and Delete.
    static func isNativeAlphabet(_ page: KeyboardPageDefinition) -> Bool {
        page.kind == .english && page.rows.map(\.keys.count) == [10, 9, 7]
            && page.rows.allSatisfy { $0.keys.allSatisfy(isLetterKey) }
    }

    /// One mark per equal-width column on a 123 / symbol page.
    static func isMarkKey(_ key: LayoutKey) -> Bool {
        key.widthWeight == 1 && key.action.type == .literal
    }

    /// Native 123 / symbol rows: 10 / 10 / 7 equal literals; the renderer adds the 123/symbol
    /// switch and Delete around the third row.
    static func isNativeMarkRows(_ page: KeyboardPageDefinition) -> Bool {
        page.kind != .english && page.rows.map(\.keys.count) == [10, 10, 7]
            && page.rows.allSatisfy { $0.keys.allSatisfy(isMarkKey) }
    }

    /// Authored ABC rows (10 / 9 / Shift + 7 letters + Delete) or 123 / symbol rows
    /// (10 / 10 / switch + 7 marks + Delete), with the default side weights.
    static func isAuthoredStandardRows(_ page: KeyboardPageDefinition) -> Bool {
        let english = page.kind == .english
        guard page.rows.map(\.keys.count) == [10, english ? 9 : 10, 9] else { return false }
        let last = page.rows[2].keys
        guard last.first?.action.type == (english ? .shift : .pageSwitch),
            last.last?.action.type == .backspace,
            last.first?.widthWeight == alphabetSideWidth, last.last?.widthWeight == alphabetSideWidth
        else { return false }
        let character = english ? isLetterKey : isMarkKey
        return page.rows[0].keys.allSatisfy(character) && page.rows[1].keys.allSatisfy(character)
            && last.dropFirst().dropLast().allSatisfy(character)
    }
}
