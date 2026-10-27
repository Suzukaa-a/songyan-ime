import Combine
import Foundation
import KeyboardCore
import OSLog

/// Interactive keyboard session: starts the real Rime engine in the background, then builds a `KeyboardController`.
///
/// The host app's typing area and the keyboard extension both go through this facade, so there is a
/// single real-engine path. The demo engine (`KeyboardCore.EngineProvider.makeDemoEngine`) is only for
/// unit tests and explicit self-checks; production never falls back to it.
///
/// Resource configuration (dynamic Rime schema resources):
///  - `init(layout:userDirectoryOverride:)` has no explicit resource set and runs the built-in scheme
///    straight from the bundle (the keyboard's fallback when nothing is published).
///  - `init(resourceSet:layout:)` names a resource set (e.g. the resources/user directories of an
///    installed scheme's active generation) and its layout-to-schema mapping. Layout pickers should only
///    list `availableLayouts`; built-in schemes are never forced onto layouts a set does not map.
///  - A resource set may carry `prebuiltDirectory` (read-only compiled resources published to the App
///    Group): startup skips deployment and learning still writes to each user directory. Missing or
///    mismatched resources fail startup explicitly instead of falling back to a full deploy.
///
/// Lifecycle:
///  - `start()` is idempotent; the process-wide `EngineOwnershipCoordinator` owns the full lifecycle.
///  - Configuration switches, navigation and background-validation handoffs wait for in-flight boot and
///    shutdown; `EngineOpQueue` runs the background operations and `bootGeneration` rejects stale results.
///  - Switching or shutting down never touches text already committed to the host (callbacks such as
///    `onCommit` are kept and picked up by the new controller) and never deletes any resource set's
///    user directory.
///  - The first start may deploy (compile dictionaries); the UI shows loading and a retryable failure.
///  - Failures are reported through `phase` (never swallowed, never a demo-engine fallback); `retry()`
///    retries the current configuration.
@MainActor
public final class KeyboardPadSession: ObservableObject {
    private static let diagnosticLogger = Logger.keyboardPadSession
    public enum Phase: Equatable {
        case starting
        case ready
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .starting
    @Published public private(set) var controller: KeyboardController?
    /// Nonfatal transition failure: keep the ready keyboard and composition visible.
    @Published public private(set) var transitionError: String?
    private var inputRecoveryObservation: AnyCancellable?

    public func dismissTransitionError() {
        guard controller?.inputUnavailableReason == nil else { return }
        transitionError = nil
        controller?.dismissRecoverableError()
    }
    @Published public private(set) var availableSchemas: [KeyboardSchemaDescriptor] = []
    @Published public private(set) var selectedSchemaID: String = ""
    @Published public private(set) var successfulChange: KeyboardSelectionChange?
    public var onMarkedComposition: ((MarkedComposition?) -> Void)?
    /// Not `@Published`: it flips awaitingHost ↔ inline on every key and nothing in the
    /// UI renders it; the visible part is `keyboardCompositionFallback` below.
    public private(set) var compositionPresentation: CompositionPresentation = .idle
    @Published public private(set) var keyboardCompositionFallback: MarkedComposition?
    /// Only a text-output adapter may report observed inline presentation. UI consumes this state.
    public func reportCompositionPresentation(_ value: CompositionPresentation) {
        if compositionPresentation != value { compositionPresentation = value }
        controller?.reportCompositionPresentation(value)
        // Reported on every keystroke; an unconditional write republished the
        // session and re-rendered the whole extension root and host each time.
        let fallback = controller?.keyboardCompositionFallback
        if keyboardCompositionFallback != fallback { keyboardCompositionFallback = fallback }
    }
    /// Call after an in-keyboard preference change; does not process an engine key or commit.
    public func refreshCompositionPresentation() {
        guard let controller, controller.snapshot.isComposing else {
            reportCompositionPresentation(.idle)
            onMarkedComposition?(nil)
            return
        }
        reportCompositionPresentation(onMarkedComposition == nil ? .keyboard(reason: "输入框暂不可用") : .awaitingHost)
        onMarkedComposition?(controller.markedComposition)
    }
    public var onSelectionChanged: ((KeyboardSelectionChange) -> Void)?
    /// Asked when a ready engine switches layout. False keeps the remembered layout on the
    /// keyboard the next start shows: a switch that cannot be saved lasts one presentation,
    /// and that presentation's height is budgeted from the remembered layout.
    public var remembersLayoutSwitch: (() -> Bool)?
    /// Host identity is memory-only. Tools refuse delivery if confirmation changes the target.
    public var hostContextIdentifier: (() -> String?)?
    /// Captured only for explicit asynchronous insertions; nil means no live target.
    public var asyncInsertionContext: (() -> AnyHashable?)?
    public lazy var quickInsert: QuickInsertState = {
        let defaults = KeyboardRecipeStore.sharedDefaults() ?? .standard
        let state = QuickInsertState(
            formatStore: QuickInsertFormatStore(
                defaults: defaults, persists: { KeyboardRecipeStore.canWriteSharedContainer }))
        state.core.confirmComposition = { [weak self] in
            guard let self, self.onDispatchCommit != nil || self.onCommit != nil,
                let controller = self.controller,
                let context = self.hostContextIdentifier?(), controller.commitComposition()
            else { return false }
            return self.hostContextIdentifier?() == context
        }
        state.core.dispatchInsert = { [weak self] text in self?.dispatchCommitToHost(text) ?? false }
        return state
    }()

