import Foundation
import KeyboardCore
import PackageManager
import RimeBridge
import SwiftUI

/// Commit prediction (Settings > Input Options).
///
/// The engine statically links librime-predict (`predictor` + `predict_translator`), but this app neither **bundles nor downloads**
/// any prediction dictionary: users import a `Rime::Predict`-format predict.db themselves. This center only orchestrates;
/// decisions and patch generation live in `PackageManager.Prediction` (no hardcoded source/scheme names):
///   * Import: structurally validates only the file header and internal table bounds, then installs it together with the prediction patch in
///     the **same** normal install transaction (`install_files`), committing only after the real engine proves the components are registered and the compiled config is wired up;
///   * On by default: the preference defaults to on once a dictionary is imported; converges once for the source in use on home refresh;
///   * No dictionary, a scheme that ships its own prediction (predictor / predict_translator already declared), or a user custom
///     that already configures it: never patch (fail closed); the 14/9-key companion schemes are generated from the source's compiled config and inherited as is;
///   * Display trusts only the compiled config and published resources **published to the keyboard**.
@MainActor
final class PredictionCenter: ObservableObject {
    static let shared = PredictionCenter()
    static let preferenceKey = "app.songyan.settings.prediction"
    private static let autoAttemptKey = "app.songyan.settings.prediction.autoAttempt"

    /// The user's choice; absent means the default (on once a database is installed).
    static var preferred: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    enum State: Equatable, Sendable {
        case loading
        case noSource
        /// Not provable for the input method the keyboard uses (fail closed).
        case unavailable(String)
        /// The scheme brings its own prediction; left as the scheme defines it.
        case schemeManaged
        /// The user's own custom configuration touches prediction.
        case userManaged
        /// Eligible, but no prediction database has been imported for this source.
        case noDatabase
        /// Wired, but the published database is missing or invalid (fail closed: shown off).
        case databaseMissing
        case on
        case off
    }

    struct PublishedContext: Sendable {
        /// `nil` when the source in use is not an installed package (custom pinyin).
        let packageID: String?
        let revision: String
        let keyboard: PublishedKeyboard?
        let schemaID: String
        let state: State
        let eligible: Bool
        let databaseBytes: Int?
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var databaseBytes: Int?
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var failure: String?
    private var reconcileTask: Task<Void, Never>?

    // MARK: - Status

    func refresh() async {
        do {
            guard let context = try await Self.readPublished() else {
                state = .noSource
                databaseBytes = nil
                return
            }
            databaseBytes = context.databaseBytes
            if context.eligible, await userManaged(context: context) {
                state = .userManaged
            } else {
                state = context.state
            }
        } catch {
            HostLog.append("prediction status read failed: \(error.localizedDescription)")
            state = .unavailable("无法读取当前输入方式的设置。")
        }
    }

    nonisolated static func context(from snapshot: KeyboardRecipeStore.Snapshot?) -> PublishedContext? {
        guard let snapshot else { return nil }
        let activation = snapshot.activation
        let packageID: String
        switch activation.kind {
        case .userScheme:
            guard let id = activation.packageID else { return nil }
            packageID = id
        case .userDictionary:
            return PublishedContext(
                packageID: nil, revision: activation.revision, keyboard: nil, schemaID: "",
                state: .unavailable("当前输入方案不支持上屏联想。"), eligible: false, databaseBytes: nil)
        }
        guard let schemaID = activation.selectedSchemaID ?? activation.requiredSchemaIDs.first else { return nil }
        let keyboard = activation.selectedLayout.map { PublishedKeyboard(schemaID: schemaID, layout: $0) }
        let database = snapshot.resources.appendingPathComponent(Prediction.databasePath)
        var bytes: Int?
        if (try? Prediction.validateDatabase(at: database)) != nil,
            let size = try? database.resourceValues(forKeys: [.fileSizeKey]).fileSize
        {
            bytes = size
        }
        func make(_ state: State, eligible: Bool = false) -> PublishedContext {
            PublishedContext(
                packageID: packageID, revision: activation.revision, keyboard: keyboard,
                schemaID: schemaID, state: state, eligible: eligible, databaseBytes: bytes)
        }
        guard
            let compiled = try? Data(
                contentsOf: InstalledPackageLayout.compiledSchemaURL(build: snapshot.build, id: schemaID))
        else {
            return make(.unavailable("无法读取当前输入方式的设置。"))
        }
        switch Prediction.eligibility(compiled: compiled, schemaID: schemaID) {
        case .sourceManaged:
            return make(.schemeManaged)
        case .ineligible:
            return make(.unavailable("当前输入方式不支持上屏联想。"))
        case .eligible:
            if Prediction.compiledEnabled(compiled: compiled) {
                return make(bytes == nil ? .databaseMissing : .on, eligible: true)
            }
            return make(bytes == nil ? .noDatabase : .off, eligible: true)
        }
    }

