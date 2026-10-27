import Foundation
import RimeKit

extension RimeEngine {
    /// Snapshot the session state into a value type and release the C copy.
    /// Rime's live schema list, copied before freeing engine-owned memory.
    public func schemaValue(_ schemaID: String, key: String) -> String? {
        queue.sync { schemaValueOnQueue(schemaID, key: key) }
    }

    /// Must run on `queue`. One `schema_open` + one `config_get_cstring`, or a
    /// memoized answer for the same (schema, key) in immutable-prebuilt mode.
    private func schemaValueOnQueue(_ schemaID: String, key: String) -> String? {
        if memoizesSchemaFacts, let cached = schemaFacts.strings[schemaID]?[key] { return cached.value }
        guard let values = schemaStringsOnQueue(schemaID, keys: [key]) else { return nil }
        let value = values[key]
        if memoizesSchemaFacts {
            schemaFacts.strings[schemaID, default: [:]][key] = RimeCachedSchemaString(value: value)
        }
        return value
    }

    /// Must run on `queue`. Opens the schema config **once** and copies every
    /// requested key out of that single snapshot, so a component-list read costs
    /// one `schema_open` instead of one per component. `nil` means the schema
    /// config could not be opened at all; keys missing from a non-nil result are
    /// absent keys, exactly as `schemaValue` reports them.
    func schemaStringsOnQueue(_ schemaID: String, keys: [String]) -> [String: String]? {
        guard !keys.isEmpty, engine != nil, let api = rime_get_api() else { return nil }
        var config = RimeConfig()
        guard schemaID.withCString({ api.pointee.schema_open($0, &config) }) != 0 else { return nil }
        defer { _ = api.pointee.config_close(&config) }
        var values: [String: String] = [:]
        values.reserveCapacity(keys.count)
        for key in keys {
            if let value = key.withCString({ string(fromC: api.pointee.config_get_cstring(&config, $0)) }) {
                values[key] = value
            }
        }
        return values
    }

    public func schemaComponents(_ schemaID: String) -> [String] {
        queue.sync {
            if memoizesSchemaFacts, let cached = schemaFacts.components[schemaID] { return cached }
            // Every candidate key of every section is requested in one call, so
            // the whole component list is built from a single `schema_open`.
            guard let values = schemaStringsOnQueue(schemaID, keys: Self.componentKeys) else { return [] }
            let components = Self.componentList { values[$0] }
            if memoizesSchemaFacts { schemaFacts.components[schemaID] = components }
            return components
        }
    }

    /// Component sections and per-section probe bound, in output order.
    static let componentSections = ["processors", "segmentors", "translators", "filters"]
    static let componentProbeLimit = 256
    /// Every `engine/<section>/@<index>` key a component read may consult, in the
    /// order the list is assembled.
    static var componentKeys: [String] {
        componentSections.flatMap { section in
            (0..<componentProbeLimit).map { "engine/\(section)/@\($0)" }
        }
    }

    /// Pure assembly of a schema's engine component list from one key-lookup
    /// closure. A nil answer ends that section, exactly like the original
    /// per-index `break`; sections are concatenated in declaration order.
    static func componentList(lookup: (String) -> String?) -> [String] {
        var components: [String] = []
        for section in componentSections {
            for index in 0..<componentProbeLimit {
                guard let name = lookup("engine/\(section)/@\(index)") else { break }
                components.append(name)
            }
        }
        return components
    }

    /// Actual runtime registry lookup after start(), not a symbol-name or config-field heuristic.
    public func hasModule(_ name: String) -> Bool {
        queue.sync {
            guard engine != nil, let api = rime_get_api() else { return false }
            return name.withCString { api.pointee.find_module($0) != nil }
        }
    }

    public func grammarDiagnostics() throws -> RimeGrammarDiagnostics {
        try queue.sync {
            guard engine != nil else { throw RimeEngineError.notStarted }
            guard let json = rb_grammar_diagnostics_json() else {
                throw RimeEngineError.operationFailed("无法获取语法模型诊断信息")
            }
            defer { rb_grammar_diagnostics_free(json) }
            return try JSONDecoder().decode(RimeGrammarDiagnostics.self, from: Data(String(cString: json).utf8))
        }
    }

