import Foundation
import KeyboardCore
import PackageManager
import RimeBridge
import SwiftUI

/// Fuzzy pinyin (Settings > Input Options > 模糊音).
///
/// Inserts the chosen confusion pairs at the start of the schema's own `speller/algebra` via Rime's native
/// `fuzz` calculus, as one managed block in `<schema>.custom.yaml`. Decisions and patch
/// generation live in `PackageManager.FuzzyPinyin`; this center only orchestrates.
///   * Off by default; the preference is remembered per source + input method.
///   * A save is one install transaction, committed only after the deployed engine proves the
///     patch (fail closed).
///   * Display trusts only the configuration published to the keyboard.
@MainActor
final class FuzzyPinyinCenter: ObservableObject {
    static let shared = FuzzyPinyinCenter()
    static let preferencePrefix = "app.songyan.settings.fuzzyPinyin."

    @Published private(set) var state: State = .loading
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var failure: String?
    /// The editable selection shown on the settings page; applied only on an explicit save.
    @Published var draft: Set<String> = []

    /// The user's saved choice for one input method of one source; absent means off.
    static func preferred(packageID: String?, schemaID: String) -> Set<String> {
        guard let ids = UserDefaults.standard.string(forKey: key(packageID: packageID, schemaID: schemaID)) else {
            return []
        }
        return Set(ids.split(separator: ",").compactMap { FuzzyPinyin.pair(id: String($0))?.id })
    }

    static func setPreferred(_ ids: Set<String>, packageID: String?, schemaID: String) {
        let value = FuzzyPinyin.allPairs.filter { ids.contains($0.id) }.map(\.id).joined(separator: ",")
        UserDefaults.standard.set(value, forKey: key(packageID: packageID, schemaID: schemaID))
    }

    private static func key(packageID: String?, schemaID: String) -> String {
        preferencePrefix + (packageID ?? "-") + "." + schemaID
    }

    enum State: Equatable, Sendable {
        case loading
        /// No published input source yet.
        case noSource
        /// Not provable for the input method the keyboard uses (fail closed).
        case unavailable(String)
        /// The user's own (or another feature's) configuration manages the algebra.
        case userManaged
        /// Our managed block exists; the set is what it appends.
        case managed(Set<String>)
        /// Our managed block does not exist; fuzzy pinyin is off for this input method.
        case off

        var isManaged: Bool {
            if case .managed = self { return true }
            return false
        }
    }

    /// What the keyboard currently uses, read from the published snapshot (off-main).
    struct PublishedContext: Equatable, Sendable {
        /// `nil` when the source in use is not an installed package (custom pinyin).
        let packageID: String?
        let revision: String
        let keyboard: PublishedKeyboard?
        let schemaID: String
        let state: State
        let target: FuzzyPinyin.Target?
        /// The publication the page saw; the republish compares against it.
        let viewedActivation: KeyboardRecipeStore.Activation?
        let viewedSourceKey: String?
        /// The whole keyboard list of this source; the republish passes it unchanged so the
        /// user's other keyboards survive.
        let viewedRoster: [PublishedKeyboard]
        var resourcesURL: URL? = nil
        var buildURL: URL? = nil
    }

    private(set) var applyTask: Task<Void, Never>?
    /// The context the settings page last displayed; save applies to exactly this input
    /// method, even if the selected input method changes while the transaction runs.
    private(set) var displayed: PublishedContext?
    /// Bumped by every read; a stale read can never overwrite a newer status or failure.
    private var refreshToken = UUID()
    /// The target a retained failure belongs to: a failed save keeps its draft only while the
    /// page still shows that same source, input method and generation.
    private var failureAnchor: PublishedContext?
    private var supportContext: PublishedContext?
    private var supportAllowed = false
    /// A save whose install committed but whose republish failed: the generation it installed,
    /// keyed by what the page displayed, so a retry from that same page can finish the job.
    private var unpublishedSave: (displayed: PublishedContext, generation: String)?

    // MARK: - Status

