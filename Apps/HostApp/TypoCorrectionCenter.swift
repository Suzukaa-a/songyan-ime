import Foundation
import KeyboardCore
import PackageManager
import RimeBridge
import SwiftUI

/// Typo correction (Settings > Input Options).
///
/// librime `script_translator`'s `<main producer namespace>/enable_correction` tolerates a single wrong key by physical neighbor on 26-key spelling
/// input methods. This center only orchestrates; decisions and patch generation live in
/// `PackageManager.TypoCorrection` (no hardcoded source/scheme names):
///   * On by default: the preference defaults to on; on home refresh, converges once for the source **in use** (one automatic attempt
///     per publish revision, no retry loop on failure);
///   * Goes through the normal install transaction: the generated patch is written to a standalone managed block in `<schema>.custom.yaml`, deployed, and committed only if the real
///     engine's per-item `schemaValue` read-back is `true` (not `true` when off), otherwise the whole attempt is abandoned;
///     the generated 14/9-key companion schemes must not read back `true`;
///   * Display trusts only the compiled config **published to the keyboard**: unreadable or unprovable shows unavailable (fail closed);
///   * When the user's own custom already writes this item, it is left to the user and not overridden.
@MainActor
final class TypoCorrectionCenter: ObservableObject {
    static let shared = TypoCorrectionCenter()
    static let preferenceKey = "app.songyan.settings.typoCorrection"
    private static let autoAttemptKey = "app.songyan.settings.typoCorrection.autoAttempt"

    /// The user's choice; absent means the default (on).
    static var preferred: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    enum State: Equatable, Sendable {
        case loading
        /// No published input source yet.
        case noSource
        /// Not provable for the input method the keyboard uses (fail closed).
        case unavailable(String)
        /// The user's own custom configuration sets this value.
        case userManaged(Bool)
        case on
        case off
    }

    /// What the keyboard currently uses, read from the published snapshot (off-main).
    struct PublishedContext: Sendable {
        /// `nil` when the source in use is not an installed package (custom pinyin).
        let packageID: String?
        let revision: String
        let keyboard: PublishedKeyboard?
        let schemaID: String
        let state: State
        /// Primary producer namespace when eligible; used for the user-managed check.
        let target: TypoCorrection.Target?
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var failure: String?
    private(set) var reconcileTask: Task<Void, Never>?

    // MARK: - Status

    func refresh() async {
        do {
            let context = try await Self.readPublished()
            guard let context else {
                state = .noSource
                return
            }
            guard let target = context.target else {
                state = context.state
                return
            }
            if let managed = await userManagedValue(context: context, target: target) {
                state = .userManaged(managed)
            } else {
                state = context.state
            }
        } catch {
            HostLog.append("typo correction status read failed: \(error.localizedDescription)")
            state = .unavailable("暂时无法读取当前输入方式的设置。")
        }
    }

    /// Reads the published compiled schema of the selected input method. Only a value the
    /// keyboard's own compiled configuration carries is reported as on.
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
                state: .unavailable("当前输入方案不支持错键纠正。"), target: nil)
        }
        guard let schemaID = activation.selectedSchemaID ?? activation.requiredSchemaIDs.first else { return nil }
        let keyboard = activation.selectedLayout.map { PublishedKeyboard(schemaID: schemaID, layout: $0) }
        let unavailable = State.unavailable("当前输入方式不支持错键纠正。")
        guard
            let compiled = try? Data(
                contentsOf: InstalledPackageLayout.compiledSchemaURL(build: snapshot.build, id: schemaID)),
            let target = TypoCorrection.eligibility(compiled: compiled, schemaID: schemaID).target
        else {
            return PublishedContext(
                packageID: packageID, revision: activation.revision, keyboard: keyboard,
                schemaID: schemaID, state: unavailable, target: nil)
        }
        let on = TypoCorrection.compiledValue(compiled: compiled, target: target) == true
        return PublishedContext(
            packageID: packageID, revision: activation.revision, keyboard: keyboard,
            schemaID: schemaID, state: on ? .on : .off, target: target)
    }

    /// Published snapshot read on the dedicated read queue (never on the main thread).
    private static func readPublished() async throws -> PublishedContext? {
        try await KeyboardResourceReadQueue.async {
            Self.context(from: try KeyboardRecipeStore.snapshot(selectedOnly: true))
        }
    }

    /// `non-nil` when the installation's user custom file sets the value itself.
    private func userManagedValue(context: PublishedContext, target: TypoCorrection.Target) async -> Bool? {
        guard let reference = context.packageID,
            let active = try? await SchemeImportCenter.shared.manager(reference).activeInstallation()
        else { return nil }
        let name = context.schemaID + ".custom.yaml"
        let urls = [active.userDataURL.appendingPathComponent(name), active.resourceURL.appendingPathComponent(name)]
        let owned =
            (try? await KeyboardResourceReadQueue.async { () -> Bool in
                urls.contains {
                    TypoCorrection.userOwnsSetting(customYAML: try? Data(contentsOf: $0), packageReference: reference)
                }
            }) ?? false
        guard owned else { return nil }
        return context.state == .on
    }

    // MARK: - Actions

    /// Explicit user toggle: remembers the choice, then applies it to the source in use.
    func setEnabled(_ enabled: Bool) {
        guard !working else { return }
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        Task { await apply(enabled, automatic: false) }
    }

    /// Default-on convergence for the source in use. Runs at most once per published
    /// revision (a failure is not retried in a loop) and never while another install or
    /// keyboard transaction is running.
    func scheduleReconcile(after previous: Task<Void, Never>? = nil) {
        guard reconcileTask == nil, Self.preferred else { return }
        reconcileTask = Task {
            defer { reconcileTask = nil }
            await previous?.value
            await refresh()
            guard state == .off,
                !SchemeImportCenter.shared.busy, !KeyboardSelectionCenter.shared.isBusy,
                let context = try? await Self.readPublished()
            else { return }
            let token = (context.packageID ?? "-") + ":" + context.revision
            guard UserDefaults.standard.string(forKey: Self.autoAttemptKey) != token else { return }
            UserDefaults.standard.set(token, forKey: Self.autoAttemptKey)
            await apply(true, automatic: true)
        }
    }

    private func apply(_ enabled: Bool, automatic: Bool) async {
        guard !working else { return }
        working = true
        failure = nil
        notice = nil
        defer { working = false }
        do {
            guard let context = try await Self.readPublished(),
                let packageID = context.packageID, context.target != nil
            else {
                throw RecipeInstallError.invalidResource("当前输入方式不支持错键纠正")
            }
            let imports = SchemeImportCenter.shared
            let outcome = try await imports.applyTypoCorrection(enabled: enabled, packageID: packageID)
            if outcome.changed {
                // Republish only when the keyboard already used the installed revision we
                // changed; a pending update the user has not chosen is never applied silently.
                if outcome.previousRevision == context.revision, let keyboard = context.keyboard {
                    _ = try await imports.performAddKeyboard(packageID: packageID, keyboard: keyboard)
                } else {
                    notice = "将在使用新版本后生效。"
                }
            }
            HostLog.append(
                "typo correction \(enabled ? "on" : "off") applied (automatic=\(automatic), changed=\(outcome.changed))"
            )
        } catch {
            HostLog.append("typo correction apply failed (automatic=\(automatic)): \(error.localizedDescription)")
            failure = enabled ? "未能开启，请重试。" : "未能关闭，请重试。"
        }
        await refresh()
    }
}