    public func resetHostContext() {
        quickInsert.resetContext()
        controller?.resetEnglishWord()
        controller?.resetPunctuationCycle()
    }
    public func selectSchema(_ id: String) { controller?.selectSchema(id) }

    // MARK: - User keyboard list (the publication record is the single source of truth; read by the long-press switcher)

    /// Published keyboard list; the long-press "ABC/Chinese" switcher only lists entries **runnable with the current resources**.
    @Published public private(set) var publishedKeyboards: [UserKeyboard] = []
    /// Why the list read failed (nil = fine). A failed read keeps the old list and surfaces the error.
    @Published public private(set) var publishedKeyboardError: String?
    /// Source of the list; reads the shared publication record by default (same data for host and extension).
    /// Tests and previews can inject a fixed implementation.
    public var publishedKeyboardProvider: PublishedKeyboardListProviding =
        ActivationPublishedKeyboardProvider()

    /// Latest-wins: when reads overlap, only the most recently started one lands; a late older read is
    /// dropped (start order and completion order are not guaranteed to match).
    private var publishedKeyboardsGate = LatestWinsReadGate()

    /// Reads the published keyboard list (on the read queue, never blocking the main thread) and injects it into the controller.
    /// Triggered by the real lifecycle: boot ready and the extension's `viewWillAppear`.
    public func refreshPublishedKeyboards() async {
        let token = publishedKeyboardsGate.begin()
        // Nothing is published: the bundled fallback offers its first input method on every
        // layout, so the switcher can still change layout.
        if enablesOfflineBundledInput && resourceSet == nil {
            applyPublishedKeyboards(UserKeyboardRoster.builtinFallback, error: nil)
            return
        }
        do {
            let keyboards = try await publishedKeyboardProvider.publishedKeyboards()
            guard publishedKeyboardsGate.accepts(token) else { return }
            applyPublishedKeyboards(keyboards, error: nil)
        } catch {
            guard publishedKeyboardsGate.accepts(token) else { return }
            // A failed read is not "no keyboards": keep the old list and surface the error.
            Self.diagnosticLogger.error(
                "published keyboard read failed: \(error.localizedDescription, privacy: .private)")
            applyPublishedKeyboards(publishedKeyboards, error: "无法读取我的键盘，请稍后重试。")
        }
    }

    private func applyPublishedKeyboards(_ keyboards: [UserKeyboard], error: String?) {
        if publishedKeyboards != keyboards { publishedKeyboards = keyboards }
        if publishedKeyboardError != error { publishedKeyboardError = error }
        controller?.updatePublishedKeyboards(keyboards, error: error)
    }
    /// Explicit joint selection (layout + bound schema). When ready, hands it to the controller for a real
    /// switch, with the success callback updating the target; otherwise records the full target and
    /// restarts, invalidating any in-flight boot so the new target wins.
    public func selectLayout(_ layout: KeyboardLayoutKind, boundSchemaID: String) {
        if phase == .ready, let controller {
            controller.selectLayout(layout, boundSchemaID: boundSchemaID)
            return
        }
        recordUnreadySelection(schemaID: boundSchemaID, layout: layout)
    }
    /// Currently selected Chinese layout (kept in sync with the panel's layout key and the host Picker, then persisted).
    @Published public private(set) var layout: KeyboardLayoutKind
    /// Physical layout options; each resource lists all layouts, and encoding limits are explained by the selection failure reason.
    @Published public private(set) var availableLayouts: [KeyboardLayoutKind]
    public private(set) var backend: RimeBackend?
    /// nil for the host app's plain session; the extension binds visibility explicitly, kept across controllers and boots.
    private var hostIsVisible: Bool?

    @discardableResult
    public func setHostVisibility(_ visible: Bool) -> Bool {
        hostIsVisible = visible
        guard !visible else { return false }
        return backend?.suspendSessionForHostDisappearance() ?? false
    }

    /// Includes the window waiting for engine ownership / resource resolution; the initial `.starting` is not an in-flight boot.
    public var hasPendingBoot: Bool { startTapped && phase == .starting }
    /// Current resource set (nil = not specified; Release without one is unconfigured, with no bundled fallback).
    public private(set) var resourceSet: KeyboardResourceSet?

    /// Commit-text callback (host text field insert / text document proxy).
    public var onCommit: ((String) -> Void)?
    /// False rejects the current operation, including any dependent document edit.
    public var onDispatchCommit: ((String) -> Bool)?

    @discardableResult
    public func insertExternalLiteral(_ text: String) -> Bool {
        guard phase == .ready, let controller else { return false }
        return quickInsert.withoutRecordingCommits { controller.insertExternalLiteral(text) }
    }