    /// Unified install/runtime gate for EACH enabled schema. Selects the target on success;
    /// caller owns the engine lease and chooses the final entry schema after iterating.
    /// Uses the actual registry, compiled dependency closure and live grammar instance.
    public func validateSchemaForActivation(schemaID: String) throws {
        try validateSchemaPrerequisites(schemaID: schemaID)
        guard selectSchema(schemaID) else { throw RimeEngineError.operationFailed("输入方式无法启用：\(schemaID)") }
        try validateGrammarLoaded(schemaID: schemaID)
    }

    /// Side-effect-free capability check for source-scoped menus. Does not select a
    /// schema or consume composition, and does not claim a live grammar instance.
    public func validateSchemaPrerequisites(schemaID: String) throws {
        try validateSchemaDependencies(schemaID: schemaID)
        let missing = unavailableComponents(schemaID: schemaID)
        guard let component = missing.first else {
            try validateGrammarRequirements(schemaID: schemaID)
            return
        }
        throw RimeEngineError.operationFailed("引擎组件不可用：\(component)")
    }

    /// Query the live registry, not a bundled capability list or schema-name heuristic.
    public func unavailableComponents(schemaID: String) -> [String] {
        schemaComponents(schemaID).filter { component in
            let name = String(component.split(separator: "@", omittingEmptySubsequences: false).first ?? "")
            return !queue.sync { engine != nil && name.withCString { rb_component_available($0) != 0 } }
        }
    }

    /// Call after selecting the target schema. Checks its Config against a live Octagram
    /// attached only after successful GramDb::Load, removed at instance destruction.
    public func validateGrammarLoaded(schemaID: String) throws {
        _ = try loadedGrammarLanguage(schemaID: schemaID)
    }

