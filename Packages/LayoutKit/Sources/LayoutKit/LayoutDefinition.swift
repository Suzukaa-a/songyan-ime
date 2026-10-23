import Foundation

/// Data only: actions are dispatched by the keyboard host, never evaluated as scripts.
public struct LayoutAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case code, literal, space, backspace, enter, globe, modeSwitch
    }

    public let type: Kind
    public let value: String?

    public init(_ type: Kind, value: String? = nil) {
        self.type = type
        self.value = value
    }

    public func validate() throws {
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
        case .modeSwitch:
            guard value == nil || value == "nextLayout" else {
                throw LayoutError.invalid("modeSwitch only supports nextLayout")
            }
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

public struct LayoutKey: Codable, Equatable, Sendable {
    public let label: String
    public let secondaryLabel: String?
    /// Positive relative weight within its row; omitted means 1.
    public let width: Double?
    public let action: LayoutAction
    public let longPress: [LayoutOption]?
    public var widthWeight: Double { width ?? 1 }

    public init(
        label: String, secondaryLabel: String? = nil, width: Double? = nil,
        action: LayoutAction, longPress: [LayoutOption]? = nil
    ) {
        self.label = label
        self.secondaryLabel = secondaryLabel
        self.width = width
        self.action = action
        self.longPress = longPress
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
        longPressDelay: Double? = nil, candidateArea: LayoutCandidateArea? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.rows = rows
        self.auxiliaryAreas = auxiliaryAreas
        self.candidateArea = candidateArea
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
    func copy(name: String? = nil) -> LayoutDefinition {
        LayoutDefinition(
            id: UUID().uuidString.lowercased(), name: name ?? self.name + " 副本",
            input: input, rows: rows, auxiliaryAreas: auxiliaryAreas,
            note: note, longPressDelay: longPressDelay, candidateArea: candidateArea)
    }

    func renamed(_ name: String) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: name, input: input, rows: rows,
            auxiliaryAreas: auxiliaryAreas, note: note, longPressDelay: longPressDelay,
            candidateArea: candidateArea)
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
            candidateArea: candidateArea)
    }

    func settingCandidateArea(_ area: LayoutCandidateArea) -> LayoutDefinition {
        LayoutDefinition(
            id: id, name: name, input: input, rows: rows,
            auxiliaryAreas: auxiliaryAreas, note: note, longPressDelay: longPressDelay,
            candidateArea: area)
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
