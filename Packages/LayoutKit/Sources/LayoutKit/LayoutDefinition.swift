import Foundation

/// Data only: actions are dispatched by the keyboard host, never evaluated as scripts.
public struct LayoutAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case code, literal, space, backspace, enter, globe, modeSwitch
        /// Page-level controls. The host dispatches them itself; they never become an engine
        /// key action, so no engine case is added for a new kind.
        case shift, pageSwitch, languageSwitch, symbolLock, clearInput
    }

    /// The only page a `.pageSwitch` key may open.
    public enum PageTarget: String, Codable, CaseIterable, Sendable {
        case letters, numeric, symbols
    }

    /// Explicit behavior of an authored language key. No value keeps the page-following default.
    public enum LanguageSwitchBehavior: String, Codable, CaseIterable, Sendable {
        /// Switch only the panel's symbol language; the page does not change.
        case symbols
        /// Return to the main letter keyboard, keeping the Chinese/English input state.
        case letters
    }

    public let type: Kind
    public let value: String?
    /// ASCII counterpart of a bilingual literal (Chinese is `value`, ASCII is this). Nil keeps
    /// the literal fixed; only `.literal` may carry it.
    public let asciiValue: String?

    public init(_ type: Kind, value: String? = nil, asciiValue: String? = nil) {
        self.type = type
        self.value = value
        self.asciiValue = asciiValue
    }

    /// The page a `.pageSwitch` key opens, or nil for every other kind.
    public var pageSwitchTarget: PageTarget? {
        guard type == .pageSwitch, let value else { return nil }
        return PageTarget(rawValue: value)
    }

    public static func pageSwitch(_ target: PageTarget) -> LayoutAction {
        LayoutAction(.pageSwitch, value: target.rawValue)
    }

    /// The value a literal key shows and types for the current punctuation state. A nil pair is
    /// fixed text; a bilingual pair resolves without rebuilding any authored face metadata.
    public func literalValue(usesASCIIPunctuation: Bool) -> String? {
        guard type == .literal else { return nil }
        if usesASCIIPunctuation, let asciiValue { return asciiValue }
        return value
    }

    /// Replaces only the ASCII counterpart, keeping the kind and the Chinese value.
    public func settingAsciiValue(_ asciiValue: String?) -> LayoutAction {
        LayoutAction(type, value: value, asciiValue: asciiValue)
    }

    /// The explicit behavior authored on a language key, or nil when the key follows the page.
    public var languageSwitchBehavior: LanguageSwitchBehavior? {
        guard type == .languageSwitch, let value else { return nil }
        return LanguageSwitchBehavior(rawValue: value)
    }

    /// Builds a language key with an explicit behavior; nil keeps the page-following default.
    public static func languageSwitch(_ behavior: LanguageSwitchBehavior? = nil) -> LayoutAction {
        LayoutAction(.languageSwitch, value: behavior?.rawValue)
    }

    public func validate() throws {
        guard type == .literal || asciiValue == nil else {
            throw LayoutError.invalid("只有文字键可以同时填写英文符号，请重新选择。")
        }
        switch type {
        case .code:
            // The current engine interface accepts one logical ASCII key at a time.
            guard let value, value.utf8.count == 1,
                let byte = value.utf8.first, (33...126).contains(byte)
            else {
                throw LayoutError.invalid("输入字母的按键只能填一个英文字母、数字或符号，请修改后保存。")
            }
        case .literal:
            guard let value, !value.isEmpty else {
                throw LayoutError.invalid("请填写按键要输入的文字。")
            }
            if let asciiValue, asciiValue.isEmpty {
                throw LayoutError.invalid("英文符号不能为空，请重新填写。")
            }
        case .modeSwitch:
            guard value == nil || value == "nextLayout" else {
                throw LayoutError.invalid("切换布局键的设置无法识别，请重新选择。")
            }
        case .pageSwitch:
            guard let value, PageTarget(rawValue: value) != nil else {
                throw LayoutError.invalid("翻页键只能选择字母、数字或符号页，请重新选择。")
            }
        case .languageSwitch:
            guard value.map({ LanguageSwitchBehavior(rawValue: $0) != nil }) ?? true else {
                throw LayoutError.invalid("中英键的行为无法识别，请重新选择。")
            }
        case .shift, .symbolLock, .clearInput, .space, .backspace, .enter, .globe:
            guard value == nil else {
                throw LayoutError.invalid("这个功能键不需要填写输入的文字，请清空后保存。")
            }
        }
    }
}

