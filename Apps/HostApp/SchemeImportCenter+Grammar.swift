import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    /// One model file may be bound to zero, one or many input methods. The user edits the
    /// complete set for a model and applies it once: a single transaction patches exactly the
    /// added schemas (bind) and removed schemas (clear), installs the model once (no per-binding
    /// copy), and is verified as a whole. Removing one input method leaves every other binding
    /// untouched because its schema patch block is simply not part of this plan.
    @discardableResult
    func checkGrammarPlan(
        modelPath: String, savedSchemaIDs: Set<String>, selectedSchemaIDs: [String],
        sourceURL: URL?, displayName: String? = nil
    ) -> Task<Void, Never>? {
        guard !busy, let workspace = installedWorkspace else { return nil }
        let desired = Array(Set(selectedSchemaIDs)).sorted()
        guard desired.allSatisfy({ workspace.schemaIDs.contains($0) }) else {
            error = "当前未安装该输入方案"
            return nil
        }
        guard GrammarModelRecipe.validModelPath(modelPath) else {
            error = "所选语法模型无效，请选择 .gram 文件。"
            return nil
        }
        // Only bindings this transaction changes produce patch blocks; the rest of the model's
        // existing bindings stay exactly as deployed.
        let changedBinding = desired.filter { !savedSchemaIDs.contains($0) }
        let changedClearing: [String] = []
        let hasProvidedModel = providedDownloadFiles[modelPath] != nil
        if changedBinding.isEmpty, changedClearing.isEmpty, !hasProvidedModel {
            error = "未作任何更改"
            return nil
        }
        // Binding a not-yet-installed model requires an explicitly provided file; unbinding an
        // existing model reuses its installed reference.
        if !changedBinding.isEmpty, providedDownloadFiles[modelPath] == nil,
            workspace.snapshot.fileResources[modelPath] == nil
        {
            error = "请先导入或下载 \(modelPath)"
            return nil
        }
        busy = true
        error = nil
        plannedRecipe = nil
        message = "正在检查…"
        let provided = providedDownloadFiles
        let modelDisplayName =
            displayName
            ?? GrammarModelRecipe.displayName(
                for: modelPath,
                sources: workspace.sources?.files)
        let step = Task {
            defer {
                busy = false
                message = nil
            }
            do {
                let task = Task.detached { () throws -> DeclarativeRecipePlan in
                    let recipe = try GrammarModelRecipe.make(
                        modelPath: modelPath,
                        bindingSchemaIDs: changedBinding, clearingSchemaIDs: changedClearing,
                        sourceURL: sourceURL, displayName: modelDisplayName)
                    guard let model = provided[modelPath] ?? workspace.snapshot.fileResources[modelPath] else {
                        // Unbinding an already-installed model still needs its file reference so the
                        // unchanged install_files entry can be re-verified, not re-downloaded.
                        throw RecipeInstallError.invalidResource("未找到模型文件引用：\(modelPath)")
                    }
                    var files = workspace.sources?.files ?? [:]
                    files[recipe.path] = recipe.source
                    var models = workspace.sources?.fileResources ?? [:]
                    models[modelPath] = model
                    return try DeclarativeRecipePlan(
                        recipe: recipe, packageReference: workspace.packageID,
                        selectedRecipe: recipe.declaredName ?? "", arguments: [], packageFiles: files,
                        existingFiles: workspace.snapshot.files, sourceRevision: workspace.revision,
                        expectedGeneration: workspace.generation, packageFileResources: models,
                        existingFileResources: workspace.snapshot.fileResources,
                        providedDownloadFiles: [modelPath: model],
                        userCustomBaseline: workspace.snapshot.userCustomFiles,
                        sharedOpenCCDirectory: Bundle.main.url(
                            forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"),
                        managedGrammar: true)
                }
                let plan = try await withTaskCancellationHandler(
                    operation: { try await task.value }, onCancel: { task.cancel() })
                // A model-only update must not change the installation's entry merely because
                // the schema inventory sorts differently from the source's declared entry.
                // This also covers a zero-binding install followed by binding later.
                let installedEntry = installedPackages.first { $0.id == workspace.packageID }?.active.installation
                    .schemaID
                let entry =
                    installedEntry.flatMap { workspace.schemaIDs.contains($0) ? $0 : nil }
                    ?? desired.first(where: { workspace.schemaIDs.contains($0) })
                    ?? workspace.schemaIDs.first ?? ""
                plannedRecipe = PlannedRecipeInstall(
                    recipePath: plan.recipePath, rx: plan.rx, schemaID: entry,
                    changedPaths: plan.changedPaths,
                    summary: Self.grammarPlanSummary(
                        modelPath: modelDisplayName ?? modelPath,
                        binding: changedBinding, clearing: changedClearing),
                    plan: plan)
            } catch { fail(.nothingCommitted, error) }
        }
        sourceTask = step
        return step
    }

    /// Plain-language summary of the whole model → input-method-set operation.
    static func grammarPlanSummary(modelPath: String, binding: [String], clearing: [String]) -> [String] {
        var lines: [String] = ["模型：\(modelPath)"]
        if binding.isEmpty, clearing.isEmpty { lines.append("将安装或更新模型文件") }
        if !binding.isEmpty { lines.append("将用于 \(binding.count) 个输入方式") }
        if !clearing.isEmpty { lines.append("将停止用于 \(clearing.count) 个输入方式") }
        return lines
    }

    /// Model management updates the selected source itself, keeping the extension's
    /// learning namespace.
    func checkGrammarConfiguration(schemaIDs: [String], restoreDefaults: Bool) -> Task<Void, Never>? {
        guard !busy, let workspace = installedWorkspace else { return nil }
        let selected = Array(Set(schemaIDs)).sorted()
        guard !selected.isEmpty, selected.allSatisfy({ workspace.schemaIDs.contains($0) }) else {
            error = "请选择当前安装中的输入方式"
            return nil
        }
        busy = true
        error = nil
        plannedRecipe = nil
        message = "正在检查…"
        let step = Task {
            defer {
                busy = false
                message = nil
            }
            do {
                let task = Task.detached { () throws -> DeclarativeRecipePlan in
                    let recipe =
                        try restoreDefaults
                        ? GrammarModelRecipe.restorationRecipe(schemaIDs: selected)
                        : GrammarModelRecipe.disabling(schemaIDs: selected)
                    let removals =
                        try restoreDefaults
                        ? GrammarModelRecipe.restorationOverrides(
                            schemaIDs: selected,
                            sources: workspace.sources, files: workspace.snapshot.files,
                            packageReference: workspace.packageID) : []
                    var sources = workspace.sources?.files ?? [:]
                    sources[recipe.path] = recipe.source
                    return try DeclarativeRecipePlan(
                        recipe: recipe, packageReference: workspace.packageID,
                        selectedRecipe: recipe.declaredName ?? "", arguments: [], packageFiles: sources,
                        existingFiles: workspace.snapshot.files, sourceRevision: workspace.revision,
                        expectedGeneration: workspace.generation,
                        packageFileResources: workspace.sources?.fileResources ?? workspace.snapshot.fileResources,
                        existingFileResources: workspace.snapshot.fileResources,
                        userCustomBaseline: workspace.snapshot.userCustomFiles,
                        sharedOpenCCDirectory: Bundle.main.url(
                            forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"),
                        managedGrammar: !restoreDefaults, restoringGrammarOverrides: removals)
                }
                let plan = try await withTaskCancellationHandler(
                    operation: { try await task.value }, onCancel: { task.cancel() })
                let packageSchema = installedPackages.first(where: { $0.id == workspace.packageID })?.active
                    .installation.schemaID
                let schemaID = packageSchema ?? workspace.schemaIDs.first ?? ""
                plannedRecipe = PlannedRecipeInstall(
                    recipePath: plan.recipePath, rx: plan.rx, schemaID: schemaID,
                    changedPaths: plan.changedPaths, summary: [restoreDefaults ? "恢复默认" : "不使用语法模型"],
                    plan: plan)
                diagnostics = []
            } catch { fail(.nothingCommitted, error) }
        }
        sourceTask = step
        return step
    }

    // MARK: - One-action grammar model changes

    /// Applies one grammar-model choice to `schemaIDs` and installs it immediately, so the user
    /// makes one decision instead of stepping through a plan, a confirmation and a re-apply.
    /// `modelPath == nil` means "no model": `restoreDefaults` returns to what the input method
    /// itself configures, otherwise the model is switched off.
    @discardableResult
    func applyGrammarChange(
        schemaIDs: [String], modelPath: String?, savedSchemaIDs: Set<String> = [],
        restoreDefaults: Bool = false
    ) async -> Bool {
        guard !busy else {
            error = "另一项操作正在进行，请稍后再试。"
            return false
        }
        guard let current = installedWorkspace else {
            error = "正在读取方案，请稍后再试。"
            return false
        }
        let packageID = current.packageID
        let check =
            modelPath.map {
                checkGrammarPlan(
                    modelPath: $0, savedSchemaIDs: savedSchemaIDs,
                    selectedSchemaIDs: schemaIDs, sourceURL: nil)
            } ?? checkGrammarConfiguration(schemaIDs: schemaIDs, restoreDefaults: restoreDefaults)
        guard await waitForSourceStep(check), error == nil, let planned = plannedRecipe else { return false }
        let install = installPlannedRecipeOnInstalled(
            currentRecipePath: planned.recipePath,
            currentArguments: [], currentStages: [])
        guard await waitForSourceStep(install) else { return false }
        // The install invalidated the workspace on purpose. A caller that binds the model it just
        // added must see the new one, so wait for the re-read instead of racing it.
        await waitForWorkspace(packageID: packageID)
        return error == nil
    }

    /// Waits (bounded) for the workspace of a source to be readable again. Starts the read itself
    /// when nothing else did, so a screen that is not watching `busy` still gets a usable state.
    private func waitForWorkspace(packageID: String) async {
        var started = false
        for _ in 0..<100 {
            if !busy, installedWorkspace != nil { return }
            if !busy, !started {
                started = true
                openInstalledWorkspace(packageID: packageID)
                continue
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Adds one `.gram` file to the current workspace without binding it; the picker URL keeps its
    /// security-scope lease from the call that starts it. `requirementsPath` is the file's place in
    /// the scheme's resources — the path the input method already refers to when it has one.
    @discardableResult
    func addGrammarModel(
        fileURL: URL?, address: URL?, filename: String,
        requirementPath: String? = nil
    ) async -> Bool {
        guard !busy else {
            error = "另一项操作正在进行，请稍后再试。"
            return false
        }
        guard let target = requirementPath ?? GrammarModelRecipe.installPath(for: filename) else {
            error = "请选择 .gram 模型文件。"
            return false
        }
        if let fileURL {
            provideExternalResource(fileURL, requirementPath: target)
        } else if let address {
            downloadExternalResource(.init(path: target, url: address))
        } else {
            error = "请选择 .gram 模型文件。"
            return false
        }
        await sourceTask?.value
        guard error == nil, providedDownloadFiles[target] != nil else { return false }
        return await applyGrammarChange(schemaIDs: [], modelPath: target)
    }
}
