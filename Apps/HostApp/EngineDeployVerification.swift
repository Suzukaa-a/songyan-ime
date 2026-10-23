import Foundation
import KeyboardCore
import PackageManager
import RimeBridge

struct SkippedEngineSchema: Codable, Sendable {
    let id: String
    let name: String?
    let components: [String]

    var notice: String { "「\(name ?? "未命名输入方式")」需要松烟暂不支持的功能，已跳过" }
}

enum EngineSchemaSelection {
    static let reportName = "keyboard-skipped-schemas.json"

    static func start(_ deployment: RecipeDeployment) throws -> (RimeEngine, [String], [SkippedEngineSchema]) {
        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: deployment.resourceURL,
                userDirectory: deployment.userDataURL))
        do {
            try engine.start()
            let original = engine.schemas().map(\.id)
            guard !original.isEmpty else { throw RecipeInstallError.deployment("引擎未找到可用的输入方式") }
            let skipped = original.compactMap { id -> SkippedEngineSchema? in
                let missing = engine.unavailableComponents(schemaID: id)
                return missing.isEmpty
                    ? nil
                    : SkippedEngineSchema(
                        id: id,
                        name: engine.schemaValue(id, key: "schema/name") ?? "未命名输入方式", components: missing)
            }
            guard !skipped.isEmpty else { return (engine, original, []) }
            let omitted = Set(skipped.map(\.id))
            let kept = original.filter { !omitted.contains($0) }
            guard !kept.isEmpty else {
                throw RecipeInstallError.missingComponents(Array(Set(skipped.flatMap(\.components))).sorted())
            }
            engine.shutdown()
            try SupportedSchemaSelection.stage(kept, deployment: deployment)
            try engine.start()
            let actual = engine.schemas().map(\.id)
            guard Set(actual) == Set(kept), actual.count == kept.count else {
                throw RecipeInstallError.deployment("安装配置后启用的输入方式与预期不一致")
            }
            try JSONEncoder().encode(skipped).write(
                to: deployment.resourceURL.appendingPathComponent(reportName), options: .atomic)
            return (engine, actual, skipped)
        } catch {
            engine.shutdown()
            throw error
        }
    }
}

/// Deploy verification for an imported dictionary (the deploy callback of RecipePackageManager):
/// starts the real RimeBridge engine on the staging directories and proves by typing that every
/// fixed template input method commits words, including one from the imported dictionary.
enum DictionaryDeployVerifier {

