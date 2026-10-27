import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    // MARK: - Declarative recipe

    /// Discover `*.recipe.yaml` and the root `recipe.yaml` in freshly imported package bytes.
    /// Unsupported semantics surface as a concrete parse error, never as silent success.
    func discoverRecipes(in prepared: PreparedSchemeImport) {
        var found: [DiscoveredRecipe] = []
        var failures: [String] = []
        var userFailures: [String] = []
        let candidates = prepared.sourceFiles.keys
            .filter { $0 == "recipe.yaml" || $0.hasSuffix(".recipe.yaml") }
            .sorted()
        for path in candidates {
            do {
                let recipe = try DeclarativeRecipe(path: path, source: prepared.sourceFiles[path]!)
                found.append(
                    DiscoveredRecipe(
                        path: path, declaredName: recipe.declaredName,
                        displayDescription: recipe.displayDescription,
                        declaredArguments: recipe.declaredArguments, downloads: recipe.downloads,
                        installPatterns: recipe.installPatterns, patchTargets: recipe.patchTargets))
            } catch {
                let raw = "\(path)：\(error.localizedDescription)"
                failures.append(raw)
                HostLog.append("recipe discovery failed: \(raw)")
                let notice = Self.recipeDiscoveryNotice(error)
                if !userFailures.contains(notice) { userFailures.append(notice) }
            }
        }
        recipes = found
        recipeDiscoveryErrors = failures
        plannedRecipe = nil
        plannedDiagnostics =
            userFailures.isEmpty
            ? (found.isEmpty ? ["此方案没有可调整的选项。"] : [])
            : userFailures
    }
    /// Build a plan for the currently prepared import using its immutable source snapshot.
    /// `arguments` are literal name=value pairs chosen in the UI (omitted args are NOT sent —
    /// recipe.args never sets environment defaults; an empty value is an explicit empty);
    /// downloads must be provided explicitly (file references for models, bounded bytes for
    /// ordinary resources) before planning succeeds. `stages` are appended in order after the
    /// root recipe via `plan.appending`. Out-of-scope recipes fail loudly here.
    /// Plan construction (including the whole-tree hash) runs on a background thread; install re-collects the UI inputs and compares them to guard against stale plans.
    func planRecipe(
        _ recipePath: String, arguments: [RecipeArgument],
        stages: [RecipeStage] = []
    ) {
        guard !busy, let prepared else { return }
        retryState.begin(
            .planRecipe(
                recipePath: recipePath, arguments: arguments,
                stages: Self.retryStages(stages), installed: false))
        guard prepared.sourceFiles[recipePath] != nil else {
            HostLog.append("recipe planning rejected missing imported path: \(recipePath)")
            error = "所选选项已不可用，请重新选择。"
            return
        }
        busy = true
        error = nil
        plannedDiagnostics = []
        message = "正在检查…"
        let downloads = providedOrdinaryResources.mapValues(\.data)
        let downloadFiles = providedDownloadFiles
        let packageID = prepared.declaration.id
        Task {
            defer { busy = false }
            do {
                // File/URL replacement keeps the destination package identity. Its
                // recipes must start from that installation, not an empty workspace.
                // Capture after stopping Host writers; the installer rechecks this
                // generation and the complete custom baseline at commit time.
                let store = manager(packageID)
                let baseline = try await EngineOwnershipCoordinator.shared.withExclusive {
                    () async throws -> InstalledRecipeWorkspace? in
                    guard let active = try await store.activeInstallation() else { return nil }
                    let snapshot = try await Self.readWorkspaceSnapshot(
                        resources: active.resourceURL,
                        userConfiguration: active.userDataURL)
                    return InstalledRecipeWorkspace(
                        packageID: packageID, displayName: prepared.declaration.name,
                        revision: active.installation.revision, generation: active.installation.generation,
                        initialUserDataURL: nil, snapshot: snapshot)
                }
                let plan = try await Self.buildPlan(
                    recipePath: recipePath, arguments: arguments, stages: stages,
                    packageID: packageID, packageFiles: prepared.sourceFiles,
                    packageFileResources: prepared.sourceFileResources,
                    existingFiles: baseline?.snapshot.files ?? [:],
                    existingFileResources: baseline?.snapshot.fileResources ?? [:],
                    userCustomBaseline: baseline?.snapshot.userCustomFiles ?? [:],
                    sourceRevision: prepared.manifest.revision, expectedGeneration: baseline?.generation,
                    downloads: downloads, downloadFiles: downloadFiles)
                var summary = Self.planSummary(plan, preparedSchemaIDs: prepared.schemaIDs)
                Self.appendModelNotes(to: &summary, plan: plan)
                // The entry is not inferred from source ordering: deploy takes the first actually enabled item on the real engine and writes the
                // full receipt set; the entry the manifest needs is predicted from the plan's effective config (including configs that change
                // schema_list), and the real entry follows the post-deploy list.
                let requestedEntry = Self.requestedEntrySchema(
                    plan: plan,
                    manifestEntry: prepared.manifest.schemaID, manifestFiles: [:])
                let deployable = plan.files.keys.contains(where: InstalledPackageLayout.isTopLevelSchemaFile)
                plannedRecipe = PlannedRecipeInstall(
                    recipePath: recipePath, rx: plan.rx,
                    schemaID: requestedEntry.isEmpty == false && deployable ? requestedEntry : "",
                    changedPaths: plan.changedPaths,
                    summary: summary, plan: plan)
                plannedDiagnostics = []
                retryState.succeeded()
                message = nil
            } catch {
                HostLog.append("recipe planning failed: \(error.localizedDescription)")
                let notice = Self.recipePlanningNotice(error)
                fail(.nothingCommitted, notice)
                plannedDiagnostics = [notice]
                message = nil
            }
        }
    }

    /// Raw recipe errors may contain package-relative paths, schema identifiers, hashes or
    /// engine component names. They belong in the developer log, never in normal user UI.
    nonisolated private static func recipeDiscoveryNotice(_ error: Error) -> String {
        switch error {
        case RecipeInstallError.invalidManifest:
            return "部分选项无效，已忽略。"
        case RecipeInstallError.invalidResource:
            return "部分选项暂不支持，已忽略。"
        default:
            return "部分选项无法读取，已忽略。"
        }
    }

    nonisolated private static func recipePlanningNotice(_ error: Error) -> String {
        switch error {
        case RecipeInstallError.http(let code):
            return "配置检查未完成（HTTP \(code)），请检查网络后重试。"
        case RecipeInstallError.busy:
            return "另一项操作正在进行，请稍后再试。"
        case RecipeInstallError.missingComponents:
            return "此方案需要松烟暂不支持的功能。"
        case RecipeInstallError.missingGrammarModels:
            return "这个方案还需要语法模型文件。请在「语法模型」里添加后重试。"
        case RecipeInstallError.invalidManifest, RecipeInstallError.invalidResource:
            return "文件不完整或格式不正确。"
        case RecipeInstallError.deployment:
            return "无法完成安装，请重试。"
        default:
            return "无法检查此选项，请重新选择。"
        }
    }

    /// Shared off-main plan construction. Root stage plans from the immutable source snapshot;
    /// each later stage is appended in order, keeping the first user-custom baseline (core).
    private static func buildPlan(
        recipePath: String, arguments: [RecipeArgument], stages: [RecipeStage],
        packageID: String, packageFiles: [String: Data],
        packageFileResources: [String: RecipeFileResource],
        existingFiles: [String: Data] = [:],
        existingFileResources: [String: RecipeFileResource] = [:],
        userCustomBaseline: [String: Data] = [:],
        sourceRevision: String? = nil, expectedGeneration: String? = nil,
        downloads: [String: Data], downloadFiles: [String: RecipeFileResource]
    ) async throws -> DeclarativeRecipePlan {
        let task = Task.detached(priority: .userInitiated) { () throws -> DeclarativeRecipePlan in
            guard let source = packageFiles[recipePath] else {
                throw RecipeInstallError.invalidResource("在可用源码中未找到所选方案配置：\(recipePath)")
            }
            let recipe = try DeclarativeRecipe(path: recipePath, source: source)
            var plan = try DeclarativeRecipePlan(
                recipe: recipe, packageReference: packageID,
                selectedRecipe: Self.selectedRecipeReference(recipe), arguments: arguments,
                packageFiles: packageFiles, existingFiles: existingFiles,
                providedDownloads: downloads, sourceRevision: sourceRevision,
                expectedGeneration: expectedGeneration,
                packageFileResources: packageFileResources,
                existingFileResources: existingFileResources,
                providedDownloadFiles: downloadFiles,
                userCustomBaseline: userCustomBaseline,
                sharedOpenCCDirectory: Bundle.main.url(
                    forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"))
            for stage in stages {
                try Task.checkCancellation()
                guard let stageSource = packageFiles[stage.path] else {
                    throw RecipeInstallError.invalidResource("在可用源码中未找到所选方案配置：\(stage.path)")
                }
                let stageRecipe = try DeclarativeRecipe(path: stage.path, source: stageSource)
                plan = try plan.appending(
                    recipe: stageRecipe, packageReference: packageID,
                    selectedRecipe: Self.selectedRecipeReference(stageRecipe), arguments: stage.arguments,
                    packageFiles: packageFiles, providedDownloads: downloads,
                    packageFileResources: packageFileResources, providedDownloadFiles: downloadFiles)
            }
            return plan
        }
        // Forward cancellation to the detached computation and wait for it to actually finish (plan construction includes the whole-tree hash).
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// plum `check_recipe_info` semantics: when the user explicitly picked a non-root
    /// recipe, the Rx reference passed to the plan must be the recipe path stem, and the core
    /// verifies the declared `recipe.Rx` matches it. The root `recipe.yaml` is exempt.
    nonisolated private static func selectedRecipeReference(_ recipe: DeclarativeRecipe) -> String {
        guard recipe.path != "recipe.yaml" else { return "" }
        let stem = recipe.path.hasSuffix(".recipe.yaml") ? String(recipe.path.dropLast(12)) : recipe.path
        return stem
    }

    /// Shared plan summary. Grammar in the plan output is reported as a real prerequisite:
    /// installation loads the actual model in the deployment directory or fails and keeps the
    /// previous state. A provided model file by itself is never presented as proof of loading.
    private static func planSummary(_ plan: DeclarativeRecipePlan, preparedSchemaIDs: [String]) -> [String] {
        var summary: [String] = []
        if !plan.changedPaths.isEmpty { summary.append("将更改 \(plan.changedPaths.count) 个文件") }
        if !plan.replacedManagedBlocks.isEmpty { summary.append("将更新 \(plan.replacedManagedBlocks.count) 项设置") }
        if !plan.retainedDifferentInvocations.isEmpty {
            summary.append("将保留 \(plan.retainedDifferentInvocations.count) 项其他设置")
        }
        if !plan.externalResources.isEmpty { summary.append("还需要 \(plan.externalResources.count) 个附加文件") }
        // Grammar is a real prerequisite. Detect it from the plan's actual output (the patch
        // target may contain ${schema:-…} expansion), and state only what will happen: the
        // deployment validator must load the real model or the install fails and keeps the
        // previous state. A provided file by itself is never reported as "loaded".
        let grammarOutputs = plan.files.keys.filter { $0.hasSuffix(".custom.yaml") }.sorted().filter { path in
            plan.files[path].flatMap { String(data: $0, encoding: .utf8) }?.contains("grammar:") == true
        }
        if !grammarOutputs.isEmpty {
            summary.append("需要先准备语法模型")
        }
        // plum semantics: a patch-only recipe copies no package sources; without a
        // schema in the plan output the fresh import would have nothing to deploy.
        let installedSchemas = InstalledPackageLayout.topLevelSchemaFiles(in: plan.files.keys)
        if installedSchemas.isEmpty {
            summary.append("此选项仅更改设置，请先点「安装」安装方案。")
        }
        return summary
    }

    /// Provided-file status lines. Only factual size/SHA facts — presence of the file says
    /// nothing about engine loading, so no "ready/loaded" wording here.
    private static func appendModelNotes(to summary: inout [String], plan: DeclarativeRecipePlan) {
        for (path, file) in plan.fileResources.sorted(by: { $0.key < $1.key }) {
            guard RecipeResourceBudget.isModel(path) else { continue }
            let kind = Prediction.isDatabasePath(path) ? "联想词库" : "语法模型"
            summary.append(
                "已提供\(kind)（\(HostStorePaths.fileSizeText(file.size))）")
        }
    }

    /// Install the planned recipe for the fresh import through the shared scheme-import
    /// deploy verifier. Still does not change the current selection; failures retain state.
    /// The entry schema is not inferred from source ordering: deploy validates every enabled scheme on the real engine,
    /// takes the first item of the actually enabled list as the entry, and writes the full enabled set into the receipt for the core to compare.
    func installPlannedRecipe(
        currentRecipePath: String, currentArguments: [RecipeArgument], currentStages: [RecipeStage]
    ) {
        guard !busy, let planned = plannedRecipe, let prepared else { return }
        retryState.begin(
            .installPlannedRecipe(
                recipePath: currentRecipePath, arguments: currentArguments,
                stages: Self.retryStages(currentStages), installed: false))
        busy = true
        error = nil
        let sourceURLAtInstall = preparedSourceURL
        message = "正在安装…"
        Task {
            defer { busy = false }
            do {
                let manager = manager(prepared.declaration.id)
                let requestedEntry = planned.schemaID.isEmpty ? prepared.manifest.schemaID : planned.schemaID
                try await EngineOwnershipCoordinator.shared.withExclusive {
                    _ = try await manager.installRecipePlan(
                        planned.plan, packageID: prepared.declaration.id,
                        schemaID: requestedEntry,
                        deploy: { deployment in
                            let verification = try await Self.verifyRecipeDeployment(
                                deployment, packageID: prepared.declaration.id, packageName: nil)
                            // Keep the package declaration discoverable by refresh()/apply().
                            let declaration = prepared.declaration
                            try JSONEncoder().encode(declaration).write(
                                to: deployment.resourceURL.appendingPathComponent(
                                    InstalledPackageLayout.keyboardPackageFile),
                                options: .atomic)
                            return verification.receipt
                        })
                }
                self.prepared = nil
                self.plannedRecipe = nil
                preparedSourceURL = nil
                lastInstalledPackageID = prepared.declaration.id
                retryState.succeeded()
                // A file update keeps the download address an earlier import recorded, so later updates
                // can still fetch from it. A Rime source origin cannot survive an install that did not
                // come from that source, so it is cleared and the scheme counts as a local file again.
                let sourceWarning: String?
                if let sourceURLAtInstall {
                    sourceWarning = saveSource(sourceURLAtInstall, packageID: prepared.declaration.id)
                } else if Self.recordedSourceTarget(packageID: prepared.declaration.id) != nil {
                    sourceWarning = saveSource(nil, packageID: prepared.declaration.id)
                } else {
                    sourceWarning = nil
                }
                providedDownloadFiles = [:]
                providedOrdinaryResources = [:]
                diagnostics = []
                userNotice = UserNoticeLayering.installationNextStep(
                    installedPackageID: prepared.declaration.id)
                message = sourceWarning
                await refresh()
            } catch {
                fail(.nothingCommitted, error)
                message = nil
            }
        }
    }

    /// Shared deploy verification for recipe plan installs/updates. Each enabled
    /// schema passes the unified validator (compiled dependency closure → actual registry
    /// components → grammar prerequisites → select → live grammar instance); the entry is the
    /// first actually-enabled schema, and the complete enabled set goes into the receipt for
    /// the core to check against user/build/default.yaml before committing.
    ///
    /// `keyboard-schemas.json` (the runnable list) only records the enabled schemes validated this time, for trial typing/publishing;
    /// schemas present in source but not enabled go to `keyboard-source-schemas.json`, display only, never part of the trial/publish set.
    struct DeployVerification {
        let receipt: RecipeDeploymentReceipt
    }

    /// `postValidation` runs on the same live engine once every enabled schema passed the validator
    /// (typo, prediction, Lua and fuzzy transactions read their patched values back there); a throw
    /// aborts the transaction. The core re-checks resolved model identities before committing.
    static func verifyRecipeDeployment(
        _ deployment: RecipeDeployment,
        packageID: String, packageName: String?,
        requestedAdapters: [PublishedKeyboard]? = nil,
        postValidation: (@Sendable (RimeEngine, [String]) throws -> Void)? = nil
    ) async throws -> DeployVerification {
        try await EngineOpQueue.async {
            let (engine, enabled, _) = try EngineSchemaSelection.start(deployment)
            defer { engine.shutdown() }
            let entrySchemaID = try deployment.declaredEntry(in: enabled)
            try engine.prepareSchemaDependencyClosure(schemaIDs: enabled)
            for id in enabled { try engine.validateSchemaForActivation(schemaID: id) }
            try postValidation?(engine, enabled)
            // The only trigger for adapter generation: `nil` = ordinary install/update (adapter registry untouched, never generated);
            // non-nil (including an empty array) = add/remove a user keyboard, or a model transaction refreshing existing registered combinations;
            // the registry is rewritten atomically from that full set and never adds layouts automatically.
            if let requestedAdapters {
                try CompactAdapterDeployment.prepare(
                    engine: engine, deployment: deployment, requested: requestedAdapters)
            }
            // Runnable list: only enabled items covered by this validation loop become trial-typeable/publishable schemes.
            var byID: [String: KeyboardSchemaDescriptor] = [:]
            for id in enabled {
                byID[id] = KeyboardSchemaDescriptor(
                    id: id,
                    name: engine.schemaValue(id, key: "schema/name") ?? id,
                    alphabet: engine.schemaValue(id, key: "speller/alphabet") ?? "")
            }
            let descriptors = byID.values.sorted { $0.id < $1.id }
            try JSONEncoder().encode(descriptors).write(
                to: deployment.resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardSchemas),
                options: .atomic)
            // Source inventory (display only): schemes whose source is in the package/workspace but not enabled; never treated as usable.
            var sourceIDs = Set(enabled)
            for source in [deployment.resourceURL, deployment.userDataURL] {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { continue }
                for name in names where name.hasSuffix(".schema.yaml") {
                    sourceIDs.insert(String(name.dropLast(12)))
                }
            }
            let inventory = sourceIDs.subtracting(byID.keys).sorted()
            try JSONEncoder().encode(inventory).write(
                to: deployment.resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardSourceSchemas),
                options: .atomic)
            if let packageName {
                // Preserve the package's author-declared bindings across a regeneration,
                // but only those whose schema is enabled in THIS generation. User
                // "advanced" bindings live in revision-bound validated-bindings.json and
                // are therefore dropped on a revision change (never resurrected here).
                var bindings: [SchemeInputBinding] = []
                if let data = try? Data(
                    contentsOf: deployment.resourceURL.appendingPathComponent(
                        InstalledPackageLayout.keyboardPackageFile)),
                    let existing = try? JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
                {
                    bindings = existing.bindings.filter {
                        enabled.contains($0.schemaID) && KeyboardLayoutKind(rawValue: $0.layout) != nil
                    }
                }
                let declaration = SchemePackageDeclaration(id: packageID, name: packageName, bindings: bindings)
                try JSONEncoder().encode(declaration).write(
                    to: deployment.resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardPackageFile),
                    options: .atomic)
            }
            return DeployVerification(
                receipt: RecipeDeploymentReceipt(
                    availableComponents: [], validatedSchemaID: entrySchemaID,
                    validatedEnabledSchemaIDs: enabled))
        }
    }

    /// Capture an installed package's quiescent workspace for recipe planning. Runs inside the
    /// exclusive engine lease: no live writer can change custom bytes between this read and the
    /// later plan/install (which rechecks the generation baseline inside the store lock).
    func openInstalledWorkspace(packageID: String) {
        guard let item = beginWorkspaceRead(packageID: packageID) else { return }
        Task { await readInstalledWorkspace(item) }
    }

    /// Resets the workspace state and claims `busy` synchronously, so callers see the change before
    /// the read starts. Returns nil when the read cannot start.
    func beginWorkspaceRead(packageID: String) -> InstalledPackage? {
        guard !busy else {
            message = "另一项操作正在进行，请稍后。"
            return nil
        }
        lastInstalledPackageID = nil
        installedWorkspace = nil
        plannedRecipe = nil
        recipeDiscoveryErrors = []
        guard let item = installedPackages.first(where: { $0.id == packageID }) else {
            error = "未找到该输入方案"
            return nil
        }
        busy = true
        error = nil
        message = "正在读取方案…"
        return item
    }

    /// Completes when the read is finished; releases the `busy` claim from `beginWorkspaceRead`.
    func readInstalledWorkspace(_ item: InstalledPackage) async {
        defer { busy = false }
        do {
            let resources = item.active.resourceURL
            let userConfiguration = item.active.userDataURL
            // The read runs inside an exclusive lease on a background thread: the MainActor keeps responding to the UI during the snapshot.
            let snapshot = try await EngineOwnershipCoordinator.shared.withExclusive {
                try await Self.readWorkspaceSnapshot(resources: resources, userConfiguration: userConfiguration)
            }
            let sources = try await Self.readInstalledSources(resources: resources)
            installedWorkspace = InstalledRecipeWorkspace(
                packageID: item.id, displayName: item.name,
                revision: item.active.installation.revision, generation: item.active.installation.generation,
                initialUserDataURL: nil, snapshot: snapshot, sources: sources)
            plannedDiagnostics = []
            let found = discoverRecipes(in: sources.files, archivedPaths: sources.receipts.map(\.recipePath))
            recipes = found
            plannedRecipe = nil
            providedDownloadFiles = [:]
            providedOrdinaryResources = [:]
            message = nil
        } catch {
            fail(.nothingCommitted, error)
            message = nil
        }
    }

    /// Heavy synchronous workspace read, run off the MainActor. Caller must already hold
    /// the coordinator lease; cancellation is forwarded to the detached worker and the lease
    /// is only released after awaiting its completion — no orphaned reads outlive the lease.
    static func readWorkspaceSnapshot(resources: URL, userConfiguration: URL?) async throws -> RecipeWorkspaceSnapshot {
        let task = Task.detached(priority: .userInitiated) {
            try RecipePackageManager.readRecipeWorkspaceSnapshot(
                resources: resources, userConfiguration: userConfiguration)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Discover recipes from a captured workspace snapshot. Same loud-failure rules as imports.
    static func readInstalledSources(resources: URL) async throws -> InstalledRecipeSources {
        let task = Task.detached(priority: .userInitiated) {
            try RecipePackageManager.readInstalledRecipeSources(resources: resources)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private func discoverRecipes(in files: [String: Data], archivedPaths: [String] = []) -> [DiscoveredRecipe] {
        var found: [DiscoveredRecipe] = []
        var failures: [String] = []
        var userFailures: [String] = []
        for path in files.keys.filter({
            $0 == "recipe.yaml" || $0.hasSuffix(".recipe.yaml") || archivedPaths.contains($0)
        }).sorted() {
            // Repository-scoped recipes must be re-acquired through their source order;
            // flattening this namespace would change Rx and install_files resolution.
            if path.hasPrefix("source-repositories/") || path.hasPrefix("frontend-generated/") { continue }
            do {
                let recipe = try DeclarativeRecipe(path: path, source: files[path]!)
                found.append(
                    DiscoveredRecipe(
                        path: path, declaredName: recipe.declaredName,
                        displayDescription: recipe.displayDescription,
                        declaredArguments: recipe.declaredArguments, downloads: recipe.downloads,
                        installPatterns: recipe.installPatterns, patchTargets: recipe.patchTargets))
            } catch {
                let raw = "\(path)：\(error.localizedDescription)"
                failures.append(raw)
                HostLog.append("installed recipe discovery failed: \(raw)")
                let notice = Self.recipeDiscoveryNotice(error)
                if !userFailures.contains(notice) { userFailures.append(notice) }
            }
        }
        recipeDiscoveryErrors = failures
        if !userFailures.isEmpty { plannedDiagnostics = userFailures }
        return found
    }

    /// Plan a recipe against the captured installed workspace. Unlike a fresh import, the
    /// existing file tree (with user custom overlaid) is the base, and the generation baseline
    /// from capture time must still match when installing — a newer user change forces a re-plan.
    /// The user's custom baseline is passed to the core separately (compared as a full set including deletions/additions), not inferred from overlay files.
    /// `stages` are appended in order after the root recipe (generic sequential composition of
    /// the official resource → configuration → optional further recipes chain).
    func planInstalledRecipe(
        _ recipePath: String, arguments: [RecipeArgument],
        stages: [RecipeStage] = []
    ) {
        guard !busy, let workspace = installedWorkspace else { return }
        retryState.begin(
            .planRecipe(
                recipePath: recipePath, arguments: arguments,
                stages: Self.retryStages(stages), installed: true))
        guard workspace.sources?.files[recipePath] != nil else {
            HostLog.append("recipe planning rejected missing installed path: \(recipePath)")
            error = "所选选项已不可用，请重新选择。"
            return
        }
        busy = true
        error = nil
        plannedDiagnostics = []
        message = "正在检查…"
        let downloads = providedOrdinaryResources.mapValues(\.data)
        let downloadFiles = providedDownloadFiles
        Task {
            defer { busy = false }
            do {
                let plan = try await Self.buildPlan(
                    recipePath: recipePath, arguments: arguments, stages: stages,
                    packageID: workspace.packageID, packageFiles: workspace.sources!.files,
                    packageFileResources: workspace.sources!.fileResources,
                    existingFiles: workspace.snapshot.files,
                    existingFileResources: workspace.snapshot.fileResources,
                    userCustomBaseline: workspace.snapshot.userCustomFiles,
                    sourceRevision: workspace.revision,
                    expectedGeneration: workspace.generation,
                    downloads: downloads, downloadFiles: downloadFiles)
                var summary = Self.planSummary(plan, preparedSchemaIDs: workspace.schemaIDs)
                Self.appendModelNotes(to: &summary, plan: plan)
                // Re-run on an installed workspace: the entry is predicted from the plan's effective config; the real entry is decided at deploy.
                let requestedEntry = Self.requestedEntrySchema(
                    plan: plan,
                    manifestEntry: workspace.schemaIDs.first ?? "", manifestFiles: [:])
                let deployable =
                    plan.files.keys.contains(where: InstalledPackageLayout.isTopLevelSchemaFile)
                    || !workspace.schemaIDs.isEmpty
                plannedRecipe = PlannedRecipeInstall(
                    recipePath: recipePath, rx: plan.rx,
                    schemaID: deployable && !requestedEntry.isEmpty ? requestedEntry : "",
                    changedPaths: plan.changedPaths, summary: summary, plan: plan)
                retryState.succeeded()
                message = nil
            } catch {
                HostLog.append("installed recipe planning failed: \(error.localizedDescription)")
                let notice = Self.recipePlanningNotice(error)
                fail(.nothingCommitted, notice)
                plannedDiagnostics = [notice]
                message = nil
            }
        }
    }

    /// Re-run the planned recipe on the installed package. The workspace capture, generation
    /// check and install happen under the same exclusive lease; user custom bytes changed since
    /// the plan are rejected (complete-set baseline, core); failure keeps the previous active
    /// installation and learning data. A first run into a fresh destination slot seeds its
    /// first generation from the stopped source user directory (`initialUserDataURL`); later
    /// runs update the destination's own active.
    @discardableResult
    func installPlannedRecipeOnInstalled(
        currentRecipePath: String, currentArguments: [RecipeArgument], currentStages: [RecipeStage]
    ) -> Task<Void, Never>? {
        guard !busy, let planned = plannedRecipe, let workspace = installedWorkspace else { return nil }
        retryState.begin(
            .installPlannedRecipe(
                recipePath: currentRecipePath, arguments: currentArguments,
                stages: Self.retryStages(currentStages), installed: true))
        busy = true
        error = nil
        message = "正在更新…"
        let step = Task {
            defer { busy = false }
            do {
                let manager = manager(workspace.packageID)
                let packageID = workspace.packageID
                let declarationName = workspace.displayName
                let initialUserDataURL = workspace.initialUserDataURL
                let requestedEntry = planned.schemaID.isEmpty ? workspace.schemaIDs.first ?? "" : planned.schemaID
                var grammarAdapters: [PublishedKeyboard]?
                if planned.plan.managesGrammar {
                    let prior = try await manager.activeInstallation()
                    guard prior?.installation.generation == workspace.generation else {
                        throw RecipeInstallError.invalidResource("方案已更改，请重新检查。")
                    }
                    let oldBuild = (prior?.userDataURL ?? initialUserDataURL)?.appendingPathComponent("build")
                    grammarAdapters = try await KeyboardResourceReadQueue.async {
                        try oldBuild.map { try CompactAdapterDeployment.registeredRequests(build: $0) } ?? []
                    }
                }
                let requestedAdapters = grammarAdapters
                try await EngineOwnershipCoordinator.shared.withExclusive {
                    _ = try await manager.installRecipePlan(
                        planned.plan, packageID: packageID,
                        schemaID: requestedEntry,
                        initialUserDataURL: initialUserDataURL,
                        deploy: { deployment in
                            let verification = try await Self.verifyRecipeDeployment(
                                deployment, packageID: packageID, packageName: declarationName,
                                requestedAdapters: requestedAdapters)
                            return verification.receipt
                        })
                }
                self.plannedRecipe = nil
                installedWorkspace = nil
                lastInstalledPackageID = workspace.packageID
                retryState.succeeded()
                recipes = []
                providedDownloadFiles = [:]
                providedOrdinaryResources = [:]
                diagnostics = []
                userNotice = "输入习惯已保留。"
                await refresh()
            } catch {
                fail(.nothingCommitted, error)
                message = nil
            }
        }
        return step
    }
}

// MARK: - Managed patch transaction

/// What a managed-patch feature reads before it plans.
struct ManagedPatchContext: Sendable {
    let active: ActiveRecipe
    let snapshot: RecipeWorkspaceSnapshot
    let sources: InstalledRecipeSources
    /// `build/` of the active installation's user data.
    let build: URL
}

/// A feature's planned recipe, the extra file resources it ships, and what verification needs.
struct ManagedPatchPlan<Change: Sendable>: Sendable {
    let recipe: DeclarativeRecipe
    var resources: [String: RecipeFileResource] = [:]
    let change: Change
}

/// Result of one managed-patch transaction. `installed` is nil when the planner found nothing to change.
struct ManagedPatchResult: Sendable {
    let installed: InstalledRecipe?
    let previousRevision: String
    let previousGeneration: String
}

extension SchemeImportCenter {
    /// Shared transaction behind typo correction, prediction, Lua components and fuzzy pinyin:
    /// plan one managed recipe patch off the main actor, install it, and let the live engine
    /// read the patched values back (`verify`) before the installation commits.
    func applyManagedPatch<Change: Sendable>(
        packageID: String, message busyMessage: String,
        preflight: @escaping @Sendable (ActiveRecipe) throws -> Void = { _ in },
        plan: @escaping @Sendable (ManagedPatchContext) throws -> ManagedPatchPlan<Change>?,
        verify: @escaping @Sendable (RimeEngine, [String], RecipeDeployment, Change) throws -> Void
    ) async throws -> ManagedPatchResult {
        guard !busy, !KeyboardSelectionCenter.shared.isBusy else { throw UserKeyboardPublicationError.busy }
        busy = true
        message = busyMessage
        defer {
            busy = false
            message = nil
        }
        let openCC = Bundle.main.url(forResource: "opencc", withExtension: nil, subdirectory: "EngineResources")
        let store = manager(packageID)
        let packageName = installedPackages.first { $0.id == packageID }?.name
        return try await EngineOwnershipCoordinator.shared.withExclusive {
            guard let active = try await store.activeInstallation() else {
                throw RecipeInstallError.invalidResource("请先安装输入方案")
            }
            try preflight(active)
            let snapshot = try await Self.readWorkspaceSnapshot(
                resources: active.resourceURL,
                userConfiguration: active.userDataURL)
            let sources = try await Self.readInstalledSources(resources: active.resourceURL)
            let context = ManagedPatchContext(
                active: active, snapshot: snapshot, sources: sources,
                build: active.userDataURL.appendingPathComponent("build"))
            let task = Task.detached(priority: .userInitiated) {
                () throws -> (DeclarativeRecipePlan, Change)? in
                guard let planned = try plan(context) else { return nil }
                let recipe = planned.recipe
                // A previous run archived a different body at the same path; the new recipe replaces it.
                var files = sources.files
                files[recipe.path] = recipe.source
                var resources = sources.fileResources
                resources.merge(planned.resources) { _, new in new }
                let declarative = try DeclarativeRecipePlan(
                    recipe: recipe, packageReference: packageID,
                    selectedRecipe: recipe.declaredName ?? "", arguments: [], packageFiles: files,
                    existingFiles: snapshot.files, sourceRevision: active.installation.revision,
                    expectedGeneration: active.installation.generation,
                    packageFileResources: resources,
                    existingFileResources: snapshot.fileResources,
                    userCustomBaseline: snapshot.userCustomFiles, sharedOpenCCDirectory: openCC)
                return (declarative, planned.change)
            }
            let planned = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() })
            guard let (declarative, change) = planned else {
                return ManagedPatchResult(
                    installed: nil, previousRevision: active.installation.revision,
                    previousGeneration: active.installation.generation)
            }
            let installed = try await store.installRecipePlan(
                declarative, packageID: packageID, schemaID: active.installation.schemaID,
                deploy: { deployment in
                    let verification = try await Self.verifyRecipeDeployment(
                        deployment,
                        packageID: packageID, packageName: packageName,
                        postValidation: { engine, enabledIDs in
                            try verify(engine, enabledIDs, deployment, change)
                        })
                    return verification.receipt
                })
            return ManagedPatchResult(
                installed: installed, previousRevision: active.installation.revision,
                previousGeneration: active.installation.generation)
        }
    }
}
