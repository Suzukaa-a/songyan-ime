import Foundation
import KeyboardCore
import RimeKit
import os

/// Cross-process handoff contains immutable deployed resources, never a live user database.
public enum KeyboardRecipeStore {
    public enum ResourceKind: String, Codable, Sendable {
        case userDictionary, userScheme
    }

    /// The structured roster key of a source (the dictionary key of the cross-source keyboard cache).
    ///
    /// The key is built only from the structured source identity and never contains a schema name,
    /// brand, recipe, path or hash. Validity and format are defined in one place by
    /// `PublishedKeyboardSourceKey` (KeyboardCore); non-ASCII/Chinese package identities admitted at
    /// install time work too (the key is only a dictionary key, not a disk path). Returns nil when the identity is missing.
    public static func rosterKey(kind: ResourceKind, packageID: String?) -> String? {
        switch kind {
        case .userDictionary: return KeyboardPublicationSource.userDictionary.cacheKey
        case .userScheme:
            guard let packageID else { return nil }
            return KeyboardPublicationSource.userScheme(packageID: packageID).cacheKey
        }
    }

    /// Roster key for a structured source identity (same format as `rosterKey(kind:packageID:)`).
    public static func rosterKey(_ source: KeyboardPublicationSource) -> String? {
        source.cacheKey
    }

    public struct Activation: Codable, Equatable, Sendable {
        public let generation: String
        public let revision: String
        public var recipeEnabled: Bool
        public let publishedAt: Date
        public var resourceKind: ResourceKind
        public var dictionaryName: String? = nil
        public var packageID: String? = nil
        public var schemas: [KeyboardSchemaDescriptor]? = nil
        public var selectedSchemaID: String? = nil
        public var selectedLayout: KeyboardLayoutKind? = nil
        public var schemaBindings: [KeyboardResourceSet.LayoutEntry]? = nil
        public var hostInstallationGeneration: String? = nil
        /// The "user keyboards" list that has been added (publication unit = input method + layout).
        /// nil means no keyboard has been added; combinations are never invented from the selection.
        /// The extension only reads it to build the switch list.
        public var publishedKeyboards: [PublishedKeyboard]? = nil
        /// The full keyboard list last successfully published for each source (key = structured source identity, see `rosterKey`).
        ///
        /// `publishedKeyboards` is always only the current source's list (so the extension's runtime
        /// validation sees only this source and never mixes in others); this field additionally keeps
        /// the full lists of other sources as the authoritative baseline when switching back to an
        /// earlier source.
        public var keyboardsBySource: [String: [PublishedKeyboard]]? = nil
        /// Explicit auxiliary English candidate routes, each owned by one exact published pair.
        /// Never inferred from enabled dependencies.
        public var englishCandidateRoutes: [EnglishCandidateRoute]? = nil
        public var kind: ResourceKind { resourceKind }
        /// Source display name (not the input-method name).
        public var name: String {
            dictionaryName ?? packageID ?? "用户方案"
        }
        /// Configuration-level display name (home page / scheme list): an imported dictionary maps to
        /// the "custom pinyin" configuration, and the dictionary name (a resource name, possibly any
        /// English file name from the user) is not used as the configuration name.
        /// Source identity and input method are separate dimensions: this property only gives the source name.
        public var displayConfigName: String {
            switch kind {
            case .userDictionary: return "自定义拼音"
            case .userScheme: return dictionaryName ?? packageID ?? "用户方案"
            }
        }
        /// Display name of the current input method (schema), separate from the source name.
        public var inputMethodDisplayName: String? {
            UserTerminology.inputMethodName(
                schemaID: selectedSchemaID ?? requiredSchemaIDs.first,
                schemas: schemas)
        }
        /// One authoritative OptionStore namespace, shared by Host settings and every runtime.
        public var resourceID: String {
            switch kind {
            case .userDictionary: return "user-pinyin"
            case .userScheme: return packageID ?? generation
            }
        }
        public var requiredSchemaIDs: [String] { schemas?.map(\.id) ?? [] }

        /// The published keyboard list (the only source for the extension's switch list).
        public var keyboards: [PublishedKeyboard] {
            PublishedKeyboard.resolve(published: publishedKeyboards)
        }

