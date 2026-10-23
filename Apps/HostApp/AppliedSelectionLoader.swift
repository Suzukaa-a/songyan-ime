import Foundation
import KeyboardCore

/// Structured async reads of the shared published selection (HostApp layer).
///
/// `KeyboardRecipeStore.activation()` does disk I/O (`Data(contentsOf:)`) and must never run on the MainActor.
/// All reads go through `KeyboardResourceReadQueue` (a dedicated low-priority read-only queue); the main thread only applies the returned value.
///
/// Returns plain values; callers (KeyboardSelectionCenter / views) only derive from them.
enum AppliedSelectionLoader {
    /// On failure, only queries the system-granted container in the background; an entitlement declared in the IPA does not imply an installation grant.
    static func sharedContainerUnavailable() async -> Bool {
        (try? await KeyboardResourceReadQueue.async {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: KeyboardRecipeStore.groupID) == nil
        }) ?? false
    }

    static let missingGroupMessage = "暂时无法读取设置，请重新安装 App 后再试。"

    static func readFailureMessage() async -> String {
        return await sharedContainerUnavailable() ? missingGroupMessage : "无法读取状态，请重试。"
    }

    /// One read; returns a selection snapshot (success) or an error.
    static func load() async -> AppliedSelectionLoadOutcome {
        do {
            return try await KeyboardResourceReadQueue.async {
                guard let activation = try KeyboardRecipeStore.activation() else {
                    // No publication record is a successful read of an **empty snapshot**, not Optional.none (failure).
                    // Otherwise resolve would keep the old selection and the UI would still show the old scheme after unpublishing.
                    return AppliedSelectionLoadOutcome(
                        snapshot: AppliedSelectionSnapshot.none,
                        error: nil)
                }
                return AppliedSelectionLoadOutcome(
                    snapshot: AppliedSelectionSnapshot(
                        recipeEnabled: activation.recipeEnabled,
                        resourceKind: activation.kind.rawValue,
                        selectedSchemaID: activation.selectedSchemaID,
                        requiredSchemaIDs: activation.requiredSchemaIDs,
                        revision: activation.revision,
                        dictionaryName: activation.dictionaryName,
                        packageID: activation.packageID,
                        hasRealPublication: !ProductionInputAvailability.isBuiltin(
                            resourceID: activation.resourceID),
                        publicationName: activation.name,
                        displayConfigName: activation.displayConfigName,
                        schemas: activation.schemas ?? [],
                        selectedLayout: activation.selectedLayout),
                    error: nil)
            }
        } catch {
            return AppliedSelectionLoadOutcome(snapshot: nil, error: await readFailureMessage())
        }
    }

    /// Convenience: returns the snapshot on success, nil on failure (callers keep the old value).
    static func loadSnapshot() async -> AppliedSelectionSnapshot? {
        await load().snapshot
    }

    /// Selection snapshot plus the strict validation result for published resources (`InputSchemeListView` uses it for `resourceError`).
    /// Validation (`snapshot(selectedOnly:)`, which resolves the deployed default) also runs on the read-only queue.
    static func loadWithResourceValidation() async
        -> (snapshot: AppliedSelectionSnapshot?, selectionError: String?, resourceError: String?)
    {
        do {
            return try await KeyboardResourceReadQueue.async {
                guard let activation = try KeyboardRecipeStore.activation() else {
                    return (AppliedSelectionSnapshot.none, nil, nil)
                }
                let snapshot = AppliedSelectionSnapshot(
                    recipeEnabled: activation.recipeEnabled,
                    resourceKind: activation.kind.rawValue,
                    selectedSchemaID: activation.selectedSchemaID,
                    requiredSchemaIDs: activation.requiredSchemaIDs,
                    revision: activation.revision,
                    dictionaryName: activation.dictionaryName,
                    packageID: activation.packageID,
                    hasRealPublication: !ProductionInputAvailability.isBuiltin(
                        resourceID: activation.resourceID),
                    publicationName: activation.name,
                    schemas: activation.schemas ?? [],
                    selectedLayout: activation.selectedLayout)
                var resourceError: String?
                do { _ = try KeyboardRecipeStore.snapshot(selectedOnly: true) } catch {
                    HostLog.append("published resource validation failed: \(error.localizedDescription)")
                    resourceError = "无法读取当前输入方案，请在「输入方案」中重新选择。"
                }
                return (snapshot, nil, resourceError)
            }
        } catch {
            return (nil, await readFailureMessage(), nil)
        }
    }

    /// Structured read when the raw `Activation` value is needed (publish baseline CAS etc.); runs on the read-only queue.
    static func loadActivation() async throws -> KeyboardRecipeStore.Activation? {
        try await KeyboardResourceReadQueue.async { try KeyboardRecipeStore.activation() }
    }

    /// The record a publication starts from; a damaged record reads as none so publishing replaces it.
    static func loadWriteBaseline() async throws -> KeyboardRecipeStore.Activation? {
        try await KeyboardResourceReadQueue.async { try KeyboardRecipeStore.writeBaseline() }
    }
}