    func refresh() async {
        guard !working else { return }
        let token = UUID()
        refreshToken = token
        state = .loading
        let context: PublishedContext?
        var supported = true
        do {
            context = try await Self.readPublished()
            if let context, context.target != nil, context.state == .off || context.state.isManaged {
                if supportContext != context {
                    supportAllowed = try await Self.nativeSupport(for: context)
                    supportContext = context
                }
                supported = supportAllowed
            }
        } catch {
            guard refreshToken == token else { return }
            HostLog.append("fuzzy pinyin status read failed: \(error.localizedDescription)")
            state = .unavailable("暂时无法读取当前输入方式的设置。")
            return
        }
        // Latest wins: a newer refresh or a save invalidates this read as a whole.
        guard refreshToken == token, !working else { return }
        guard let context else {
            state = .noSource
            displayed = nil
            draft = []
            failure = nil
            notice = nil
            failureAnchor = nil
            return
        }
        guard context.target != nil else {
            state = context.state
            displayed = nil
            draft = []
            failure = nil
            notice = nil
            failureAnchor = nil
            return
        }
        guard supported else {
            state = .unavailable("这个输入方式暂不支持模糊音，请选择其他输入方式。")
            displayed = nil
            draft = []
            failure = nil
            notice = nil
            failureAnchor = nil
            return
        }
        // A failure and its draft survive a refresh only while the page shows the same target.
        let sameTarget = failure != nil && failureAnchor == context
        if displayed != context {
            failure = nil
            notice = nil
            failureAnchor = nil
        }
        state = context.state
        switch context.state {
        case .managed(let ids):
            if !sameTarget, failure == nil { draft = ids }
        case .off:
            if !sameTarget, failure == nil {
                draft = Self.preferred(packageID: context.packageID, schemaID: context.schemaID)
            }
        default: break
        }
        displayed = context
    }

    /// Reads the published compiled schema of the selected input method. Only a value the
    /// keyboard's own compiled configuration carries is reported as applied.
    nonisolated static func context(
        from snapshot: KeyboardRecipeStore.Snapshot?,
        applicationSupport: URL
    ) throws -> PublishedContext? {
        guard let snapshot else { return nil }
        let activation = snapshot.activation
        let roster = activation.keyboards
        func make(
            _ keyboard: PublishedKeyboard?, _ schemaID: String, _ state: State,
            _ target: FuzzyPinyin.Target?, packageID: String?
        ) -> PublishedContext {
            PublishedContext(
                packageID: packageID, revision: activation.revision, keyboard: keyboard,
                schemaID: schemaID, state: state, target: target,
                viewedActivation: activation,
                viewedSourceKey: packageID.flatMap { SchemeImportCenter.rosterKey(packageID: $0) },
                viewedRoster: roster, resourcesURL: snapshot.resources, buildURL: snapshot.build)
        }
        let packageID: String
        switch activation.kind {
        case .userScheme:
            guard let id = activation.packageID else { return nil }
            packageID = id
        case .userDictionary:
            return make(nil, "", .unavailable("当前输入方案不支持模糊音。"), nil, packageID: nil)
        }
        guard let schemaID = activation.selectedSchemaID ?? activation.requiredSchemaIDs.first else { return nil }
        let keyboard = activation.selectedLayout.map { PublishedKeyboard(schemaID: schemaID, layout: $0) }
        let unavailable = State.unavailable("当前输入方式不支持模糊音。")
        guard let compiled = try? Data(contentsOf: snapshot.build.appendingPathComponent(schemaID + ".schema.yaml")),
            let target = FuzzyPinyin.eligibility(compiled: compiled, schemaID: schemaID).target
        else {
            return make(keyboard, schemaID, unavailable, nil, packageID: packageID)
        }
        // The custom file lives in the installer's user directory of the published generation;
        // without that exact directory our block would be invisible, so the state is unavailable.
        let reference: String
        let custom: Data?
        do {
            let userDirectory = try RimePaths.hostTrialUserDirectory(activation, applicationSupport: applicationSupport)
            let parent = userDirectory.deletingLastPathComponent().lastPathComponent
            guard parent != "PublishedTrials", parent == activation.hostInstallationGeneration else {
                return make(keyboard, schemaID, unavailable, nil, packageID: packageID)
            }
            struct SourceReference: Decodable { let id: String }
            guard
                let source = try Self.optionalCustomData(
                    at: userDirectory.deletingLastPathComponent()
                        .appendingPathComponent("source.json"))
            else {
                return make(keyboard, schemaID, unavailable, nil, packageID: packageID)
            }
            let identity = try JSONDecoder().decode(SourceReference.self, from: source)
            guard !identity.id.isEmpty else {
                return make(keyboard, schemaID, unavailable, nil, packageID: packageID)
            }
            reference = packageID
            let fromUser = try Self.optionalCustomData(
                at: userDirectory.appendingPathComponent(schemaID + ".custom.yaml"))
            let fromResources = try Self.optionalCustomData(
                at: snapshot.resources.appendingPathComponent(schemaID + ".custom.yaml"))
            // The user copy overrides the shared one, matching Rime's own merge order.
            custom = fromUser ?? fromResources
        } catch {
            return make(keyboard, schemaID, unavailable, nil, packageID: packageID)
        }
        if FuzzyPinyin.userOwnsSetting(customYAML: custom, packageReference: reference) {
            return make(keyboard, schemaID, .userManaged, target, packageID: packageID)
        }
        guard let appended = FuzzyPinyin.managedAlgebra(customYAML: custom, packageReference: reference) else {
            // The scheme's author already ships fuzzy rules, which ours could never turn off.
            let baseline = FuzzyPinyin.compiledAlgebra(compiled: compiled, schemaID: schemaID) ?? []
            if baseline.contains(where: isFuzzyRule) {
                return make(keyboard, schemaID, .userManaged, target, packageID: packageID)
            }
            return make(keyboard, schemaID, .off, target, packageID: packageID)
        }
        // An appended list we cannot recognize means the block was edited outside the app.
        guard let ids = FuzzyPinyin.pairIDs(rules: appended) else {
            return make(keyboard, schemaID, .unavailable("模糊音设置无法识别，可能是被其他工具修改过。"), target, packageID: packageID)
        }
        return make(keyboard, schemaID, .managed(ids), target, packageID: packageID)
    }