    /// Returns the configured language only after the current live session has an Octagram
    /// instance associated with that exact model file. `nil` means the schema does not request
    /// grammar; a configured-but-unloaded model throws and must never become a success receipt.
    public func loadedGrammarLanguage(schemaID: String) throws -> String? {
        try validateGrammarRequirements(schemaID: schemaID)
        guard let language = schemaValue(schemaID, key: "grammar/language"), !language.isEmpty else { return nil }
        guard currentSchemaID == schemaID else { throw RimeEngineError.operationFailed("语法模型验证目标不是当前正在使用的输入方式") }
        let paths = [configuration.userDirectory, configuration.sharedDirectory].map {
            $0.appendingPathComponent(language + ".gram")
        }
        guard let expected = paths.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw RimeEngineError.operationFailed("找不到语法模型文件")
        }
        let canonical = expected.resolvingSymlinksInPath().standardizedFileURL.path
        let associated: Bool = queue.sync { () -> Bool in
            guard engine != nil, session != 0 else { return false }
            return canonical.withCString { rb_grammar_session_loaded(session, $0) != 0 }
        }
        guard associated else {
            throw RimeEngineError.operationFailed("\(language) 语法模型未能成功加载")
        }
        return language
    }

    /// Mandatory prerequisite check for configured grammar. Passing this is NOT proof of model
    /// loading or ranking effects; a grammar-capable build still needs a behavioural/load probe.
    public func validateGrammarRequirements(schemaID: String) throws {
        try queue.sync { guard engine != nil else { throw RimeEngineError.notStarted } }
        guard let language = schemaValue(schemaID, key: "grammar/language"), !language.isEmpty else { return }
        guard hasModule("grammar") || hasModule("octagram") else {
            throw RimeEngineError.operationFailed("\(schemaID) 设置了语法模型 \(language)，但当前输入引擎未启用语法模型支持")
        }
        guard
            language.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":")
                    && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            })
        else { throw RimeEngineError.operationFailed("找不到语法模型文件或路径不支持：\(language).gram") }
        let sharedModel = configuration.sharedDirectory.appendingPathComponent(language + ".gram")
        let userModel = configuration.userDirectory.appendingPathComponent(language + ".gram")
        guard
            FileManager.default.fileExists(atPath: sharedModel.path)
                || FileManager.default.fileExists(atPath: userModel.path)
        else {
            throw RimeEngineError.operationFailed("找不到语法模型文件或路径不支持：\(language).gram")
        }
    }

    /// Host installer preparation. librime's workspace update compiles direct
    /// dependencies, but does not necessarily compile their transitive closure
    /// (luna_pinyin_simp -> stroke -> luna_pinyin -> stroke is a real example).
    /// Compile missing companions without enabling them in schema_list. Read-only
    /// activation validation below still requires every compiled dependency.
    public func prepareSchemaDependencyClosure(schemaIDs: [String]) throws {
        guard configuration.prebuiltDirectory == nil else {
            throw RimeEngineError.operationFailed("dependency compilation requires a host deployment engine")
        }
        let fm = FileManager.default
        let build = configuration.userDirectory.appendingPathComponent("build")
        var visited = Set<String>()
        func visit(_ id: String) throws {
            guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), !id.contains("..") else {
                throw RimeEngineError.operationFailed("输入方案依赖无效：\(id)")
            }
            guard visited.insert(id).inserted else { return }
            guard visited.count <= 256 else { throw RimeEngineError.operationFailed("输入方案依赖项过多（超过 256 项）") }
            if !fm.fileExists(atPath: build.appendingPathComponent(id + ".schema.yaml").path) {
                let sources = [configuration.userDirectory, configuration.sharedDirectory]
                    .map { $0.appendingPathComponent(id + ".schema.yaml") }
                guard let source = sources.first(where: { fm.fileExists(atPath: $0.path) }) else {
                    throw RimeEngineError.operationFailed("缺少配套方案文件：\(id).schema.yaml")
                }
                try deploySchemaFile(source)
            }
            for dependency in schemaStringList(id, key: "schema/dependencies") ?? [] { try visit(dependency) }
        }
        for id in schemaIDs { try visit(id) }
        for id in schemaIDs { try validateSchemaDependencies(schemaID: id) }
    }

    /// Deployment can report success while an auxiliary schema failed to compile. Check the
    /// declared compiled dependency closure as well as the main schema; do not enable source-only entries.
    public func validateSchemaDependencies(schemaID: String) throws {
        let build = configuration.prebuiltDirectory ?? configuration.userDirectory.appendingPathComponent("build")
        var visited = Set<String>()
        func visit(_ id: String) throws {
            guard visited.insert(id).inserted else { return }
            guard !id.isEmpty, !id.contains("/"), !id.contains(".."),
                FileManager.default.fileExists(atPath: build.appendingPathComponent(id + ".schema.yaml").path),
                schemaValue(id, key: "schema/schema_id") == id
            else {
                throw RimeEngineError.operationFailed("输入方案或配套依赖未成功准备：\(id)")
            }
            for dependency in schemaStringList(id, key: "schema/dependencies") ?? [] { try visit(dependency) }
        }
        try visit(schemaID)
    }

    /// Copies an effective scalar list from the deployed config. nil means absent/non-list or
    /// non-scalar items; [] means a real empty list. Useful for auditing speller/algebra without
    /// interpreting recipes, modifying custom patches, or assuming that select_schema configured dependencies.
    public func schemaStringList(_ schemaID: String, key: String) -> [String]? {
        queue.sync {
            if memoizesSchemaFacts, let cached = schemaFacts.lists[schemaID]?[key] { return cached.value }
            let value = schemaStringListOnQueue(schemaID, key: key)
            if memoizesSchemaFacts, let value {
                schemaFacts.lists[schemaID, default: [:]][key] = RimeCachedSchemaList(value: value)
            }
            return value
        }
    }

    /// Must run on `queue`. One `schema_open` for the whole list read. Only a
    /// successfully opened list is memoized (an unopenable/missing key stays
    /// re-readable, so a transient failure is never frozen as "absent").
    func schemaStringListOnQueue(_ schemaID: String, key: String) -> [String]? {
        guard engine != nil, let api = rime_get_api() else { return nil }
        var config = RimeConfig()
        guard schemaID.withCString({ api.pointee.schema_open($0, &config) }) != 0 else { return nil }
        defer { _ = api.pointee.config_close(&config) }
        var iterator = RimeConfigIterator()
        guard key.withCString({ api.pointee.config_begin_list(&iterator, &config, $0) }) != 0 else { return nil }
        defer { api.pointee.config_end(&iterator) }
        var values: [String] = []
        while api.pointee.config_next(&iterator) != 0 {
            guard let path = iterator.path, let value = api.pointee.config_get_cstring(&config, path) else {
                return nil
            }
            values.append(String(cString: value))
        }
        return values
    }

    public func schemas() -> [(id: String, name: String)] {
        queue.sync {
            guard engine != nil, let api = rime_get_api() else { return [] }
            var list = RimeSchemaList()
            guard api.pointee.get_schema_list(&list) != 0 else { return [] }
            defer { api.pointee.free_schema_list(&list) }
            guard let items = list.list else { return [] }
            return (0..<Int(list.size)).map {
                (String(cString: items[$0].schema_id), String(cString: items[$0].name))
            }
        }
    }
}