    @discardableResult
    private func dispatchCommitToHost(_ text: String) -> Bool {
        guard hostContextIdentifier?() != nil else { return false }
        if let onDispatchCommit { return onDispatchCommit(text) }
        guard let onCommit else { return false }
        onCommit(text)
        return true
    }
    /// Backspace-on-empty-composition callback (the host deletes an already committed character).
    public var onDeleteBackward: (() -> Void)?
    public var onReadDocumentContext: (() -> String?)?
    public var onReplaceLiteralSuffix: ((String, String, String) -> Bool)?
    /// Re-reads host text-input traits (`hasText` etc.) immediately; see `KeyboardController.onRequestHostTraitsRefresh`.
    public var onRefreshHostTraits: (() -> Void)?
    /// Switch-keyboard callback (extension: advanceToNextInputMode; host app: shows a hint).
    public var onSwitchKeyboard: (() -> Void)?
    /// Relative cursor-move callback (argument = character offset), from `controller.moveCursor(by:)`.
    /// The extension host should wire `textDocumentProxy.adjustTextPosition(byCharacterOffset:)`;
    /// the host typing area implements it only if it can move the selection exactly, otherwise leaves it nil (never fakes a move).
    public var onMoveCursor: ((Int) -> Void)?

    /// Extension-only: with nothing published, the switcher lists the bundled fallback's keyboards.
    public var enablesOfflineBundledInput = false
    /// Explicit user directory (the bundled package uses a private one; default `RimePaths.interactiveUserDirectory`).
    public var userDirectoryOverride: URL?
    /// Set before start. Host and extension should inject the same App Group URL.
    /// Without injection preferences are local to this resource's user directory.
    public var optionPreferencesDirectory: URL?
    /// Resolve mutable installation generations only after acquiring engine ownership.
    /// A queued installer may have committed while this screen was waiting to boot.
    public var resourceResolver: (() async throws -> KeyboardResourceSet?)?
    /// Only the installed keyboard extension enables this. Host previews/self-tests must never
    /// produce evidence that can be mistaken for a real system-keyboard session.
    public var recordsRuntimeGrammarReceipts = false
    private let runtimeReceiptSessionID = UUID().uuidString

    /// Target selection of the current session: the source schema + physical layout last applied
    /// successfully, bound to the source snapshot it belongs to. A restart keeps it only if the
    /// resolved source snapshot equals it (same source, same generation); on a new generation it boots
    /// from the new source's published selection. `resources == nil` means a not-yet-resolved pending request.
    private struct SelectionTarget {
        var resources: KeyboardResourceSet?
        var schemaID: String?
        var layout: KeyboardLayoutKind
    }
    private var selectionTarget: SelectionTarget?
    /// The running real engine (production = RimeBackend). `backend` is kept only as the RimeBackend API facade.
    private var runningEngine: EngineBackend?

    private var startTapped = false
    private let ownershipID = UUID()
    /// What is running (publication-level identity), what is booting, and the boot generation. While
    /// `running` equals the target identity, never tear down or reboot and never drop back to `.starting`.
    private var routeState = KeyboardRouteState()
    private var runningResources: KeyboardResourceSet?
    /// Composition resume must keep the original physical layout and source schema paired.
    private var suspendedComposition:
        (
            resources: KeyboardResourceSet, sourceSchemaID: String,
            layout: KeyboardLayoutKind, input: String
        )?
    private var lastReadySelection: (schemaID: String, layout: KeyboardLayoutKind)?
    /// Test injection: nil = real RimeBackend in production; tests may return a DemoEngine.
    var bootEngineFactory: ((KeyboardResourceSet) throws -> EngineBackend)?
    /// Test injection: pausable gate after the engine is ready and before ready is published (covers the background-start await window).
    var bootGate: (() async -> Void)?

    // MARK: - Construction

    /// Without an explicit resource set the extension can still start the bundled basic input; the host typing area does not by default.
    public init(layout: KeyboardLayoutKind, userDirectoryOverride: URL? = nil) {
        self.layout = layout
        self.userDirectoryOverride = userDirectoryOverride
        self.resourceSet = nil
        self.availableLayouts = KeyboardLayoutKind.allCases
    }

    /// Session for an explicit resource set (e.g. an installed scheme's active generation). `layout`
    /// defaults to the set's first available layout; a layout outside the set is ignored (first
    /// available is used) rather than forcing a mapping.
    public init(resourceSet: KeyboardResourceSet, layout: KeyboardLayoutKind? = nil) {
        let fallback = resourceSet.preferredLayout ?? resourceSet.availableLayouts.first ?? .qwerty26
        self.layout = layout.flatMap { resourceSet.supports($0) ? $0 : nil } ?? fallback
        self.userDirectoryOverride = nil
        self.resourceSet = resourceSet
        self.availableLayouts = resourceSet.availableLayouts
    }

    // MARK: - Start / retry

    /// Idempotent start. Call `retry()` after a failure.
    public func start() {
        guard !startTapped else { return }
        startTapped = true
        routeState.beginBoot()
        noteRequestedBootRoute()
        requestOwnership()
    }

    /// Registers the target before queuing for engine ownership; otherwise repeated appears keep
    /// invalidating the same request while `boot()` has not run yet. `boot()` still re-verifies the resolver's result.
    private func noteRequestedBootRoute() {
        guard let resourceSet, let plan = bootPlan(on: resourceSet) else { return }
        routeState.notePending(plan.routeKey)
    }

