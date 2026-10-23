import Foundation

/// A failure shown next to the import/editor UI; the message names the offending field.
public struct ShuangpinHintError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Bounded JSON reading for hint documents.
///
/// Imported files are rejected whole, with the offending field named, rather than partially
/// accepted into a preset that only looks complete.
public enum ShuangpinHintDocument {
    public static let maximumBytes = 256 * 1024

    static func checkSize(_ data: Data, _ label: String) throws {
        guard data.count <= maximumBytes else {
            throw ShuangpinHintError("\(label)过大：请控制在 \(maximumBytes / 1024) KB 以内。")
        }
    }

    static func object(_ data: Data, _ label: String, _ malformed: String) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data), let object = root as? [String: Any] else {
            throw ShuangpinHintError("\(label)无法读取：\(malformed)。")
        }
        return object
    }

    /// Unknown fields are refused: a typo in a hand-written file must not be silently dropped.
    static func rejectUnknownKeys(_ object: [String: Any], allowed: Set<String>) throws {
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ShuangpinHintError("提示文件里有不支持的字段「\(unknown)」，请检查文件。")
        }
    }

    /// `label` is the field's everyday name; the raw `key` is added only so a hand-written file can
    /// be located.
    static func string(_ value: Any?, _ label: String, key: String, required: Bool) throws -> String? {
        guard let value else {
            if required { throw ShuangpinHintError("提示文件缺少「\(label)」（\(key)），请填写后再导入。") }
            return nil
        }
        guard let text = value as? String else {
            throw ShuangpinHintError("提示文件里的「\(label)」需要是文字（\(key)）。")
        }
        return text
    }

    /// JSON numbers only: JSONSerialization bridges true/false to NSNumber too, so a plain
    /// "as? Int" would accept "version": true as 1.
    static func int(_ value: Any?, _ label: String, key: String) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
            number.doubleValue == number.doubleValue.rounded()
        else {
            throw ShuangpinHintError("提示文件里的「\(label)」需要是整数（\(key)）。")
        }
        return number.intValue
    }

    /// JSON booleans only: a number is refused here, not coerced.
    static func bool(_ value: Any?, _ label: String, key: String) throws -> Bool? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ShuangpinHintError("提示文件里的「\(label)」需要填 true 或 false（\(key)）。")
        }
        return number.boolValue
    }
}

/// One named set of shuangpin key hints for the standard 26-key letters page: one letter maps to
/// a short annotation drawn as the keycap subtitle.
///
/// Display data only; it never changes a key action, the engine input or a layout structure. The
/// letter is the data key ("q": "iu"), so a hand-written, exported and downloaded file are the
/// same document.
public struct ShuangpinHintPreset: Codable, Equatable, Sendable, Identifiable {
    /// Format version of a single preset document; an unknown version is refused.
    public static let currentVersion = 1
    /// One annotation per letter of the standard letters page.
    public static let maximumHints = 26
    /// A keycap hint is a corner annotation on a phone key. The renderer wraps at most two lines
    /// and truncates beyond that, so the format refuses text that could never be read anyway.
    public static let maximumHintBytes = 16
    public static let maximumIDBytes = 64
    public static let maximumNameBytes = 128

    /// The standard 26-key letters page: the only surface hints are drawn on.
    public static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    public static let letters: [String] = letterRows.flatMap { row in row.map(String.init) }

    public var version: Int
    public var id: String
    public var name: String
    /// Letter (single lowercase ASCII a-z) to short annotation. A missing or empty entry means
    /// "no hint on this key"; blank entries are dropped by normalization, never drawn as an
    /// empty badge.
    public var hints: [String: String]

    public init(id: String, name: String, hints: [String: String], version: Int = currentVersion) {
        self.version = version
        self.id = id
        self.name = name
        self.hints = hints
    }

    public var letterCount: Int { hints.count }

    // MARK: - Validation

    /// Idempotent: keys lowercased, blank annotations dropped. Dictionary order is not significant.
    public func normalized() -> Self {
        var value = self
        var result: [String: String] = [:]
        for (key, text) in hints {
            let letter = key.lowercased()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result[letter] = trimmed
        }
        value.hints = result
        return value
    }

