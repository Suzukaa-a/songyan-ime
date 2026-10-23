import CandidateKit
import Darwin
import Foundation
import SkinKit

/// The unified "appearance project": one user-facing unit = keyboard skin + candidate area layout behavior.
///
/// Identity rule (single, verifiable):
///     document.id == skin.id == candidateBar.id
/// Any mismatch is a mixed-generation document and is rejected on decode/read. A runtime snapshot
/// therefore always comes from one commit; "new skin + old candidate bar" cannot exist.
///
/// Content boundary:
///   - `skin` still owns all colors and fonts (including `typography.candidateSize`).
///   - `candidateBar` only describes candidate area layout behavior (composition row visibility,
///     collapsed strip height/padding, expanded layout, control placement); it carries no colors
///     and cannot configure fake candidates.
public struct AppearanceDocument: Codable, Equatable, Identifiable, Sendable {
    public static let formatVersionValue = 1
    public static let systemDefaultID = "system-default"
    public static let fileExtension = ".songyanappearance.json"

    public var formatVersion = AppearanceDocument.formatVersionValue
    public var id: String
    public var name: String
    public var author: String?
    /// Light/dark/follow-system is committed together with the skin and belongs to the same appearance identity.
    public var appearance: SkinAppearance
    public var skin: SkinDefinition
    public var candidateBar: CandidateBarDefinition

    /// Construction enforces identity lockstep: the given skin and candidate area are re-attached to
    /// this project's identity (only id/name change), so a mixed-generation document cannot be built.
    public init(
        id: String, name: String,
        appearance: SkinAppearance = .system,
        skin: SkinDefinition? = nil,
        candidateBar: CandidateBarDefinition? = nil
    ) {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.skin = Self.reidentified(skin ?? SkinDefinition(id: id, name: name), id: id, name: name)
        self.candidateBar = Self.reidentified(
            candidateBar ?? CandidateBarDefinition(id: id, name: name),
            id: id, name: name)
    }

    /// Built-in system default appearance: system default skin + system default candidate layout (read-only; duplicate to edit).
    public static let systemDefault = AppearanceDocument(
        id: systemDefaultID, name: "系统默认",
        skin: .systemDefault, candidateBar: .systemDefault)

    public var isSystemDefault: Bool { id == Self.systemDefaultID }

    // MARK: - Identity consistency

    /// Whether the three identities agree (skin, candidate bar, project).
    public var identityIsConsistent: Bool {
        id == skin.id && id == candidateBar.id
    }

    /// Stable identity string for logs/tests (contains no user-visible text).
    public var identityDescription: String {
        "\(id)|\(skin.id)|\(candidateBar.id)"
    }

    // MARK: - Normalize / duplicate

    /// Normalizes: the name is unified to the project name (one user-visible name per appearance),
    /// the skin is normalized (resolved colors are filled and materialized), the candidate bar is re-attached to the same identity.
    public func normalized() -> AppearanceDocument {
        var result = self
        result.formatVersion = Self.formatVersionValue
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.skin = Self.reidentified(skin, id: id, name: result.name).normalized()
        result.candidateBar = Self.reidentified(candidateBar, id: id, name: result.name)
        return result
    }

    /// Duplicates: one new identity is applied to project, skin and candidate bar at once; the name gets a "副本" suffix.
    public func copy() -> AppearanceDocument {
        let newID = UUID().uuidString.lowercased()
        var result = normalized()
        result.id = newID
        result.name = name + " 副本"
        result.skin = Self.reidentified(skin, id: newID, name: result.name).normalized()
        result.candidateBar = Self.reidentified(candidateBar, id: newID, name: result.name)
        return result
    }

    /// Re-attaches the skin to a new identity (only id/name change; content as-is).
    public static func reidentified(_ skin: SkinDefinition, id: String, name: String) -> SkinDefinition {
        var copy = skin
        copy.id = id
        copy.name = name
        return copy
    }

