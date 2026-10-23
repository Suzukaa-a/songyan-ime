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

    /// Removes trash left by a deletion that was interrupted after the directory was moved.
    /// Trash entries are always already unpublished, so nothing needs to be restored.
    @discardableResult
    func recoverInterruptedDeletions() async -> [String] {
        guard !busy else { return [] }
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