    public func validate() throws {
        try check(version == Self.currentVersion, "版本", "只支持版本 \(Self.currentVersion)")
        try check(
            !id.isEmpty && id.utf8.count <= Self.maximumIDBytes,
            "标识", "必填且不超过 \(Self.maximumIDBytes) 字节")
        try check(
            id.unicodeScalars.allSatisfy { Self.idCharacters.contains($0) },
            "标识", "只能用英文字母、数字、短横线和下划线")
        try check(
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && name.utf8.count <= Self.maximumNameBytes,
            "名称", "必填且不超过 \(Self.maximumNameBytes) 字节")
        try check(hints.count <= Self.maximumHints, "提示条目", "最多 \(Self.maximumHints) 条")
        for (key, text) in hints {
            try check(Self.isSingleLetter(key), "提示条目 \(key)", "键名必须是一个英文字母 a-z")
            try check(key == key.lowercased(), "提示条目 \(key)", "键名请用小写字母")
            try check(
                text.utf8.count <= Self.maximumHintBytes,
                "提示条目 \(key)", "内容不超过 \(Self.maximumHintBytes) 字节")
            // Scalars, not Characters: "\r\n" is a single Character and would slip past contains("\n").
            try check(
                !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0.value == 0 }),
                "提示条目 \(key)", "内容不能换行")
        }
    }

    private static let idCharacters = CharacterSet(
        charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    static func isSingleLetter(_ key: String) -> Bool {
        key.count == 1 && key.unicodeScalars.count == 1
            && key.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
    }

    private func check(_ condition: Bool, _ field: String, _ reason: String) throws {
        guard condition else { throw ShuangpinHintError("提示文件「\(field)」无法使用：\(reason)。") }
    }

    // MARK: - Reading and writing

    /// Strict decode of one preset document; unknown fields and wrong versions are refused.
    public static func decode(_ data: Data) throws -> Self {
        try ShuangpinHintDocument.checkSize(data, "提示文件")
        let root = try ShuangpinHintDocument.object(data, "提示文件", "请选择提示预设文件")
        try ShuangpinHintDocument.rejectUnknownKeys(root, allowed: ["version", "id", "name", "hints"])
        let version = try ShuangpinHintDocument.int(root["version"], "版本", key: "version") ?? currentVersion
        let id = try ShuangpinHintDocument.string(root["id"], "标识", key: "id", required: true) ?? ""
        let name = try ShuangpinHintDocument.string(root["name"], "名称", key: "name", required: true) ?? ""
        let preset = ShuangpinHintPreset(
            id: id, name: name,
            hints: try decodeHints(root["hints"]), version: version
        ).normalized()
        try preset.validate()
        return preset
    }

    public func encoded() throws -> Data {
        let value = normalized()
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try ShuangpinHintDocument.checkSize(data, "提示文件")
        return data
    }

    /// Hint keys are data, not schema: each is checked as a letter, and two keys differing only by
    /// case are refused instead of merged.
    private static func decodeHints(_ value: Any?) throws -> [String: String] {
        guard let value else { return [:] }
        guard let object = value as? [String: Any] else {
            throw ShuangpinHintError("提示文件「提示内容」无法使用：需要一张「字母：提示」表。")
        }
        guard object.count <= maximumHints else {
            throw ShuangpinHintError("提示文件「提示内容」无法使用：最多 \(maximumHints) 条。")
        }
        var result: [String: String] = [:]
        for (rawKey, rawValue) in object {
            let lowered = rawKey.lowercased()
            guard isSingleLetter(lowered), rawKey.unicodeScalars.count == 1 else {
                throw ShuangpinHintError("提示文件「\(rawKey)」无法使用：键名必须是一个英文字母 a-z。")
            }
            guard result[lowered] == nil else {
                throw ShuangpinHintError("提示文件「\(rawKey)」无法使用：同一个字母只写一次。")
            }
            guard let text = rawValue as? String else {
                throw ShuangpinHintError("提示文件「\(rawKey)」无法使用：提示内容需要文字。")
            }
            result[lowered] = text
        }
        return result
    }

    /// A user-editable copy: new identity, same hints.
    public func copy(name: String? = nil) -> Self {
        ShuangpinHintPreset(
            id: UUID().uuidString.lowercased(),
            name: name ?? self.name + " 副本", hints: hints)
    }

    public func renamed(_ newName: String) -> Self {
        var value = self
        value.name = newName
        return value
    }
}