        /// Whether this record forces showing only added keyboards: true with an explicit list or a
        /// selection; a record with neither (built-in pinyin) keeps every bundled combination.
        public var enforcesPublishedKeyboards: Bool {
            publishedKeyboards != nil || selectedSchemaID != nil
        }

        /// The structured source identity (provenance) of the record. Used to decide publication
        /// ownership when an install is deleted; never guessed from schema strings. nil when no valid identity can be formed (e.g. a userScheme without a package identity).
        public var publicationSource: KeyboardPublicationSource? {
            switch kind {
            case .userDictionary: return .userDictionary
            case .userScheme:
                guard let packageID, !packageID.isEmpty else { return nil }
                return .userScheme(packageID: packageID)
            }
        }

        /// The structured roster key of this record's source: `kind` + `packageID` (unique, stable,
        /// independent of path/name). nil when no valid identity can be formed (no cross-source list is recorded then, and keys are never guessed).
        public var rosterKey: String? {
            KeyboardRecipeStore.rosterKey(kind: kind, packageID: packageID)
        }

        /// A copy of the same publication record with a different enabled state: keeps all publication
        /// metadata (generation / revision / source identity / `schemas` / selection / bindings / added
        /// keyboard list, ...) and changes only `recipeEnabled`. Never rebuild field by field (that would drop fields such as `publishedKeyboards`).
        public func withEnabled(_ enabled: Bool) -> Activation {
            var copy = self
            copy.recipeEnabled = enabled
            return copy
        }
    }

