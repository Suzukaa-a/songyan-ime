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
                throw LayoutError.invalid("code requires one printable ASCII character")
            }
        case .literal:
            guard let value, !value.isEmpty else {
                throw LayoutError.invalid("literal requires nonempty value")
            }
            if let asciiValue, asciiValue.isEmpty {
                throw LayoutError.invalid("英文符号不能为空，请重新填写。")
            }
        case .modeSwitch:
            guard value == nil || value == "nextLayout" else {
                throw LayoutError.invalid("modeSwitch only supports nextLayout")
            }
        case .pageSwitch:
            guard let value, PageTarget(rawValue: value) != nil else {
                throw LayoutError.invalid("翻页键只能选择字母、数字或符号页，请重新选择。")
            }
        case .languageSwitch:
            guard value == nil || LanguageSwitchBehavior(rawValue: value!) != nil else {
                throw LayoutError.invalid("中英键的行为无法识别，请重新选择。")
            }
        case .shift, .symbolLock, .clearInput:
            guard value == nil else { throw LayoutError.invalid("这个功能键不能带值，请重新选择。") }
        case .space, .backspace, .enter, .globe:
            guard value == nil else { throw LayoutError.invalid("\(type.rawValue) takes no value") }
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

/// How a key face derives its title. Nil keeps the old class semantics, so an existing catalog
/// decodes and renders exactly as before.
public enum LayoutKeyTitleMode: String, Codable, Sendable {
    /// The host draws the control's live native face (Return title/state, Shift icon, language,
    /// lock, page target, space, delete). The stored label is the editor/accessibility fallback.
    case automatic
    /// The author's stored label is shown on every control, whatever the live state says.
    case custom
}

