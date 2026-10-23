import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    /// Generates the requested combinations' adapters inside a transactional regeneration
    /// of the installed generation. `requested` is the exact list of user keyboards being
    /// added/updated; nothing else is generated. Any failure aborts without committing.
    private func prepareCompactKeyboards(
        packageID id: String, requested: [PublishedKeyboard],
        packageName explicitName: String? = nil,
        announce: Bool = true
    ) async throws {
        #if DEBUG
            let preparationStarted = Date()
            defer {
                let ms = Date().timeIntervalSince(preparationStarted) * 1000
                Logger.keyboardPreparation.debug("finished in \(ms, format: .fixed(precision: 1), privacy: .public) ms")
            }
        #endif
        if announce { message = "正在添加键盘…" }
        let store = manager(id)
        let packageName = explicitName ?? installedPackages.first { $0.id == id }?.name ?? id
        let reused = try await EngineOwnershipCoordinator.shared.withExclusive {
            guard let active = try await store.activeInstallation() else {
                throw RecipeInstallError.invalidResource("请先安装输入方案")
            }
            // Inspect this installation under the same lease as regeneration. A roster-only
            // change must not reinstall dictionaries or restart the engine unnecessarily.
            let reusable = try await KeyboardResourceReadQueue.async {
                let schemas = try KeyboardRecipeStore.deployedSchemas(
                    build: active.userDataURL.appendingPathComponent("build"))
                return try CompactAdapterDeployment.canReuseBuild(
                    resourceURL: active.resourceURL, userDataURL: active.userDataURL,
                    enabledSchemas: schemas, requested: requested)
            }
            if reusable {
                #if DEBUG
                    Logger.keyboardPreparation.debug(
                        "reused current installation; keyboards=\(requested.count, privacy: .public)")
                #endif
                return true
            }
            let snapshot = try await Self.readWorkspaceSnapshot(
                resources: active.resourceURL, userConfiguration: active.userDataURL)
            let sources = try await Self.readInstalledSources(resources: active.resourceURL)
            let task = Task.detached { () throws -> DeclarativeRecipePlan in
                let recipe = try DeclarativeRecipe(
                    path: "keyboard-adapters.recipe.yaml",
                    source: Data("recipe:\n  Rx: keyboard-adapters\n  description: 生成物理键盘编码适配\n".utf8))
                return try DeclarativeRecipePlan(
                    recipe: recipe, packageReference: id, selectedRecipe: "keyboard-adapters",
                    arguments: [], packageFiles: sources.files, existingFiles: snapshot.files,
                    sourceRevision: active.installation.revision, expectedGeneration: active.installation.generation,
                    packageFileResources: sources.fileResources, existingFileResources: snapshot.fileResources,
                    userCustomBaseline: snapshot.userCustomFiles,
                    sharedOpenCCDirectory: Bundle.main.url(
                        forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"))
            }
            let plan = try await withTaskCancellationHandler(
                operation: { try await task.value }, onCancel: { task.cancel() })
            let tasks = PublishedKeyboard.generationTasks(for: requested)
            _ = try await store.installRecipePlan(
                plan, packageID: id, schemaID: active.installation.schemaID,
                initialUserDataURL: nil,
                deploy: { deployment in
                    let verification = try await Self.verifyRecipeDeployment(
                        deployment, packageID: id, packageName: packageName, requestedAdapters: tasks)
                    // Every requested combination must be provably available in THIS
                    // generation: the enabled descriptors were just proven by the live
                    // engine. A combination that cannot be produced aborts the whole
                    // transaction, so a failed keyboard is never published.
                    let enabledSchemas = (verification.receipt.validatedEnabledSchemaIDs ?? []).map {
                        KeyboardSchemaDescriptor(id: $0, name: "", alphabet: "")
                    }
                    for combo in requested {
                        guard
                            CompactAdapterDeployment.combinationAvailable(
                                resourceURL: deployment.resourceURL,
                                userDataURL: deployment.userDataURL,
                                enabledSchemas: enabledSchemas,
                                requested: combo)
                        else {
                            throw RecipeInstallError.deployment(UserTerminology.layoutUnavailableReason(combo.layout))
                        }
                    }
                    return verification.receipt
                })
            return false
        }
        if reused { return }
        lastInstalledPackageID = id
        await refresh()
        diagnostics = []
        if announce { userNotice = "已准备所选键盘。" }
    }

    private static var outdatedAdapterRebuild: Task<Void, Never>?

    /// Keyboards saved before the current adapter generator keep their old adapters until they are
    /// regenerated, so once per launch the source in use is regenerated and republished when its
    /// published build carries an older generator. Silent unless it fails. Returns the launch's single run so
    /// other automatic changes can wait for it instead of contending for the installer.
    func rebuildOutdatedAdapters() -> Task<Void, Never> {
        if let run = Self.outdatedAdapterRebuild { return run }
        let run = Task { await rebuildAdaptersIfOutdated() }
        Self.outdatedAdapterRebuild = run
        return run
    }

    private func rebuildAdaptersIfOutdated() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let shared = try? await loadSharedActivation(), shared.kind == .userScheme,
            let packageID = shared.packageID,
            let active = try? await activeRecipe(packageID: packageID),
            // A pending update the user has not chosen is never applied silently.
            shared.revision == active.installation.revision,
            (try? await KeyboardResourceReadQueue.async({
                let published = try KeyboardRecipeStore.snapshot(for: shared, root: KeyboardRecipeStore.root())
                return CompactAdapterDeployment.publicationNeedsRebuild(
                    enabled: shared.recipeEnabled, keyboards: shared.keyboards, publishedBuild: published.build)
            })) == true
        else { return }
        do {
            try await prepareCompactKeyboards(packageID: packageID, requested: shared.keyboards, announce: false)
        } catch {
            fail(.nothingCommitted, error)
            return
        }
        do {
            // Keep whatever the user selected meanwhile, e.g. from the keyboard itself.
            try await publishRoster(
                packageID: packageID, roster: shared.keyboards, selection: nil,
                prepare: false, added: nil, baseline: .publication(shared), preservingSelection: true)
            HostLog.append("rebuilt keyboard adapters for generator \(CompactSchemaAdapter.displayGeneratorVersion)")
        } catch {
            fail(.installedNotApplied, error)
        }
    }

    /// Add/update ONE user keyboard (input method × layout) and select it.
    ///
    /// 14/9-key pairs run a combination-scoped adapter preparation whose `requested` set covers the
    /// **complete** post-transaction roster, so adding a second compact keyboard never drops the
    /// first one's adapter. A 26-key pair normally publishes directly, but when it moves an
    /// existing compact roster to a new installed revision that roster is regenerated first.
    func performAddKeyboard(packageID: String, keyboard: PublishedKeyboard) async throws
        -> UserKeyboardMutationOutcome
    {
        try await rosterTransaction("正在添加键盘…") {
            let shared = try await loadSharedActivation()
            let list = PublishedKeyboard.adding(
                keyboard, to: try await resolvedRosterForTargetSource(shared, packageID: packageID))
            let target = try await activeRecipe(packageID: packageID)
            let migratesCompactRoster =
                Self.sameSource(shared, packageID: packageID)
                && shared?.revision != target.installation.revision
                && list.contains(where: \.needsGeneratedAdapter)
            try await publishRoster(
                packageID: packageID, roster: list, selection: keyboard,
                prepare: keyboard.needsGeneratedAdapter || migratesCompactRoster,
                added: keyboard, baseline: shared.map { .publication($0) } ?? .absent)
            return UserKeyboardMutationOutcome(keyboard: keyboard, added: true, publishedKeyboards: list)
        }
    }

    /// Remove one keyboard. When it needed a generated adapter, the adapter registry is rebuilt for
    /// exactly the remaining roster. An unaffected selection is kept; removing the selected keyboard
    /// falls back to the first remaining one. Removing the last keyboard of a package is refused.
    func performRemoveKeyboard(packageID: String, keyboard: PublishedKeyboard) async throws
        -> UserKeyboardMutationOutcome
    {
        try await rosterTransaction("正在移除键盘…") {
            guard let shared = try await loadSharedActivation(),
                Self.sameSource(shared, packageID: packageID)
            else {
                throw UserKeyboardPublicationError.sourceNotInstalled
            }
            guard shared.keyboards.contains(keyboard) else { throw UserKeyboardPublicationError.notAdded }
            let list = PublishedKeyboard.removing(keyboard, from: shared.keyboards)
            if list.isEmpty { throw Self.keepOneKeyboard }
            let selected = shared.selectedSchemaID.flatMap { schemaID in
                shared.selectedLayout.map { PublishedKeyboard(schemaID: schemaID, layout: $0) }
            }
            try await publishRoster(
                packageID: packageID, roster: list,
                selection: PublishedKeyboard.selectionAfterRemoval(from: list, current: selected),
                prepare: keyboard.needsGeneratedAdapter, added: nil,
                baseline: .publication(shared))
            return UserKeyboardMutationOutcome(keyboard: keyboard, added: false, publishedKeyboards: list)
        }
    }

    /// Apply the complete edited roster with one adapter preparation and one publication. A page-bound
    /// save passes the publication it was read from (`viewedActivation`); the store refuses the save
    /// when the publication changed since. `selecting` makes that pair the current keyboard ("use now");
    /// without it the current selection is kept when it survives, otherwise the first pair is used.
    func performReplaceKeyboards(
        packageID: String, requested: [PublishedKeyboard],
        selecting: PublishedKeyboard? = nil,
        viewedActivation: KeyboardRecipeStore.Activation? = nil,
        viewedRoster: [PublishedKeyboard]? = nil,
        viewedSourceKey: String? = nil
    ) async throws
        -> [PublishedKeyboard]
    {
        try await rosterTransaction("正在更新我的键盘…") {
            let shared = try await loadSharedActivation()
            var list: [PublishedKeyboard] = []
            for keyboard in requested where !list.contains(keyboard) { list.append(keyboard) }
            if let selecting, !list.contains(selecting) { list.append(selecting) }
            if list.isEmpty { throw Self.keepOneKeyboard }
            let installed = try await activeRecipe(packageID: packageID)
            let selected =
                Self.sameSource(shared, packageID: packageID)
                ? shared?.selectedSchemaID.flatMap { schemaID in
                    shared?.selectedLayout.map { PublishedKeyboard(schemaID: schemaID, layout: $0) }
                } : nil
            if Self.sameSource(shared, packageID: packageID), shared?.recipeEnabled == true,
                shared?.revision == installed.installation.revision,
                shared?.hostInstallationGeneration == installed.installation.generation,
                shared?.keyboards == list, selecting == nil || selecting == selected
            {
                return list
            }
            let baseline: KeyboardRecipeStore.PublishBaseline =
                (viewedRoster != nil ? viewedActivation : shared)
                .map { .publication($0) } ?? .absent
            try await publishRoster(
                packageID: packageID, roster: list,
                selection: selecting ?? selected.flatMap { list.contains($0) ? $0 : nil } ?? list.first,
                prepare: true, added: nil, baseline: baseline)
            return list
        }
    }

    private static let keepOneKeyboard = UserKeyboardPublicationError.unavailable(
        "请至少保留一个键盘。如需停用整个方案，请直接删除该输入方案。")

    /// Runs one roster change; `busy` is the only gate (the engine lease and the store's compare-and-set
    /// cover everything else). Conflicts throw, failures propagate unchanged and publish nothing.
    private func rosterTransaction<T>(_ progress: String, _ body: () async throws -> T) async throws -> T {
        guard !busy else { throw UserKeyboardPublicationError.busy }
        busy = true
        defer {
            busy = false
            message = nil
        }
        message = progress
        return try await body()
    }

    /// The one publish path for add, remove and replace. `prepare` regenerates the compact adapters
    /// for `roster`, whose deployment proves every requested pair; a pair published without that
    /// (`added`, 26-key) is checked against the installed resources instead.
    private func publishRoster(
        packageID: String, roster: [PublishedKeyboard], selection: PublishedKeyboard?,
        prepare: Bool, added: PublishedKeyboard?,
        baseline: KeyboardRecipeStore.PublishBaseline, preservingSelection: Bool = false
    ) async throws {
        if prepare {
            try await prepareCompactKeyboards(
                packageID: packageID, requested: roster,
                packageName: installedPackages.first { $0.id == packageID }?.name)
        }
        let resources = try await keyboardResources(packageID: packageID)
        if !prepare, let added {
            guard resources.schemas.contains(where: { $0.id == added.schemaID }) else {
                throw UserKeyboardPublicationError.unavailable("此输入方案已变更，请重新选择。")
            }
            guard
                resources.availableCombinations.contains(where: {
                    $0.schemaID == added.schemaID && $0.layout == added.layout
                })
            else {
                throw UserKeyboardPublicationError.unavailable(UserTerminology.layoutUnavailableReason(added.layout))
            }
        }
        let active = try await activeRecipe(packageID: packageID)
        try await EngineOwnershipCoordinator.shared.withExclusive {
            try await EngineOpQueue.async {
                try KeyboardRecipeStore.publish(
                    resources: active.resourceURL,
                    compiledBuild: active.userDataURL.appendingPathComponent("build"),
                    revision: active.installation.revision, kind: .userScheme,
                    dictionaryName: resources.name,
                    packageID: packageID, schemas: resources.schemas,
                    selectedSchemaID: selection?.schemaID, layout: selection?.layout,
                    bindings: resources.layoutEntries, publishedKeyboards: roster,
                    preservingSelection: preservingSelection, baseline: baseline)
            }
        }
        selectionRevision = UUID()
    }

    /// Narrow transaction bound to one source, used by the dictionary import flow.
    func userKeyboardTransaction(packageID: String) -> any UserKeyboardPublicationTransaction {
        SchemeKeyboardPublicationTransaction(center: self, packageID: packageID)
    }

    /// Current published keyboards for a source (transaction read; no UI state).
    func publishedKeyboards(packageID: String) async throws -> [PublishedKeyboard] {
        // Read the roster of the source itself by source identity: the current source uses the record directly, other sources use their persisted
        // cross-source roster. A read failure is not silently treated as "no keyboards" (throws; the caller keeps the old roster).
        let shared = try await AppliedSelectionLoader.loadActivation()
        return try await resolvedRosterForTargetSource(shared, packageID: packageID)
    }

    private func loadSharedActivation() async throws -> KeyboardRecipeStore.Activation? {
        do { return try await AppliedSelectionLoader.loadWriteBaseline() } catch {
            throw KeyboardRecipeStore.StoreError(message: "共享选择读取失败：\(error.localizedDescription)")
        }
    }

    private static func sameSource(
        _ activation: KeyboardRecipeStore.Activation?,
        packageID: String
    ) -> Bool {
        guard let activation else { return false }
        return activation.kind == .userScheme && activation.packageID == packageID
    }

    /// The target source's structured roster key (same kind as used when `performAddKeyboard` publishes).
    /// Cross-source keyboard rosters are persisted under this key.
    nonisolated static func rosterKey(packageID: String) -> String? {
        KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: packageID)
    }

    /// The target source's full keyboard roster from its last successful publication (authoritative baseline).
    ///
    /// - If the shared record belongs to that source, the record's flat roster is its roster;
    /// - if the record belongs to another source, use that source's own roster in the record (`keyboardsBySource`),
    ///   never the current source's roster as baseline, and never an empty set merely because the source differs;
    /// - if the record has no entry for that source (first publication), an empty roster:
    ///   the install of this source re-enumerates (compact layouts regenerate and validate / 26-key uses the default layout), never guessing.
    func resolvedRosterForTargetSource(
        _ shared: KeyboardRecipeStore.Activation?,
        packageID: String
    ) async throws -> [PublishedKeyboard] {
        guard let shared else { return [] }
        if Self.sameSource(shared, packageID: packageID) { return shared.keyboards }
        guard let key = Self.rosterKey(packageID: packageID),
            let stored = shared.keyboardsBySource?[key]
        else { return [] }
        return stored
    }

    private func activeRecipe(packageID: String) async throws -> ActiveRecipe {
        // Publication must observe the committed marker, even before the source list refreshes.
        if PublishedKeyboardSourceKey.validPackageID(packageID),
            let active = try await manager(packageID).activeInstallation()
        {
            return active
        }
        throw UserKeyboardPublicationError.sourceNotInstalled
    }

    /// Human-facing projection of added keyboards (long-press switcher / list): names come from the current publication record's
    /// structured scheme descriptions (`activation.schemas`), not persisted and not hardcoded. A read failure throws; the caller
    /// keeps the old roster and reports the failure, never treating failure as "no keyboards".
    func publishedKeyboardDisplays(packageID: String) async throws -> [PublishedKeyboardDisplay] {
        let resources = try await keyboardResources(packageID: packageID)
        let published = try await publishedKeyboards(packageID: packageID)
        return resources.publishedDisplays(published)
    }

    /// A user-facing notice for published keyboards that currently cannot run (compact layout missing structured adapter/binding, or engine schema missing);
    /// nil when all can run. The list uses it to explain why, never treating "published but not runnable" as usable,
    /// and never silently adding a source combination.
    func unrunnableKeyboardNotice(packageID: String) async throws -> String? {
        let resources = try await keyboardResources(packageID: packageID)
        let published = try await publishedKeyboards(packageID: packageID)
        let unrunnable = resources.unrunnablePublished(published)
        guard !unrunnable.isEmpty else { return nil }
        let names = unrunnable.map { UserTerminology.layoutName($0.layout) }.joined(separator: "、")
        return "有 \(unrunnable.count) 个已添加的键盘暂时无法使用（\(names)）。请重新添加该键盘。"
    }

    /// Candidate keyboards that can be added for the current source (input method x layout): 26-key is directly available; compact layouts (14 / 9)
    /// are listed only when the source is structurally adaptable and the physical alphabet can fold. Used by the "add keyboard" UI;
    /// the list holds candidates to try adding, and an add failure is reported as such, never pretending to be usable here.
    func addableKeyboards(packageID: String) async throws -> [PublishedKeyboard] {
        let resources = try await keyboardResources(packageID: packageID)
        return try await KeyboardResourceReadQueue.async {
            let build = resources.prebuiltDirectory ?? resources.userDirectory.appendingPathComponent("build")
            let auxiliarySchemaIDs = Set(resources.englishCandidateRoutes.map(\.candidateSchemaID))
            let enabled =
                (resources.schemas.isEmpty
                ? Array(Set(resources.layoutEntries.map(\.schemaID))).sorted()
                : resources.schemas.map(\.id)).filter { !auxiliarySchemaIDs.contains($0) }
            // Native layouts and explicit author bindings remain usable even when
            // the schema cannot safely generate an automatic compact adapter.
            var result = resources.availableCombinations.map {
                PublishedKeyboard(schemaID: $0.schemaID, layout: $0.layout)
            }
            for source in enabled {
                guard let compiled = try? Data(contentsOf: build.appendingPathComponent(source + ".schema.yaml")),
                    case .adaptable = (try? CompactSchemaAdapter.adaptability(compiled: compiled, sourceID: source))
                        ?? .unsupported("")
                else { continue }
                let alphabet = resources.schemas.first { $0.id == source }?.alphabet
                for layout in KeyboardLayoutKind.allCases where layout.requiresSpellingDisplay {
                    let foldable =
                        layout.compactFold.flatMap { fold in
                            (alphabet.flatMap { $0.isEmpty ? nil : $0 }).map {
                                CompactSchemaAdapter.physicalFold(sourceAlphabet: $0, fold: fold) != nil
                            }
                        } ?? false
                    guard foldable else { continue }
                    let keyboard = PublishedKeyboard(schemaID: source, layout: layout)
                    if !result.contains(keyboard) { result.append(keyboard) }
                }
            }
            return result
        }
    }

    func installedKeyboardIdentity(packageID: String) async throws -> (revision: String, generation: String) {
        let active = try await activeRecipe(packageID: packageID)
        return (active.installation.revision, active.installation.generation)
    }

    func keyboardResources(packageID: String) async throws -> KeyboardResourceSet {
        if let set = try await tryResources(packageID: packageID) { return set }
        throw RecipeInstallError.deployment("未找到已安装方案")
    }
}