public struct LayoutOption: Codable, Equatable, Sendable {
    public let label: String
    public let action: LayoutAction
    public init(label: String, action: LayoutAction) {
        self.label = label
        self.action = action
    }
}

/// How a key face derives its title. Nil draws the stored label, which is what every key of a
/// main layout file does.
public enum LayoutKeyTitleMode: String, Codable, Sendable {
    /// The host draws the control's live native face (Return title/state, Shift icon, language,
    /// lock, page target, space, delete). The stored label is the editor/accessibility fallback.
    case automatic
    /// The author's stored label is shown on every control, whatever the live state says.
    case custom
}

public struct LayoutKey: Codable, Equatable, Sendable {
    public internal(set) var label: String
    public internal(set) var secondaryLabel: String?
    /// Positive relative weight. In a key row or the footer it is a relative width; in a leading
    /// or trailing rail it is a relative vertical span. Omitted means 1.
    public internal(set) var width: Double?
    public internal(set) var action: LayoutAction
    public internal(set) var longPress: [LayoutOption]?
    /// Nil draws the stored label; see `LayoutKeyTitleMode`.
    public internal(set) var titleMode: LayoutKeyTitleMode?
    public var widthWeight: Double { width ?? 1 }

    public init(
        label: String, secondaryLabel: String? = nil, width: Double? = nil,
        action: LayoutAction, longPress: [LayoutOption]? = nil,
        titleMode: LayoutKeyTitleMode? = nil
    ) {
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.width = width
        self.action = action
        self.longPress = longPress
        self.titleMode = titleMode
    }

    /// Field-preserving edits: editors must not rebuild a key and silently drop `titleMode`.
    public func title(_ label: String) -> LayoutKey {
        with {
            $0.label = label
            $0.titleMode = .custom
        }
    }

    public func settingTitleMode(_ mode: LayoutKeyTitleMode?) -> LayoutKey { with { $0.titleMode = mode } }

    public func settingSecondaryLabel(_ label: String?) -> LayoutKey { with { $0.secondaryLabel = label } }

    public func settingWidth(_ width: Double?) -> LayoutKey { with { $0.width = width } }

    public func settingAction(_ action: LayoutAction) -> LayoutKey { with { $0.action = action } }

    public func settingLongPress(_ options: [LayoutOption]?) -> LayoutKey { with { $0.longPress = options } }

    private func with(_ change: (inout LayoutKey) -> Void) -> LayoutKey {
        var key = self
        change(&key)
        return key
    }
}

public struct LayoutRow: Codable, Equatable, Sendable {
    public let keys: [LayoutKey]
    public init(keys: [LayoutKey]) { self.keys = keys }
}

/// A schemaID is a reference to an installed Rime schema, not a translator implementation.
public struct LayoutInput: Codable, Equatable, Sendable {
    public enum Builtin: String, Codable, Sendable, CaseIterable {
        case qwerty26, merged14, merged18, phone9
    }
    public let schemaID: String?
    public let builtinLayout: Builtin?
    public init(schemaID: String? = nil, builtinLayout: Builtin? = nil) {
        self.schemaID = schemaID
        self.builtinLayout = builtinLayout
    }
}

public struct LayoutAuxiliaryArea: Codable, Equatable, Sendable {
    public enum Position: String, Codable, Sendable { case leading, trailing }
    public enum Role: String, Codable, Sendable { case punctuation, editing, disambiguation }
    public let position: Position
    public let role: Role
    public let keys: [LayoutKey]
    /// The host must hide this region unless an engine-backed disambiguation API exists.
    public var requiresEngineDisambiguation: Bool { role == .disambiguation }
    public init(position: Position, role: Role, keys: [LayoutKey] = []) {
        self.position = position
        self.role = role
        self.keys = keys
    }
}

