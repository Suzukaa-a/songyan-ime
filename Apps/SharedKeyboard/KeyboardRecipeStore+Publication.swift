import Darwin
import Foundation
import KeyboardCore
import OSLog

extension KeyboardRecipeStore {
    /// Publish-time consistency checks; readers rely on them and surface a missing file as an ordinary error.
    private static func validatePublication(_ activation: Activation, build: URL) throws {
        if let selected = activation.selectedSchemaID, !activation.requiredSchemaIDs.contains(selected) {
            throw StoreError(message: "所选输入方式不在已启用的列表中，请在「输入方案」中重新选择")
        }
        if activation.kind == .userScheme {
            guard activation.selectedSchemaID != nil,
                RimePaths.recipeUserDirectory(kind: .userScheme, packageID: activation.packageID) != nil
            else {
                throw StoreError(message: "方案缺少有效标识或所选输入方式，请重新选择")
            }
        }
        for schema in activation.requiredSchemaIDs {
            guard !schema.isEmpty, !schema.contains("/"), schema != ".", schema != ".." else {
                throw StoreError(message: "输入方案名称或路径格式无效")
            }
            guard FileManager.default.fileExists(atPath: build.appendingPathComponent("\(schema).schema.yaml").path)
            else {
                throw StoreError(message: "输入方案缺少已编译文件 \(schema)，请在「松烟」App 中重新构建")
            }
        }
        // Invariant for added keyboards: every published compact keyboard (14 / 9 key) must have a
        // structured generated adapter or author binding, and its engine schema's compiled output must
        // really exist. Any missing item blocks publication (throws, the caller does not write active.json), never silently degrading to a source combination.
        let adapters = KeyboardResourceSet.readEncodingAdapters(build: build)
        let enabledIDs = Set(activation.requiredSchemaIDs)
        for keyboard in activation.keyboards {
            guard enabledIDs.contains(keyboard.schemaID) else {
                throw StoreError(message: "已添加的键盘包含未启用的输入方案 \(keyboard.schemaID)，请重新添加")
            }
            guard keyboard.needsGeneratedAdapter else { continue }
            let boundEngine = activation.schemaBindings?.first {
                $0.schemaID == keyboard.schemaID && $0.layout == keyboard.layout
            }?.schemaID
            let engine =
                adapters.first {
                    $0.sourceSchemaID == keyboard.schemaID && $0.layout == keyboard.layout
                }?.schemaID ?? boundEngine
            guard let engine else {
                throw StoreError(message: "已添加的 \(keyboard.layout.userTitle) 键盘缺少按键映射，请重新添加后再保存")
            }
            guard FileManager.default.fileExists(atPath: build.appendingPathComponent("\(engine).schema.yaml").path)
            else {
                throw StoreError(message: "已添加的 \(keyboard.layout.userTitle) 键盘缺少已编译的适配方案 \(engine)，请重新添加后再保存")
            }
        }
        let englishRoutes = activation.englishCandidateRoutes ?? []
        let routeOwners = Set(englishRoutes.map(\.owner))
        guard routeOwners.count == englishRoutes.count else {
            throw StoreError(message: "英语候选设置中存在重复的键盘，请重新设置")
        }
        for route in englishRoutes {
            guard activation.keyboards.contains(route.owner) else {
                throw StoreError(message: "英语候选关联的键盘不存在，请重新设置")
            }
            let target = route.candidateSchemaID
            guard enabledIDs.contains(target) else {
                throw StoreError(message: "英语候选关联的目标方案不在当前启用列表中，请重新设置")
            }
            guard target != route.owner.schemaID,
                activation.selectedSchemaID != target,
                !activation.keyboards.contains(where: { $0.schemaID == target }),
                !target.isEmpty,
                !target.contains("/"),
                !target.contains(".."),
                target != "."
            else {
                throw StoreError(message: "英语候选关联的目标方案不在当前启用列表中，请重新设置")
            }
            let compiledTarget = build.appendingPathComponent("\(target).schema.yaml")
            guard FileManager.default.fileExists(atPath: compiledTarget.path) else {
                throw StoreError(message: "英语候选关联的目标方案缺少已编译文件 \(target)，请重新构建")
            }
        }
    }

