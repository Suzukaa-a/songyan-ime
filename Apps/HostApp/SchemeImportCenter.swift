import CryptoKit
import Foundation
import KeyboardCore
import OSLog
import PackageManager
import RimeBridge
import SwiftUI

/// Complete-source installations. Each package owns an independent transactional store.
/// Installation never changes the shared selection; apply is an explicit, separate action.
@MainActor
final class SchemeImportCenter: ObservableObject {
    static let shared = SchemeImportCenter()
    /// `schemas` is the runnable list: schemes fully validated at install and actually enabled by the deployed config,
    /// used for trial typing/publishing. `sourceSchemas` is the source inventory: schemes whose source is in the package but
    /// not enabled; informational only, never part of the trial/publish set.
    struct InstalledPackage: Identifiable {
        let id: String
        let name: String
        let active: ActiveRecipe
        let schemas: [KeyboardSchemaDescriptor]
        let sourceSchemas: [String]
        let skippedSchemas: [SkippedEngineSchema]
        let bindings: [KeyboardResourceSet.LayoutEntry]
        /// Keyboard layouts this source supports (dynamic capability: the truly available input method x 26/14/9 combinations).
        /// A capability fact only; not bound to source identity and hardcodes no schema ID.
        let supportedLayouts: [KeyboardLayoutKind]
        /// Source URL recorded by a URL import; nil when none (local-file sources show "not recorded").
        let sourceURL: URL?
    }
    private struct VerifiedBindings: Codable {
        let revision: String
        let values: [SchemeInputBinding]
    }
    /// Source URL record of a URL import (written once at install to the package slot's source-url.json; used by detail source / re-download).
    struct PackageSourceMetadata: Codable {
        let url: URL?
    }
    /// Read the URL source recorded for a package slot; nil when none (detail shows "not recorded").
    static func recordedSourceURL(packageID: String) -> URL? {
        recordedSourceURL(packageID: packageID, storeRoot: storeRoot)
    }

    nonisolated private static func recordedSourceURL(packageID: String, storeRoot: URL) -> URL? {
        let url = storeRoot.appendingPathComponent(packageID).appendingPathComponent("source-url.json")
        guard let data = try? Data(contentsOf: url),
            let metadata = try? JSONDecoder().decode(PackageSourceMetadata.self, from: data)
        else { return nil }
        return metadata.url
    }

    /// Records a file/URL install's source once; a package keeps one kind of source record, so a
    /// Rime-source origin left by an earlier install is dropped.
    func saveSource(_ url: URL?, packageID: String) -> String? {
        let slot = Self.storeRoot.appendingPathComponent(packageID)
        do {
            try JSONEncoder().encode(PackageSourceMetadata(url: url))
                .write(to: slot.appendingPathComponent("source-url.json"), options: .atomic)
            try? FileManager.default.removeItem(at: slot.appendingPathComponent("source-origin.json"))
            return nil
        } catch {
            HostLog.append("source metadata save failed: \(error.localizedDescription)")
            return "方案已安装，但未能记录下载地址。"
        }
    }
    struct DamagedPackage: Identifiable {
        let id: String
        let name: String
        let schemaIDs: Set<String>
    }
    @Published private(set) var installedPackages: [InstalledPackage] = []
    @Published private(set) var damagedPackages: [DamagedPackage] = []
    private var refreshGeneration: UInt64 = 0
    @Published var prepared: PreparedSchemeImport?
    @Published var preparingExternalResource = false
    /// URL of this import's source (kept for URL imports, for the recognition result and the detail page's source display).
    @Published var preparedSourceURL: URL?
    /// ID of the most recently installed package (for the "view scheme" entry; install does not auto-apply).
    @Published var lastInstalledPackageID: String?
    /// The last install replaced an existing package's files instead of adding a scheme.
    @Published var lastInstallReplacedVersion = false