/// Candidate surface requirements belong to the physical layout, not its name or schema.
public struct LayoutCandidateArea: Codable, Equatable, Sendable {
    public var candidates: Bool
    public var reading: Bool

    public init(candidates: Bool, reading: Bool) {
        self.candidates = candidates
        self.reading = reading
    }
}

public struct LayoutDefinition: Codable, Equatable, Sendable, Identifiable {
    public internal(set) var id: String
    public internal(set) var name: String
    public let input: LayoutInput
    public internal(set) var rows: [LayoutRow]
    public internal(set) var auxiliaryAreas: [LayoutAuxiliaryArea]?
    /// Nil lets the key structure decide (see `effectiveCandidateArea`).
    public internal(set) var candidateArea: LayoutCandidateArea?
    public internal(set) var split: LayoutSplitConfiguration?
    public let note: String?
    /// Seconds until the alternate picker opens. Release commits one selected alternate only.
    public let longPressDelay: Double?
    public var effectiveLongPressDelay: Double { longPressDelay ?? 0.35 }
    public var sendsEngineCode: Bool {
        let keys = rows.flatMap(\.keys) + (auxiliaryAreas ?? []).flatMap(\.keys)
        return keys.contains { key in
            key.action.type == .code || (key.longPress ?? []).contains { $0.action.type == .code }
        }
    }
    public var effectiveCandidateArea: LayoutCandidateArea {
        candidateArea
            ?? LayoutCandidateArea(
                candidates: sendsEngineCode,
                reading: CompactSpellingLayout.matches(self) && !PhoneKeypadStructure.matches(self))
    }

    public init(
        id: String, name: String, input: LayoutInput, rows: [LayoutRow],
        auxiliaryAreas: [LayoutAuxiliaryArea]? = nil, note: String? = nil,
        longPressDelay: Double? = nil, candidateArea: LayoutCandidateArea? = nil,
        split: LayoutSplitConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.rows = rows
        self.auxiliaryAreas = auxiliaryAreas
        self.candidateArea = candidateArea
        self.split = split
        self.note = note
        self.longPressDelay = longPressDelay
    }

    /// Caller keeps security-scoped access alive for the entire synchronous read.
    public static func read(from url: URL) throws -> Self {
        try decode(LayoutResourceBudget.read(url, maximumBytes: LayoutResourceBudget.definitionBytes))
    }

    public static func decode(_ data: Data) throws -> Self {
        try LayoutResourceBudget.check(data.count <= LayoutResourceBudget.definitionBytes, "布局文件过大，请删掉一些按键或文字后再试。")
        let layout = try JSONDecoder().decode(Self.self, from: data)
        try layout.validate()
        return layout
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try LayoutResourceBudget.check(data.count <= LayoutResourceBudget.definitionBytes, "布局文件过大，请删掉一些按键或文字后再试。")
        return data
    }

    public func validate() throws { _ = try validatedUsage() }