    /// Missing customization is valid; unreadable or oversized customization proves no state.
    nonisolated private static func optionalCustomData(at url: URL) throws -> Data? {
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= RecipeResourceBudget.sourceFile else {
                throw RecipeInstallError.invalidResource("设置文件过大，请重新导入输入方案。")
            }
            return data
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
    }

    /// Either spelling of a native fuzzy derivation: the standalone `fuzz` calculus or the
    /// tagged `derive ... fuzz` form (librime treats both as `Fuzzing`).
    private nonisolated static func isFuzzyRule(_ rule: String) -> Bool {
        rule.hasPrefix("fuzz/") || (rule.hasPrefix("derive/") && rule.hasSuffix("/fuzz/"))
    }

    /// Inspect prebuilt Rime data in an isolated learning directory before offering edits.
    private static func nativeSupport(for context: PublishedContext) async throws -> Bool {
        guard let resources = context.resourcesURL, let build = context.buildURL else {
            throw RecipeInstallError.invalidResource("无法读取输入方式，请在「我的键盘」中重新选择。")
        }
        return try await EngineOwnershipCoordinator.shared.withExclusive {
            try await EngineOpQueue.async {
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FuzzySupport-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporary) }
                let engine = RimeEngine(
                    configuration: .init(
                        sharedDirectory: resources,
                        userDirectory: temporary, prebuiltDirectory: build))
                defer { engine.shutdown() }
                try engine.start()
                try engine.validateSchemaForActivation(schemaID: context.schemaID)
                guard
                    let projection = engine.sourceProjectionMap()
                        .flatMap(CompactSchemaAdapter.SourceProjection.decode(json:))
                else {
                    throw RecipeInstallError.deployment("暂时无法检查输入方式，请稍后重试。")
                }
                return FuzzyPinyinPlanning.supportsFullPinyin(projection)
            }
        }
    }

    /// Published snapshot read on the dedicated read queue (never on the main thread).
    private static func readPublished() async throws -> PublishedContext? {
        let applicationSupport = HostStorePaths.applicationSupport
        return try await KeyboardResourceReadQueue.async {
            let snapshot = try KeyboardRecipeStore.snapshot(selectedOnly: true)
            guard let snapshot else { return nil }
            return try context(from: snapshot, applicationSupport: applicationSupport)
        }
    }

    // MARK: - Actions

    /// Explicit save: applies the whole draft to exactly the input method the page displayed.
    /// The choice is remembered only after the transaction succeeds, so a failure keeps both
    /// the draft and the previous saved state for another try.
    func save() {
        switch state {
        case .off, .managed: break
        default: return
        }
        guard !working, applyTask == nil, let context = displayed else { return }
        refreshToken = UUID()
        working = true
        failure = nil
        notice = nil
        failureAnchor = nil
        let ids = FuzzyPinyin.allPairs.filter { draft.contains($0.id) }.map(\.id)
        let schemaID = context.schemaID
        applyTask = Task {
            defer { applyTask = nil }
            await apply(Set(ids), schemaID: schemaID, displayed: context)
        }
    }

    private func apply(_ enabledPairIDs: Set<String>, schemaID: String, displayed: PublishedContext) async {
        defer { working = false }
        do {
            guard let packageID = displayed.packageID else {
                throw RecipeInstallError.invalidResource("当前输入方案不支持模糊音")
            }
            let imports = SchemeImportCenter.shared
            let pending = unpublishedSave.flatMap { $0.displayed == displayed ? $0.generation : nil }
            let outcome = try await imports.applyFuzzyPinyin(
                schemaID: schemaID, enabledPairIDs: enabledPairIDs,
                packageID: packageID,
                viewedGeneration: displayed.viewedActivation?.hostInstallationGeneration,
                savedGeneration: pending)
            unpublishedSave = nil
            // The preference records what actually took effect, per source + input method.
            Self.setPreferred(enabledPairIDs, packageID: packageID, schemaID: schemaID)
            if outcome.changed {
                await imports.refresh()
                // Republish only when the keyboard already used the revision we changed; a pending
                // update the user has not chosen is never applied silently.
                if outcome.previousRevision == displayed.revision, let keyboard = displayed.keyboard,
                    displayed.viewedRoster.contains(keyboard)
                {
                    do {
                        _ = try await imports.performReplaceKeyboards(
                            packageID: packageID,
                            requested: displayed.viewedRoster, viewedActivation: displayed.viewedActivation,
                            viewedRoster: displayed.viewedRoster,
                            viewedSourceKey: displayed.viewedSourceKey)
                    } catch {
                        // The install is committed; only the keyboard is behind. Remember it so
                        // saving again from this page republishes instead of being refused.
                        unpublishedSave = (displayed, outcome.generation)
                        HostLog.append("fuzzy pinyin republish failed: \(error.localizedDescription)")
                        failure = "模糊音已保存，但键盘还没用上新设置，请再保存一次。"
                        failureAnchor = displayed
                        working = false
                        await refresh()
                        return
                    }
                } else {
                    notice = "将在使用新版本后生效。"
                }
            }
            HostLog.append(
                "fuzzy pinyin applied (schema=\(schemaID), pairs=\(enabledPairIDs.sorted().joined(separator: ",")), changed=\(outcome.changed))"
            )
        } catch {
            HostLog.append("fuzzy pinyin apply failed: \(error.localizedDescription)")
            failure = (error as? UserKeyboardPublicationError)?.localizedDescription ?? "未能保存，请重试。"
            failureAnchor = displayed
        }
        working = false
        await refresh()
    }
}

