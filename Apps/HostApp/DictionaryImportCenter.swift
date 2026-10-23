import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

/// One replaceable installation slot, independent from the reviewed recipe's learning store.
@MainActor
final class DictionaryImportCenter: ObservableObject {
    static let shared = DictionaryImportCenter()

    struct Summary: Codable {
        let name: String
        let entryCount: Int
        let files: Int
    }

    /// A lease starts synchronously in the picker callback and survives all async reads.
    private final class ScopedSource {
        let file: DictionaryImportFile
        private let scoped: Bool
        init(url: URL, path: String) {
            scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
            file = DictionaryImportFile(path: path, location: url)
        }
        deinit { if scoped { file.location.stopAccessingSecurityScopedResource() } }
    }

    private actor Downloads {
        var bytes: [URL: Data] = [:]
        func read(_ url: URL) async throws -> Data {
            if let data = bytes[url] { return data }
            let data = try await RecipePackageManager.fetchHTTP(url)
            guard bytes.values.reduce(0, { $0 + $1.count }) + data.count <= 64 * 1024 * 1024 else {
                throw DictionaryImportError.invalid("源码合计超过64 MiB")
            }
            bytes[url] = data
            return data
        }
        func clear() { bytes.removeAll() }
    }

    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var inspections: [DictionarySourceInspection] = []
    @Published private(set) var missing: [String] = []
    @Published private(set) var prepared: PreparedDictionaryImport?
    @Published private(set) var installed: ActiveRecipe?
    @Published private(set) var installedSummary: Summary?
    @Published private(set) var selectionRevision = UUID()
    private let manager: RecipePackageManager
    private let downloads: Downloads
    private var root: ScopedSource?
    private var dependencies: [String: ScopedSource] = [:]

    static var storeRoot: URL {
        HostStorePaths.applicationSupport.appendingPathComponent("DictionaryImportStore")
    }

    private init() {
        let downloads = Downloads()
        self.downloads = downloads
        manager = RecipePackageManager(rootURL: Self.storeRoot) { try await downloads.read($0) }
    }

    func report(_ error: Error) {
        switch error {
        case RecipeInstallError.http:
            self.error = "下载失败，请检查链接后重试。"
        case RecipeInstallError.busy:
            self.error = "另一个安装正在进行，请稍后重试。"
        case RecipeInstallError.deployment:
            HostLog.append("dictionary deployment failed: \(error.localizedDescription)")
            self.error = "无法安装此词库，请检查文件后重试。"
        case let dictionaryError as DictionaryImportError:
            // These are intentionally authored, actionable validation reasons (format,
            // content, or a dependency the user must provide), not raw engine diagnostics.
            self.error = dictionaryError.localizedDescription
        default:
            HostLog.append("dictionary operation failed: \(error.localizedDescription)")
            self.error = "词库操作未完成，请检查来源后重试。"
        }
    }

    func accept(_ url: URL, dependencyPath: String? = nil) {
        guard !busy else { return }
        let filename = url.lastPathComponent
        // A download endpoint need not have a file extension. Explicit unsupported file
        // extensions still reach the format validator with their original name.
        let explicitFile =
            url.isFileURL || filename.hasSuffix(".dict.yaml") || filename.hasSuffix(".zip")
            || filename.hasSuffix(".schema.yaml") || filename.contains("userdb")
        let path = dependencyPath ?? (explicitFile ? filename : "imported.dict.yaml")
        let source = ScopedSource(url: url, path: path)
        busy = true
        error = nil
        prepared = nil
        message = "正在读取词库…"
        Task {
            defer { busy = false }
            do {
                if dependencyPath == nil {
                    root = nil
                    dependencies.removeAll()
                    inspections = []
                    missing = []
                    await downloads.clear()
                }
                let info = try await manager.inspectDictionary(source.file)
                if dependencyPath == nil { root = source } else { dependencies[path] = source }
                inspections.removeAll { $0.path == path }
                inspections.append(info)
                updateMissing()
                message = missing.isEmpty ? "文件已读取。" : "还缺少以下文件。"
            } catch {
                report(error)
                message = nil
            }
        }
    }

    private func updateMissing() {
        let supplied = Set(inspections.map(\.path))
        missing = Set(inspections.flatMap(\.dependencies)).subtracting(supplied).sorted()
    }

    func prepare() {
        guard !busy, let root else { return }
        busy = true
        error = nil
        message = "正在检查…"
        Task {
            defer { busy = false }
            do {
                guard let builtin = RimePaths.builtinPackage() else {
                    throw DictionaryImportError.invalid("找不到内置输入方案，请重新安装 App。")
                }
                prepared = try await manager.prepareDictionaryImport(
                    root: root.file,
                    dependencies: dependencies.values.map(\.file), builtinResources: builtin)
                // Prepared owns all installation bytes. External file leases are no longer needed.
                self.root = nil
                dependencies.removeAll()
                await downloads.clear()
                message = "准备就绪，可以安装。"
            } catch DictionaryImportError.missingDependencies(let paths) {
                missing = paths
                error = "请先添加所需文件。"
            } catch { report(error) }
        }
    }