    /// Validates the layout once and returns what it spends, so the catalog check never walks the
    /// layout a second time.
    func validatedUsage() throws -> LayoutResourceBudget.Usage {
        let usage = try LayoutResourceBudget.usage(self)
        try split?.validate(rowKeyCounts: rows.map { $0.keys.count })
        guard effectiveLongPressDelay.isFinite, effectiveLongPressDelay > 0 else {
            throw LayoutError.invalid("长按等待时间要大于 0 秒，请修改后保存。")
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LayoutError.invalid("请填写名称后再保存。")
        }
        if let schema = input.schemaID, schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LayoutError.invalid("这个布局指定的输入方案是空的，请重新选择输入方案。")
        }
        guard input.schemaID != nil || input.builtinLayout != nil else {
            throw LayoutError.invalid("请选择这个布局适用的输入方案，或者适用的键盘（如 26 键、9 键）。")
        }
        guard !rows.isEmpty, rows.allSatisfy({ !$0.keys.isEmpty }) else {
            throw LayoutError.invalid("请至少保留一行，每行至少保留一个按键。")
        }
        let area = effectiveCandidateArea
        if area.reading && !area.candidates {
            throw LayoutError.invalid("拼音提示行需要显示候选栏，请开启后保存。")
        }
        if area.reading && PhoneKeypadStructure.matches(self) {
            throw LayoutError.invalid("9 键的拼音显示在左侧栏，请关闭拼音提示行后保存。")
        }
        if !area.candidates && sendsEngineCode {
            throw LayoutError.invalid("输入字母的按键需要显示候选栏，请开启后保存。")
        }
        for area in auxiliaryAreas ?? [] {
            // This is a dynamic engine-provided region, never static fake letter filters.
            if area.role == .disambiguation && !area.keys.isEmpty {
                throw LayoutError.invalid("选字辅助区的按键由输入法自动提供，请清空其中的按键后保存。")
            }
        }
        for key in rows.flatMap(\.keys) + (auxiliaryAreas ?? []).flatMap(\.keys) {
            guard !key.label.isEmpty, key.widthWeight.isFinite, key.widthWeight > 0 else {
                throw LayoutError.invalid("请填写按键标题，并把宽度设为大于 0 的数字。")
            }
            try key.action.validate()
            for option in key.longPress ?? [] {
                guard !option.label.isEmpty else { throw LayoutError.invalid("请填写长按项的标题。") }
                try option.action.validate()
            }
        }
        return usage
    }
}

/// Stable structural address shared by the editor and engine-free preview.
public enum LayoutKeyPath: Hashable, Sendable {
    case row(Int, key: Int)
    case auxiliary(Int, key: Int)
}

public extension LayoutDefinition {
    func supportsComposition(inputMethodID: String, layout: LayoutInput.Builtin) -> Bool {
        (input.schemaID == nil || input.schemaID == inputMethodID)
            && (input.builtinLayout == nil || input.builtinLayout == layout)
    }

    func copy(name: String? = nil) -> LayoutDefinition {
        var copy = self
        copy.id = UUID().uuidString.lowercased()
        copy.name = name ?? self.name + " 副本"
        return copy
    }

    func renamed(_ name: String) -> LayoutDefinition {
        var copy = self
        copy.name = name
        return copy
    }

    func key(at path: LayoutKeyPath) -> LayoutKey? {
        switch path {
        case .row(let row, let key):
            guard rows.indices.contains(row), rows[row].keys.indices.contains(key) else { return nil }
            return rows[row].keys[key]
        case .auxiliary(let area, let key):
            guard let areas = auxiliaryAreas, areas.indices.contains(area),
                areas[area].keys.indices.contains(key)
            else { return nil }
            return areas[area].keys[key]
        }
    }

    /// Draft mutation deliberately allows invalid intermediate values; save validates the whole draft.
    func replacingKey(at path: LayoutKeyPath, with key: LayoutKey) -> LayoutDefinition {
        guard self.key(at: path) != nil else { return self }
        var copy = self
        switch path {
        case .row(let row, let index):
            var keys = rows[row].keys
            keys[index] = key
            copy.rows[row] = LayoutRow(keys: keys)
        case .auxiliary(let area, let index):
            if let original = auxiliaryAreas?[area] {
                var keys = original.keys
                keys[index] = key
                copy.auxiliaryAreas?[area] = LayoutAuxiliaryArea(
                    position: original.position, role: original.role, keys: keys)
            }
        }
        return copy
    }

    func settingCandidateArea(_ area: LayoutCandidateArea) -> LayoutDefinition {
        var copy = self
        copy.candidateArea = area
        return copy
    }

    func settingSplit(_ split: LayoutSplitConfiguration?) -> LayoutDefinition {
        var copy = self
        copy.split = split
        return copy
    }
}

/// Every message is written for the person editing the layout: it says what is wrong and what to
/// change, so hosts show it as is under their own title.
public enum LayoutError: Error, LocalizedError, Equatable {
    case invalid(String)
    case duplicateID(String)
    case unknownID(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .duplicateID: return "已经有一个相同的键盘布局，请选择替换，或者另存为副本。"
        case .unknownID: return "找不到这个键盘布局，它可能已经被删除。"
        }
    }
}