/// Result of one fuzzy-pinyin installation transaction.
struct FuzzyPinyinOutcome: Sendable {
    /// The installation differs from what the keyboard showed, so the keyboard needs the
    /// new version (a fresh install, or one an earlier save left unpublished).
    let changed: Bool
    /// Installed revision before this transaction.
    let previousRevision: String
    /// The installed generation after this transaction.
    let generation: String
}

extension SchemeImportCenter {
    /// One transactional update of the given source:
    /// eligible enabled input methods whose managed block differs from the requested pairs
    /// get one append patch; the live engine must prove the native projection before commit.
    /// Failure leaves the previous installation and publication untouched.
    func applyFuzzyPinyin(
        schemaID: String, enabledPairIDs: Set<String>, packageID: String,
        viewedGeneration: String?, savedGeneration: String? = nil
    ) async throws -> FuzzyPinyinOutcome {
        guard !busy, !KeyboardSelectionCenter.shared.isBusy else { throw UserKeyboardPublicationError.busy }
        busy = true
        message = enabledPairIDs.isEmpty ? "正在关闭模糊音…" : "正在保存模糊音…"
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
            // `savedGeneration` is the version an earlier save of this page installed but the
            // keyboard never picked up; retrying from it only has to finish the republish.
            let installedGeneration = active.installation.generation
            guard
                installedGeneration == viewedGeneration
                    || (savedGeneration != nil && installedGeneration == savedGeneration)
            else {
                throw UserKeyboardPublicationError.unavailable(
                    "输入方案已有新版本，请先在「我的键盘」中选择要使用的版本。")
            }
            let unpublished = installedGeneration != viewedGeneration
            let reference = packageID
            let snapshot = try await Self.readWorkspaceSnapshot(
                resources: active.resourceURL,
                userConfiguration: active.userDataURL)
            let sources = try await Self.readInstalledSources(resources: active.resourceURL)
            let build = active.userDataURL.appendingPathComponent("build")
            let task = Task.detached(priority: .userInitiated) {
                () throws -> (DeclarativeRecipePlan, FuzzyPinyin.Target)? in
                let planned: FuzzyPinyin.Planned
                switch FuzzyPinyin.plan(
                    schemaID: schemaID, enabledPairIDs: enabledPairIDs,
                    build: build, customFiles: snapshot.files, packageReference: reference)
                {
                case .noChange: return nil
                case .refused(let reason): throw UserKeyboardPublicationError.unavailable(reason)
                case .planned(let value): planned = value
                }
                // The recipe's targets must be exactly the pair map's keys: the changed one
                // plus every input method whose saved pairs ride along.
                let recipe = try FuzzyPinyin.make(
                    enabledPairIDsBySchema: planned.pairIDsBySchema,
                    targets: planned.targets)
                // A previous run archived a different body at the same path; the new recipe
                // replaces it (same as typo correction bindings).
                var files = sources.files
                files[recipe.path] = recipe.source
                let plan = try DeclarativeRecipePlan(
                    recipe: recipe, packageReference: reference,
                    selectedRecipe: recipe.declaredName ?? "", arguments: [], packageFiles: files,
                    existingFiles: snapshot.files, sourceRevision: active.installation.revision,
                    expectedGeneration: active.installation.generation,
                    packageFileResources: sources.fileResources,
                    existingFileResources: snapshot.fileResources,
                    userCustomBaseline: snapshot.userCustomFiles, sharedOpenCCDirectory: openCC)
                return (plan, planned.changed)
            }
            let planned = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() })
            guard let planned else {
                return FuzzyPinyinOutcome(
                    changed: unpublished, previousRevision: active.installation.revision,
                    generation: installedGeneration)
            }
            let (plan, changedTarget) = planned
            let installed = try await store.installRecipePlan(
                plan, packageID: reference, schemaID: active.installation.schemaID,
                deploy: { deployment in
                    let verification = try await Self.verifyRecipeDeployment(
                        deployment,
                        packageID: reference, packageName: packageName,
                        postValidation: { _, enabledIDs in
                            try FuzzyPinyinPlanning.verify(enabledSchemaIDs: enabledIDs, target: changedTarget)
                        })
                    return verification.receipt
                })
            return FuzzyPinyinOutcome(
                changed: true, previousRevision: active.installation.revision,
                generation: installed.generation)
        }
    }
}

/// Native support check and the post-deployment gate, independent of any UI state.
enum FuzzyPinyinPlanning {
    /// The dictionary's own syllables must be full pinyin. Rules sit before the schema's
    /// algebra, so 双拼 schemas over a full-pinyin dictionary qualify too.
    static func supportsFullPinyin(_ projection: CompactSchemaAdapter.SourceProjection) -> Bool {
        CompactSchemaAdapter.isCanonicalPinyinDomainAllowingBenignExtras(projection.syllables.map(\.token))
    }

    /// The written patch is trusted; the engine only has to confirm the input method is enabled.
    static func verify(enabledSchemaIDs: [String], target: FuzzyPinyin.Target) throws {
        guard enabledSchemaIDs.contains(target.schemaID) else {
            throw RecipeInstallError.deployment("这个输入方式（\(target.schemaID)）还没有启用，模糊音没有保存。")
        }
    }
}