public struct LayoutKey: Codable, Equatable, Sendable {
    public let label: String
    public let secondaryLabel: String?
    /// Positive relative weight. In a key row or the footer it is a relative width; in a leading
    /// or trailing rail it is a relative vertical span. Omitted means 1.
    public let width: Double?
    public let action: LayoutAction
    public let longPress: [LayoutOption]?
    /// Nil keeps the legacy class semantics; see `LayoutKeyTitleMode`.
    public let titleMode: LayoutKeyTitleMode?
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
        LayoutKey(
            label: label, secondaryLabel: secondaryLabel, width: width, action: action,
            longPress: longPress, titleMode: .custom)
    }

    public func settingTitleMode(_ mode: LayoutKeyTitleMode?) -> LayoutKey {
        LayoutKey(
            label: label, secondaryLabel: secondaryLabel, width: width, action: action,
            longPress: longPress, titleMode: mode)
    }

    public func settingSecondaryLabel(_ label: String?) -> LayoutKey {
        LayoutKey(
            label: self.label, secondaryLabel: label, width: width, action: action,
            longPress: longPress, titleMode: titleMode)
    }

    public func settingWidth(_ width: Double?) -> LayoutKey {
        LayoutKey(
            label: label, secondaryLabel: secondaryLabel, width: width, action: action,
            longPress: longPress, titleMode: titleMode)
    }

    public func settingAction(_ action: LayoutAction) -> LayoutKey {
        LayoutKey(
            label: label, secondaryLabel: secondaryLabel, width: width, action: action,
            longPress: longPress, titleMode: titleMode)
    }

    public func settingLongPress(_ options: [LayoutOption]?) -> LayoutKey {
        LayoutKey(
            label: label, secondaryLabel: secondaryLabel, width: width, action: action,
            longPress: options, titleMode: titleMode)
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
    public let id: String
    public let name: String
    public let input: LayoutInput
    public let rows: [LayoutRow]
    public let auxiliaryAreas: [LayoutAuxiliaryArea]?
    /// Nil keeps existing imported layouts compatible; their key structure supplies the default.
    public let candidateArea: LayoutCandidateArea?
    public let split: LayoutSplitConfiguration?
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
        try LayoutResourceBudget.check(data.count <= LayoutResourceBudget.definitionBytes, "布局文件过大")
        let layout = try JSONDecoder().decode(Self.self, from: data)
        try layout.validate()
        return layout
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try LayoutResourceBudget.check(data.count <= LayoutResourceBudget.definitionBytes, "布局文件过大")
        return data
    }

    public func validate() throws {
        try LayoutResourceBudget.validate(self)
        try split?.validate(rowKeyCounts: rows.map { $0.keys.count })
        guard effectiveLongPressDelay.isFinite, effectiveLongPressDelay > 0 else {
            throw LayoutError.invalid("longPressDelay must be positive finite seconds")
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LayoutError.invalid("id and name are required")
        }
        if let schema = input.schemaID, schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LayoutError.invalid("schemaID must not be empty")
        }
        guard input.schemaID != nil || input.builtinLayout != nil else {
            throw LayoutError.invalid("input requires schemaID or builtinLayout")
        }
        guard !rows.isEmpty, rows.allSatisfy({ !$0.keys.isEmpty }) else {
            throw LayoutError.invalid("rows must contain keys")
        }
        let area = effectiveCandidateArea
        if area.reading && !area.candidates {
            throw LayoutError.invalid("reading row requires a candidate area")
        }
        if area.reading && PhoneKeypadStructure.matches(self) {
            throw LayoutError.invalid("phone layouts use their leading reading rail")
        }
        if !area.candidates && sendsEngineCode {
            throw LayoutError.invalid("Rime code keys require a candidate area")
        }
        for area in auxiliaryAreas ?? [] {
            // This is a dynamic engine-provided region, never static fake letter filters.
            if area.role == .disambiguation && !area.keys.isEmpty {
                throw LayoutError.invalid("disambiguation keys must be supplied by the engine at runtime")
            }
        }
        for key in rows.flatMap(\.keys) + (auxiliaryAreas ?? []).flatMap(\.keys) {
            guard !key.label.isEmpty, key.widthWeight.isFinite, key.widthWeight > 0 else {
                throw LayoutError.invalid("keys require label and positive finite width")
            }
            try key.action.validate()
            for option in key.longPress ?? [] {
                guard !option.label.isEmpty else { throw LayoutError.invalid("longPress requires label") }
                try option.action.validate()
            }
        }
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
        LayoutDefinition(
            id: UUID().uuidString.lowercased(), name: name ?? self.name + " 副本",
            input: input, rows: rows, auxiliaryAreas: auxiliaryAreas,
            note: note, longPressDelay: longPressDelay, candidateArea: candidateArea, split: split)
    }

    func renamed(_ name: String) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: name, input: input, rows: rows,
            auxiliaryAreas: auxiliaryAreas, note: note, longPressDelay: longPressDelay,
            candidateArea: candidateArea, split: split)
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
        var rows = rows
        var areas = auxiliaryAreas
        switch path {
        case .row(let row, let index):
            var keys = rows[row].keys
            keys[index] = key
            rows[row] = LayoutRow(keys: keys)
        case .auxiliary(let area, let index):
            if let original = areas?[area] {
                var keys = original.keys
                keys[index] = key
                areas?[area] = LayoutAuxiliaryArea(position: original.position, role: original.role, keys: keys)
            }
        }
        return LayoutDefinition(
            id: id, name: name, input: input, rows: rows,
            auxiliaryAreas: areas, note: note, longPressDelay: longPressDelay,
            candidateArea: candidateArea, split: split)
    }

    func settingCandidateArea(_ area: LayoutCandidateArea) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: name, input: input, rows: rows,
            auxiliaryAreas: auxiliaryAreas, note: note, longPressDelay: longPressDelay,
            candidateArea: area, split: split)
    }

    func settingSplit(_ split: LayoutSplitConfiguration?) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: name, input: input, rows: rows, auxiliaryAreas: auxiliaryAreas,
            note: note, longPressDelay: longPressDelay, candidateArea: candidateArea, split: split)
    }
}

public enum LayoutError: Error, LocalizedError, Equatable {
    case invalid(String)
    case duplicateID(String)
    case unknownID(String)
    case lastEnabledLayout
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid layout: \(reason)"
        case .duplicateID(let id): return "Layout already exists: \(id)"
        case .unknownID(let id): return "Unknown layout: \(id)"
        case .lastEnabledLayout: return "Keep at least one enabled layout."
        }
    }
}
