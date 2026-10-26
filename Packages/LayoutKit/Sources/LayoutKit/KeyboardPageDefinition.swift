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
    /// pairing keeps the built-in page, exactly as it did before pairings existed.
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
    /// Authored function area. Nil keeps the exact legacy synthesis; non-nil is drawn as data and
    /// nothing is ever synthesized for it.
    public var chrome: KeyboardPageChrome?
    /// The symbol branch this page opens in when the panel has no explicit override. Nil follows
    /// the live keyboard; authored pages keep nil unless the copy/materialization chose a branch,
    /// so an old page is never guessed into one.
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

    public func validate() throws {
        guard numericPresentation == nil || kind == .numeric else {
            throw LayoutError.invalid("只有 123 页可以选择「自动」或「数字盘」，请重新选择页面。")
        }
        if numericPresentation == .automatic {
            guard rows.isEmpty, categories == nil, symbolPresentation == nil, chrome == nil else {
                throw LayoutError.invalid("「自动 123」不能带按键或分类，请复制一份再编辑。")
            }
            try Self.validateIdentity(id: id, name: name)
            try split?.validate(rowKeyCounts: [])
            try LayoutResourceBudget.validate(self)
            return
        }
        guard kind == .symbols || (symbolPresentation == nil && categories == nil) else {
            throw LayoutError.invalid("分类浏览只适用于符号页，请重新选择页面。")
        }
        if let chrome { try chrome.validate() }
        if symbolPresentation == .categorized {
            if let chrome, !chrome.leading.isEmpty {
                throw LayoutError.invalid("分类符号页的左侧栏由分类决定，不能再放按键。")
            }
            try LayoutResourceBudget.validate(self)
            // Existing catalogs only had the non-empty check, so length stays unvalidated here to
            // keep an old catalog readable.
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw LayoutError.invalid("请填写页面名称。") }
            if let categories {
                guard !categories.isEmpty else { throw LayoutError.invalid("请至少保留一个分类。") }
                guard Set(categories.map(\.id)).count == categories.count else {
                    throw LayoutError.invalid("分类标识重复，请重新复制分类。")
                }
                for category in categories { try category.validate() }
            }
            try split?.validate(rowKeyCounts: splitRowKeyCounts)
            return
        }
        guard categories == nil else { throw LayoutError.invalid("请为分类选择分类符号页。") }
        if chrome != nil {
            // Authored pages keep deliberate structural emptiness: an empty key area, footer or
            // rail is a user decision, not a state to repair.
            try Self.validateIdentity(id: id, name: name)
            try split?.validate(rowKeyCounts: splitRowKeyCounts)
            try LayoutResourceBudget.validate(self)
            for key in rows.flatMap(\.keys) { try Self.validateKey(key) }
            return
        }
        guard numericPresentation == nil else {
            throw LayoutError.invalid("数字盘页面缺少按键数据，请复制预设后重新保存。")
        }
        try layoutDefinition.validate()
        for key in rows.flatMap(\.keys) { try Self.validateKey(key) }
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
            throw LayoutError.invalid("页面按键请选择「输入文字」。")
        }
        try key.action.validate()
        for option in key.longPress ?? [] {
            guard !option.label.isEmpty else { throw LayoutError.invalid("请填写长按项的标题。") }
            try option.action.validate()
        }
    }

    /// Split row counts including the footer row. The footer cut lives at `rows.count`, so a
    /// materialized page can keep the legacy footer split without a bogus row.
    private var splitRowKeyCounts: [Int] {
        var counts = rows.map { $0.keys.count }
        if let bottom = chrome?.bottom, !bottom.isEmpty { counts.append(bottom.count) }
        return counts
    }

    // MARK: - Materialized drafts and copies

    /// The editable form of this page: legacy synthesis becomes real data. It is idempotent: an
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
                // The legacy row page got its tenth-column Delete from the renderer; materialized
                // data carries it explicitly so an authored page still has a Delete key.
                page.rows = Self.rowsInsertingLegacyControls(rows: page.rows, kind: .numeric, split: &page.split)
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
                page.rows = Self.rowsInsertingLegacyControls(rows: page.rows, kind: .symbols, split: &page.split)
                page.chrome = Self.rowsChrome(kind: .symbols)
                page.defaultSymbolMarks = numericMarks
            } else if symbolPresentation == .categorized || categories != nil {
                page.symbolPresentation = .categorized
                // Legacy browser rows stay readable and editable; materialising must not delete
                // stored content, even though the category grid is what renders.
                page.chrome = Self.categoryChrome
            } else {
                page.rows = Self.rowsInsertingLegacyControls(rows: page.rows, kind: page.kind, split: &page.split)
                page.chrome = Self.rowsChrome(kind: page.kind)
            }
        }
        return page
    }

    /// A copy is editable authored content, so an automatic page materialises into the built-in
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
        label: "⇧", width: 1.5, action: .init(.shift), titleMode: .automatic)
    private static let deleteKey = LayoutKey(
        label: "⌫", width: 1.5, action: .init(.backspace), titleMode: .automatic)
    private static let plainDeleteKey = LayoutKey(
        label: "⌫", action: .init(.backspace), titleMode: .automatic)

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
    private static var spaceKey: LayoutKey { functionKey("空格", .init(.space), width: 4) }
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
    /// control row already budgets — so materialising a page never re-tunes the bottom row.
    /// Authored chrome is data and is never rebuilt here; only a nil chrome (legacy synthesis or a
    /// new preset) is materialised by this factory.
    private static func rowsChrome(kind: KeyboardPageKind) -> KeyboardPageChrome {
        switch kind {
        case .english:
            // globe, 123, 中英, space, 符号, Return
            return KeyboardPageChrome(
                bottom: [
                    globeKey, pageSwitchKey(.numeric), languageSwitchKey, spaceKey,
                    pageSwitchKey(.symbols), enterKey,
                ])
        case .numeric:
            // globe, 返回, 中英, space, 符号, Return
            return KeyboardPageChrome(
                bottom: [
                    globeKey, pageSwitchKey(.letters), languageSwitchKey, spaceKey,
                    pageSwitchKey(.symbols), enterKey,
                ])
        case .symbols:
            // globe, 返回, 中英, space, 123, Return
            return KeyboardPageChrome(
                bottom: [
                    globeKey, pageSwitchKey(.letters), languageSwitchKey, spaceKey,
                    pageSwitchKey(.numeric), enterKey,
                ])
        }
    }

    /// The categorized symbol page keeps its category navigation as metadata; the authored chrome
    /// only carries the footer and the full-height editing rail.
    private static var categoryChrome: KeyboardPageChrome {
        KeyboardPageChrome(
            bottom: [
                // The categorised default return keeps the native language/tools menu.
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
                LayoutKey(label: "0", action: .init(.literal, value: "0")),
            ],
            leading: keypadLeadingKeys(marks: marks),
            trailing: [
                railKey("⌫", .init(.backspace), span: 1), railKey("重输", .init(.clearInput), span: 1),
                railKey("⏎", .init(.enter), span: 2),
            ],
            trailingSpansBottom: true)
    }

    /// Legacy rendering synthesized Shift/Delete around the last row. Materializing writes them as
    /// keys instead; a stored split cut on the Shift row moves by one because Shift is inserted
    /// before the characters, while an appended Delete never moves a cut.
    private static func rowsInsertingLegacyControls(
        rows: [LayoutRow], kind: KeyboardPageKind, split: inout LayoutSplitConfiguration?
    ) -> [LayoutRow] {
        guard !rows.isEmpty else { return rows }
        let declared = rows.flatMap(\.keys)
        let declaresShift = declared.contains { $0.action.type == .shift }
        let declaresDelete = declared.contains { $0.action.type == .backspace }
        var result = rows
        var shiftRow: Int?
        if kind == .english, !declaresShift {
            let index = result.count - 1
            var keys = result[index].keys
            keys.insert(shiftKey, at: 0)
            result[index] = LayoutRow(keys: keys)
            shiftRow = index
        }
        if !declaresDelete {
            let index = result.count - 1
            var keys = result[index].keys
            keys.append(kind == .english ? deleteKey : plainDeleteKey)
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