    private static func readPublished() async throws -> PublishedContext? {
        try await KeyboardResourceReadQueue.async {
            Self.context(from: try KeyboardRecipeStore.snapshot(selectedOnly: true))
        }
    }

    private func userManaged(context: PublishedContext) async -> Bool {
        guard let reference = context.packageID,
            let active = try? await SchemeImportCenter.shared.manager(reference).activeInstallation()
        else { return false }
        let name = context.schemaID + ".custom.yaml"
        let urls = [active.userDataURL.appendingPathComponent(name), active.resourceURL.appendingPathComponent(name)]
        return
            (try? await KeyboardResourceReadQueue.async { () -> Bool in
                urls.contains {
                    Prediction.userOwnsSetting(customYAML: try? Data(contentsOf: $0), packageReference: reference)
                }
            }) ?? false
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        guard !working else { return }
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        Task { await apply(enabled, database: nil, automatic: false) }
    }

    /// User-picked file: captured while its security scope is held, structurally checked,
    /// then installed together with the preferred on/off state in one transaction.
    func importDatabase(from url: URL) {
        guard !working else { return }
        working = true
        failure = nil
        notice = nil
        Task {
            let resource: RecipeFileResource
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "prediction-import", isDirectory: true)
                resource = try await RecipeFileResource.capture(from: url, directory: directory)
                try await KeyboardResourceReadQueue.async { try Prediction.validateDatabase(at: resource.url) }
            } catch {
                HostLog.append("prediction database import rejected: \(error.localizedDescription)")
                failure = "所选文件不是有效的联想词库（predict.db）。"
                working = false
                return
            }
            working = false
            await apply(Self.preferred, database: resource, automatic: false)
        }
    }

    /// Default-on convergence for the source in use, at most once per published revision.
    /// Runs after typo correction's own convergence so the two never race for the installer.
    func scheduleReconcile(after previous: Task<Void, Never>? = nil) {
        guard reconcileTask == nil, Self.preferred else { return }
        reconcileTask = Task {
            defer { reconcileTask = nil }
            await previous?.value
            await refresh()
            guard state == .off, !SchemeImportCenter.shared.busy, !KeyboardSelectionCenter.shared.isBusy,
                let context = try? await Self.readPublished()
            else { return }
            let token = (context.packageID ?? "-") + ":" + context.revision
            guard UserDefaults.standard.string(forKey: Self.autoAttemptKey) != token else { return }
            UserDefaults.standard.set(token, forKey: Self.autoAttemptKey)
            await apply(true, database: nil, automatic: true)
        }
    }

    private func apply(_ enabled: Bool, database: RecipeFileResource?, automatic: Bool) async {
        guard !working else { return }
        working = true
        failure = nil
        notice = nil
        defer { working = false }
        do {
            guard let context = try await Self.readPublished(), let packageID = context.packageID,
                context.eligible || database != nil
            else {
                throw RecipeInstallError.invalidResource("当前输入方式不支持上屏联想")
            }
            let imports = SchemeImportCenter.shared
            let outcome = try await imports.applyPrediction(
                enabled: enabled, packageID: packageID,
                database: database)
            if outcome.changed {
                if outcome.previousRevision == context.revision, let keyboard = context.keyboard {
                    _ = try await imports.performAddKeyboard(packageID: packageID, keyboard: keyboard)
                } else {
                    notice = "将在使用新版本后生效。"
                }
            }
            HostLog.append(
                "prediction \(enabled ? "on" : "off") applied (automatic=\(automatic), database=\(database != nil), changed=\(outcome.changed))"
            )
        } catch {
            HostLog.append("prediction apply failed (automatic=\(automatic)): \(error.localizedDescription)")
            failure =
                database != nil
                ? "导入联想词库失败，请重试。"
                : (enabled ? "开启失败，请重试。" : "关闭失败，请重试。")
        }
        await refresh()
    }
}