    /// The recognized import replaces this already installed package, because it is the same scheme.
    var preparedUpdatesInstalledPackage: Bool {
        guard let prepared else { return false }
        return installedPackages.contains { $0.id == prepared.declaration.id }
    }
    var preparedReplacedPackageName: String? {
        guard let prepared else { return nil }
        return installedPackages.first { $0.id == prepared.declaration.id }?.name
    }
    @Published var recipeDiscoveryErrors: [String] = []
    @Published var diagnostics: [String] = []
    /// Plain-language notice for ordinary users (no IDs/paths); set only when recovery cannot be automatic or a successful operation needs a next step.
    /// Kept separate from `diagnostics`: developer diagnostics never enter the ordinary flow.
    @Published var userNotice: String?
    @Published var busy = false
    @Published var error: String? {
        didSet { if error == nil { failureState = nil } }
    }
    /// Structured statement of whether state changed on failure; set by `fail(_:_:)` from real transaction semantics.
    /// An unclassified failure stays nil, so the failure page shows a neutral "cannot confirm" and never blanket-claims "unchanged".
    @Published var failureState: OperationFailureState?
    @Published var message: String?
    @Published var selectionRevision = UUID()
    // Recipe configuration state.
    @Published var acquiredSources: [AcquiredRimeSource] = []
    @Published var sourceTarget = ""
    @Published var sourcePlan: DeclarativeRecipePlan?
    @Published var sourcePackageID: String?
    var sourceBaseline: RecipeWorkspaceSnapshot?
    var sourceGeneration: String?
    var sourceTask: Task<Void, Never>?
    @Published var recipes: [DiscoveredRecipe] = []
    @Published var plannedRecipe: PlannedRecipeInstall?
    @Published var plannedDiagnostics: [String] = []
    /// Installed-package recipe workspace (existing custom/model references + generation baseline).
    @Published var installedWorkspace: InstalledRecipeWorkspace?
    @Published private(set) var installedWorkspacePackages: [String] = []
    /// Explicitly provided external resources keyed by the recipe-declared requirement path
    /// (never the picked filename). Models stay file references end-to-end (each reference
    /// owns a private temporary-file lease released when the last holder drops it); no 420MB Data.
    @Published var providedDownloadFiles: [String: RecipeFileResource] = [:]
    /// Non-model provided resources (yaml/dicts) are bounded bytes frozen as immutable
    /// `ProvidedOrdinaryResource`, hashed once in the background acquisition. The core plan API
    /// accepts Data only for these; model bytes stay file references.
    @Published var providedOrdinaryResources: [String: ProvidedOrdinaryResource] = [:]

    /// The most recent import operation that started but has not succeeded. The failure page's retry replays the same chosen file/scheme from it
    /// (`SchemeImportRetryState`) and never reopens the fileImporter to make the user choose again.
    var retryState = SchemeImportRetryState()
    var retryDecision: SchemeImportRetryDecision { retryState.decision }

    /// Failure page retry: replays the operation from the same captured inputs. Returns true if replayed;
    /// false means there is no chosen operation to replay (the UI may then fall back to re-selecting).
    @discardableResult
    func retryLastOperation() -> Bool {
        guard !busy, let intent = retryState.consume() else { return false }
        switch intent {
        case .installRecognizedImport:
            install()
        case .planRecipe(let path, let arguments, let stages, let installed):
            if installed {
                planInstalledRecipe(path, arguments: arguments, stages: stages.map(Self.recipeStage))
            } else {
                planRecipe(path, arguments: arguments, stages: stages.map(Self.recipeStage))
            }
        case .installPlannedRecipe(let path, let arguments, let stages, let installed):
            let mapped = stages.map(Self.recipeStage)
            if plannedRecipe == nil {
                // The plan was invalidated after the failure (e.g. root selection changed).
                // Re-plan the captured selection rather than silently doing nothing.
                retryState.begin(
                    .planRecipe(recipePath: path, arguments: arguments, stages: stages, installed: installed))
                if installed {
                    planInstalledRecipe(path, arguments: arguments, stages: mapped)
                } else {
                    planRecipe(path, arguments: arguments, stages: mapped)
                }
            } else if installed {
                installPlannedRecipeOnInstalled(
                    currentRecipePath: path, currentArguments: arguments, currentStages: mapped)
            } else {
                installPlannedRecipe(currentRecipePath: path, currentArguments: arguments, currentStages: mapped)
            }
        case .installSourcePlan:
            installSourcePlan()
        case .acquireSource(let target, let updating):
            acquireSource(target, updatingPackageID: updating)
        }
        return true
    }