    /// The publication state captured before a (possibly long) operation. Distinguishing
    /// these prevents `nil` from being used both as "no CAS" and "expected absent".
    public enum PublishBaseline: Sendable, Equatable {
        /// No CAS contract (caller has no baseline and accepts overwriting).
        case unchecked
        /// The lock must observe exactly this publication (identity + selection +
        /// recipeEnabled). A value CAS, not a monotonic revision token.
        case publication(Activation)
        /// The lock must observe no active publication.
        case absent
    }

    /// Call only after deployment shutdown, while host interactive writers remain paused.
    ///
    /// Selection semantics:
    ///  - `preservingSelection` is valid ONLY with `.publication` baseline and only when the
    ///    locked current publication is the SAME source as the target (same kind/packageID).
    ///    It then adopts the newest schema/layout/bindings and preserves `recipeEnabled`, so
    ///    a concurrent selection — or a switch back to builtin — during the update is never
    ///    overwritten. A different/absent publication fails explicitly.
    ///  - otherwise the target selection is explicit; `.publication` requires identity +
    ///    selection values + recipeEnabled unchanged (stale operation refused), `.absent`
    ///    requires no publication appeared, `.unchecked` commits the explicit selection.
    ///
    /// The checks are value based: a same-generation A→B→A selection sequence is accepted
    /// (this is NOT a monotonic selection-revision CAS). A selection unsupported by the new
    /// generation fails explicitly and is never silently defaulted.
    public static func publish(
        resources: URL, compiledBuild: URL, revision: String, rootURL: URL? = nil,
        kind: ResourceKind, dictionaryName: String? = nil,
        packageID: String? = nil, schemas: [KeyboardSchemaDescriptor]? = nil,
        selectedSchemaID: String? = nil, layout: KeyboardLayoutKind? = nil,
        bindings: [KeyboardResourceSet.LayoutEntry]? = nil,
        publishedKeyboards: [PublishedKeyboard]? = nil,
        englishCandidateRoutes: [EnglishCandidateRoute]? = nil,
        preservingSelection: Bool = false,
        baseline: PublishBaseline = .unchecked
    ) throws {
        let fm = FileManager.default
        let schemas = try resolvedSchemas(schemas, build: compiledBuild)
        let root = try rootURL ?? root()
        let generation = UUID().uuidString
        let version = root.appendingPathComponent("versions/\(generation)")
        try fm.createDirectory(at: version.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkdir(version.path, 0o700) == 0 else {
            throw StoreError(message: "无法创建方案版本目录：\(String(cString: strerror(errno)))")
        }
        var activeWriteAttempted = false
        defer {
            if !activeWriteAttempted {
                do { try fm.removeItem(at: version) } catch {
                    Logger.keyboardStorage.error(
                        "failed to remove uncommitted publication: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let destination = version.appendingPathComponent("resources")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        // Upstream includes build/.gitkeep; only the verifier's compiled build is authoritative.
        for entry in try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        where entry.lastPathComponent != "build" {
            try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
        try fm.copyItem(at: compiledBuild, to: destination.appendingPathComponent("build"))
        for schema in schemas.map(\.id) {
            guard fm.fileExists(atPath: destination.appendingPathComponent("build/\(schema).schema.yaml").path) else {
                throw StoreError(message: "启用失败，输入方案 \(schema) 尚未编译")
            }
        }

        let lock = try ActiveLock(root: root)
        defer { lock.unlock() }
        let current = try writeBaseline(rootURL: root)
        var effectiveSchemaID = selectedSchemaID
        var effectiveLayout = layout
        var effectiveBindings = bindings
        var effectiveKeyboards = publishedKeyboards
        var effectiveEnglishCandidateRoutes = englishCandidateRoutes
        var inheritedEnglishCandidateRoutes = false
        var effectiveRoster = current?.keyboardsBySource
        if preservingSelection {
            // Preserving is only meaningful for the SAME publication source.
            guard case .publication(let expected) = baseline, let current else {
                throw StoreError(message: "缺少原有方案记录，无法保留当前选择，请刷新后重试")
            }
            guard current.generation == expected.generation,
                current.revision == expected.revision,
                current.kind == expected.kind,
                current.packageID == expected.packageID
            else {
                throw StoreError(message: "输入方案配置已被更新，请刷新后重试")
            }
            // The target must be the same source as the locked current, so preserving can
            // never inherit another source's selection.
            guard current.kind == kind, current.packageID == packageID else {
                throw StoreError(message: "当前输入方案已更改，无法保留之前的选择，请重新选择")
            }
            // A switch back to builtin during the update is a newer user intent.
            guard current.recipeEnabled == expected.recipeEnabled else {
                throw StoreError(message: "输入方案启用状态已改变，请刷新后重试")
            }
            // Same publication: adopt whatever the user selected most recently, including
            // a selection saved by the extension during the update.
            effectiveSchemaID = current.selectedSchemaID
            effectiveLayout = current.selectedLayout
            effectiveBindings = current.schemaBindings ?? bindings
            // The added-keyboard list is part of the same publication; preserve the
            // locked current list when the caller did not supply one.
            effectiveKeyboards = publishedKeyboards ?? current.publishedKeyboards
        } else {
            switch baseline {
            case .unchecked:
                break
            case .absent:
                guard current == nil else {
                    throw StoreError(message: "输入方案配置已存在，请刷新后重试")
                }
            case .publication(let expected):
                guard let current else { throw StoreError(message: "找不到已有的输入方案配置，请刷新后重试") }
                guard current.generation == expected.generation,
                    current.revision == expected.revision,
                    current.kind == expected.kind,
                    current.packageID == expected.packageID
                else {
                    throw StoreError(message: "输入方案配置已被更新，请刷新后重试")
                }
                guard current.selectedSchemaID == expected.selectedSchemaID,
                    current.selectedLayout == expected.selectedLayout,
                    current.schemaBindings == expected.schemaBindings,
                    current.recipeEnabled == expected.recipeEnabled
                else {
                    throw StoreError(message: "输入方案的选择或启用状态已被更新，请刷新后重试")
                }
            }
        }
        if effectiveEnglishCandidateRoutes == nil, let current,
            current.kind == kind, current.packageID == packageID
        {
            effectiveEnglishCandidateRoutes = current.englishCandidateRoutes
            inheritedEnglishCandidateRoutes = true
        }
        if let effectiveKeyboards {
            // The added-keyboard list is part of the publication and must reference only
            // enabled schemes. Enforced regardless of whether a single selection exists.
            let enabledIDs = Set(schemas.map(\.id))
            guard effectiveKeyboards.allSatisfy({ enabledIDs.contains($0.schemaID) }),
                Set(effectiveKeyboards.map(\.id)).count == effectiveKeyboards.count
            else {
                throw StoreError(message: "已添加的键盘包含新版本未启用的方案，请重新选择")
            }
        } else if let effectiveSchemaID {
            // Without an explicit list, the selected schema/layout becomes the single added keyboard.
            effectiveKeyboards = [
                PublishedKeyboard(
                    schemaID: effectiveSchemaID,
                    layout: effectiveLayout ?? .qwerty26)
            ]
        }
        // Cross-source cache: keep the full lists of other sources from the locked current record
        // as they are, and file this list under this source's own key. `publishedKeyboards` holds only
        // this source's list (never mixing in other sources); other sources' lists go in
        // `keyboardsBySource` as the authoritative baseline when switching back. A caller-supplied
        // list replaces this source's recorded list as a whole (delete/edit semantics are the caller's
        // call; items the user removed are never merged back here); without a list, this source's own
        // recorded list is kept (a cross-source "start using" must not clear the target source).
        if let targetKey = rosterKey(kind: kind, packageID: packageID) {
            var rosters: [PublishedKeyboardRoster] = []
            for (key, list) in (current?.keyboardsBySource ?? [:]).sorted(by: { $0.key < $1.key })
            where key != targetKey {
                rosters.append(PublishedKeyboardRoster(key: key, keyboards: list))
            }
            if let keyboards = effectiveKeyboards {
                rosters.append(PublishedKeyboardRoster(key: targetKey, keyboards: keyboards))
            } else if let storedTarget = current?.keyboardsBySource?[targetKey] {
                rosters.append(PublishedKeyboardRoster(key: targetKey, keyboards: storedTarget))
            }
            let merged = PublishedKeyboardRoster.merged(rosters)
            guard merged.selfConsistent else {
                throw StoreError(message: "输入方案来源信息不完整，无法保存已添加的键盘，请重新选择")
            }
            // Invariant: `publishedKeyboards` always equals this source's list in the cache
            // (the extension's runtime validation sees only this source, never mixing in others).
            if merged.rosters[targetKey] != nil {
                effectiveKeyboards = merged.rosters[targetKey]
            }
            effectiveRoster = merged.rosters
        } else if effectiveKeyboards != nil {
            throw StoreError(message: "输入方案来源信息不完整，无法保存已添加的键盘")
        }
        if inheritedEnglishCandidateRoutes, let routes = effectiveEnglishCandidateRoutes {
            let owners = Set(effectiveKeyboards ?? [])
            effectiveEnglishCandidateRoutes = routes.filter { owners.contains($0.owner) }
        }
        if let effectiveSchemaID {
            guard schemas.contains(where: { $0.id == effectiveSchemaID }) else {
                throw StoreError(message: "新版本不包含当前选择的输入方案 \(effectiveSchemaID)，请重新选择")
            }
            let enabledIDs = Set(schemas.map(\.id))
            if let effectiveBindings, !effectiveBindings.allSatisfy({ enabledIDs.contains($0.schemaID) }) {
                throw StoreError(message: "键盘设置中引用了新版本未启用的输入方案，请重新选择")
            }
            if let effectiveLayout {
                let view = KeyboardResourceSet(
                    id: "publish-check", name: "", sharedDirectory: resources,
                    userDirectory: resources, layoutEntries: effectiveBindings ?? [],
                    prebuiltDirectory: compiledBuild, schemas: schemas,
                    selectedSchemaID: effectiveSchemaID, preferredLayout: effectiveLayout)
                guard view.incompatibilityReason(layout: effectiveLayout, schemaID: effectiveSchemaID) == nil else {
                    throw StoreError(message: "新版本不支持当前键盘布局，请重新选择")
                }
            }
        }
        let activation = Activation(
            generation: generation, revision: revision, recipeEnabled: true,
            publishedAt: Date(), resourceKind: kind, dictionaryName: dictionaryName,
            packageID: packageID, schemas: schemas,
            selectedSchemaID: effectiveSchemaID,
            selectedLayout: effectiveLayout, schemaBindings: effectiveBindings,
            hostInstallationGeneration: compiledBuild.deletingLastPathComponent().deletingLastPathComponent()
                .lastPathComponent,
            publishedKeyboards: effectiveKeyboards,
            keyboardsBySource: effectiveRoster,
            englishCandidateRoutes: effectiveEnglishCandidateRoutes)
        try validatePublication(activation, build: destination.appendingPathComponent("build"))
        try Task.checkCancellation()
        let encodedActivation = try canonicalJSONEncoder().encode(activation)
        // An atomic replacement can commit even if its caller reports an error.
        // From this point leave the generation intact unless a later recovery proves it unreferenced.
        activeWriteAttempted = true
        try encodedActivation.write(to: root.appendingPathComponent("active.json"), options: .atomic)
        pruneUnreferencedGenerations(root: root, keeping: [generation, current?.generation].compactMap { $0 })
    }

    /// Every publication copies the resources whole; without reclaiming, the App Group grows
    /// without bound as keyboards are added and removed. Call while still holding `ActiveLock`:
    /// keeps only the new generation and the just-replaced previous one (a keyboard not yet rebound
    /// may still use it; older generations always rebind from `active.json` the next time they appear).
    /// Best effort: a reclaim failure is only logged and never affects the committed publication.
    private static func pruneUnreferencedGenerations(root: URL, keeping: [String]) {
        let fm = FileManager.default
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        guard
            let entries = try? fm.contentsOfDirectory(
                at: versions, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])
        else { return }
        let kept = Set(keeping)
        for entry in entries where !kept.contains(entry.lastPathComponent) {
            do { try fm.removeItem(at: entry) } catch {
                Logger.keyboardStorage.error(
                    "failed to prune publication \(entry.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    public static func setEnabled(_ enabled: Bool, rootURL: URL? = nil, expectedGeneration: String? = nil) throws {
        let root = try rootURL ?? root()
        let lock = try ActiveLock(root: root)
        defer { lock.unlock() }
        let current = try writeBaseline(rootURL: root)
        if let expectedGeneration, current?.generation != expectedGeneration {
            throw StoreError(message: "输入方案配置版本已更新，请刷新后重试")
        }
        // Choosing builtin does not require any installed recipe or working build.
        // Choosing the recipe needs an existing publication.
        if enabled {
            guard let current, !current.generation.isEmpty else {
                throw StoreError(message: "尚未选择输入方案，请先在「松烟」App 中添加并选择方案")
            }
        }
        // No record means built-in pinyin; a damaged one is removed to mean the same.
        guard let current else {
            let active = root.appendingPathComponent("active.json")
            if FileManager.default.fileExists(atPath: active.path) { try FileManager.default.removeItem(at: active) }
            return
        }
        // Preserve the full publication record (all metadata incl. publishedKeyboards)
        // and only flip the enabled flag; never field-by-field reconstruct.
        try canonicalJSONEncoder().encode(current.withEnabled(enabled))
            .write(to: root.appendingPathComponent("active.json"), options: .atomic)
    }

    // MARK: - Publication list prune / restore (CAS) on install deletion

    /// Atomically rewrites the publication record (generation / resources untouched), used to
    /// clear a source's publication traces when its install is deleted.
    ///
    /// Semantics:
    ///  * Flat list (current source): prune by `deletedSchemaIDs` and fix the single selection
    ///    only when the deleted source is the current publication source (same structured
    ///    provenance); otherwise keep it as is, never deleting another source's same-named
    ///    combination by schema string. When provenance cannot be formed, no flat prune is done
    ///    (fail closed; no fallback to the caller-supplied source).
    ///  * Cross-source cache: the deleted source's own cache key is always cleared (whether or not
    ///    it is the current source); other sources' caches and the current flat list are untouched,
    ///    so deleting a non-current source B leaves no stale list of B to be inherited by a re-import.
    ///
    /// CAS: must match the record the caller observed field by field, otherwise refused. When
    /// nothing changes `updated == nil` (nothing written).
    public static func prunePublishedKeyboards(
        expected: Activation,
        deletingSource: KeyboardPublicationSource,
        deletedSchemaIDs: Set<String>,
        rootURL: URL? = nil
    ) throws
        -> (result: PublishedKeyboardPrune.Result, updated: Activation?)
    {
        let root = try rootURL ?? root()
        let lock = try ActiveLock(root: root)
        defer { lock.unlock() }
        guard let current = try activation(rootURL: root), current == expected else {
            throw StoreError(message: "输入方案配置已被更新，请刷新后重试")
        }
        // The flat list is decided only by the current record's own structured provenance, never falling back to the caller-supplied value.
        let result: PublishedKeyboardPrune.Result
        if current.publicationSource == deletingSource {
            result = PublishedKeyboardPrune.retained(
                published: current.keyboards,
                publicationSource: deletingSource,
                deletingSource: deletingSource,
                deletedSchemaIDs: deletedSchemaIDs)
        } else {
            result = PublishedKeyboardPrune.Result(retained: current.keyboards, removed: [])
        }
        var updated = current
        var changed = false
        if result.didChange {
            updated.publishedKeyboards = result.retained
            updated.englishCandidateRoutes = updated.englishCandidateRoutes?.filter {
                result.retained.contains($0.owner)
            }
            // The keyboard list is part of the publication: keep the single selection consistent.
            if let selected = updated.selectedSchemaID,
                !result.retained.contains(where: { $0.schemaID == selected })
            {
                updated.selectedSchemaID = result.retained.first?.schemaID
                updated.selectedLayout = result.retained.first?.layout
            }
            changed = true
        }
        // The deleted source's own cached list must be cleared (whether or not it is the current source); other sources are kept as they are.
        if let key = deletingSource.cacheKey, var map = updated.keyboardsBySource,
            map.removeValue(forKey: key) != nil
        {
            updated.keyboardsBySource = map.isEmpty ? nil : map
            changed = true
        }
        guard changed else { return (result, nil) }
        try canonicalJSONEncoder().encode(updated).write(
            to: root.appendingPathComponent("active.json"), options: .atomic)
        return (result, updated)
    }

    /// The atomic inverse of prune: writes the original record back only if the on-disk record
    /// still equals the pruned record. Lets the delete transaction roll back the list when the final
    /// delete fails; refused (no overwrite of newer intent) if the user changed the selection meanwhile.
    public static func restorePublishedKeyboards(
        _ original: Activation,
        expectingCurrent expected: Activation,
        rootURL: URL? = nil
    ) throws {
        let root = try rootURL ?? root()
        let lock = try ActiveLock(root: root)
        defer { lock.unlock() }
        guard let current = try activation(rootURL: root), current == expected else {
            throw StoreError(message: "输入方案配置已被更新，无法恢复已添加的键盘列表")
        }
        try canonicalJSONEncoder().encode(original).write(
            to: root.appendingPathComponent("active.json"), options: .atomic)
    }

    /// Outcome of a keyboard-side selection save.
    ///
    /// The running session is not always the active publication: while full access
    /// is unavailable the extension keeps running the built-in package even though the
    /// App Group still holds an enabled published recipe. Such a session-local
    /// choice must never be written over the published selection, and it must not
    /// be reported as a failed save or as a replaced publication.
    public enum SelectionSaveOutcome: Equatable, Sendable {
        /// Written to the active publication.
        case saved
        /// No write: the running resources are not the active published recipe
        /// (built-in package or a disabled publication). The published
        /// generation and selection are untouched.
        case notPublishedRuntime
    }

    /// Identity of the resources that produced a keyboard selection.
    ///
    /// Publication identity is the generation captured in `Snapshot`; filesystem
    /// path spellings are deliberately not part of this value. In particular, a
    /// symlink/alias to a publication remains that publication, while built-in package is
    /// explicitly non-published and can never write the shared selection.
    public enum SelectionRuntimeIdentity: Equatable, Sendable {
        case builtin
        case published
    }

    /// Preferred generation-CAS entry point. The snapshot generation is authoritative;
    /// schema validation and atomic replacement.
    @discardableResult
    public static func saveSelection(
        schemaID: String, layout: KeyboardLayoutKind,
        runtimeIdentity: SelectionRuntimeIdentity,
        rootURL: URL? = nil
    ) throws -> SelectionSaveOutcome {
        let root = try rootURL ?? root()
        let lock = try ActiveLock(root: root)
        defer { lock.unlock() }
        guard var current = try activation(rootURL: root), current.recipeEnabled else {
            return .notPublishedRuntime
        }
        switch runtimeIdentity {
        case .builtin:
            return .notPublishedRuntime
        case .published:
            // Validated against whatever publication is current, so a session still
            // running an older one can save as long as its choice is still published.
            break
        }
        return try saveSelection(schemaID: schemaID, layout: layout, current: &current, root: root)
    }

    private static func saveSelection(
        schemaID: String, layout: KeyboardLayoutKind,
        current: inout Activation, root: URL
    ) throws -> SelectionSaveOutcome {
        current = try snapshot(for: current, root: root).activation
        guard current.requiredSchemaIDs.contains(schemaID) else {
            throw StoreError(message: "当前输入方案中未包含 \(schemaID)，请重新选择")
        }
        current.selectedSchemaID = schemaID
        current.selectedLayout = layout
        let data = try canonicalJSONEncoder().encode(current)
        try data.write(to: root.appendingPathComponent("active.json"), options: .atomic)
        return .saved
    }
}

private final class ActiveLock {
    private var fd: Int32
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fd = open(root.appendingPathComponent("active.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // The lock is briefly held while the host publishes: background threads retry within a bound
        // (up to ~500 ms, 25 ms each) instead of failing immediately. All production callers run on
        // EngineOpQueue / KeyboardResourceReadQueue; if called on the main thread it tries once and never blocks the main thread.
        var remainingWaits = Thread.isMainThread ? 0 : Self.maximumWaits
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            if code == EWOULDBLOCK, remainingWaits > 0 {
                remainingWaits -= 1
                usleep(Self.waitMicroseconds)
                continue
            }
            let error = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            close(fd)
            fd = -1
            throw error
        }
    }
    private static let waitMicroseconds: useconds_t = 25_000
    private static let maximumWaits = 20
    func unlock() {
        if fd >= 0 {
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
    }
    deinit { unlock() }
}