    /// Re-attaches the candidate-area config to a new identity (only id/name change; layout parameters as-is).
    public static func reidentified(_ bar: CandidateBarDefinition, id: String, name: String) -> CandidateBarDefinition {
        var copy = bar
        copy.id = id
        copy.name = name
        return copy
    }

    /// Replaces this appearance's candidate-area layout (skin unchanged; the three identities stay in lockstep).
    public func replacing(candidateBar bar: CandidateBarDefinition) -> AppearanceDocument {
        AppearanceDocument(id: id, name: name, appearance: appearance, skin: skin, candidateBar: bar)
    }

    /// Replaces this appearance's skin (candidate layout unchanged; the three identities stay in lockstep).
    public func replacing(skin: SkinDefinition) -> AppearanceDocument {
        AppearanceDocument(id: id, name: name, appearance: appearance, skin: skin, candidateBar: candidateBar)
    }

    // MARK: - Validation

    public func validate() throws {
        func require(_ test: Bool, _ path: String) throws {
            if !test { throw AppearanceError("\(path): 值无效") }
        }
        try require(formatVersion == Self.formatVersionValue, "$.formatVersion")
        let charset = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        try require(!id.isEmpty && id.unicodeScalars.allSatisfy(charset.contains), "$.id")
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "$.name")
        try skin.validate()
        try candidateBar.validate()
        // Composite identity: skin/candidate-bar generation mixing is not allowed.
        try require(id == skin.id, "$.skin.id 必须等于 $.id（皮肤与外观项目标识必须一致）")
        try require(id == candidateBar.id, "$.candidateBar.id 必须等于 $.id（候选栏归属该外观项目）")
    }

    // MARK: - Coding (strict fields + default filling, same discipline as SkinKit/CandidateKit)

    static let topLevelFields: Set<String> = [
        "formatVersion", "id", "name", "author", "appearance", "skin", "candidateBar",
    ]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppearanceError("$: 需要对象")
        }
        guard source["formatVersion"] as? Int == formatVersionValue else {
            throw AppearanceError("$.formatVersion: 只支持 \(formatVersionValue)")
        }
        // Known fields are kept, unknown fields rejected; nested content is validated by each package's strict decoding.
        var payload: [String: Any] = [:]
        for (key, value) in source {
            guard topLevelFields.contains(key) else { throw AppearanceError("$.\(key): 未知字段") }
            payload[key] = value
        }
        guard let id = payload["id"] as? String, !id.isEmpty else { throw AppearanceError("$.id: 缺少或为空") }
        guard let name = payload["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AppearanceError("$.name: 缺少或为空")
        }
        guard let skinObject = payload["skin"], let barObject = payload["candidateBar"] else {
            throw AppearanceError("$: 外观项目必须同时包含 skin 与 candidateBar")
        }
        // Skin and candidate area each go through their own package's strict decoding (unknown fields, invalid values, wrong versions are rejected).
        let skin = try SkinDefinition.decode(try JSONSerialization.data(withJSONObject: skinObject))
        let bar = try CandidateBarDefinition.decode(try JSONSerialization.data(withJSONObject: barObject))
        // Mixed generations must be rejected: skin/candidate-area identities in the file must match the project's.
        // (The programmatic `init` re-attaches identities, but persisted content must not be inconsistent.)
        guard skin.id == id else {
            throw AppearanceError("$.skin.id: 与 $.id 不一致（皮肤与外观项目不匹配）")
        }
        guard bar.id == id else {
            throw AppearanceError("$.candidateBar.id: 与 $.id 不一致（候选栏与外观项目不匹配）")
        }
        var document = AppearanceDocument(id: id, name: name, skin: skin, candidateBar: bar)
        if let author = payload["author"] {
            guard let author = author as? String else { throw AppearanceError("$.author: 需要字符串") }
            document.author = author
        }
        if let appearance = payload["appearance"] {
            guard let raw = appearance as? String, let parsed = SkinAppearance(rawValue: raw) else {
                throw AppearanceError("$.appearance: 需要 system/light/dark")
            }
            document.appearance = parsed
        }
        try document.validate()
        return document.normalized()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized())
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        return data
    }

    // MARK: - Import of user-supplied files

    /// Imports one file as an appearance project, handling three input kinds deterministically:
    ///   1. appearance project JSON (this package's format);
    ///   2. standalone skin JSON (`*.songyanskin.json`) -> wrapped with the current system-default candidate layout;
    ///   3. standalone candidate-area JSON (`*.songyancand.json`) -> wrapped with the system-default skin.
    /// Legacy `system-default` files are copied to a new identity to avoid colliding with the read-only built-in.
    public static func decodeImported(contentsOf url: URL) throws -> AppearanceDocument {
        try decodeImported(
            readData(
                from: url, maximumBytes: 256 * 1024,
                oversizeMessage: "$: JSON 超过 256KB"))
    }

    /// Reads an untrusted user-supplied file: it must be a regular file within the size limit.
    static func readData(from url: URL, maximumBytes: Int, oversizeMessage: String) throws -> Data {
        guard url.isFileURL else { throw AppearanceError("需要本地普通文件") }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw AppearanceError("需要普通文件") }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw AppearanceError(oversizeMessage) }
        return try Data(contentsOf: url)
    }

    public static func decodeImported(_ data: Data) throws -> AppearanceDocument {
        guard data.count <= 256 * 1024 else { throw AppearanceError("$: JSON 超过 256KB") }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
            let object = raw as? [String: Any]
        else {
            throw AppearanceError("$: 需要对象")
        }
        // A snapshot file (selection + content) is not an importable config: give clear guidance instead of a vague schema error.
        let snapshotKeys: Set<String> = ["selectedSkinID", "selectedBarID", "selectedID"]
        if !snapshotKeys.isDisjoint(with: object.keys) {
            throw AppearanceError("$: 这是快照文件（选择与内容），请分别导入皮肤、候选栏或外观项目文件。")
        }
        if object["skin"] != nil || object["candidateBar"] != nil {
            return try decode(data)
        }
        let skinKeys: Set<String> = ["variants", "typography", "keycap", "spacing"]
        let barKeys: Set<String> = ["compositionRow", "collapsed", "expanded", "controls"]
        if !skinKeys.isDisjoint(with: object.keys) {
            var skin = try SkinDefinition.decode(data)
            if skin.id == SkinDefinition.systemDefault.id { skin = skin.copy() }
            return try decode(
                AppearanceDocument(
                    id: skin.id, name: skin.name,
                    skin: skin, candidateBar: .systemDefault
                ).encoded())
        }
        if !barKeys.isDisjoint(with: object.keys) {
            var bar = try CandidateBarDefinition.decode(data)
            if bar.id == CandidateBarDefinition.systemDefaultID { bar = bar.copy() }
            return try decode(
                AppearanceDocument(
                    id: bar.id, name: bar.name,
                    skin: .systemDefault, candidateBar: bar
                ).encoded())
        }
        throw AppearanceError("$: 无法识别为皮肤、候选栏或外观项目文件。")
    }
}