struct PredictionOutcome: Sendable {
    let changed: Bool
    let previousRevision: String
}

extension SchemeImportCenter {
    /// One transactional update of the given source:
    /// optionally installs the imported database, and patches eligible enabled input methods
    /// whose compiled state differs from `enabled`. Enabling requires a database in the
    /// resulting installation. The live engine must prove the wiring before commit.
    func applyPrediction(enabled: Bool, packageID: String, database: RecipeFileResource?) async throws
        -> PredictionOutcome
    {
        let result = try await applyManagedPatch(
            packageID: packageID,
            message: database != nil ? "正在导入联想词库…" : (enabled ? "正在开启上屏联想…" : "正在关闭上屏联想…"),
            plan: { context in
                let hasDatabase = database != nil || context.snapshot.fileResources[Prediction.databasePath] != nil
                guard hasDatabase || !enabled else { throw RecipeInstallError.invalidResource("请先导入联想词库。") }
                let changes = PredictionPlanning.changes(
                    desired: enabled, build: context.build,
                    customFiles: context.snapshot.files, packageReference: packageID)
                guard !changes.isEmpty || database != nil else { return nil }
                let recipe = try Prediction.make(
                    enabling: enabled ? changes : [], disabling: enabled ? [] : changes,
                    installDatabase: database != nil)
                var resources: [String: RecipeFileResource] = [:]
                if let database { resources[Prediction.databasePath] = database }
                return ManagedPatchPlan(recipe: recipe, resources: resources, change: changes)
            },
            verify: { engine, enabledIDs, deployment, changes in
                try PredictionPlanning.verify(
                    engine: engine, enabledSchemaIDs: enabledIDs,
                    changes: changes, desired: enabled,
                    build: deployment.userDataURL.appendingPathComponent("build"),
                    resources: deployment.resourceURL)
            })
        return PredictionOutcome(changed: result.installed != nil, previousRevision: result.previousRevision)
    }
}

/// File-level planning and live read-back, independent of any UI state.
enum PredictionPlanning {
    static func changes(
        desired: Bool, build: URL, customFiles: [String: Data],
        packageReference: String
    ) -> [Prediction.Target] {
        var targets: [Prediction.Target] = []
        var current: [String: Bool] = [:]
        var managed = Set<String>()
        for (id, compiled) in TypoCorrection.enabledCompiledSchemas(build: build) {
            guard let target = Prediction.eligibility(compiled: compiled, schemaID: id).target else { continue }
            targets.append(target)
            current[id] = Prediction.compiledEnabled(compiled: compiled)
            if Prediction.userOwnsSetting(
                customYAML: customFiles[id + ".custom.yaml"], packageReference: packageReference)
            {
                managed.insert(id)
            }
        }
        return Prediction.changes(desired: desired, targets: targets, current: current, userManaged: managed)
    }

    /// Live proof on the deployed engine (the unified validator already proved every declared
    /// component is registered): each changed input method runs exactly the managed wiring
    /// and the database it names is a structurally valid predict db.
    static func verify(
        engine: RimeEngine, enabledSchemaIDs: [String], changes: [Prediction.Target],
        desired: Bool, build: URL, resources: URL
    ) throws {
        if desired, !changes.isEmpty {
            try Prediction.validateDatabase(at: resources.appendingPathComponent(Prediction.databasePath))
        }
        for target in changes {
            guard enabledSchemaIDs.contains(target.schemaID) else {
                throw RecipeInstallError.deployment("上屏联想设置失败，输入方式「\(target.schemaID)」尚未启用")
            }
            let components = engine.schemaComponents(target.schemaID)
            let wired = components.contains(Prediction.processor) && components.contains(Prediction.translator)
            let marker = engine.schemaValue(target.schemaID, key: Prediction.markerKey) == "true"
            let database = engine.schemaValue(target.schemaID, key: "predictor/db") == Prediction.databasePath
            guard desired ? (wired && marker && database) : (!wired && !marker) else {
                throw RecipeInstallError.deployment("上屏联想设置未生效，输入方式「\(target.schemaID)」当前配置不符")
            }
        }
        // Generated 14/9-key companions are regenerated from this build when the keyboard is
        // republished; CompactAdapterDeployment proves they carry the source's wiring.
    }
}