    /// Retries the current resource configuration (explicit resource set; Release without one is unconfigured).
    public func retry() {
        restart(resourceSet: resourceSet, layout: layout)
    }

    // MARK: - Engine route (reuse criterion)

    /// Publication-level route identity of the running engine; nil = no ready engine to reuse.
    /// The upper layer uses it to decide whether a same-process return can reuse it directly.
    public var runningRouteKey: KeyboardRouteKey? {
        guard phase == .ready, controller != nil else { return nil }
        return routeState.running
    }

    /// Syncs the real identity of the ready engine within one run (after a source schema / physical layout switch).
    /// The keyboard's own layout/schema switch writes the selection back to the shared record; without
    /// updating the running key, the next appear would mistake that self-caused change for a resource
    /// change and restart (spinner).
    private func noteRunningIdentity() {
        guard phase == .ready, let controller, let resources = runningResources else { return }
        routeState.updateRunning(
            KeyboardRouteKey(
                resource: resources,
                sourceSchemaID: resources.sourceSchemaID(controller.selectedSchemaID),
                layout: controller.layout))
    }

    /// The real combination a boot adopts. Single source: `boot()` and external route checks share it,
    /// so two copies of the candidate/restriction rules cannot compute different keys (the root cause of repeated restarts).
    public struct BootPlan: Equatable, Sendable {
        public let onResource: KeyboardResourceSet
        public let layout: KeyboardLayoutKind
        public let engineSchemaID: String
        public let sourceSchemaID: String
        public var routeKey: KeyboardRouteKey {
            KeyboardRouteKey(resource: onResource, sourceSchemaID: sourceSchemaID, layout: layout)
        }
    }

    /// Resolves the real combination for this boot on `resolvedSet`. Pure computation: no disk, no engine.
    /// nil = the set has no bootable combination under the current target / source restriction (a real failure).
    public func bootPlan(on resolvedSet: KeyboardResourceSet) -> BootPlan? {
        let resume = suspendedComposition
        let preservedTarget: SelectionTarget? = {
            guard let target = selectionTarget else { return nil }
            guard target.resources == nil || target.resources == resolvedSet else { return nil }
            return target
        }()
        let restrictedSource: String?
        let layoutCandidates: [KeyboardLayoutKind]
        if let resume {
            restrictedSource = resume.sourceSchemaID
            layoutCandidates = [resume.layout] + resolvedSet.availableLayouts
        } else if let target = preservedTarget {
            restrictedSource = target.schemaID ?? resolvedSet.selectedSchemaID
            layoutCandidates = [target.layout] + resolvedSet.availableLayouts
        } else {
            restrictedSource = resolvedSet.selectedSchemaID
            var candidates: [KeyboardLayoutKind] = []
            if let published = resolvedSet.preferredLayout { candidates.append(published) }
            candidates.append(layout)
            candidates.append(contentsOf: resolvedSet.availableLayouts)
            layoutCandidates = candidates
        }
        guard
            let boot = resolvedSet.bootSelection(
                candidates: layoutCandidates,
                restrictedToSource: restrictedSource)
        else {
            return nil
        }
        return BootPlan(
            onResource: resolvedSet, layout: boot.layout, engineSchemaID: boot.schemaID,
            sourceSchemaID: resolvedSet.sourceSchemaID(boot.schemaID))
    }

    // MARK: - Layout selection (callers should limit the list to availableLayouts)

    /// Switches layout once the engine is ready (when not ready, records the target and applies it after
    /// ready) and remembers the choice. A failed selection leaves state unchanged; code-level capability
    /// checks are left to InputSession/ResourceSet.
    public func selectLayout(_ newLayout: KeyboardLayoutKind) {
        guard layout != newLayout else { return }
        if phase == .ready, let controller {
            transitionError = nil
            controller.selectLayout(newLayout)
            // The successful onLayoutChanged callback is the only writer while ready.
            return
        }
        recordUnreadySelection(schemaID: selectionTarget?.schemaID, layout: newLayout)
    }

    /// Explicit selection while not ready: records the target (optionally with a bound schema) and
    /// invalidates the in-flight boot so the new target wins. This closes the `selectLayout` promise to
    /// apply the target after ready; a stale boot result cannot overwrite it. Before `start()` it only records.
    ///
    /// A pending resume composition (rawInput captured by a maintenance stop) loses to an explicit new
    /// selection: it is cancelled (neither replayed nor committed, since it was never confirmed and the new
    /// boot has no ready engine to confirm it) and the new target boots fresh. Otherwise the next boot
    /// would take the old resume and override the new target.
    private func recordUnreadySelection(schemaID: String?, layout newLayout: KeyboardLayoutKind) {
        guard availableLayouts.contains(newLayout) else {
            transitionError = "当前输入方式不支持所选键盘布局，已保留当前输入。"
            return
        }
        transitionError = nil
        suspendedComposition = nil
        selectionTarget = SelectionTarget(resources: resourceSet, schemaID: schemaID, layout: newLayout)
        self.layout = newLayout
        persistLayout(newLayout)
        guard startTapped else { return }
        // Invalidate the in-flight boot (including the background engine start await) and restart with the new
        // target; the old engine shuts itself down per the bootGeneration rules.
        restart(resourceSet: resourceSet, layout: newLayout)
    }