/// Appearance project errors (same readable "path: message" convention as the two underlying packages).
public struct AppearanceError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Built-in preset appearances (read-only; duplicate to edit)

extension AppearanceDocument {
    /// Built-in appearances besides the system default. Identities are fixed and not deletable; users "duplicate and edit" to get their own.
    public static let builtinPresets: [AppearanceDocument] = [
        preset(
            id: "builtin-ink", name: "墨夜", appearance: .system,
            light: [
                "panel": "#E5E7EB", "key": "#FFFFFF", "control": "#D1D5DB",
                "accent": "#2B2D33", "accentText": "#FFFFFF", "text": "#111827",
                "secondaryText": "#4B5563", "selected": "#D1D5DB", "pressed": "#9CA3AF",
            ],
            dark: [
                "panel": "#141518", "key": "#2B2D33", "control": "#1F2126",
                "accent": "#3A6EA5", "accentText": "#FFFFFF", "text": "#F2F3F5",
                "secondaryText": "#A7ADB8", "selected": "#3A6EA5", "pressed": "#454952",
            ]),
        preset(
            id: "builtin-bamboo", name: "青竹", appearance: .system,
            light: [
                "panel": "#DDE8E0", "key": "#FBFDFB", "control": "#C3D6C8",
                "accent": "#2E7D5B", "accentText": "#FFFFFF", "text": "#1E2A23",
                "secondaryText": "#4C5E53", "selected": "#BFDCCB", "pressed": "#B3CBBB",
            ],
            dark: [
                "panel": "#1B2520", "key": "#34443B", "control": "#27342D",
                "accent": "#3F9A71", "accentText": "#FFFFFF", "text": "#EEF5F0",
                "secondaryText": "#AFC2B6", "selected": "#2F5F48", "pressed": "#4A5E52",
            ]),
        preset(
            id: "builtin-paper", name: "暖纸", appearance: .system,
            light: [
                "panel": "#EDE6DA", "key": "#FFFCF6", "control": "#DCD1BF",
                "accent": "#B5652B", "accentText": "#FFFFFF", "text": "#2E261D",
                "secondaryText": "#6A5C4B", "selected": "#EAD3BC", "pressed": "#D6C9B4",
            ],
            dark: [
                "panel": "#2A2520", "key": "#4A423A", "control": "#3A332C",
                "accent": "#C8773A", "accentText": "#FFFFFF", "text": "#F6EFE6",
                "secondaryText": "#C9BBAA", "selected": "#6A4A30", "pressed": "#5C534A",
            ]),
        preset(
            id: "builtin-galaxy", name: "星河", appearance: .system,
            light: [
                "panel": "#DCE4EC", "key": "#FFFFFF", "control": "#C5D3E3",
                "accent": "#1A56DB", "accentText": "#FFFFFF", "text": "#0F1E36",
                "secondaryText": "#465975", "selected": "#C7D8ED", "pressed": "#B5C8DE",
            ],
            dark: [
                "panel": "#111827", "key": "#1F2937", "control": "#182234",
                "accent": "#3B82F6", "accentText": "#FFFFFF", "text": "#F3F4F6",
                "secondaryText": "#8FA3BF", "selected": "#28436B", "pressed": "#364761",
            ]),
        preset(
            id: "builtin-twilight", name: "薄暮", appearance: .system,
            light: [
                "panel": "#E8E3EE", "key": "#FFFFFF", "control": "#D5CDDE",
                "accent": "#7E3AF2", "accentText": "#FFFFFF", "text": "#261A35",
                "secondaryText": "#635570", "selected": "#DDD4E8", "pressed": "#C5BDD0",
            ],
            dark: [
                "panel": "#1A1625", "key": "#2D243A", "control": "#221C2E",
                "accent": "#A855F7", "accentText": "#FFFFFF", "text": "#F3EEF9",
                "secondaryText": "#AFA3BF", "selected": "#4E3A63", "pressed": "#493F59",
            ]),
    ]

    public static let builtinPresetIDs: Set<String> = Set(builtinPresets.map(\.id))

    /// Built-in appearances (system default + presets): read-only, not deletable.
    public var isBuiltin: Bool { isSystemDefault || Self.builtinPresetIDs.contains(id) }

    private static func preset(
        id: String, name: String, appearance: SkinAppearance,
        light: [String: String]?, dark: [String: String]?
    ) -> AppearanceDocument {
        var skin = SkinDefinition.systemDefault
        skin.id = id
        skin.name = name
        if let light { skin.variants.light?.colors = light }
        if let dark { skin.variants.dark?.colors = dark }
        return AppearanceDocument(
            id: id, name: name, appearance: appearance, skin: skin,
            candidateBar: .systemDefault
        ).normalized()
    }
}
