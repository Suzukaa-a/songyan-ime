import Foundation

/// Real-engine probe for the runtime identity passed to
/// `KeyboardRecipeStore.saveSelection`.
///
/// The keyboard runs the built-in schemes whenever the published recipe is not active
/// (no full access, no applied recipe, or a disabled publication). In that state
/// the session's `RimeBackend.sharedDirectory` is the bundle's BuiltinPackages/Basic,
/// which is not the active publication. Saving must neither write that
/// session-local choice over the published selection nor report it as a replaced
/// publication / failed save. A genuine stale generation must still be refused.
///
/// Run via `Tests/IOS/run_fallback_selection_macos.py`.
@main
struct FallbackSelectionProbe {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    static func rejects(_ action: () throws -> Void, _ message: String) {
        do {
            try action()
            fatalError("expected refusal: \(message)")
        } catch {}
    }

    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        let root = base.appendingPathComponent("store")
        let shared = base.appendingPathComponent("shared")
        let user = base.appendingPathComponent("user")
        for directory in [root, shared, user] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let enabled = ["rime_ice", "double_pinyin_flypy"]
        for id in enabled {
            let yaml = """
                schema:
                  schema_id: \(id)
                  name: \(id)
                  version: '1'
                engine:
                  processors: [speller, selector, navigator, express_editor]
                  segmentors: [abc_segmentor, fallback_segmentor]
                  translators: [echo_translator]
                speller:
                  alphabet: abcdefghijklmnopqrstuvwxyz
                """
            try Data(yaml.utf8).write(to: shared.appendingPathComponent(id + ".schema.yaml"))
        }
        try Data(("config_version: '1'\nschema_list:\n" + enabled.map { "  - schema: \($0)\n" }.joined()).utf8)
            .write(to: shared.appendingPathComponent("default.yaml"))

        // Real engine deploys the compiled build the store validates against.
        let engine = RimeEngine(configuration: .init(sharedDirectory: shared, userDirectory: user))
        try engine.start()
        engine.shutdown()
        let compiledBuild = user.appendingPathComponent("build")

        try KeyboardRecipeStore.publish(
            resources: shared, compiledBuild: compiledBuild,
            revision: "fallback-fixture", rootURL: root, kind: .userScheme,
            packageID: "pkg-a", selectedSchemaID: "rime_ice")
        let snapshot = try KeyboardRecipeStore.snapshot(rootURL: root)!
        let runtimeResources = snapshot.resourceSet(userDirectory: user)
        check(
            runtimeResources.publicationGeneration == snapshot.activation.generation,
            "resource set must preserve the authoritative publication generation")
        let active = root.appendingPathComponent("active.json")

        // 1) A publication snapshot carries the authoritative generation identity.
        let saved = try KeyboardRecipeStore.saveSelection(
            schemaID: "double_pinyin_flypy", layout: .merged14,
            runtimeIdentity: snapshot.selectionRuntimeIdentity, rootURL: root)
        check(saved == .saved, "published runtime selection must save")
        check(
            try KeyboardRecipeStore.activation(rootURL: root)?.selectedSchemaID == "double_pinyin_flypy",
            "published selection persisted")
        let aliasBytes = try Data(contentsOf: active)

        // 2) A builtin runtime must not overwrite the published selection and reports a no-write.
        let explicitBuiltin = try KeyboardRecipeStore.saveSelection(
            schemaID: "keyboard_47246213a538cb99d374_9", layout: .phone9,
            runtimeIdentity: .builtin, rootURL: root)
        check(explicitBuiltin == .notPublishedRuntime, "explicit builtin identity cannot write")
        check(try Data(contentsOf: active) == aliasBytes, "explicit builtin identity is read-only")

        // 3) A session on an older publication saves onto the current one.
        try KeyboardRecipeStore.publish(
            resources: shared, compiledBuild: compiledBuild,
            revision: "fallback-fixture-2", rootURL: root, kind: .userScheme,
            packageID: "pkg-a", selectedSchemaID: "rime_ice")
        let current = try KeyboardRecipeStore.snapshot(rootURL: root)!
        _ = try KeyboardRecipeStore.saveSelection(
            schemaID: "rime_ice", layout: .qwerty26,
            runtimeIdentity: snapshot.selectionRuntimeIdentity,
            rootURL: root)
        check(
            try KeyboardRecipeStore.activation(rootURL: root)?.generation == current.activation.generation,
            "selection from an older session keeps the current publication")

        // 4) A disabled publication shows no selected route and cannot accept a selection.
        try KeyboardRecipeStore.setEnabled(false, rootURL: root)
        check(try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) == nil, "builtin route")
        let disabledBytes = try Data(contentsOf: active)
        let disabledOutcome = try KeyboardRecipeStore.saveSelection(
            schemaID: "rime_ice", layout: .qwerty26,
            runtimeIdentity: current.selectionRuntimeIdentity, rootURL: root)
        check(disabledOutcome == .notPublishedRuntime, "disabled publication cannot accept a selection")
        check(try Data(contentsOf: active) == disabledBytes, "disabled publication unchanged")

        // 5) Concurrent publication/selection: the store lock orders them, and the
        // selection never overwrites the newly published generation.
        try KeyboardRecipeStore.setEnabled(
            true, rootURL: root,
            expectedGeneration: current.activation.generation)
        let raceSnapshot = try KeyboardRecipeStore.snapshot(rootURL: root)!
        let group = DispatchGroup()
        let resultLock = NSLock()
        var publishError: Error?
        var selectionError: Error?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                try KeyboardRecipeStore.publish(
                    resources: shared, compiledBuild: compiledBuild,
                    revision: "fallback-race-winner", rootURL: root, kind: .userScheme, packageID: "pkg-a",
                    selectedSchemaID: "rime_ice")
            } catch {
                resultLock.lock()
                publishError = error
                resultLock.unlock()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                _ = try KeyboardRecipeStore.saveSelection(
                    schemaID: "double_pinyin_flypy", layout: .merged14,
                    runtimeIdentity: raceSnapshot.selectionRuntimeIdentity, rootURL: root)
            } catch {
                resultLock.lock()
                selectionError = error
                resultLock.unlock()
            }
        }
        group.wait()
        if let publishError { throw publishError }
        let raced = try KeyboardRecipeStore.activation(rootURL: root)!
        check(raced.revision == "fallback-race-winner", "concurrent stale selection cannot replace publication")
        check(raced.generation != raceSnapshot.activation.generation, "concurrent publish advances generation")
        if let selectionError { throw selectionError }

        print(
            "PASS fallback selection: generation identity; builtin/disabled no-write; older-session and concurrent selections keep the current publication"
        )
    }
}