    public struct Snapshot {
        public let activation: Activation
        public let resources: URL
        public let build: URL
        /// Stable runtime identity carried by the publication snapshot. Callers should
        /// preserve this value rather than reconstructing identity from a path spelling.
        public var selectionRuntimeIdentity: SelectionRuntimeIdentity {
            .published
        }
        public func resourceSet(userDirectory: URL) -> KeyboardResourceSet {
            if let selected = activation.selectedSchemaID {
                let templateBindings: [KeyboardResourceSet.LayoutEntry]
                switch activation.kind {
                case .userDictionary:
                    templateBindings = BuiltinTemplateSchemas.layoutEntries
                case .userScheme: templateBindings = []
                }
                return KeyboardResourceSet(
                    id: activation.resourceID,
                    name: activation.name, sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: activation.schemaBindings ?? templateBindings, prebuiltDirectory: build,
                    schemas: activation.schemas ?? activation.requiredSchemaIDs.map { .init(id: $0, name: $0) },
                    selectedSchemaID: selected, preferredLayout: activation.selectedLayout,
                    sourceRevision: activation.revision, publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            }
            switch activation.kind {
            case .userDictionary:
                return KeyboardResourceSet(
                    id: activation.resourceID, name: activation.name,
                    sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: BuiltinTemplateSchemas.layoutEntries,
                    prebuiltDirectory: build, schemas: activation.schemas ?? [],
                    sourceRevision: activation.revision, publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            case .userScheme:
                return KeyboardResourceSet(
                    id: activation.resourceID, name: activation.name,
                    sharedDirectory: resources, userDirectory: userDirectory,
                    layoutEntries: activation.schemaBindings ?? [], prebuiltDirectory: build,
                    schemas: activation.schemas ?? [], selectedSchemaID: activation.selectedSchemaID,
                    preferredLayout: activation.selectedLayout, sourceRevision: activation.revision,
                    publicationGeneration: activation.generation,
                    publishedKeyboards: activation.enforcesPublishedKeyboards ? activation.keyboards : nil,
                    englishCandidateRoutes: activation.englishCandidateRoutes ?? [])
            }
        }
    }

    public struct StoreError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Resolves the App Group container and creates the recipe directory. Writers use this; readers use `readRoot()`.
    public static func root() throws -> URL {
        guard let container = sharedContainerURL() else {
            throw StoreError(message: "无法访问共享数据，请在系统设置中开启「允许完全访问」")
        }
        let root = container.appendingPathComponent("KeyboardRecipes", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw StoreError(message: "共享存储空间无法读写，请检查存储权限与设备可用空间")
        }
        return root
    }

    /// Process-level cached root for read-only paths: does not call `root()`, which creates directories.
    /// Caches only a successfully resolved system App Group URL; when the container is unavailable it is re-evaluated next time.
    private static let cachedReadRoot = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static func readRoot() throws -> URL {
        if let cached = cachedReadRoot.withLock({ $0 }) { return cached }
        guard let container = sharedContainerURL() else {
            throw StoreError(message: "无法访问共享数据，请在系统设置中开启「允许完全访问」")
        }
        let resolved = container.appendingPathComponent("KeyboardRecipes", isDirectory: true)
        cachedReadRoot.withLock { $0 = resolved }
        return resolved
    }

    /// One bounded read of the shared `active.json`; `snapshot(selection:)` parses these same bytes.
    public struct SelectionRead: Sendable {
        public let root: URL?
        /// The bytes read; nil when absent or unreadable.
        public let data: Data?
        /// Why the read failed (never silently treated as absent).
        public let readError: String?
        /// The container is readable and `active.json` does not exist.
        public var isAbsent: Bool { root != nil && data == nil && readError == nil }
    }

    public static func readSelection(rootURL: URL? = nil) -> SelectionRead {
        let root: URL
        do {
            root = try rootURL ?? readRoot()
        } catch {
            return SelectionRead(
                root: nil, data: nil,
                readError: "共享存储空间不可用：\(error.localizedDescription)")
        }
        let active = root.appendingPathComponent("active.json")
        switch BoundedFileRead.read(active) {
        case .success(let data):
            return SelectionRead(root: root, data: data, readError: nil)
        case .failure(.missing):
            return SelectionRead(root: root, data: nil, readError: nil)
        case .failure(.tooLarge(let size)):
            return SelectionRead(
                root: root, data: nil,
                readError: "输入方案配置过大（\(size) 字节），已取消读取")
        case .failure(.unreadable(let detail)):
            return SelectionRead(
                root: root, data: nil,
                readError: "输入方案配置无法读取：\(detail)")
        }
    }

    /// Whether the record still names the running engine's generation, input method and
    /// layout. Any missing field or decode failure returns false, so the caller re-resolves.
    public static func selection(_ selection: SelectionRead, matches running: KeyboardRouteKey) -> Bool {
        guard selection.readError == nil, let data = selection.data,
            let activation = try? JSONDecoder().decode(Activation.self, from: data),
            activation.recipeEnabled, !activation.generation.isEmpty,
            activation.generation == running.publicationGeneration,
            let source = activation.selectedSchemaID, source == running.sourceSchemaID,
            let layout = activation.selectedLayout, layout == running.layout
        else { return false }
        return true
    }

    public static func snapshot(selection: SelectionRead, selectedOnly: Bool = false) throws -> Snapshot? {
        if let readError = selection.readError {
            throw StoreError(message: "无法读取已保存的输入方案配置：\(readError)")
        }
        guard let root = selection.root, let data = selection.data else { return nil }
        // Single production resolve path: parse from the same immutable active.json bytes (identity and content share one source).
        let activation = try JSONDecoder().decode(Activation.self, from: data)
        if selectedOnly && !activation.recipeEnabled { return nil }
        if activation.generation.isEmpty && !activation.recipeEnabled { return nil }
        return try snapshot(for: activation, root: root)
    }

    /// active.json is the only persisted selection, shared by host and keyboard.
    /// A builtin selection before first publication uses an empty generation.
    ///
    /// Reads use the cached `readRoot()`; writers call `root()`.
    public static func activation(rootURL: URL? = nil) throws -> Activation? {
        let root = try rootURL ?? readRoot()
        let active = root.appendingPathComponent("active.json")
        // Same bounded read as `readSelection`: keyboard extension memory is limited, so an abnormally large shared file is not read whole into memory.
        switch BoundedFileRead.read(active) {
        case .success(let data):
            return try JSONDecoder().decode(Activation.self, from: data)
        case .failure(.missing):
            return nil
        case .failure(let error):
            throw StoreError(message: "无法读取已保存的输入方案配置：\(error)")
        }
    }

    /// The record a write starts from. A damaged or unreadable record counts as missing, so
    /// switching to built-in or publishing a scheme replaces it instead of failing on it.
    public static func writeBaseline(rootURL: URL? = nil) throws -> Activation? {
        let root = try rootURL ?? readRoot()
        return (try? activation(rootURL: root)) ?? nil
    }

    public static func snapshot(rootURL: URL? = nil, selectedOnly: Bool = false) throws -> Snapshot? {
        let root = try rootURL ?? readRoot()
        guard let activation = try activation(rootURL: root) else { return nil }
        if selectedOnly && !activation.recipeEnabled { return nil }
        if activation.generation.isEmpty && !activation.recipeEnabled { return nil }
        return try snapshot(for: activation, root: root)
    }

    static func snapshot(for activation: Activation, root: URL) throws -> Snapshot {
        var activation = activation
        guard !activation.generation.isEmpty,
            activation.generation.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw StoreError(message: "输入方案版本标识格式无效")
        }
        let version = root.appendingPathComponent("versions/\(activation.generation)")
        let resources = version.appendingPathComponent("resources")
        let build = resources.appendingPathComponent("build")
        activation.schemas = try resolvedSchemas(activation.schemas, build: build)
        return Snapshot(activation: activation, resources: resources, build: build)
    }

