import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

public struct CommonPhrase: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var shortcut: String
    public init(id: UUID = UUID(), text: String, shortcut: String = "") {
        self.id = id
        self.text = text
        self.shortcut = shortcut
    }
    public func matches(_ query: String) -> Bool {
        let value = SymbolSearch.normalize(query)
        return value.isEmpty || SymbolSearch.normalize(text).contains(value)
            || SymbolSearch.normalize(shortcut).contains(value)
    }
}

public struct LocalQuickContent: Codable, Equatable, Sendable {
    public var version = 1
    public var phrases: [CommonPhrase] = []
    public var clipboardEnabled = false
    public var clipboard: [String] = []
    public init() {}
}

/// Local-only storage. No pasteboard API, automatic capture, backup copy or clipboard export.
/// A file lock serializes host/extension read-modify-write transactions across processes.
public struct LocalQuickContentStore: Sendable {
    public static let directoryName = "LocalQuickContent"
    public static let maximumPhrases = 100
    public static let maximumHistory = 20
    public static let maximumTextBytes = 4096
    public static let maximumFileBytes = 1024 * 1024
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("content.json") }

    public func read() throws -> LocalQuickContent {
        // Missing storage is a disabled, empty state, with no write as a side effect.
        guard FileManager.default.fileExists(atPath: directory.path) else { return LocalQuickContent() }
        return try load()
    }

    @discardableResult
    public func setClipboardEnabled(_ enabled: Bool) throws -> LocalQuickContent {
        try mutate { state in
            state.clipboardEnabled = enabled
            if !enabled { state.clipboard = [] }
        }
    }

    /// Whether history can hold `text` at all; callers skip text that fails this instead of
    /// surfacing the store's rejection for a paste that already succeeded.
    public static func canRecord(_ text: String) -> Bool {
        (try? validateText(text)) != nil
    }

    /// The caller must invoke this only after an explicit paste was dispatched successfully.
    /// Returns false when disabled; oversized text is rejected whole rather than truncated.
    @discardableResult
    public func recordExplicitPaste(_ text: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: file.path), try load().clipboardEnabled else { return false }
        return try locked {
            var state = try load()
            guard state.clipboardEnabled else { return false }
            try Self.validateText(text)
            state.clipboard.removeAll { $0 == text }
            state.clipboard.insert(text, at: 0)
            state.clipboard = Array(state.clipboard.prefix(Self.maximumHistory))
            try save(state)
            return true
        }
    }

    @discardableResult
    public func clearClipboard() throws -> LocalQuickContent {
        try mutate { $0.clipboard = [] }
    }

    @discardableResult
    public func deleteClipboard(_ text: String) throws -> LocalQuickContent {
        try mutate { $0.clipboard.removeAll { $0 == text } }
    }

    @discardableResult
    public func savePhrase(_ phrase: CommonPhrase) throws -> LocalQuickContent {
        try mutate { state in
            if let index = state.phrases.firstIndex(where: { $0.id == phrase.id }) {
                state.phrases[index] = phrase
            } else {
                state.phrases.append(phrase)
            }
        }
    }

    @discardableResult
    public func deletePhrase(_ id: UUID) throws -> LocalQuickContent {
        try mutate { $0.phrases.removeAll { $0.id == id } }
    }

    /// Phrase transfers intentionally omit clipboard records and its opt-in setting.
    public func exportPhrases() throws -> Data {
        try Self.encode(PhraseArchive(phrases: read().phrases))
    }

    @discardableResult
    public func importPhrases(_ data: Data) throws -> LocalQuickContent {
        guard data.count <= Self.maximumFileBytes else { throw SymbolCatalogError("文件过大，请减少常用语后重试") }
        let archive: PhraseArchive
        do { archive = try JSONDecoder().decode(PhraseArchive.self, from: data) } catch {
            throw SymbolCatalogError("文件不完整或格式不正确，请选择松烟导出的常用语文件")
        }
        guard archive.version == 1 else { throw SymbolCatalogError("文件格式不支持，请选择松烟常用语文件") }
        try Self.validatePhrases(archive.phrases)
        return try mutate { $0.phrases = archive.phrases }
    }

    /// The caller owns security-scoped access while this bounded descriptor read runs.
    @discardableResult
    public func importPhrases(from url: URL) throws -> LocalQuickContent {
        let data = try QuickContentFileReader.read(
            url, maximumBytes: Self.maximumFileBytes,
            sizeError: "文件过大，请选择松烟常用语文件")
        return try importPhrases(data)
    }

    private struct PhraseArchive: Codable {
        var version = 1
        var phrases: [CommonPhrase]
    }

    private func mutate(_ body: (inout LocalQuickContent) throws -> Void) throws -> LocalQuickContent {
        try locked {
            var state = try load()
            try body(&state)
            try save(state)
            return state
        }
    }

    private func load() throws -> LocalQuickContent {
        guard FileManager.default.fileExists(atPath: file.path) else { return LocalQuickContent() }
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        guard size <= Self.maximumFileBytes else { throw SymbolCatalogError("保存的内容过大，请清理后重试") }
        let data = try Data(contentsOf: file)
        let state = try JSONDecoder().decode(LocalQuickContent.self, from: data)
        try Self.validate(state)
        return state
    }

    private func save(_ state: LocalQuickContent) throws {
        try Self.validate(state)
        let data = try Self.encode(state)
        guard data.count <= Self.maximumFileBytes else { throw SymbolCatalogError("保存的内容过大，请减少内容后重试") }
        #if os(iOS)
            // Readable after first unlock: the keyboard is used over a locked screen too, and
            // complete protection would make history unreadable there.
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: file, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(excluded)
        let descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SymbolCatalogError("无法打开常用语与剪贴板，请稍后重试") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw SymbolCatalogError("内容正在使用，请稍后重试") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= maximumTextBytes, !text.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw SymbolCatalogError("内容为空或超过 4 KB，请缩短后重试")
        }
    }

    private static func validatePhrases(_ phrases: [CommonPhrase]) throws {
        guard phrases.count <= maximumPhrases, Set(phrases.map(\.id)).count == phrases.count else {
            throw SymbolCatalogError("常用语最多保存 100 条，每条需要独立的编号")
        }
        for phrase in phrases {
            try validateText(phrase.text)
            guard phrase.shortcut.utf8.count <= 64 else { throw SymbolCatalogError("搜索词过长，请缩短后重试") }
        }
    }

    private static func validate(_ state: LocalQuickContent) throws {
        guard state.version == 1, state.clipboard.count <= maximumHistory,
            Set(state.clipboard).count == state.clipboard.count,
            state.clipboardEnabled || state.clipboard.isEmpty
        else {
            throw SymbolCatalogError("保存的内容无法读取，请检查文件后重试")
        }
        try validatePhrases(state.phrases)
        for text in state.clipboard { try validateText(text) }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
