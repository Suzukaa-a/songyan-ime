import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    // MARK: - Externally supplied resources (models etc.)

    /// Private staging for captured/downloaded external resources. Snapshots live here until
    /// the plan's install copies them into a generation; never inside a package store slot.
    static var modelStagingDirectory: URL {
        HostStorePaths.applicationSupport.appendingPathComponent("RecipeModelStaging", isDirectory: true)
    }

    /// User picked a local file for a declared download requirement. The security-scoped lease
    /// starts synchronously here and is held until the async capture finishes (the snapshot is
    /// then process-readable and independent of the picker URL). The key is the recipe-declared
    /// `requirement.path`, not the picked filename; the actual SHA/size fix the real identity.
    /// Declared-model requirements keep file references (`*.gram`; the reference itself holds a temp-file lease).
    /// Ordinary resources use bounded bytes. Replacing an entry releases the old reference's staging lease; never delete files by hand.
    func provideExternalResource(_ url: URL, requirementPath: String) {
        guard !busy else {
            message = "另一项操作正在进行，请稍后再试。"
            return
        }
        invalidatePlannedRecipeForResourceEdit()
        let isModel = RecipeResourceBudget.isModel(requirementPath)
        let expectsDatabase = Prediction.isDatabasePath(requirementPath)
        if isModel, url.pathExtension.lowercased() != (expectsDatabase ? "db" : "gram") {
            HostLog.append("external resource type mismatch: \(requirementPath) <- \(url.lastPathComponent)")
            error =
                expectsDatabase
                ? "需要联想词库文件（.db）。"
                : "需要语法模型文件（.gram）。"
            return
        }
        busy = true
        error = nil
        preparingExternalResource = true
        HostLog.append("reading external resource: \(requirementPath)")
        message = "正在读取文件…"
        // The lease must start in this picker callback, before any suspension point.
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        sourceTask = Task {
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                busy = false
                preparingExternalResource = false
            }
            do {
                if isModel {
                    let asset = try await RecipeFileResource.capture(
                        from: url, directory: Self.modelStagingDirectory,
                        maximumBytes: RecipeResourceBudget.maximumFileBytes(requirementPath))
                    try Task.checkCancellation()
                    providedOrdinaryResources[requirementPath] = nil
                    providedDownloadFiles[requirementPath] = asset
                    message =
                        "已添加文件（\(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))）。"
                } else {
                    // Ordinary resources are read as bounded immutable bytes on a background task; the SHA/size identity
                    // is pinned from those same bytes, and cancel is forwarded to the reader.
                    let maximumBytes = RecipeResourceBudget.maximumFileBytes(requirementPath)
                    let remainingTotal =
                        RecipeResourceBudget.sourceTotal
                        - providedOrdinaryResources.values.reduce(0) { $0 + $1.size }
                    let budget = providedOrdinaryResources
                    let sourceURL = url
                    let task = Task.detached(priority: .userInitiated) { () throws -> ProvidedOrdinaryResource in
                        let info = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        guard info.isSymbolicLink != true, info.isRegularFile == true else {
                            throw RecipeInstallError.invalidResource("文件类型不支持：\(sourceURL.lastPathComponent)")
                        }
                        let resource = try RecipePackageManager.readLocalOrdinaryResource(
                            sourceURL,
                            maximumBytes: min(maximumBytes, max(remainingTotal, 0)))
                        var sizes = budget.mapValues(\.size)
                        sizes[requirementPath] = resource.size
                        try RecipeResourceBudget.validate(sizes)
                        return resource
                    }
                    let resource: ProvidedOrdinaryResource
                    do {
                        resource = try await withTaskCancellationHandler(
                            operation: { try await task.value },
                            onCancel: { task.cancel() })
                    }
                    try Task.checkCancellation()
                    providedDownloadFiles[requirementPath] = nil
                    providedOrdinaryResources[requirementPath] = resource
                    message =
                        "已添加文件（\(ByteCountFormatter.string(fromByteCount: Int64(resource.size), countStyle: .file))）。"
                }
            } catch is CancellationError {
                message = "已取消。"
            } catch {
                report(error)
                message = nil
            }
        }
    }

    /// Explicit user-requested acquisition from the requirement's own declared HTTPS URL.
    /// Not a default download and not tied to any preset: nothing happens without this tap,
    /// and the destination bytes are fixed by the actual SHA recorded in the plan receipt.
    /// Models are downloaded to disk as file references via URLSession; ordinary resources are collected as immutable bytes within budget
    /// with the SHA/size identity pinned in the same background fetch; the MainActor only publishes the identity.
    func downloadExternalResource(_ requirement: RecipeExternalResource) {
        guard !busy else {
            message = "另一项操作正在进行，请稍后。"
            return
        }
        invalidatePlannedRecipeForResourceEdit()
        busy = true
        error = nil
        preparingExternalResource = true
        HostLog.append("downloading external resource: \(requirement.path)")
        message = "正在下载…"
        let isModel = RecipeResourceBudget.isModel(requirement.path)
        sourceTask = Task {
            defer {
                busy = false
                preparingExternalResource = false
            }
            do {
                if isModel {
                    let asset = try await RecipeFileResource.download(
                        from: requirement.url, directory: Self.modelStagingDirectory,
                        maximumBytes: RecipeResourceBudget.maximumFileBytes(requirement.path))
                    try Task.checkCancellation()
                    providedOrdinaryResources[requirement.path] = nil
                    providedDownloadFiles[requirement.path] = asset
                    message = "已下载（\(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))）。"
                } else {
                    let resource = try await RecipePackageManager.fetchOrdinaryResource(
                        requirement.url,
                        maximumBytes: RecipeResourceBudget.maximumFileBytes(requirement.path))
                    var sizes = providedOrdinaryResources.mapValues(\.size)
                    sizes[requirement.path] = resource.size
                    try RecipeResourceBudget.validate(sizes)
                    try Task.checkCancellation()
                    providedDownloadFiles[requirement.path] = nil
                    providedOrdinaryResources[requirement.path] = resource
                    message =
                        "已下载（\(ByteCountFormatter.string(fromByteCount: Int64(resource.size), countStyle: .file))）。"
                }
            } catch is CancellationError {
                message = "已取消。"
            } catch {
                report(error)
                message = nil
            }
        }
    }

    /// Remove a provided resource. Data entries drop with the dictionary; file-reference
    /// entries release their temporary snapshot lease. Fails soft; planning simply
    /// goes back to requiring the resource explicitly. Removing invalidates a pending
    /// plan — the old plan was built against different resource bytes.
    func removeProvidedExternalResource(requirementPath: String) {
        guard busy == false else { return }
        invalidatePlannedRecipeForResourceEdit()
        providedOrdinaryResources[requirementPath] = nil
        providedDownloadFiles[requirementPath] = nil
    }

    /// Any external resource add/remove/replace immediately revokes the current plan.
    private func invalidatePlannedRecipeForResourceEdit() {
        sourcePlan = nil
        // A resource add/remove/replace is a new user action, not a "retry of the last chosen operation"; clear the captured retry intent
        // so a retry after a failed resource preparation does not replay an earlier install action.
        retryState.succeeded()
        guard plannedRecipe != nil else { return }
        plannedRecipe = nil
        plannedDiagnostics = ["文件已更改，请重新检查。"]
    }

    /// After the root recipe selection, its parameters or the stages change, the old plan no longer matches the current input; revoke it immediately.
    func invalidatePlannedRecipeForRootChange() {
        guard plannedRecipe != nil else { return }
        plannedRecipe = nil
        plannedDiagnostics = ["选项已更改，请重新检查。"]
    }

    /// Reset recipe-planning state, dropping provided external resources (the staging
    /// snapshots are re-creatable from their sources; nothing here is user learning data).
    func resetRecipePlanningState() {
        plannedRecipe = nil
        plannedDiagnostics = []
        recipes = []
        recipeDiscoveryErrors = []
        providedDownloadFiles = [:]
        providedOrdinaryResources = [:]
    }
}