    /// Without schema metadata only the deployed default is authoritative, never layout aliases
    /// or the set of compiled dependency files. Nonempty publication metadata stays restrictive.
    static func resolvedSchemas(_ metadata: [KeyboardSchemaDescriptor]?, build: URL) throws
        -> [KeyboardSchemaDescriptor]
    {
        // Private Config object: no global config_open, engine startup, deployment or select.
        let yaml = try String(contentsOf: build.appendingPathComponent("default.yaml"), encoding: .utf8)
        guard let api = rime_get_api() else { throw StoreError(message: "Rime 配置接口不可用") }
        var config = RimeConfig()
        defer { _ = api.pointee.config_close(&config) }
        guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else {
            throw StoreError(message: "方案默认配置文件（default.yaml）解析失败，请重新安装输入方案")
        }
        let count = Int(api.pointee.config_list_size(&config, "schema_list"))
        let ids: [String] = (0..<count).compactMap { index in
            "schema_list/@\(index)/schema".withCString { key in
                api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
            }
        }
        guard !ids.isEmpty, ids.count == count, Set(ids).count == ids.count,
            ids.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") })
        else {
            throw StoreError(message: "方案默认配置中缺少有效的方案列表，请重新安装输入方案")
        }
        let result = (metadata?.isEmpty == false) ? metadata! : ids.map { .init(id: $0, name: $0) }
        guard Set(result.map(\.id)).count == result.count,
            result.allSatisfy({ ids.contains($0.id) })
        else {
            throw StoreError(message: "已添加的键盘与方案默认配置不一致，请重新选择")
        }
        return result
    }

    static func deployedSchemas(build: URL) throws -> [KeyboardSchemaDescriptor] {
        let enabled = try resolvedSchemas(nil, build: build)
        guard let api = rime_get_api() else { throw StoreError(message: "Rime 配置接口不可用") }
        return try enabled.map { entry in
            let yaml = try String(contentsOf: build.appendingPathComponent(entry.id + ".schema.yaml"), encoding: .utf8)
            var config = RimeConfig()
            defer { _ = api.pointee.config_close(&config) }
            guard yaml.withCString({ api.pointee.config_load_string(&config, $0) }) != 0 else {
                throw StoreError(message: "无法读取输入方案：\(entry.id)")
            }
            let name = api.pointee.config_get_cstring(&config, "schema/name").map { String(cString: $0) } ?? entry.id
            let alphabet = api.pointee.config_get_cstring(&config, "speller/alphabet").map { String(cString: $0) } ?? ""
            return KeyboardSchemaDescriptor(id: entry.id, name: name, alphabet: alphabet)
        }
    }
}

/// Sorted keys keep the encoded bytes of dictionary-bearing records identical across processes.
func canonicalJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}