    // MARK: - Resource switch / shutdown / restore configured route

    /// Switches the resource configuration (e.g. an installed scheme's active generation): stops the old
    /// engine, then starts the new one (serially). Committed text and per-set user data are unaffected.
    /// `targetLayout` outside the new set falls back to its first available layout. Start / schema
    /// failures surface in `phase` (never swallowed, no fallback); `retry()` retries the new configuration.
    public func switchResource(
        to newSet: KeyboardResourceSet,
        layout targetLayout: KeyboardLayoutKind? = nil
    ) {
        let requested = targetLayout ?? newSet.availableLayouts.first ?? .qwerty26
        // Resolve the layout within the explicit/published source's own schema (fallback only within the same source, never across sources).
        let candidates = [requested] + newSet.availableLayouts
        guard let boot = newSet.bootSelection(candidates: candidates, restrictedToSource: newSet.selectedSchemaID)
        else {
            transitionError = "所选键盘布局暂时无法使用，已保留当前输入。"
            return
        }
        if let reason = newSet.incompatibilityReason(layout: boot.layout, schemaID: boot.schemaID) {
            transitionError = reason
            return
        }
        // Same-process return: the shared published selection may be rewritten by an in-keyboard layout/schema
        // switch, but if the running engine already serves the same publication-level identity (same resource
        // id + generation + source schema + layout) there is nothing to apply. Return here, keeping the ready
        // engine with no teardown and no transient `.starting` (spinner after lock-screen / app-switch return).
        let targetKey = KeyboardRouteKey(
            resource: newSet,
            sourceSchemaID: newSet.sourceSchemaID(boot.schemaID),
            layout: boot.layout)
        if routeState.canReuse(targetKey, isReady: phase == .ready && controller != nil) {
            KeyboardLifecycleDiagnostics.emit(
                "resourceSwitch.reuse",
                [
                    "generation": String(targetKey.publicationGeneration?.prefix(8) ?? "-"),
                    "layout": targetKey.layout.rawValue,
                ])
            selectionTarget = SelectionTarget(
                resources: newSet, schemaID: newSet.selectedSchemaID,
                layout: boot.layout)
            return
        }
        guard
            FileManager.default.fileExists(
                atPath: (newSet.prebuiltDirectory ?? newSet.sharedDirectory)
                    .appendingPathComponent(boot.schemaID + ".schema.yaml").path)
        else {
            transitionError = "所选键盘布局暂时无法使用，已保留当前输入。"
            return
        }
        let running = routeState.running
        let changed: [String] = [
            running?.resourceID != targetKey.resourceID ? "resource" : nil,
            running?.publicationGeneration != targetKey.publicationGeneration ? "generation" : nil,
            running?.sharedDirectory != targetKey.sharedDirectory ? "sharedDirectory" : nil,
            running?.userDirectory != targetKey.userDirectory ? "userDirectory" : nil,
            running?.prebuiltDirectory != targetKey.prebuiltDirectory ? "prebuiltDirectory" : nil,
            running?.sourceSchemaID != targetKey.sourceSchemaID ? "source" : nil,
            running?.layout != targetKey.layout ? "layout" : nil,
        ].compactMap { $0 }
        KeyboardLifecycleDiagnostics.emit(
            "resourceSwitch.restart",
            [
                "readyBefore": phase == .ready ? "1" : "0", "changed": changed.joined(separator: ","),
                "generation": String(targetKey.publicationGeneration?.prefix(8) ?? "-"),
            ])
        // An explicit resource switch sets a new target: bind the new source snapshot and the resolved source/layout.
        selectionTarget = SelectionTarget(resources: newSet, schemaID: newSet.selectedSchemaID, layout: boot.layout)
        restart(resourceSet: newSet, layout: boot.layout)
    }

    /// Shuts the engine down (yielding to recipe installation / mutual exclusion / leaving the page).
    /// Committed host text and per-set user data are unaffected; afterwards `start()`/`retry()` can restart
    /// the current configuration, or `switchResource`/`restoreConfiguredRoute()` can change it.
    public func shutdown() {
        reportCompositionPresentation(.idle)
        resetHostContext()
        onMarkedComposition?(nil)
        suspendedComposition = nil
        selectionTarget = nil
        // Do NOT clear runningEngine here: the coordinator stop closure is the single owner
        // that captures it and explicitly awaits its shutdown before clearing references.
        // Clearing here made stop observe nil and left the real engine/lease alive whenever
        // an external holder (retained controller/backend) kept it referenced.
        routeState.cancel()
        startTapped = false
        controller?.retire()
        controller = nil
        phase = .failed("键盘已停止，请轻点「重试」")
        EngineOwnershipCoordinator.shared.release(ownershipID)
    }

    /// Recovery for an explicit real resource set: discard the explicit target and
    /// re-run the configured route. Without a real route, the keyboard extension may
    /// start its limited bundled offline input; Host trial remains unconfigured.
    public func restoreConfiguredRoute() {
        guard prepareForConfigurationChange() else { return }
        userDirectoryOverride = nil
        selectionTarget = nil
        if resourceSet != nil {
            // Keep any route resolver so the real configured source is re-resolved.
            restart(resourceSet: nil, layout: layout)
        } else if startTapped {
            retry()
        } else {
            start()
        }
    }

