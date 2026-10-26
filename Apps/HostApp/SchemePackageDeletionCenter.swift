import Foundation
import KeyboardCore
import PackageManager

// MARK: - Deleting a user-installed source
//
// Host wiring for package deletion. The ordered steps (prune published state, rename into trash,
// delete) live in `PackageManager` (`SchemePackageDeletion`); publication decisions consume the
// canonical store, and this file reimplements none of it:
//   * whether a source is in use -> `InstalledSourceDeletionPolicy`;
//   * CAS prune/restore of the published roster -> `PublishedKeyboardPruner` (async);
//   * authoritative record reads -> `AppliedSelectionLoader` (canonical read queue).
//
// Kept in its own file because `SchemeImportCenter.swift` must not own whole-package
// deletion transactions (ownership boundary).
extension SchemeImportCenter {

    /// Trash area (a sibling of `storeRoot` on the same volume). Deleting an install renames it
    /// here after it has been unpublished, then deletes it.
    static var deletionTrashRoot: URL {
        storeRoot.deletingLastPathComponent().appendingPathComponent("SchemePackageTrash", isDirectory: true)
    }

    /// Deletes a user-installed source (transactional, reversible).
    ///
    /// Deletion targets exactly this source's own install slot `SchemePackages/<id>`; its
    /// resources, version/recovery generations and trial learning all belong to the install and
    /// go with it. It does not touch other sources' install slots, the dictionary store
    /// (`DictionaryImportStore`), the extension-private learning directory, or the shared
    /// resource snapshot already published to the App Group.
    ///
    /// All heavy I/O (authoritative record reads, directory probing and rename,
    /// publication prune) runs under the exclusive engine lease on the engine serial queue, off
    /// the MainActor; the MainActor only calls `await refresh()` afterwards.
    func deleteInstalledPackage(packageID: String) async throws {
        guard !busy else { throw RecipeInstallError.busy }
        let schemaIDs: Set<String>
        if let item = installedPackages.first(where: { $0.id == packageID }) {
            schemaIDs = Set(item.schemas.map(\.id))
        } else if let damaged = damagedPackages.first(where: { $0.id == packageID }) {
            schemaIDs = damaged.schemaIDs
        } else {
            throw RecipeInstallError.invalidResource("找不到输入方案")
        }
        let layout = SchemePackageDeletion.Layout(
            storeRoot: Self.storeRoot,
            trashRoot: Self.deletionTrashRoot)
        busy = true
        defer { busy = false }
        message = "正在删除输入方案…"
        do {
            let outcome = try await EngineOwnershipCoordinator.shared.withExclusive {
                try await EngineOpQueue.asyncExclusive {
                    try await Self.performDeletion(packageID: packageID, schemaIDs: schemaIDs, layout: layout)
                }
            }
            if let leftover = outcome.leftoverTrash {
                // State is already consistent and only trash remains: record it as a diagnostic and keep the committed deletion.
                diagnostics = ["delete-leftover-trash: \(leftover.lastPathComponent)"]
            }
            if lastInstalledPackageID == packageID { lastInstalledPackageID = nil }
            message = nil
            await refresh()
            // The install is gone; its page pairings can be dropped once nothing else provides them.
            await reconcileCompositionsWithoutProvider()
        } catch {
            // Classify the real failure phase; the host failure page relies on it and must not claim "unchanged" for every error.
            failureState = Self.deletionFailureState(error)
            message = nil
            throw error
        }
    }

    /// Deletion failure -> `OperationFailureState`: `SchemePackageDeletion.Failure` carries its own
    /// classification; any other error comes from refusal or the prune step -> `.nothingCommitted`.
    nonisolated static func deletionFailureState(_ error: Error) -> OperationFailureState {
        if let failure = error as? SchemePackageDeletion.Failure { return failure.failureState }
        return .nothingCommitted
    }

    /// Deletion body, run on the engine serial queue while holding exclusive ownership.
    /// The scheme is pruned from the published state first (CAS against the baseline read here),
    /// then the directory moves to the trash and is deleted.
    nonisolated static func performDeletion(
        packageID: String, schemaIDs: Set<String>,
        layout: SchemePackageDeletion.Layout
    ) async throws
        -> SchemePackageDeletion.Outcome
    {
        let selection = try await AppliedSelectionLoader.loadActivation()
        let decision = InstalledSourceDeletionPolicy.decision(
            recipeEnabled: selection?.recipeEnabled ?? false,
            publicationSource: selection?.publicationSource,
            deletingPackageID: packageID)
        guard decision == .allowed else {
            throw RecipeInstallError.invalidResource(InstalledSourceDeletionPolicy.refusedMessage)
        }
        return try await SchemePackageDeletion.delete(packageID: packageID, layout: layout) {
            guard let current = selection else { return }
            _ = try await PublishedKeyboardPruner.prune(
                expected: current, deletedSchemaIDs: schemaIDs, deletingPackageID: packageID)
        }
    }