    /// Caller owns one exclusive lease from learning snapshot through transaction commit.
    /// Do not acquire another coordinator lease inside this callback.
    static func verifyDictionaryWhileExclusive(_ deployment: RecipeDeployment) async throws -> RecipeDeploymentReceipt {
        try await EngineOpQueue.async {
            let engine = RimeEngine(
                configuration: .init(
                    sharedDirectory: deployment.resourceURL,
                    userDirectory: deployment.userDataURL))
            defer { engine.shutdown() }
            try engine.start()
            // Effective enabled inventory from the deployed config; every layout is a target
            // here, not just the manifest entry. Failure of any one rejects the transaction.
            let enabled = try Self.enabledSchemaIDs(engine: engine)
            let sources = BuiltinTemplateSchemas.sourceSchemaIDs
            // The receipt records only what this loop verified item by item; a leftover custom
            // that adds schemes would leave the core's enabled-set check facing unverified items.
            guard Set(enabled) == Set(sources) else {
                throw RecipeInstallError.deployment(
                    "导入词库时启用的输入方式应为 \(sources.joined(separator: "、"))，实际为 \(enabled.sorted().joined(separator: "、"))；请移除自定义配置中对输入方式列表的修改后重试"
                )
            }
            // The compact layouts are generated against the imported dictionary, exactly as for
            // an installed scheme, then every scheme on every layout must type 你好.
            let compact = sources.flatMap { source in
                KeyboardLayoutKind.allCases.filter { $0.compactFold != nil }
                    .map { PublishedKeyboard(schemaID: source, layout: $0) }
            }
            try CompactAdapterDeployment.prepare(
                engine: engine, resourceURL: deployment.resourceURL,
                userDataURL: deployment.userDataURL, requested: compact)
            let set = KeyboardResourceSet.userDictionary(
                name: "", sharedDirectory: deployment.resourceURL,
                userDirectory: deployment.userDataURL,
                prebuiltDirectory: deployment.userDataURL.appendingPathComponent("build"))
            for source in sources {
                let code = source == BuiltinTemplateSchemas.flypy ? "nihc" : "nihao"
                for layout in KeyboardLayoutKind.allCases {
                    let schema = set.logicalSchemaID(source, layout: layout)
                    guard layout == .qwerty26 || schema != source else {
                        throw RecipeInstallError.deployment("没能为「\(source)」生成\(layout.userTitle)")
                    }
                    let typed = layout.compactFold.map { fold in String(code.map { fold.map[$0] ?? $0 }) } ?? code
                    try engine.validateSchemaForActivation(schemaID: schema)
                    try typeAndSelect(engine: engine, code: typed, target: "你好")
                    HostLog.append("import verified \(schema): \(typed) → 你好")
                }
            }
            // Verify a word from the actual normalized import, not only bundled fallback words.
            let text = try String(
                contentsOf: deployment.resourceURL.appendingPathComponent("songyan_imported.dict.yaml"), encoding: .utf8
            )
            guard let row = text.components(separatedBy: "...\n").last?.split(separator: "\n").first else {
                throw RecipeInstallError.deployment("导入的词条内容为空")
            }
            let fields = row.split(separator: "\t")
            guard fields.count >= 2 else {
                throw RecipeInstallError.deployment("无法验证导入的词条")
            }
            engine.clearComposition()
            try engine.validateSchemaForActivation(schemaID: BuiltinTemplateSchemas.quanpin)
            try typeAndSelect(
                engine: engine, code: fields[1].replacingOccurrences(of: " ", with: "'"), target: String(fields[0]))
            HostLog.append("import source candidate verified: \(fields[0])")
            // Entry is the manifest entry (first enabled schema of the fixed import set);
            // the complete validated set goes to the core receipt check.
            return RecipeDeploymentReceipt(
                availableComponents: ["script_translator"],
                validatedSchemaID: BuiltinTemplateSchemas.quanpin, validatedEnabledSchemaIDs: enabled)
        }
    }

    /// Enabled schema ids in effective schema_list order (engine's live enabled list).
    /// Core compares this set against user/build/default.yaml before committing; the first
    /// element is the effective entry used for the receipt.
    static func enabledSchemaIDs(engine: RimeEngine) throws -> [String] {
        let enabled = engine.schemas().map(\.id)
        guard !enabled.isEmpty else { throw RecipeInstallError.deployment("安装后引擎未启用任何输入方式") }
        return enabled
    }

    // MARK: - Check implementations

    private static func typeAndSelect(engine: RimeEngine, code: String, target: String) throws {
        engine.clearComposition()
        for ch in code { try engine.processKey(Self.key(ch)) }
        var snap = engine.state()
        var pages = 0
        while !snap.candidates.contains(where: { $0.text == target }), !snap.isLastPage, pages < 1000 {
            snap = try engine.processKey(RimeKey(keycode: RimeKeyCode.keyPageDown)).state
            pages += 1
        }
        let preview = snap.candidates.map(\.text).prefix(8).joined(separator: "/")
        guard let idx = snap.candidates.firstIndex(where: { $0.text == target }) else {
            throw RecipeInstallError.deployment("输入「\(code)」后未在候选栏中找到「\(target)」：\(preview)")
        }
        guard engine.selectCandidate(idx)?.commitText == target else {
            throw RecipeInstallError.deployment("选择「\(target)」后上屏内容为「\((engine.state().commitText))」，与预期不符")
        }
    }

    /// Single character -> RimeKey (lowercase letters/ASCII), consistent with RimeBackend's mapping.
    private static func key(_ ch: Character) -> RimeKey {
        RimeKey(character: ch) ?? RimeKey(keycode: 0)
    }
}