    /// Unified switch entry: invalidate the in-flight boot, wait for it to finish, shut down the old engine, then boot the new configuration.
    private func restart(resourceSet newSet: KeyboardResourceSet?, layout target: KeyboardLayoutKind) {
        guard prepareForConfigurationChange() else { return }
        routeState.beginBoot()
        startTapped = true
        controller?.retire()
        controller = nil
        resourceSet = newSet
        layout = target
        availableLayouts = newSet?.availableLayouts ?? KeyboardLayoutKind.allCases
        phase = .starting
        persistLayout(target)
        noteRequestedBootRoute()
        requestOwnership()
    }

    /// Call before an asynchronous custom-layout/resource route discards this controller.
    /// switchResource/retry/restoreConfiguredRoute also enforce this at their teardown boundary.
    @discardableResult
    public func prepareForConfigurationChange() -> Bool {
        transitionError = nil
        guard let controller else { return true }
        // Unverified engine state must be restarted, never confirmed or replayed.
        if controller.inputUnavailableReason != nil {
            suspendedComposition = nil
            return true
        }
        guard controller.prepareForConfigurationChange() else {
            transitionError = controller.inputError ?? "当前输入尚未确认，已保留原布局。"
            return false
        }
        return true
    }

    private func requestOwnership() {
        EngineOwnershipCoordinator.shared.claim(
            ownershipID,
            start: { [self] in
                guard startTapped else { return }
                phase = .starting
                await boot()
            },
            stop: { [self] in
                reportCompositionPresentation(.idle)
                // Keys still decoding off the main thread are not in `rawInput` yet; land
                // them so the resumed composition keeps every key that was typed.
                controller?.session.refresh()
                if startTapped, let controller, controller.inputUnavailableReason == nil,
                    controller.snapshot.isComposing,
                    let resources = runningResources, !controller.snapshot.rawInput.isEmpty
                {
                    suspendedComposition = (
                        resources, controller.selectedSchemaID, controller.layout,
                        controller.snapshot.rawInput
                    )
                }
                onMarkedComposition?(nil)
                controller?.retire()
                controller = nil
                if startTapped { phase = .starting }
                // Capture, explicitly await the real shutdown, and only then drop references.
                // `old` is the single owner keeping the engine alive across the await even if an
                // external holder retains it; releasing the reference must not precede shutdown.
                // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
                nonisolated(unsafe) let old = runningEngine
                await EngineOwnershipCoordinator.shutdown { old?.shutdown() }
                runningEngine = nil
                backend = nil
            })
    }

    // MARK: - boot