    /// Drops page pairings whose input method no longer has any provider, after reading the
    /// complete declared inventory. Returns whether the catalog was saved.
    ///
    /// Convergent by design: it identifies orphans from what is on disk now, so a failed save
    /// or a relaunch is repaired by the next successful read, and it never needs a record of
    /// which install was deleted. A pairing survives while any installed or damaged package
    /// still declares its input method (enabled or not) or a built-in scheme provides it, so
    /// disabling a scheme or leaving a keyboard unused removes nothing.
    ///
    /// An inventory that cannot be read completely keeps every pairing: it never guesses that
    /// an input method has no provider.
    @discardableResult
    func reconcileCompositionsWithoutProvider() async -> Bool {
        // No early return on an empty in-memory catalog: at launch it may not be loaded yet,
        // and LayoutManager reads the catalog before mutating, so skipping here would skip
        // exactly the relaunch that is supposed to repair an earlier failed cleanup.
        let root = Self.storeRoot
        let providers: Set<String>?
        do {
            providers = try await HostConfigIOQueue.async { Self.declaredInputMethods(in: root) }
        } catch {
            diagnostics.append("composition-cleanup-skipped: \(error.localizedDescription)")
            return false
        }
        guard let providers else {
            diagnostics.append("composition-cleanup-skipped: 读不到已安装的输入方式，这次没有清理页面搭配")
            return false
        }
        let saved = await LayoutManager.shared.pruneCompositions { !providers.contains($0) }
        if !saved, let detail = LayoutManager.shared.lastError {
            diagnostics.append("composition-cleanup-failed: \(detail)")
        }
        return saved
    }

    /// Input methods the installs on disk still declare: the built-in schemes plus every
    /// install's own declarations. The authoritative lists win over filenames, because a
    /// damaged install can lose `X.schema.yaml` while still declaring X.
    ///
    /// nil = something declared exists but could not be read, so the inventory is incomplete
    /// and the caller keeps every pairing rather than risk dropping a live preference.
    nonisolated static func declaredInputMethods(in storeRoot: URL) -> Set<String>? {
        let fm = FileManager.default
        var providers = Set(BuiltinTemplateSchemas.sourceSchemaIDs)
        guard fm.fileExists(atPath: storeRoot.path) else { return providers }
        guard
            let slots = try? fm.contentsOfDirectory(
                at: storeRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        for slot in slots {
            guard PublishedKeyboardSourceKey.validPackageID(slot.lastPathComponent) else { continue }
            guard let values = try? slot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            else { return nil }
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            // A real install slot that cannot be listed may be hiding declarations.
            guard (try? fm.contentsOfDirectory(atPath: slot.path)) != nil else { return nil }
            guard let ids = inputMethodIDs(inSlot: slot) else { return nil }
            providers.formUnion(ids)
        }
        return providers
    }

    /// Input methods one install slot declares. The active marker is the authority: it names
    /// the live generation and the default input method, so a lost resource directory still
    /// declares its method. nil = the slot exists but cannot be re-read completely.
    private nonisolated static func inputMethodIDs(inSlot slot: URL) -> Set<String>? {
        let marker: ActiveInstallMarker?
        do {
            marker = try readDeclaration(ActiveInstallMarker.self, at: slot.appendingPathComponent("active.json"))
        } catch { return nil }
        let versions = slot.appendingPathComponent("versions", isDirectory: true)
        guard let generations = try? FileManager.default.contentsOfDirectory(atPath: versions.path) else {
            // No versions/ is a failed or staging install; an unlistable one is incomplete.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: versions.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                return nil
            }
            return marker == nil ? [] : nil
        }
        guard let marker else {
            // No active marker: every generation present still declares its own methods.
            return generationInputMethodIDs(in: versions, generations: generations)
        }
        // The marker's generation must be re-readable, or the install's methods are unknown.
        guard generations.contains(marker.generation) else { return nil }
        let generation = versions.appendingPathComponent(marker.generation, isDirectory: true)
        // The marker names only the default method, so without the generation's own resources
        // the rest of its declared set cannot be recovered. The inventory is then incomplete,
        // rather than suddenly declaring just the default and dropping the others' preferences.
        var isDirectory: ObjCBool = false
        let resources = generation.appendingPathComponent("resources")
        guard FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        guard var ids = generationInputMethodIDs(in: generation) else { return nil }
        // A marked generation that declares nothing is damaged, not an install with no input
        // methods: the marker names only the default, so the set must not shrink to just it.
        guard !ids.isEmpty else { return nil }
        ids.insert(marker.schemaID)
        return ids
    }