/// Async prune/restore interface for the publish manifest when an install is deleted.
///
/// Runs the `KeyboardRecipeStore` CAS prune/restore on a dedicated background queue,
/// for deletion transactions that call it from a synchronous closure inside the engine queue / coordinator lease and need an async boundary.
/// Callers only `await` this interface and never duplicate any store implementation.
enum PublishedKeyboardPruner {
    /// Cleans up by provenance: when the deleted source IS the current source, prunes the flat manifest by `deletedSchemaIDs`
    /// and fixes the selection; otherwise only clears the deleted source's own cross-source cache keys and never touches the current
    /// source's flat manifest or other sources. CAS verifies the publication record was not modified concurrently.
    static func prune(
        expected: KeyboardRecipeStore.Activation,
        deletedSchemaIDs: Set<String>,
        deletingPackageID: String
    ) async throws
        -> (result: PublishedKeyboardPrune.Result, updated: KeyboardRecipeStore.Activation?)
    {
        try await KeyboardResourceReadQueue.async {
            try KeyboardRecipeStore.prunePublishedKeyboards(
                expected: expected,
                deletingSource: .userScheme(packageID: deletingPackageID),
                deletedSchemaIDs: deletedSchemaIDs)
        }
    }

    /// Atomic inverse of prune (CAS): rolls back only if the on-disk record still equals `expected` (the post-prune record).
    static func restore(
        _ original: KeyboardRecipeStore.Activation,
        expectingCurrent expected: KeyboardRecipeStore.Activation
    ) async throws {
        try await KeyboardResourceReadQueue.async {
            try KeyboardRecipeStore.restorePublishedKeyboards(original, expectingCurrent: expected)
        }
    }
}

/// One structured async read for the onboarding status row: reads `activation` on the read-only queue and resolves the
/// plain-value inputs needed for display (input method name / layout name / config name / source identity).
/// Never leaves `Data(contentsOf:)` on the MainActor.
enum AppliedSelectionDisplayLoader {
    static func load() async -> AppliedSelectionDisplayInputs? {
        do {
            return try await KeyboardResourceReadQueue.async {
                guard let activation = try KeyboardRecipeStore.activation() else { return nil }
                return AppliedSelectionDisplayInputs(
                    resourceID: activation.resourceID,
                    recipeEnabled: activation.recipeEnabled,
                    resourceKind: activation.kind.rawValue,
                    displayConfigName: activation.displayConfigName,
                    // Resolves by `selectedSchemaID` only (no required fallback).
                    selectedInputMethodName: UserTerminology.inputMethodName(
                        schemaID: activation.selectedSchemaID, schemas: activation.schemas),
                    selectedLayoutName: activation.selectedLayout.map { UserTerminology.layoutName($0) })
            }
        } catch {
            return nil
        }
    }
}