    private func boot() async {
        let generation = routeState.generation
        defer { routeState.clearPending(token: generation) }
        let resume = suspendedComposition
        if let suspended = resume {
            // A maintenance job must not erase the screen's pending input or replay it into
            // an unrelated newly installed schema. Resume against its immutable old generation.
            resourceSet = suspended.resources
            availableLayouts = suspended.resources.availableLayouts
        } else if let resourceResolver {
            do {
                let current = try await resourceResolver()
                guard routeState.isCurrent(generation) else { return }
                resourceSet = current
                availableLayouts = current?.availableLayouts ?? KeyboardLayoutKind.allCases
            } catch {
                Self.diagnosticLogger.error(
                    "resource resolver failed: \(error.localizedDescription, privacy: .private)")
                if routeState.isCurrent(generation) { phase = .failed("无法读取输入方案，请重试。") }
                return
            }
        }
        // 1. Resolve the resource set (nil = the built-in package in the bundle + this process's private user directory).
        let resolvedSet: KeyboardResourceSet
        if let set = resourceSet {
            resolvedSet = set
        } else {
            guard let shared = RimePaths.builtinPackage() else {
                if routeState.isCurrent(generation) {
                    phase = .failed("找不到内置输入方案，请重新安装 App。")
                }
                return
            }
            let user: URL
            if let userDirectoryOverride {
                user = userDirectoryOverride
            } else if let interactive = RimePaths.interactiveUserDirectory() {
                user = interactive
            } else {
                if routeState.isCurrent(generation) {
                    phase = .failed("无法访问本地存储目录，请重试")
                }
                return
            }
            resolvedSet = KeyboardResourceSet.builtin(sharedDirectory: shared, userDirectory: user)
        }
        // 2. Compute the boot (physical layout, engine schema). One selection lifecycle:
        //  - Composition resume: boot only from the original source schema paired with the original layout.
        //  - Same source, same generation (selectionTarget.resources == resolvedSet): prefer the last
        //    successful real schema/layout over the resolver's published preferred (retry / resume without composition).
        //  - First entry to a source / new generation / not-yet-resolved pending request: boot from the published selection.
        //  - Explicit/published sources are limited with restrictedToSource; never fall back to another schema in the union.
        // The rules live in `bootPlan(on:)`, so external route checks always agree with this.
        guard let plan = bootPlan(on: resolvedSet) else {
            if routeState.isCurrent(generation) {
                phase = .failed("当前输入方案没有可用的键盘布局。")
            }
            return
        }
        let bootLayout = plan.layout
        let schemaID = plan.engineSchemaID
        // Publication-level route identity of this boot: the source schema and the physical layout must come
        // from the same bootSelection result, never from a possibly nil/stale published selection in the
        // resource set; otherwise one running engine computes two different keys and restarts repeatedly.
        let bootRouteKey = plan.routeKey
        routeState.notePending(bootRouteKey)
        // 3. Start the engine (serial on EngineOpQueue; a real first run deploys dictionaries and may take a
        //    while; prebuilt sets skip deployment, and missing resources fail explicitly here or in the engine).
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine: EngineBackend
        // The initial schema on resume must come from the same boot combination so schema and physical layout stay paired.
        let initialSchema = schemaID
        do {
            let dirs = resolvedSet
            let optionDirectory =
                optionPreferencesDirectory ?? dirs.userDirectory.appendingPathComponent("keyboard-options")
            if let factory = bootEngineFactory {
                engine = try factory(dirs)
            } else {
                let receiptContext =
                    recordsRuntimeGrammarReceipts
                    ? dirs.publicationGeneration.map { generation in
                        GrammarRuntimeReceiptStore.Context(
                            publicationGeneration: generation, sessionID: runtimeReceiptSessionID)
                    }
                    : nil
                engine = RimeBackend(
                    sharedDirectory: dirs.sharedDirectory,
                    userDirectory: dirs.userDirectory,
                    prebuiltDirectory: dirs.prebuiltDirectory,
                    resourceID: dirs.id,
                    optionStore: OptionStore(directory: optionDirectory),
                    allowedSchemaIDs: dirs.schemas.isEmpty ? nil : Set(dirs.schemas.map(\.id)),
                    runtimeGrammarReceiptContext: receiptContext,
                    sharedWritesAllowed: { KeyboardRecipeStore.canWriteSharedContainer })
            }
            try await EngineOpQueue.async { () -> Void in
                do {
                    if let rime = engine as? RimeBackend {
                        try rime.startIfNeeded()
                    } else {
                        try engine.setup(sharedDirectory: dirs.sharedDirectory, userDirectory: dirs.userDirectory)
                    }
                    // Ownership remains held across this await. No controller can touch the
                    // engine until startup, model validation and optional raw replay all finish.
                    try engine.selectSchema(initialSchema)
                    if let resume {
                        for key in resume.input {
                            let state = try engine.processKey(String(key))
                            guard state.committed.isEmpty else {
                                throw EngineBackendError.operationFailed("恢复输入状态时输入方案提前上屏；已保留原始编码：\(resume.input)")
                            }
                        }
                    }
                } catch {
                    engine.shutdown()
                    throw error
                }
            }
        } catch {
            routeState.clearPending(token: generation)
            Self.diagnosticLogger.error("engine start failed: \(String(describing: error), privacy: .private)")
            if routeState.isCurrent(generation) {
                phase = .failed("键盘引擎未能启动，请重试。")
            }
            return
        }
        // Background-start await window: tests can pause here to verify that a not-ready explicit selection
        // invalidates the in-flight boot and the new target wins. Production `bootGate` is nil.
        if let bootGate { await bootGate() }
        // 4. Stale boot (a switch/shutdown happened meanwhile): shut down the just-started engine and exit,
        //    so at most one active engine exists in the process at any time and old results never land on new state.
        guard routeState.isCurrent(generation) else {
            await EngineOwnershipCoordinator.shutdown { engine.shutdown() }
            return
        }
        suspendedComposition = nil
        // Publish normalization only after real enabled/publication validation and activation.
        if layout != bootLayout {
            layout = bootLayout
            persistLayout(bootLayout)
        }
        // 5. Generation publish point (before any observable side effect): first confirm this boot is still
        //    the latest intent, then build the controller / install callbacks / write any ready state. A
        //    failed boot must shut down the engine it just started (`engine` belongs only to this boot, never
        //    to a newer one) and publish no state. If a newer generation has begun, the taker owns `phase`:
        //    `beginBoot()` (restart/switch) sets `.starting` again and `cancel()` (shutdown) already set
        //    `.failed`, so no ownerless `.starting` is left behind.
        guard routeState.commitReady(bootRouteKey, token: generation) else {
            await EngineOwnershipCoordinator.shutdown { engine.shutdown() }
            return
        }

        let ctrl = KeyboardController(layout: bootLayout, engine: engine, resourceSet: resolvedSet)
        // A boot can span a disappear; the backend was not yet published, so the disappearance could not
        // suspend it directly. Read the real schema at construction and apply the latest visibility before handoff, keeping the same engine.
        if hostIsVisible == false, let backend = engine as? RimeBackend {
            backend.suspendSessionForHostDisappearance()
        }
        inputRecoveryObservation = ctrl.$snapshot.removeDuplicates().dropFirst().sink { [weak self, weak ctrl] _ in
            guard let self, let ctrl, self.controller === ctrl,
                ctrl.session.inputUnavailableReason == nil, ctrl.inputError == nil
            else { return }
            // Runs on every key: an unconditional write republished the session and
            // re-rendered the extension root, the panel host and the panel once more.
            if self.transitionError != nil { self.transitionError = nil }
        }
        ctrl.onDispatchCommit = { [weak self] text in
            self?.dispatchCommitToHost(text) ?? false
        }
        ctrl.onRequestDeleteBackward = { [weak self] in self?.onDeleteBackward?() }
        ctrl.onReadDocumentContext = { [weak self] in
            guard let self, self.hostContextIdentifier?() != nil else { return nil }
            return self.onReadDocumentContext?()
        }
        ctrl.onReplaceLiteralSuffix = { [weak self] expected, old, new in
            guard let self, self.hostContextIdentifier?() != nil else { return false }
            return self.onReplaceLiteralSuffix?(expected, old, new) ?? false
        }
        ctrl.onRequestHostTraitsRefresh = { [weak self] in self?.onRefreshHostTraits?() }
        ctrl.onRequestSwitchKeyboard = { [weak self] in self?.onSwitchKeyboard?() }
        ctrl.onMoveCursor = { [weak self] offset in self?.onMoveCursor?(offset) }
        ctrl.onInputError = { [weak self, weak ctrl] message in
            guard let self else { return }
            self.transitionError = message
            if let reason = ctrl?.session.inputUnavailableReason {
                Self.diagnosticLogger.error("input became unavailable: \(reason, privacy: .private)")
                self.selectedSchemaID = ctrl?.session.selectedSchemaID ?? ""
                self.phase = .failed("当前输入方案无法启用，已保留原布局；请重试或改用其他方案。")
            }
        }
        ctrl.onMarkedComposition = { [weak self] composition in
            guard let self else { return }
            self.reportCompositionPresentation(
                composition == nil
                    ? .idle
                    : (self.onMarkedComposition == nil ? .keyboard(reason: "输入框暂不可用") : .awaitingHost))
            self.onMarkedComposition?(composition)
        }
        ctrl.onSelectionChanged = { [weak self] change in
            guard let self else { return }
            self.selectedSchemaID = change.schemaID
            self.successfulChange = change
            self.lastReadySelection = (change.schemaID, change.layout)
            // A successful selection updates the session target: a same-source same-generation restart reuses this exact schema/layout.
            self.selectionTarget = SelectionTarget(
                resources: self.runningResources,
                schemaID: change.schemaID, layout: change.layout)
            // The ready engine's real identity changed (within one run): sync the running key so the next appear
            // reuses it instead of restarting because the selection was written back to the shared record.
            self.noteRunningIdentity()
            self.onSelectionChanged?(change)
        }
        // After the panel's layout key cycles, sync back to this session and persist, so the host Picker and the next start agree.
        ctrl.onLayoutChanged = { [weak self] newLayout in
            guard let self else { return }
            self.layout = newLayout
            if self.remembersLayoutSwitch?() ?? true { self.persistLayout(newLayout) }
            self.noteRunningIdentity()
        }
        // The generation was validated and published before the controller was built (see 5); only state writes happen here.
        availableSchemas = engine.availableSchemas
        selectedSchemaID = ctrl.selectedSchemaID
        runningEngine = engine
        self.backend = engine as? RimeBackend
        runningResources = resolvedSet
        self.controller = ctrl
        self.phase = .ready
        // User keyboards: first inject the session's existing list (possibly from a previous boot) into the
        // new controller, then re-read the publication record. A failed read keeps the old list and surfaces the error; never clears to "no keyboards".
        ctrl.updatePublishedKeyboards(publishedKeyboards, error: publishedKeyboardError)
        // Bounded, once-per-boot resource/schema diagnostic for Dev validation.
        // No user input content: resource id, startup identity and the schema the
        // engine actually activated (which can differ from the published request).
        Self.diagnosticLogger.info(
            """
            resource active id=\(resolvedSet.id, privacy: .public) \
            prebuilt=\(resolvedSet.prebuiltDirectory != nil, privacy: .public) \
            schema=\(ctrl.selectedSchemaID, privacy: .public) layout=\(ctrl.layout.rawValue, privacy: .public) \
            requested=\(resolvedSet.selectedSchemaID ?? "-", privacy: .public)
            """)
        // Record this boot's real session target; a same-source same-generation retry keeps it, and only a new source generation follows the new published selection.
        selectionTarget = SelectionTarget(
            resources: resolvedSet,
            schemaID: ctrl.selectedSchemaID, layout: ctrl.layout)
        if let previous = lastReadySelection,
            previous.schemaID != ctrl.selectedSchemaID || previous.layout != ctrl.layout
        {
            ctrl.reportSuccessfulSelectionChange()
        }
        lastReadySelection = (ctrl.selectedSchemaID, ctrl.layout)
        if ctrl.snapshot.isComposing {
            refreshCompositionPresentation()
        }
        // Once ready the user can switch schemas; after the await returns, do not write this boot's selection back to state.
        await refreshPublishedKeyboards()
    }

    /// Remembers the selected Chinese layout in this process's `UserDefaults.standard` only (not the App Group
    /// container: HostApp and the extension each persist in their own sandbox). Layout kinds are shared by
    /// every resource set, so the stored value stays meaningful after a switch.
    private func persistLayout(_ newLayout: KeyboardLayoutKind) {
        UserDefaults.standard.set(newLayout.rawValue, forKey: AppSettings.selectedLayoutKey)
    }
}