    /// Input methods declared by the given generations of one slot.
    private nonisolated static func generationInputMethodIDs(
        in versions: URL, generations: [String]
    ) -> Set<String>? {
        var ids: Set<String> = []
        for name in generations {
            guard
                let declared = generationInputMethodIDs(
                    in: versions.appendingPathComponent(name, isDirectory: true))
            else { return nil }
            ids.formUnion(declared)
        }
        return ids
    }
    /// Input methods one generation declares. nil = a declaration in it is present but unreadable.
    private nonisolated static func generationInputMethodIDs(in generation: URL) -> Set<String>? {
        var ids: Set<String> = []
        for directory in ["resources", "user"] {
            guard let names = schemaFileNames(in: generation.appendingPathComponent(directory))
            else { return nil }
            ids.formUnion(names)
        }
        let resources = generation.appendingPathComponent("resources")
        do {
            if let declared = try readDeclaration(
                [KeyboardSchemaDescriptor].self,
                at: resources.appendingPathComponent("keyboard-schemas.json"))
            {
                ids.formUnion(declared.map(\.id))
            }
            if let declared = try readDeclaration(
                [String].self,
                at: resources.appendingPathComponent("keyboard-source-schemas.json"))
            {
                ids.formUnion(declared)
            }
        } catch { return nil }
        for build in ["resources/build", "user/build"] {
            guard
                let sources = adapterInputMethodIDs(
                    in: generation.appendingPathComponent(build), known: ids)
            else { return nil }
            ids.formUnion(sources)
        }
        return ids
    }

    /// Input methods a build declares. Its adapter registry maps each generated companion back
    /// to the source it serves. Without a registry, a schema file that is not already a known
    /// input method cannot be attributed, so the inventory stays incomplete (an ordinary 26-key
    /// install writes no registry and its build files are all known source schemas).
    private nonisolated static func adapterInputMethodIDs(in build: URL, known: Set<String>) -> Set<String>? {
        let registry = build.appendingPathComponent("keyboard-adapters.json")
        if FileManager.default.fileExists(atPath: registry.path) {
            guard
                let adapters = try? readDeclaration(
                    [KeyboardResourceSet.EncodingAdapter].self, at: registry)
            else { return nil }
            return Set(adapters.map(\.sourceSchemaID))
        }
        guard let names = schemaFileNames(in: build) else { return nil }
        return names.allSatisfy { known.contains($0) } ? [] : nil
    }

    /// `*.schema.yaml` names in a directory; [] when it is absent, nil when it exists but cannot
    /// be listed (only the latter makes the inventory incomplete).
    private nonisolated static func schemaFileNames(in directory: URL) -> Set<String>? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return nil }
        return Set(
            names.filter { $0.hasSuffix(schemaFileSuffix) }
                .map { String($0.dropLast(schemaFileSuffix.count)) })
    }

    /// The fields of the install's active marker this cleanup needs. Read as a narrow shape so
    /// the cleanup stays independent of the install record's full encoding.
    private struct ActiveInstallMarker: Decodable {
        let generation: String
        let schemaID: String
    }

    /// nil = the file is absent (an install that never wrote it).
    private nonisolated static func readDeclaration<T: Decodable>(
        _ type: T.Type, at url: URL
    ) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static let schemaFileSuffix = ".schema.yaml"

    /// Removes trash left by a deletion that was interrupted after the directory was moved.
    /// Trash entries are always already unpublished, so nothing needs to be restored.
    @discardableResult
    func recoverInterruptedDeletions() async -> [String] {
        guard !busy else { return [] }
        // Launch convergence: this runs whether or not the trash sweep below succeeds, so a
        // cleanup whose save failed earlier, or one an interrupted delete never reached, is
        // repaired from the installs that exist now. It is an idempotent read of the inventory.
        await reconcileCompositionsWithoutProvider()
        let layout = SchemePackageDeletion.Layout(
            storeRoot: Self.storeRoot,
            trashRoot: Self.deletionTrashRoot)
        do {
            let lines = try await EngineOwnershipCoordinator.shared.withExclusive {
                try await EngineOpQueue.asyncExclusive {
                    SchemePackageDeletion.purgeTrash(layout: layout)
                }
            }
            diagnostics = lines
            return lines
        } catch {
            diagnostics = ["delete-trash-cleanup-failed: \(error.localizedDescription)"]
            return diagnostics
        }
    }
}
