import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

extension SchemeImportCenter {
    // MARK: - Re-running an installed package's recipe (official rime-install step: reselect config after updating resources)

    /// Rime-source expression an installed package came from; written once by the source install.
    struct SourceOrigin: Codable {
        let target: String
    }
    static func recordedSourceTarget(packageID: String) -> String? {
        let root = storeRoot.appendingPathComponent(packageID)
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("source-origin.json")),
            let origin = try? JSONDecoder().decode(SourceOrigin.self, from: bytes)
        else { return nil }
        return origin.target
    }

    /// Starts the acquisition and returns its own task, or nil when the center is busy. Callers
    /// wait on this handle rather than the shared `sourceTask`, which another page can replace.
    @discardableResult
    func acquireSource(_ target: String, updatingPackageID: String? = nil) -> Task<Void, Never>? {
        guard !busy else { return nil }
        retryState.begin(.acquireSource(target: target, updatingPackageID: updatingPackageID))
        busy = true
        error = nil
        message = "正在解析来源…"
        acquiredSources = []
        sourcePlan = nil
        sourcePackageID = nil
        sourceBaseline = nil
        sourceGeneration = nil
        providedDownloadFiles = [:]
        providedOrdinaryResources = [:]
        lastInstalledPackageID = nil
        let step = Task {
            defer {
                busy = false
                message = nil
            }
            do {
                let orders = try await RimeSourceOrder.expand(target)
                guard !orders.isEmpty, orders.count <= 64 else {
                    throw RecipeInstallError.invalidResource("请填写1至64个来源")
                }
                var refs: [String: String] = [:]
                for order in orders {
                    if let previous = refs[order.repository], previous != (order.ref ?? "HEAD") {
                        throw RecipeInstallError.invalidResource("同一事务不能混装同仓库不同 ref：\(order.repository)")
                    }
                    refs[order.repository] = order.ref ?? "HEAD"
                }
                let identity = refs.keys.sorted().joined(separator: "\n")
                let hash = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
                let packageID = updatingPackageID ?? "source-" + hash
                var acquired: [AcquiredRimeSource] = []
                for order in orders {
                    let sourceBytes = acquired.reduce(0) { $0 + $1.files.values.reduce(0) { $0 + $1.count } }
                    let modelBytes = acquired.reduce(0) { $0 + $1.models.values.reduce(0) { $0 + $1.size } }
                    acquired.append(
                        try await AcquiredRimeSource.fetch(
                            order,
                            sourceBudget: RecipeResourceBudget.sourceTotal - sourceBytes,
                            modelBudget: RecipeResourceBudget.modelTotal - modelBytes
                        ) { note in
                            Task { @MainActor in self.message = note }
                        })
                }
                var externalURLs: [String: URL] = [:]
                var fixedRevisions: [String: String] = [:]
                for source in acquired {
                    if let revision = fixedRevisions[source.order.repository], revision != source.revision {
                        throw RecipeInstallError.invalidResource("仓库在获取步骤期间发生更新，请重新获取：\(source.order.repository)")
                    }
                    fixedRevisions[source.order.repository] = source.revision
                }
                for resource in acquired.flatMap(\.externalResources) {
                    if let previous = externalURLs[resource.path], previous != resource.url {
                        throw RecipeInstallError.invalidResource("输入方案中包含同名但下载地址不同的文件：\(resource.path)，请分别安装。")
                    }
                    externalURLs[resource.path] = resource.url
                }
                try Task.checkCancellation()
                let store = manager(packageID)
                let baseline = try await EngineOwnershipCoordinator.shared.withExclusive {
                    guard let active = try await store.activeInstallation() else {
                        return (nil as RecipeWorkspaceSnapshot?, nil as String?)
                    }
                    return (
                        try await Self.readWorkspaceSnapshot(
                            resources: active.resourceURL, userConfiguration: active.userDataURL),
                        active.installation.generation
                    )
                }
                acquired = try await RimeSourceDependencies.acquire(
                    for: acquired, existingFiles: baseline.0?.files ?? [:],
                    sharedOpenCCDirectory: Bundle.main.url(
                        forResource: "opencc", withExtension: nil, subdirectory: "EngineResources")
                ) { note in
                    Task { @MainActor in self.message = note }
                }
                acquiredSources = acquired
                sourceTarget = target
                sourcePackageID = packageID
                sourceBaseline = baseline.0
                sourceGeneration = baseline.1
                retryState.succeeded()
            } catch is CancellationError {
            } catch {
                fail(.nothingCommitted, error)
            }
        }
        sourceTask = step
        return step
    }

    func cancelSourceOperation() {
        sourceTask?.cancel()
        if preparingExternalResource { message = "正在取消资源准备并清理临时文件…" }
    }

    /// Page-level cancel of a one-action update; it propagates only to the steps and download
    /// that update started.
    func cancelUpdateTarget() {
        schemeUpdateTask?.cancel()
    }

    func invalidateSourcePlan() { sourcePlan = nil }

    /// Starts the plan check and returns its own task, or nil when nothing was started
    /// (same contract as `acquireSource`).
    @discardableResult
    func checkSourcePlan(entrySchemaID: String = "") -> Task<Void, Never>? {
        guard !busy, !acquiredSources.isEmpty else { return nil }
        busy = true
        error = nil
        sourcePlan = nil
        message = "正在检查输入方案安装配置…"
        let sources = acquiredSources, baseline = sourceBaseline, generation = sourceGeneration
        let downloads = providedOrdinaryResources.mapValues(\.data), models = providedDownloadFiles
        let step = Task {
            defer {
                busy = false
                message = nil
            }
            let task = Task.detached { () throws -> DeclarativeRecipePlan in
                var result: DeclarativeRecipePlan?
                for source in sources {
                    try Task.checkCancellation()
                    if let earlier = result {
                        result = try earlier.appending(
                            recipe: source.recipe, packageReference: source.order.repository,
                            selectedRecipe: source.order.recipe, arguments: source.order.arguments,
                            packageFiles: source.files, providedDownloads: downloads, sourceRevision: source.revision,
                            packageFileResources: source.models, providedDownloadFiles: models,
                            sourceArchivePrefix: source.archivePrefix)
                    } else {
                        result = try DeclarativeRecipePlan(
                            recipe: source.recipe, packageReference: source.order.repository,
                            selectedRecipe: source.order.recipe, arguments: source.order.arguments,
                            packageFiles: source.files, existingFiles: baseline?.files ?? [:],
                            providedDownloads: downloads,
                            sourceRevision: source.revision, expectedGeneration: generation,
                            packageFileResources: source.models, existingFileResources: baseline?.fileResources ?? [:],
                            providedDownloadFiles: models, userCustomBaseline: baseline?.userCustomFiles ?? [:],
                            sharedOpenCCDirectory: Bundle.main.url(
                                forResource: "opencc", withExtension: nil, subdirectory: "EngineResources")
                        )
                        .archivingSources(prefix: source.archivePrefix)
                    }
                }
                return try result!.selectingSourceEntry(
                    entrySchemaID, sources: sources, isNewInstallation: baseline == nil)
            }
            do {
                let plan = try await withTaskCancellationHandler(
                    operation: { try await task.value },
                    onCancel: { task.cancel() })
                // Resources or a newer step may have replaced this one while the plan was built.
                sourcePlan = plan
            } catch {
                fail(.nothingCommitted, error)
            }
        }
        sourceTask = step
        return step
    }

    /// Installs the checked plan and returns its own task, or nil when nothing was started.
    @discardableResult
    func installSourcePlan() -> Task<Void, Never>? {
        guard !busy, let plan = sourcePlan, let packageID = sourcePackageID else { return nil }
        retryState.begin(.installSourcePlan)
        guard let schema = InstalledPackageLayout.topLevelSchemaFiles(in: plan.files.keys).sorted().first
        else {
            error = "来源列表里没有可用的输入方案。请把输入方案和它需要的文件放进同一个来源列表。"
            return nil
        }
        busy = true
        error = nil
        message = "正在安装并检查输入方案…"
        let target = sourceTarget
        let step = Task {
            defer {
                busy = false
                message = nil
            }
            do {
                let store = manager(packageID)
                try await EngineOwnershipCoordinator.shared.withExclusive {
                    _ = try await store.installRecipePlan(
                        plan, packageID: packageID, schemaID: String(schema.dropLast(12)),
                        deploy: { deployment in
                            let verification = try await Self.verifyRecipeDeployment(
                                deployment, packageID: packageID, packageName: target)
                            return verification.receipt
                        })
                }
                do {
                    let slot = Self.storeRoot.appendingPathComponent(packageID)
                    try JSONEncoder().encode(SourceOrigin(target: target))
                        .write(to: slot.appendingPathComponent("source-origin.json"), options: .atomic)
                    try? FileManager.default.removeItem(at: slot.appendingPathComponent("source-url.json"))
                } catch {
                    // The install itself is committed; only one-action updates lose their address.
                    HostLog.append("source update record failed after install: \(error.localizedDescription)")
                    userNotice = "输入方案已安装，但没能记住它的来源。以后更新时，请重新输入来源。"
                }
                sourcePlan = nil
                acquiredSources = []
                lastInstalledPackageID = packageID
                retryState.succeeded()
                await refresh()
            } catch {
                fail(.nothingCommitted, error)
            }
        }
        sourceTask = step
        return step
    }
}
