import Foundation
import KeyboardCore
import PackageManager
import RimeBridge

/// Runs only inside the installer engine lease. Generated schemas/prisms are deployment
/// products in user/build; original source recipes and schema_list are never rewritten.
///
/// Publish contract: the unit of publication is a "user keyboard" added in the host app, each being
/// input method (schema) x keyboard layout. So this file only generates and verifies adapter resources for combinations the host app
/// **explicitly requests**, never "all 14/9 adapters unconditionally for every enabled source". 26-key combinations need no generation
/// and use the source schema itself.
enum CompactAdapterDeployment {
    private static let generatorVersionFileName = "keyboard-adapter-generator.txt"

    static func registeredRequests(build: URL) throws -> [PublishedKeyboard] {
        let url = build.appendingPathComponent(KeyboardResourceSet.adapterRegistryFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000 else { throw RecipeInstallError.invalidResource("键盘适配配置文件大小超出限制") }
        let adapters = try JSONDecoder().decode([KeyboardResourceSet.EncodingAdapter].self, from: data)
        let requests = adapters.map { PublishedKeyboard(schemaID: $0.sourceSchemaID, layout: $0.layout) }
        guard Set(requests).count == requests.count,
            adapters.allSatisfy({ $0.sourceSchemaID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil })
        else {
            throw RecipeInstallError.invalidResource("键盘适配配置文件格式无效")
        }
        return PublishedKeyboard.generationTasks(for: requests)
    }

    /// Whether the adapters in `build` came from the current generator. A newer generator must
    /// reach existing installs, so an older (or missing) stamp means regenerate.
    static func generatorIsCurrent(build: URL) -> Bool {
        (try? String(contentsOf: build.appendingPathComponent(generatorVersionFileName), encoding: .utf8))
            == String(CompactSchemaAdapter.displayGeneratorVersion)
    }

    /// Reuse the compiled build when it already holds exactly the requested adapters. Exact task
    /// equality also removes obsolete adapters through the normal regeneration path when a compact
    /// keyboard is deleted.
    static func canReuseBuild(
        resourceURL: URL, userDataURL: URL,
        enabledSchemas: [KeyboardSchemaDescriptor],
        requested: [PublishedKeyboard]
    ) throws -> Bool {
        let build = userDataURL.appendingPathComponent("build")
        let tasks = PublishedKeyboard.generationTasks(for: requested)
        guard generatorIsCurrent(build: build),
            Set(try registeredRequests(build: build)) == Set(tasks)
        else { return false }
        return requested.allSatisfy { keyboard in
            guard enabledSchemas.contains(where: { $0.id == keyboard.schemaID }),
                let engineID = availableEngineSchemaID(
                    resourceURL: resourceURL, userDataURL: userDataURL,
                    enabledSchemas: enabledSchemas, requested: keyboard)
            else { return false }
            return FileManager.default.fileExists(
                atPath: InstalledPackageLayout.compiledSchemaURL(build: build, id: engineID).path)
        }
    }

    /// Deploy-callback entry point.
    static func prepare(
        engine: RimeEngine, deployment: RecipeDeployment,
        requested: [PublishedKeyboard]
    ) throws {
        try prepare(
            engine: engine, resourceURL: deployment.resourceURL,
            userDataURL: deployment.userDataURL, requested: requested)
    }

    /// Generates/refreshes display-capable companions **only for the requested
    /// combinations** (input method × layout) that need a generated adapter (14 / 9).
    /// Throws on a real projection/generation failure; a source that cannot be adapted
    /// (not a foldable standard script_translator, empty or unrepresentable token domain) is
    /// skipped and keeps the native display.
    /// Generation depends only on the compiled schema's structure and the native source
    /// projection; it never samples candidates.
    static func prepare(
        engine: RimeEngine, resourceURL: URL, userDataURL: URL,
        requested: [PublishedKeyboard]
    ) throws {
        let build = userDataURL.appendingPathComponent("build")
        let fm = FileManager.default

        // The registry reflects **this generation's requested** adapters only. A keyboard
        // that is not added (or was deleted) never gets a companion here.
        var adapters: [KeyboardResourceSet.EncodingAdapter] = []

        // Group requested layouts by source so the source projection / capability is
        // computed once, then generate only the requested layout(s) for that source.
        var layoutsBySource: [String: [KeyboardLayoutKind]] = [:]
        for combo in requested where combo.needsGeneratedAdapter {
            layoutsBySource[combo.schemaID, default: []].append(combo.layout)
        }
        // A stable, schema-agnostic iteration order (source id is just the enabled key).
        let sources = layoutsBySource.keys.sorted()

        for source in sources {
            try Task.checkCancellation()
            let requestedLayouts = layoutsBySource[source] ?? []
            guard !requestedLayouts.isEmpty else { continue }
            let compiled = try Data(contentsOf: InstalledPackageLayout.compiledSchemaURL(build: build, id: source))
            switch try CompactSchemaAdapter.adaptability(compiled: compiled, sourceID: source) {
            case .unsupported:
                continue
            case .adaptable:
                break
            }
            try engine.validateSchemaForActivation(schemaID: source)
            let wasASCII = engine.option("ascii_mode")
            engine.setOption("ascii_mode", value: false)
            defer { engine.setOption("ascii_mode", value: wasASCII) }
            // The native projection MUST be available and complete. Missing or
            // undecodable projection is a real failure, never silently native.
            guard
                let projection = engine.sourceProjectionMap()
                    .flatMap(CompactSchemaAdapter.SourceProjection.decode(json:))
            else {
                throw RecipeInstallError.deployment("无法读取输入方式「\(source)」的编码映射")
            }
            // Structural contract, NOT a candidate oracle:
            //   * no primary token at all          -> `.native` (nothing to represent);
            //   * token domain not exactly representable (over the versioned limit,
            //     duplicate, or an unrepresentable token) -> `.native` for the alias
            //     layer; the display companion may still be built, but no rewrite
            //     capability is written (never a fake one).
            // Whether a dictionary *happens* to contain some standalone candidate for
            // a probe is irrelevant and is never consulted.
            guard !projection.syllables.isEmpty else { continue }
            // The producer class used for the DISPLAY/REWRITE split is resolved from
            // the compiled schema with the SAME contract as `adaptability` and the
            // generators, so all three agree.
            let producer = CompactSchemaAdapter.autoAdaptableProducer(inCompiled: compiled)
            let isTableSource = producer?.klass == .table
            let aliasRepresentable =
                !isTableSource
                && CompactSchemaAdapter.tokenAliasDomain(projection) != nil

            // A source that already has a usable numeric (2–9) spelling space runs
            // natively on a phone-digit layout. This is derived from the projection's
            // own spellings, never from candidate presence.
            let routes = layoutRoutes(
                requestedLayouts,
                numericSource: aliasRepresentable && CompactSchemaAdapter.isNumericCodeSource(projection))
            if let digits = routes.native {
                adapters.append(
                    .init(
                        sourceSchemaID: source, schemaID: source, layout: digits,
                        schemaName: engine.schemaValue(source, key: "schema/name")))
            }

            // Display (letter groups: source codes; 9 keys: canonical pinyin, declared sources
            // only) and rewrite (alias or direct-code layer) are decided by the plan.
            let sourceDelimiter =
                engine.schemaValue(source, key: "translator/delimiter")
                ?? engine.schemaValue(source, key: "speller/delimiter")
            let plan: CompactSchemaAdapter.CompanionPlan
            do {
                plan = try .init(
                    compiled: compiled, sourceID: source, projection: projection,
                    sourceDelimiter: sourceDelimiter)
            } catch {
                throw RecipeInstallError.deployment("无法为输入方式「\(source)」生成按键显示：\(error)")
            }

            // Requested layouts are always compact (needsGeneratedAdapter): letter groups or phone digits.
            for layout in routes.companions {
                try Task.checkCancellation()
                // A layout that cannot fold this source's own physical alphabet is skipped, not forced.
                guard let fold = layout.compactFold,
                    let data = try plan.companion(fold: fold)
                else { continue }
                let target = CompactSchemaAdapter.identifier(sourceID: source, fold: fold)
                let generated = userDataURL.appendingPathComponent(InstalledPackageLayout.schemaFile(target))
                guard
                    !fm.fileExists(
                        atPath: resourceURL.appendingPathComponent(InstalledPackageLayout.schemaFile(target)).path)
                else {
                    throw RecipeInstallError.deployment("生成的键盘适配名称与已有输入方式冲突：\(target)")
                }
                try data.write(to: generated, options: .atomic)
                // Ensure the rewritten source is strictly newer than any recorded
                // build timestamp so a same-ID re-deploy actually replaces the
                // compiled adapter rather than serving the previous generation.
                try? fm.setAttributes(
                    [.modificationDate: Date().addingTimeInterval(2)],
                    ofItemAtPath: generated.path)
                try engine.deploySchemaFile(generated)
                try engine.validateSchemaForActivation(schemaID: target)
                // Prediction follows the source exactly (whoever wired it).
                guard Prediction.sameWiring(engine.schemaComponents(source), engine.schemaComponents(target)),
                    engine.schemaValue(source, key: "predictor/db") == engine.schemaValue(target, key: "predictor/db")
                else {
                    throw RecipeInstallError.deployment("输入方式「\(source)」在\(layout.userTitle)上的联想词设置与原方案不一致")
                }
                adapters.append(
                    .init(
                        sourceSchemaID: source, schemaID: target, layout: layout,
                        schemaName: engine.schemaValue(target, key: "schema/name")))
            }
        }

        // The registry is authoritative for THIS generation: it contains exactly the
        // companions generated for requested combinations and nothing else.
        try JSONEncoder().encode(adapters).write(
            to: build.appendingPathComponent(KeyboardResourceSet.adapterRegistryFileName), options: .atomic)
        try Data(String(CompactSchemaAdapter.displayGeneratorVersion).utf8)
            .write(to: build.appendingPathComponent(generatorVersionFileName), options: .atomic)
        if let first = sources.first {
            try engine.validateSchemaForActivation(schemaID: first)
            engine.clearComposition()
        }
    }

    /// One route per source/layout pair, since the registry rejects duplicates: a phone-digit
    /// layout served natively by a numeric source gets no generated companion.
    static func layoutRoutes(_ layouts: [KeyboardLayoutKind], numericSource: Bool)
        -> (native: KeyboardLayoutKind?, companions: [KeyboardLayoutKind])
    {
        let native = numericSource ? layouts.first { $0.keyFold == .phoneDigits } : nil
        return (native, layouts.filter { $0 != native })
    }

    /// Whether the launch-time rebuild applies: an enabled publication with compact keyboards
    /// whose published build predates the current generator. The published copy is checked, not
    /// the installed one, so a publication that failed after preparation is retried next launch.
    static func publicationNeedsRebuild(enabled: Bool, keyboards: [PublishedKeyboard], publishedBuild: URL)
        -> Bool
    {
        enabled && keyboards.contains(where: \.needsGeneratedAdapter) && !generatorIsCurrent(build: publishedBuild)
    }

    /// Whether a requested combination (input method × layout) is satisfied by THIS
    /// generation: the enabled descriptors are the values just proven by the live
    /// engine. Reuses the production `KeyboardResourceSet` selection validation over
    /// the new generation's enabled schema list and its preserved author bindings.
    /// Never reads a prior generation's registry, so an invalidated old binding is not
    /// resurrected.
    static func combinationAvailable(
        resourceURL: URL, userDataURL: URL,
        enabledSchemas: [KeyboardSchemaDescriptor],
        requested: PublishedKeyboard
    ) -> Bool {
        availableEngineSchemaID(
            resourceURL: resourceURL, userDataURL: userDataURL, enabledSchemas: enabledSchemas, requested: requested)
            != nil
    }

    /// The engine schema that runs an available requested combination; nil when it is unavailable.
    static func availableEngineSchemaID(
        resourceURL: URL, userDataURL: URL,
        enabledSchemas: [KeyboardSchemaDescriptor],
        requested: PublishedKeyboard
    ) -> String? {
        let build = userDataURL.appendingPathComponent("build")
        var bindings: [KeyboardResourceSet.LayoutEntry] = []
        if let data = try? Data(
            contentsOf: resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardPackageFile)),
            let declaration = try? JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
        {
            bindings = declaration.bindings.compactMap { binding in
                guard let layout = KeyboardLayoutKind(rawValue: binding.layout) else { return nil }
                return .init(layout: layout, schemaID: binding.schemaID)
            }
        }
        let set = KeyboardResourceSet(
            id: "combination-check", name: "",
            sharedDirectory: resourceURL, userDirectory: userDataURL,
            layoutEntries: bindings, prebuiltDirectory: build,
            schemas: enabledSchemas, selectedSchemaID: requested.schemaID)
        return set.availableCombinations.first {
            $0.schemaID == requested.schemaID && $0.layout == requested.layout
        }?.engineSchemaID
    }
}