    nonisolated static func retryStages(_ stages: [RecipeStage]) -> [SchemeImportStageSelection] {
        stages.map { SchemeImportStageSelection(path: $0.path, arguments: $0.arguments) }
    }

    nonisolated private static func recipeStage(_ stage: SchemeImportStageSelection) -> RecipeStage {
        RecipeStage(path: stage.path, arguments: stage.arguments)
    }

    /// A recipe discovered from immutable package/source bytes. Path is package-relative;
    /// declaredArguments come from `recipe.args` documentation and carry no runtime defaults.
    struct DiscoveredRecipe: Identifiable, Equatable {
        let path: String
        let declaredName: String?
        let displayDescription: String?
        let declaredArguments: [String]
        let downloads: [RecipeExternalResource]
        let installPatterns: [String]
        let patchTargets: [String]
        var id: String { path }
        var displayName: String {
            if let first = displayDescription?.split(separator: "\n").first,
                !first.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return first.trimmingCharacters(in: .whitespaces)
            }
            if let declaredName, !declaredName.trimmingCharacters(in: .whitespaces).isEmpty {
                return declaredName.trimmingCharacters(in: .whitespaces)
            }
            return "方案选项"
        }
    }

    /// A validated plan awaiting the user's explicit install command. The plan itself
    /// changes nothing; installing through `installPlannedRecipe` is transactional.
    struct PlannedRecipeInstall {
        let recipePath: String
        let rx: String
        /// Placeholder only: the effective entry is decided at deploy time from the
        /// actually-enabled schema_list, never from source ordering or the plan UI.
        let schemaID: String
        let changedPaths: [String]
        let summary: [String]
        /// False when the recipe's output contains no schema to deploy (patch-only recipe
        /// on a fresh import). Installing would be a guaranteed deployment failure.
        var isDeployable: Bool { !schemaID.isEmpty }
        let plan: DeclarativeRecipePlan
    }

    /// The core transaction requires the manifest entry's .schema.yaml to be among the planned files (origins other than userRecipe
    /// also require the receipt entry == manifest entry). Here the entry is predicted from the effective config the plan produces:
    /// the first schema in default.yaml (including the final list synthesized from custom managed blocks) that is in the planned files;
    /// falling back to the manifest declaration or any in-plan schema. The real entry is still decided at deploy time by the actually
    /// enabled list and written into the receipt.
    nonisolated static func requestedEntrySchema(
        plan: DeclarativeRecipePlan, manifestEntry: String, manifestFiles: [String: Data]
    ) -> String {
        var listed: [String] = []
        if let custom = plan.files["default.custom.yaml"].flatMap({ String(data: $0, encoding: .utf8) }) {
            listed = Self.schemaListRows(in: custom, custom: true)
        }
        if listed.isEmpty,
            let defaults = plan.files["default.yaml"].flatMap({ String(data: $0, encoding: .utf8) })
        {
            listed = Self.schemaListRows(in: defaults, custom: false)
        }
        let inPlan = { (id: String) -> Bool in
            plan.files["\(id).schema.yaml"] != nil || plan.fileResources["\(id).schema.yaml"] != nil
        }
        if let first = listed.first(where: inPlan) { return first }
        if inPlan(manifestEntry) { return manifestEntry }
        if let any = plan.files.keys.filter({ $0.hasSuffix(".schema.yaml") && !$0.contains("/") }).sorted().first {
            return String(any.dropLast(12))
        }
        return manifestEntry
    }

    /// Ordered extraction of `- schema: X` lines under the top-level `schema_list:` (no other YAML is interpreted).
    /// The recipe-synthesized `default.custom.yaml` is a `__patch:` block sequence with the target list indented inside a block,
    /// so for custom files take the lines after the last `schema_list:`, and for plain default files the first top-level one.
    /// Both only accept `- schema: X` lines and stop at any other top-level key.
    nonisolated private static func schemaListRows(in text: String, custom: Bool) -> [String] {
        guard let range = text.range(of: "schema_list:") else { return [] }
        var rows: [String] = []
        for line in text[range.upperBound...].split(separator: "\n") {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty || clean.hasPrefix("#") { continue }
            guard clean.hasPrefix("- schema:") else {
                // The next target or end marker inside a custom managed block ends this list.
                if custom || !clean.hasPrefix("- ") { break }
                continue
            }
            let value = clean.dropFirst("- schema:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !value.isEmpty, !value.contains("#") else { continue }
            rows.append(value)
        }
        return rows
    }
    static var storeRoot: URL { HostStorePaths.applicationSupport.appendingPathComponent("SchemePackages") }
    func manager(_ id: String) -> RecipePackageManager {
        RecipePackageManager(
            rootURL: Self.storeRoot.appendingPathComponent(id),
            sharedOpenCCDirectory: Bundle.main.url(
                forResource: "opencc", withExtension: nil, subdirectory: "EngineResources"))
    }

    /// An installed package's quiescent workspace captured for recipe planning: the effective
    /// file tree (user custom overlaid), model file references (never read as Data), and the
    /// generation baseline that a later plan must match inside the same exclusive lease.
    struct InstalledRecipeWorkspace {
        let packageID: String
        let displayName: String
        let revision: String
        let generation: String?
        let initialUserDataURL: URL?
        let snapshot: RecipeWorkspaceSnapshot
        var sources: InstalledRecipeSources? = nil
        var schemaIDs: [String] {
            snapshot.files.keys.filter { $0.hasSuffix(".schema.yaml") && !$0.contains("/") }
                .map { String($0.dropLast(12)) }.sorted()
        }
    }

    /// One ordered composition step appended after the root recipe (configuration, grammar, …).
    /// Generic sequencing of the official rime-install order — resources first, then any
    /// number of configuration recipes — with nothing package-specific inside.
    struct RecipeStage: Equatable {
        let path: String
        let arguments: [RecipeArgument]
    }

    /// Pure policy: resolve a package's currently used input method from an already-read publication selection snapshot, with no sync disk read.
    /// Reads happen on the read queue (see `selectionSnapshot` in `SchemePackageDetailView`).
    func currentSchemaID(
        packageID: String,
        snapshot: AppliedSelectionSnapshot
    ) -> String? {
        ActiveSchemaResolver.currentSchemaID(
            recipeEnabled: snapshot.recipeEnabled, resourceKind: snapshot.resourceKind,
            packageID: snapshot.packageID, selectedSchemaID: snapshot.selectedSchemaID,
            requiredSchemaIDs: snapshot.requiredSchemaIDs, forPackageID: packageID)
    }

    func incompatibilityReason(packageID: String, schemaID: String, layout: KeyboardLayoutKind) -> String? {
        guard let item = installedPackages.first(where: { $0.id == packageID }),
            item.schemas.contains(where: { $0.id == schemaID })
        else { return "方案未安装" }
        let set = KeyboardResourceSet(
            id: item.id, name: item.name, sharedDirectory: item.active.resourceURL,
            userDirectory: item.active.userDataURL, layoutEntries: item.bindings, schemas: item.schemas,
            selectedSchemaID: schemaID)
        return set.incompatibilityReason(layout: layout, schemaID: schemaID)
    }

    /// Input method x keyboard layout information architecture for this source (dynamic from the resource snapshot, not bound to source identity).
    func inputConfiguration(packageID: String) -> InputConfigurationChoices? {
        guard let item = installedPackages.first(where: { $0.id == packageID }) else { return nil }
        return InputConfigurationChoices(
            resourceSet: KeyboardResourceSet(
                id: item.id, name: item.name, sharedDirectory: item.active.resourceURL,
                userDirectory: item.active.userDataURL, layoutEntries: item.bindings,
                prebuiltDirectory: item.active.userDataURL.appendingPathComponent("build"),
                schemas: item.schemas))
    }

    /// Supported keyboard layouts (union of dynamic capabilities; empty when there are no input methods).
    nonisolated static func supportedLayouts(resourceSet: KeyboardResourceSet) -> [KeyboardLayoutKind] {
        InputConfigurationChoices(resourceSet: resourceSet).supportedLayouts
    }

    /// Establish a compact-key input contract against the actual deployed engine. Preferences
    /// alone never grant compatibility. Verification uses a separate user directory, not live learning.
    func validateBinding(_ binding: SchemeInputBinding, packageID: String) async throws {
        guard !busy, let item = installedPackages.first(where: { $0.id == packageID }),
            item.schemas.contains(where: { $0.id == binding.schemaID }),
            let layout = KeyboardLayoutKind(rawValue: binding.layout), !binding.code.isEmpty, !binding.candidate.isEmpty
        else {
            throw RecipeInstallError.invalidResource("无效方案关联或另一项操作正在进行")
        }
        let codes = Set(
            KeyboardLayoutTable.mainRows(for: layout).flatMap(\.caps).compactMap { cap -> String? in
                if case .code(let value) = cap.action { return value }
                return nil
            }.joined() + "'")
        guard Set(binding.code).isSubset(of: codes) else { throw RecipeInstallError.invalidResource("试打码包含此布局未发送的逻辑键") }
        busy = true
        defer { busy = false }
        let directory = Self.storeRoot.appendingPathComponent(item.id)
        let scratch = directory.appendingPathComponent("verification/" + UUID().uuidString)
        do {
            try await EngineOwnershipCoordinator.shared.withExclusive {
                try await EngineOpQueue.async {
                    let engine = RimeEngine(
                        configuration: .init(
                            sharedDirectory: item.active.resourceURL,
                            userDirectory: scratch,
                            prebuiltDirectory: item.active.userDataURL.appendingPathComponent("build")))
                    defer { engine.shutdown() }
                    try engine.start()
                    // Unified validator: dependency closure, component capability, grammar prerequisites, select, and current-instance load in one pass.
                    try engine.validateSchemaForActivation(schemaID: binding.schemaID)
                    for character in binding.code {
                        guard let event = RimeKey(character: character) else {
                            throw RecipeInstallError.deployment("无效的按键编码")
                        }
                        _ = try engine.processKey(event)
                    }
                    var state = engine.state()
                    for _ in 0..<20 {
                        if let index = state.candidates.firstIndex(where: { $0.text == binding.candidate }) {
                            guard engine.selectCandidate(index)?.commitText == binding.candidate else {
                                throw RecipeInstallError.deployment("候选词未完整上屏")
                            }
                            return
                        }
                        guard !state.isLastPage, let next = engine.pageForward() else { break }
                        state = next
                    }
                    throw RecipeInstallError.deployment("输入「\(binding.code)」后未在候选栏中找到「\(binding.candidate)」")
                }
            }
        } catch {
            // The validation scratch directory is created by this method and cleaned directly on failure (touches no user data directory).
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        // On success, likewise clean only the scratch created here (self-managed lifecycle).
        try? FileManager.default.removeItem(at: scratch)
        let url = directory.appendingPathComponent("validated-bindings.json")
        var values: [SchemeInputBinding] = []
        if let data = try? Data(contentsOf: url),
            let old = try? JSONDecoder().decode(VerifiedBindings.self, from: data),
            old.revision == item.active.installation.revision
        {
            values = old.values
        }
        values.removeAll { $0.layout == binding.layout && $0.schemaID == binding.schemaID }
        values.append(binding)
        try JSONEncoder().encode(VerifiedBindings(revision: item.active.installation.revision, values: values)).write(
            to: url, options: .atomic)
        await refresh()
    }

    /// Progress/error surface shared by the import UI. Real failures are shown in place;
    /// user cancellation is not an error and stays silent.
    func report(_ failure: Error) {
        guard !isUserCancellation(failure) else { return }
        fail(.nothingCommitted, failure)
    }

    /// Record a failure: `state` must come from real transaction semantics (see `OperationFailureState`).
    /// Install/import is an atomic transaction: before commit neither content nor keyboard has changed; a failed post-commit write
    /// only reaches "install content saved, current keyboard unchanged".
    func fail(_ state: OperationFailureState, _ detail: String) {
        failureState = state
        error = detail
    }

    /// Core errors often carry package paths, schema IDs, hashes and engine details. Keep
    /// those in the developer log; normal failure UI receives only a stable category.
    func fail(_ state: OperationFailureState, _ failure: Error) {
        HostLog.append("scheme operation failed: \(failure.localizedDescription)")
        fail(state, Self.userFacingOperationError(failure))
    }

    nonisolated private static func userFacingOperationError(_ failure: Error) -> String {
        switch failure {
        case RecipeInstallError.http(let code):
            return "下载未完成（HTTP \(code)），请检查网络和来源后重试。"
        case RecipeInstallError.busy:
            return "另一项操作正在进行，请稍后再试。"
        case RecipeInstallError.missingComponents:
            return (failure as? RecipeInstallError)?.userFacingDescription ?? "暂不支持此方案。"
        case RecipeInstallError.missingSchemaFiles(let names):
            // Show file names only (no paths within the source), at most 5.
            let files = names.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
            let more = names.count > 5 ? " 等 \(names.count) 个文件" : ""
            return names.isEmpty
                ? "输入方案缺少所依赖的文件，请将所需文件放入同一个 ZIP 压缩包或文件夹后重新导入。"
                : "输入方案缺少文件：\(files)\(more)。请将所需文件放入同一个 ZIP 压缩包或文件夹后重新导入。"
        case RecipeInstallError.invalidManifest, RecipeInstallError.invalidResource,
            RecipeInstallError.missingGrammarModels, RecipeInstallError.deployment:
            return (failure as? RecipeInstallError)?.userFacingDescription ?? "无法完成安装，请重试。"
        default:
            return "操作未完成，请重试。"
        }
    }

    /// fileImporter's `.failure` for a plain Cancel is a user action, not a failure to report.
    private func isUserCancellation(_ failure: Error) -> Bool {
        if failure is CancellationError { return true }
        if let cocoa = failure as? CocoaError, cocoa.code == .userCancelled { return true }
        if let underlying = (failure as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.code == NSUserCancelledError
        {
            return true
        }
        return false
    }

    /// One direct update may run at a time: two of them for one package would race on its store slot.
    var schemeUpdateActive = false
    /// The running update, owned here so a dismissed detail page can still cancel it.
    var schemeUpdateTask: Task<SchemeUpdateOutcome, Never>?

    nonisolated private static func decodeInstalledPackage(
        _ id: String, active: ActiveRecipe,
        storeRoot: URL
    ) throws -> InstalledPackage {
        let declaration = try JSONDecoder().decode(
            SchemePackageDeclaration.self,
            from: Data(contentsOf: active.resourceURL.appendingPathComponent("keyboard-package.json")))
        guard declaration.id == id else { throw RecipeInstallError.invalidResource("安装身份不匹配") }
        let schemas = try JSONDecoder().decode(
            [KeyboardSchemaDescriptor].self,
            from: Data(contentsOf: active.resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardSchemas)))
        // The enabled receipt is authoritative; missing source inventory never grants input capability.
        let sourceSchemas: [String]
        if let data = try? Data(
            contentsOf: active.resourceURL.appendingPathComponent(InstalledPackageLayout.keyboardSourceSchemas))
        {
            sourceSchemas = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            sourceSchemas = []
        }
        let skippedURL = active.resourceURL.appendingPathComponent(EngineSchemaSelection.reportName)
        let skippedSchemas =
            (try? JSONDecoder().decode(
                [SkippedEngineSchema].self,
                from: Data(contentsOf: skippedURL))) ?? []
        let slot = storeRoot.appendingPathComponent(id)
        let verifiedURL = slot.appendingPathComponent("validated-bindings.json")
        var declaredBindings = declaration.bindings
        if let data = try? Data(contentsOf: verifiedURL),
            let verified = try? JSONDecoder().decode(VerifiedBindings.self, from: data),
            verified.revision == active.installation.revision
        {
            declaredBindings += verified.values
        }
        let bindings = declaredBindings.compactMap { binding -> KeyboardResourceSet.LayoutEntry? in
            guard let layout = KeyboardLayoutKind(rawValue: binding.layout),
                schemas.contains(where: { $0.id == binding.schemaID })
            else { return nil }
            return .init(layout: layout, schemaID: binding.schemaID)
        }
        let resources = KeyboardResourceSet(
            id: id, name: declaration.name, sharedDirectory: active.resourceURL,
            userDirectory: active.userDataURL, layoutEntries: bindings,
            prebuiltDirectory: active.userDataURL.appendingPathComponent("build"), schemas: schemas)
        return InstalledPackage(
            id: id, name: declaration.name, active: active, schemas: schemas,
            sourceSchemas: sourceSchemas, skippedSchemas: skippedSchemas, bindings: bindings,
            supportedLayouts: supportedLayouts(resourceSet: resources),
            sourceURL: recordedSourceURL(packageID: id, storeRoot: storeRoot))
    }

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let root = Self.storeRoot
        do {
            let ids = try await KeyboardResourceReadQueue.async { () -> [String] in
                guard FileManager.default.fileExists(atPath: root.path) else { return [] }
                return try FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
                )
                .compactMap { url in
                    let id = url.lastPathComponent
                    guard PublishedKeyboardSourceKey.validPackageID(id),
                        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                        values.isDirectory == true, values.isSymbolicLink != true
                    else { return nil }
                    return id
                }
            }
            var installed: [InstalledPackage] = []
            var damaged: [DamagedPackage] = []
            for id in ids {
                guard !Task.isCancelled else { return }
                var active: ActiveRecipe?
                do {
                    active = try await manager(id).activeInstallation()
                    // Failed first installs leave a private staging slot but never commit active.json.
                    guard let active else { continue }
                    installed.append(
                        try await KeyboardResourceReadQueue.async {
                            try Self.decodeInstalledPackage(id, active: active, storeRoot: root)
                        })
                } catch {
                    let schemaIDs: Set<String> = active.map { [$0.installation.schemaID] } ?? []
                    let name: String
                    if let active {
                        name =
                            (try? await KeyboardResourceReadQueue.async {
                                let data = try Data(
                                    contentsOf: active.resourceURL.appendingPathComponent("keyboard-package.json"))
                                let declaration = try JSONDecoder().decode(SchemePackageDeclaration.self, from: data)
                                return declaration.id == id ? declaration.name : "输入方案已损坏"
                            }) ?? "输入方案已损坏"
                    } else {
                        name = "输入方案已损坏"
                    }
                    damaged.append(DamagedPackage(id: id, name: name, schemaIDs: schemaIDs))
                }
            }
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            installedPackages = installed.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            damagedPackages = damaged.sorted { $0.id < $1.id }
        } catch {
            guard generation == refreshGeneration, !Task.isCancelled else { return }
            fail(.nothingCommitted, error)
        }
    }

    func tryResources(packageID: String, schemaID: String? = nil) async throws -> KeyboardResourceSet? {
        await refresh()
        guard let item = installedPackages.first(where: { $0.id == packageID }) else { return nil }
        // The default trial uses the install record's effective entry (InstalledRecipe.schemaID, written by the install receipt),
        // not the first source schema after sorting.
        let selected = schemaID ?? item.active.installation.schemaID
        guard item.schemas.contains(where: { $0.id == selected }) else { return nil }
        return KeyboardResourceSet(
            id: item.id, name: item.name, sharedDirectory: item.active.resourceURL,
            userDirectory: item.active.userDataURL, layoutEntries: item.bindings,
            prebuiltDirectory: item.active.userDataURL.appendingPathComponent("build"), schemas: item.schemas,
            selectedSchemaID: selected,
            sourceRevision: item.active.installation.revision)
    }
}