/// Result of one typo-correction installation transaction.
struct TypoCorrectionOutcome: Sendable {
    let changed: Bool
    /// Installed revision before this transaction.
    let previousRevision: String
}

extension SchemeImportCenter {
    /// One transactional update of the given source:
    /// eligible enabled input methods whose compiled value differs from `enabled` get a
    /// managed patch; the live engine must read the new value back before commit. Failure
    /// leaves the previous installation and publication untouched.
    func applyTypoCorrection(enabled: Bool, packageID: String) async throws -> TypoCorrectionOutcome {
        let result = try await applyManagedPatch(
            packageID: packageID, message: enabled ? "正在开启错键纠正…" : "正在关闭错键纠正…",
            plan: { context in
                let changes = TypoCorrectionPlanning.changes(
                    desired: enabled, build: context.build,
                    customFiles: context.snapshot.files, packageReference: packageID)
                guard !changes.isEmpty else { return nil }
                let recipe = try TypoCorrection.make(
                    enabling: enabled ? changes : [],
                    disabling: enabled ? [] : changes)
                return ManagedPatchPlan(recipe: recipe, change: changes)
            },
            verify: { engine, enabledIDs, deployment, changes in
                try TypoCorrectionPlanning.verify(
                    engine: engine, enabledSchemaIDs: enabledIDs,
                    changes: changes, desired: enabled,
                    build: deployment.userDataURL.appendingPathComponent("build"))
            })
        return TypoCorrectionOutcome(changed: result.installed != nil, previousRevision: result.previousRevision)
    }
}

/// File-level planning and live read-back, independent of any UI state.
enum TypoCorrectionPlanning {
    /// Enabled (`build/default.yaml` schema_list), eligible, not user-managed input methods
    /// whose compiled value differs from `desired`.
    static func changes(
        desired: Bool, build: URL, customFiles: [String: Data],
        packageReference: String
    ) -> [TypoCorrection.Target] {
        var targets: [TypoCorrection.Target] = []
        var current: [String: Bool] = [:]
        var managed = Set<String>()
        for (id, compiled) in TypoCorrection.enabledCompiledSchemas(build: build) {
            guard let target = TypoCorrection.eligibility(compiled: compiled, schemaID: id).target else { continue }
            targets.append(target)
            current[id] = TypoCorrection.compiledValue(compiled: compiled, target: target)
            if TypoCorrection.userOwnsSetting(
                customYAML: customFiles[id + ".custom.yaml"],
                packageReference: packageReference)
            {
                managed.insert(id)
            }
        }
        return TypoCorrection.changes(desired: desired, targets: targets, current: current, userManaged: managed)
    }

    /// Live proof on the deployed engine: every changed input method reads back the desired
    /// value, and no generated 14/9-key companion runs with correction on.
    static func verify(
        engine: RimeEngine, enabledSchemaIDs: [String], changes: [TypoCorrection.Target],
        desired: Bool, build: URL
    ) throws {
        for target in changes {
            guard enabledSchemaIDs.contains(target.schemaID) else {
                throw RecipeInstallError.deployment("错键纠正设置失败，输入方式「\(target.schemaID)」尚未启用")
            }
            let value = engine.schemaValue(target.schemaID, key: target.configKey)
            guard (value == "true") == desired else {
                throw RecipeInstallError.deployment("错键纠正设置未生效，输入方式「\(target.schemaID)」当前配置为 \(value ?? "nil")")
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []
        for name in names where name.hasSuffix(InstalledPackageLayout.schemaFileSuffix) {
            let id = String(name.dropLast(InstalledPackageLayout.schemaFileSuffix.count))
            guard CompactSchemaAdapter.isGeneratedCompanionID(id) else { continue }
            if engine.schemaValue(id, key: "translator/" + TypoCorrection.configLeaf) == "true" {
                throw RecipeInstallError.deployment("错键纠正不适用于紧凑键盘：\(id)")
            }
        }
    }
}