    func install() {
        guard !busy, let prepared, let name = inspections.first?.name else { return }
        busy = true
        error = nil
        message = "正在安装…"
        let summary = Summary(name: name, entryCount: prepared.entryCount, files: prepared.sources.count)
        Task {
            defer { busy = false }
            do {
                // Includes the first snapshot AND subsequent-generation snapshot: no live writer
                // can reopen the source learning database before the transaction has committed.
                try await EngineOwnershipCoordinator.shared.withExclusive { [self] in
                    let initial = RimePaths.interactiveUserDirectory().flatMap {
                        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                    }
                    _ = try await manager.installDictionaryImport(prepared, initialUserDataURL: initial) { deployment in
                        let receipt = try await DictionaryDeployVerifier.verifyDictionaryWhileExclusive(deployment)
                        try JSONEncoder().encode(summary).write(
                            to: deployment.resourceURL.appendingPathComponent("host-import-summary.json"),
                            options: .atomic)
                        return receipt
                    }
                }
                await refresh()
                self.prepared = nil
                self.root = nil
                inspections = []
                missing = []
                dependencies.removeAll()
                await downloads.clear()
                message = "安装完成，可在「自定义拼音」中点「\(UserTerminology.startUsing)」。"
            } catch {
                report(error)
                message = "安装未完成，请重试。"
            }
        }
    }

    /// Imported dictionaries carry generated 14/18/9-key adapters too. An installation built by
    /// an older generator is redeployed, and the publication in use is republished while its copy
    /// is older, so a failed republish is retried on the next refresh. Silent unless it fails.
    func rebuildOutdatedAdapters() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard let active = try await manager.activeInstallation() else { return }
            let build = active.userDataURL.appendingPathComponent("build")
            let resources = active.resourceURL
            let (installedCurrent, summary) = try await KeyboardResourceReadQueue.async {
                (
                    CompactAdapterDeployment.generatorIsCurrent(build: build),
                    try Data(contentsOf: resources.appendingPathComponent("host-import-summary.json"))
                )
            }
            if !installedCurrent {
                try await EngineOwnershipCoordinator.shared.withExclusive { [manager] in
                    _ = try await manager.reinstallActiveDictionary { deployment in
                        let receipt = try await DictionaryDeployVerifier.verifyDictionaryWhileExclusive(deployment)
                        try summary.write(
                            to: deployment.resourceURL.appendingPathComponent("host-import-summary.json"),
                            options: .atomic)
                        return receipt
                    }
                }
                await refresh()
                HostLog.append(
                    "rebuilt imported dictionary adapters for generator \(CompactSchemaAdapter.displayGeneratorVersion)"
                )
            }
            guard let shared = try await AppliedSelectionLoader.loadWriteBaseline(),
                shared.kind == .userDictionary, shared.recipeEnabled,
                let current = try await manager.activeInstallation(),
                shared.revision == current.installation.revision,
                try await KeyboardResourceReadQueue.async({
                    let published = try KeyboardRecipeStore.snapshot(for: shared, root: KeyboardRecipeStore.root())
                    return !CompactAdapterDeployment.generatorIsCurrent(build: published.build)
                })
            else { return }
            try await EngineOpQueue.async {
                try KeyboardRecipeStore.publish(
                    resources: current.resourceURL,
                    compiledBuild: current.userDataURL.appendingPathComponent("build"),
                    revision: current.installation.revision, kind: .userDictionary,
                    dictionaryName: shared.dictionaryName,
                    preservingSelection: true, baseline: .publication(shared))
            }
            selectionRevision = UUID()
        } catch { report(error) }
    }

    func refresh() async {
        do {
            installed = try await manager.activeInstallation()
            if let installed {
                // The summary is display-only: read from disk on the resource read queue; if missing or corrupt, show no summary
                // rather than posing as a "dictionary operation incomplete" error.
                let url = installed.resourceURL.appendingPathComponent("host-import-summary.json")
                installedSummary = try? await KeyboardResourceReadQueue.async {
                    try JSONDecoder().decode(Summary.self, from: Data(contentsOf: url))
                }
            } else {
                installedSummary = nil
            }
        } catch { report(error) }
    }

    /// Called from a session's ownership lease, so a just-finished install is visible.
    /// The returned set carries the revision of this very `active` parse (`sourceRevision`),
    /// so callers can require an exact same-snapshot revision before overlaying a publication.
    func tryResources() async throws -> KeyboardResourceSet? {
        guard let active = try await manager.activeInstallation() else { return nil }
        let summary = try JSONDecoder().decode(
            Summary.self,
            from: Data(
                contentsOf:
                    active.resourceURL.appendingPathComponent("host-import-summary.json")))
        return .userDictionary(
            name: summary.name, sharedDirectory: active.resourceURL,
            userDirectory: active.userDataURL, prebuiltDirectory: active.userDataURL.appendingPathComponent("build"),
            sourceRevision: active.installation.revision,
            schemas: try KeyboardRecipeStore.deployedSchemas(build: active.userDataURL.appendingPathComponent("build")))
    }

    func apply() {
        guard !busy else { return }
        busy = true
        error = nil
        message = "正在切换…"
        Task {
            defer { busy = false }
            do {
                guard let active = try await manager.activeInstallation() else {
                    throw DictionaryImportError.invalid("请先安装词库")
                }
                let name = installedSummary?.name ?? "导入词库"
                try await EngineOpQueue.async {
                    try KeyboardRecipeStore.publish(
                        resources: active.resourceURL,
                        compiledBuild: active.userDataURL.appendingPathComponent("build"),
                        revision: active.installation.revision, kind: .userDictionary, dictionaryName: name)
                }
                selectionRevision = UUID()
                message = "\(UserTerminology.statusInUse)「\(name)」，下次打开键盘时生效。"
            } catch {
                report(error)
                message = "无法确认结果，请重新读取后重试。"
                selectionRevision = UUID()
            }
        }
    }

    var canPrepare: Bool { root != nil && missing.isEmpty && prepared == nil }
}
