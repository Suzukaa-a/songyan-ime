import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

/// UIKit keyboard extension root controller. The panel and the host app's try-input area share
/// KeyboardPadSession + KeyboardController (the real Rime engine); commits go through UITextDocumentProxy.
///
/// Input behavior:
///   - Backspace: deletes a code inside a composition; calls deleteBackward() when it is empty.
///   - Space/Return: with candidates, confirms the highlighted one (librime may commit at once, as a
///     single commit); with an empty composition, inserts a space/newline through the proxy.
///   - Layout menu: picks among the internal layouts the current scheme supports.
///   - Globe key: all touch events go to handleInputModeList, keeping the system tap/long-press/swipe-up behavior.
///
/// Key feedback (KeyboardFeedbackService, shared with the host app):
///   - Clicks play through AVAudioPlayer, haptics through the shared generator.
///   - Without Full Access neither is called (public reports say they block the main thread for a long
///     time or fail silently in that state); typing is unaffected.
///
/// Typing works without Full Access: the engine writes to its own container (RimePaths.interactiveUserDirectory).
/// The system can terminate the extension at any time; engine startup (including first deployment) runs in the
/// background while the UI shows loading/error.
class KeyboardViewController: UIInputViewController {
    nonisolated static let diagnosticLogger = Logger.keyboardExtension

    // UIKit may retain a dismissed input controller while creating its successor
    // in the same extension process. The process, not a controller's view, owns
    // the single librime engine. Reuse its session even if boot is still pending.
    private static let processSession: KeyboardPadSession = {
        // Register the candidate-area renderer (same default renderer as the host app).
        CandidateRenders.installDefault()
        var saved = UserDefaults.standard.string(forKey: AppSettings.selectedLayoutKey)
        #if DEBUG
            // Automation: `make sim-layout` overrides the layout through the App Group, avoiding the extension's private container.
            if let forced = KeyboardRecipeStore.sharedDefaults()?
                .string(forKey: DebugProbe.layoutOverrideKey)
            {
                saved = forced
            }
        #endif
        let layout = KeyboardLayoutKind(rawValue: saved ?? "") ?? .qwerty26
        let session = KeyboardPadSession(layout: layout)
        session.setHostVisibility(false)
        session.enablesOfflineBundledInput = true
        session.recordsRuntimeGrammarReceipts = true
        session.optionPreferencesDirectory = RimePaths.optionPreferencesDirectory()
        return session
    }()
    static weak var activeController: KeyboardViewController?
    /// Every controller that loaded its view, weakly: a replaced one may never become
    /// `activeController`'s previous value (it already unbound on disappear).
    private static let liveControllers = NSHashTable<KeyboardViewController>.weakObjects()
    /// Set when a newer controller appears while this one is still on screen.
    private var retiresPanelWhenHidden = false
    /// From `viewWillAppear` to `viewDidDisappear`. A window alone is not proof: a host
    /// can keep a dismissed controller's view attached.
    private var isOnScreen = false
    /// This controller was the active one when its keyboard started to hide; only it may
    /// budget the next presentation, once off screen.
    private var preparesNextPresentation = false
    private lazy var panelHostLifetime = KeyboardPanelHostLifetime { [weak self] in
        guard let self else { return false }
        return Self.activeController === self
    }
    /// Process-wide: whether this process has ever reached ready. Separates a true cold start (first engine in
    /// the process) from an in-process re-boot; neither is a warm resume, and diagnostics must not call them
    /// "resume". It resets only in a new process, so it changes no engine behavior.
    static var processHasEverBeenReady = false

    var session: KeyboardPadSession!
    private var hostAppearanceToken: UUID?
    private var hostResumeTask: Task<Void, Never>?
    /// Full Access as read in `viewWillAppear`; `viewDidAppear` re-routes immediately if it changed.
    private var fullAccessAtWillAppear: Bool?
    private var controllerObservation: AnyCancellable?
    private var phaseObservation: AnyCancellable?
    /// Classification and entry time of this appearance, used to log warm/cold start duration at `.ready`.
    var appearanceBootClassification: KeyboardBootClassification?
    var appearanceEntryMonotonic: CFTimeInterval?
    var lastObservedPhaseLabel: String?
    var restartedDuringAppearance = false
    var hostingController: UIHostingController<ExtensionKeyboardPanel>?
    var panelHeightConstraint: NSLayoutConstraint?
    var hostingHeightConstraint: NSLayoutConstraint?
    var lastLayoutGeometry = ""
    var lifecycleGeometryEnabled = KeyboardLifecycleDiagnostics.isEnabled
    private lazy var initialPresentation = KeyboardInitialPresentation.load()
    lazy var presentation = ExtensionPresentationStatus(
        budget: initialPresentation.presentationBudget(compact: traitCollection.verticalSizeClass == .compact))
    private static let processRoute = ExtensionRouteStatus()
    var route: ExtensionRouteStatus { Self.processRoute }
    /// What the last applied route resolution showed, restored as-is when nothing changed.
    struct AppliedRoute {
        var key: String
        var reason: String
        var notice: String?
        var schemeName: String
    }
    static var applied: AppliedRoute?
    /// This controller's in-flight route refresh; each new refresh cancels the previous one.
    var routeTask: Task<Void, Never>?
    var selectionSaveTask: Task<Void, Never>?
    var selectionSaveInFlight = false
    /// Latest-wins gate for layout registry reads (per instance): only drops this instance's stale results.
    var layoutReadGate = LatestWinsReadGate()
    /// Polling task for learning-data transfer, alive only while visible (every 1-2 s).
    ///
    /// Started in `viewDidAppear`, cancelled in `viewWillDisappear` / `deinit`. Cancelling it does not cancel
    /// a backup/merge already running; that is owned by `KeyboardLearningTransfer`'s process-wide worker.
    var learningTransferPollTask: Task<Void, Never>?
    /// This appearance's Full Access, read once in `viewDidAppear`. `hasFullAccess`
    /// is a TCC IPC on the main thread; the poll read it twice every two seconds.
    /// Changing Full Access in Settings terminates the extension, so it holds.
    var pollFullAccess = false
    /// The host is in the background: the extension may be suspended at any
    /// moment, and a shared-container flock held then is a 0xdead10cc kill.
    var hostInBackground = false
    private var hostLifecycleObservers: [NSObjectProtocol] = []
    /// Set once this appearance has started its route refresh; `viewDidAppear` then skips a second read.
    var routeRefreshedThisAppearance = false
    // Runtime rescue only. A newly published shared generation supersedes it.
    static var rescuedRoute: String?
    static let selectedDefinitionKey = "keyboard.selectedLayoutDefinitionID"
    var markedDocument: UUID?
    var pendingMarked: MarkedComposition?
    var lastEchoedMarked: MarkedComposition?
    var markedBaselineContext: ProxyDocumentContext?
    var markedInsertionContext: ProxyDocumentContext?
    var keyboardOnlyComposition = false
    /// Marked text the host showed when the keyboard hid. Teardown cannot touch the
    /// proxy and the suspended engine drops the composition, so the host would keep an
    /// underlined composition the keyboard no longer has (the next key silently
    /// replaced it). Cancelled on the next appearance once the document is writable.
    /// Process-wide: iOS often returns with a new controller on the same session.
    static var orphanedMarked = false
    struct CancelledMarkedEcho {
        let document: UUID
        let context: ProxyDocumentContext
    }
    var cancelledMarkedEcho: CancelledMarkedEcho?
    var proxyContext: ProxyDocumentContext {
        ProxyDocumentContext(
            before: textDocumentProxy.documentContextBeforeInput,
            after: textDocumentProxy.documentContextAfterInput,
            selected: textDocumentProxy.selectedText)
    }
    /// The document this controller currently serves; nil until the first proxy contact.
    var activeDocumentID: UUID?
    /// Orders asynchronous shared-selection saves. Only the newest request from
    /// the still-active controller may publish a completion notice.
    private var selectionSaveGeneration: UInt64 = 0
    /// Orders saves across controllers and presentations: a failure may only roll the
    /// remembered layout back while no newer selection has been made.
    static var layoutSaveGeneration: UInt64 = 0
    var proxyWriteInProgress = false
    var expectedContext: ProxyDocumentContext?
    /// Set in `viewWillAppear`; the proxy is first read once the host handoff settles.
    var hostDocumentAttachPending = false
    /// Pairs the live-controller count from `viewDidLoad` with `deinit`.
    private var loadedViewCounted = false
    /// One deferred trait re-read per main-queue turn. Every proxy write and every
    /// textDidChange asked for its own; during fast typing that was several proxy
    /// round trips per key for the same answer.
    var hostTraitsRefreshScheduled = false

    /// The single identity read. UIKit declares the identifier nonnull but an
    /// inactive proxy returns nil, so it is read through the Objective-C shim.
    /// Nil fails closed: local state is dropped (the host is never written), so a
    /// later read of the same UUID cannot revive an interrupted operation.

    #if DEBUG
        var timingProbeLink: CADisplayLink?
        var timingProbeStartedAt: CFTimeInterval = 0
        var timingProbeLastEmitAt: CFTimeInterval = 0
        var timingProbeLines = 0
        var timingProbeLastSignature = ""
        var timingProbeActive = false
    #endif

    // MARK: Lifecycle

    /// Release contract: a destroyed controller must leave no observer or in-flight route task behind.
    /// `activeController` is a weak reference, so process-wide shared state is not altered by this instance going away.
    deinit {
        if loadedViewCounted { KeyboardLiveObjects.controllers.decrement() }
        // viewWillDisappear is not guaranteed to pair, so retire the route task here too.
        routeTask?.cancel()
        routeTask = nil
        hostResumeTask?.cancel()
        // UIKit releases view controllers on the main thread.
        MainActor.assumeIsolated {
            // The poll can no longer become visible: stop starting new checks (a running transfer is owned by the service).
            stopLearningTransferPolling()
            hostLifecycleObservers.forEach(NotificationCenter.default.removeObserver)
            // UIKit keeps a replaced controller's input view alive (heap after four host
            // relaunches: one controller, but four FeedbackInputViews each still holding
            // its _UIHostingView). Those SwiftUI panels kept observing the process session
            // and re-rendered on every key, so typing got slower with every presentation.
            // Detached, the hosting view and its graph go with this controller.
            if hostingController != nil { KeyboardLiveObjects.panels.decrement() }
            hostingController?.view.removeFromSuperview()
        }
    }

    /// Installs a typed `inputView` during controlled view creation.
    /// `UIInputViewController.inputView` is publicly a `UIInputView?` (the system supplies an empty one); it is
    /// replaced with a FeedbackInputView (a UIInputView subclass), and the
    /// controller's view points at the same instance:
    ///   - view and inputView are always the same instance, so system styling and sizing stay with the input view pipeline;
    ///   - the child controller (UIHostingController) and constraints are attached by viewDidLoad as usual,
    ///     with no plain-UIView root replacement;
    ///   - the `.default` style keeps the existing look (the panel paints its own background).
    override func loadView() {
        // Give a reasonable initial frame (the system lays it out to the keyboard geometry afterwards) to avoid
        // the deprecated UIScreen.main; the height constraint takes over the final height.
        // Fixed shell height: identical for every phase (starting/failed/unconfigured/ready), so cold start has no
        // header height jump.
        let height = initialPresentation.shellHeight(compact: traitCollection.verticalSizeClass == .compact)
        let inputView = FeedbackInputView(
            frame: CGRect(x: 0, y: 0, width: 320, height: height),
            inputViewStyle: .default)
        // The root input view stays transparent. The system applies a transient
        // oversized frame to it during keyboard presentation; an opaque root
        // would render that entire transient as a full-width background slab
        // (the large gray slab). The fixed-height content uses the iOS-owned surface
        // for the default skin; only a user-authored skin paints its own area.
        // Either way the root adds no extra slab outside the keyboard budget.
        inputView.backgroundColor = .clear
        #if DEBUG
            // Attribution probe (default off, Debug only): paints the root input
            // view a unique color so a recorded frame can prove whether the
            // transient oversized band is drawn *by this root view* or by the
            // system keyboard window behind it. Read once at load; no production
            // path changes when the key is absent.
            if UserDefaults.standard.bool(forKey: "keyboard.transientAttributionProbe") {
                inputView.backgroundColor = .magenta
            }
        #endif
        // The keyboard sits above the home indicator: the bottom edge is the
        // stable screen anchor. Clip so any system-side transient sizing can
        // never drag content outside the final keyboard area.
        inputView.clipsToBounds = true
        view = inputView
        self.inputView = inputView
        panelHeightConstraint = inputView.budgetHeightConstraint
        preferredContentSize.height = height
        logPanelGeometry("loadView")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyboardStallReport.installMemoryWarningObserver()
        KeyboardLiveObjects.controllers.increment()
        loadedViewCounted = true

        // The host can go to the background without a disappearance (device log:
        // 30 s of polling while BackgroundRunning, then a 0xdead10cc kill on suspend).
        hostLifecycleObservers = [
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostDidEnterBackground,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostMovedToBackground(true) }
            },
            NotificationCenter.default.addObserver(
                forName: .NSExtensionHostWillEnterForeground,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hostMovedToBackground(false) }
            },
        ]

        // UIKit can change the keyboard window's light/dark trait while the
        // extension remains visible. Do not wait for a new host appearance cycle
        // to repaint the SwiftUI panel; the observed route drives its environment.
        syncSystemColorScheme(animated: false)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _) in
            controller.syncSystemColorScheme(animated: true)
        }
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _) in
            controller.syncPresentationSizeClass()
        }
        // The keyboard host may update its input view's environment without
        // changing the extension controller's own trait collection. Observe the
        // actual UIInputView too: it owns the system-backed keyboard surface.
        inputView?.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIInputView, _) in
            self?.syncSystemColorScheme(animated: true)
        }

        session = Self.processSession
        // Presentation geometry belongs to this controller, not processRoute.
        // Engine-ready observation: records how this appearance became ready (warm resume / in-process re-boot /
        // true cold start) with duration and memory, only on a real transition to `.ready`. Read-only diagnostics;
        // never triggers a boot or teardown on phase changes.
        phaseObservation = session.$phase
            .removeDuplicates()
            .sink { [weak self] phase in self?.noteEnginePhase(phase) }
        // The typed input view installed its budget constraint and self-sizing
        // contract in loadView, before any SwiftUI measurement or engine startup.
        controllerObservation = session.$controller.sink { [weak self] controller in
            guard let controller else { return }
            // @Published emits before assignment: use the new controller directly.
            // Session publishes on MainActor, including after retry/resource recovery.
            self?.updateHostTraits(on: controller)
        }
        Self.liveControllers.add(self)
        installPanelHost()
    }

    /// Builds the SwiftUI panel. Also called by `viewWillAppear` when UIKit shows a
    /// controller again after `retirePanelHost()`.
    private func installPanelHost() {
        let host = ExtensionKeyboardPanel(
            session: session, route: route, panelHostLifetime: panelHostLifetime,
            selectBuiltin: { [weak self] builtin in
                self?.selectBuiltin(builtin)
            },
            systemKeyboardSwitch: { [weak self] sender, event in
                guard let self, Self.activeController === self else { return }
                self.handleInputModeList(from: sender, with: event)
            }, retryRoute: { [weak self] operation in self?.retryRoute(operation) },
            restoreBuiltin: { [weak self] in
                self?.restoreBuiltinTemporarily()
            }, reloadLayouts: { [weak self] in self?.refreshLayoutRegistry() },
            selectDefinition: { [weak self] definition in
                guard let self, Self.activeController === self else { return }
                self.route.selectedLayoutID = definition.id
                UserDefaults.standard.set(definition.id, forKey: Self.selectedDefinitionKey)
            }, initialPresentation: initialPresentation, presentation: presentation,
            onAppearanceChange: { _ in
                // The root input view is transparent; the bottom-anchored content
                // paints the opaque skin surface itself, so an appearance change
                // needs no root-side repaint.
            },
            openHostApp: { [weak self] url, completion in
                HostAppLink.open(url, from: self, completion: completion)
            },
            dismissKeyboard: { [weak self] in
                guard let self, Self.activeController === self else { return }
                self.dismissKeyboard()
            })
        let hosting = UIHostingController(rootView: host)
        hosting.sizingOptions = []  // the input view owns external height, not phase content
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        // The bottom-anchored content paints the opaque skin surface itself
        // (loading/error/ready alike); the root and hosting layers stay clear
        // so the system's transient oversized frame is never filled.
        hosting.view.backgroundColor = .clear
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        hostingController = hosting
        KeyboardLiveObjects.panels.increment()
        // Bottom-anchored fixed-height hosting instead of four-edge pinning.
        // The bottom edge is stable; content keeps its exact height and vertical
        // position when the view service applies a transient oversized frame
        // during keyboard launch.
        // Same source as loadView: the initial hosting height is the fixed shell height.
        // `view` was already replaced by KeyboardPanelInputView in loadView; the fallback applies only if that cast fails.
        // These constraints also keep the hosting subtree in the root's layout
        // engine, which the system's presentation measure relies on
        // (`systemLayoutSizeFitting` is not queried for a frame-placed child).
        let hostingHeight = hosting.view.heightAnchor.constraint(
            equalToConstant: (view as? KeyboardPanelInputView)?.panelHeight
                ?? initialPresentation.shellHeight(compact: traitCollection.verticalSizeClass == .compact))
        hostingHeight.priority = .required
        hostingHeightConstraint = hostingHeight
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingHeight,
        ])
        logPanelGeometry("hostAttached")
    }

    /// Releases the SwiftUI panel of a controller another one has replaced. Hosts can
    /// keep replaced controllers alive (device: 26 live after 117 appearances in one
    /// process); each kept panel observed the session and re-rendered on every key,
    /// so typing took seconds and memory hit the extension limit.
    private func retirePanelHost() {
        guard let hosting = hostingController else { return }
        hosting.willMove(toParent: nil)
        hosting.view.removeFromSuperview()
        hosting.removeFromParent()
        hostingController = nil
        hostingHeightConstraint = nil
        retiresPanelWhenHidden = false
        KeyboardLiveObjects.panels.decrement()
    }

    /// Called on the controller that is appearing: every other live controller gives
    /// up its panel now, or once it is off screen if it is still animating out.
    private func retireReplacedPanels() {
        for other in Self.liveControllers.allObjects where other !== self {
            if !other.isOnScreen {
                other.retirePanelHost()
            } else {
                other.retiresPanelWhenHidden = true
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // No proxy read is safe until the host state arrives (viewDidAppear or the first
        // text/selection callback); reading earlier crashes in documentIdentifier.
        hostDocumentAttachPending = true
        isOnScreen = true
        preparesNextPresentation = false
        retiresPanelWhenHidden = false
        if hostingController == nil { installPanelHost() }
        adoptPresentationShell()
        #if DEBUG
            DebugProbe.reportEnvironment(role: "keyboardExtension")
        #endif
        lifecycleGeometryEnabled = KeyboardLifecycleDiagnostics.isEnabled
        logPanelGeometry("willAppear")
        KeyboardLifecycleDiagnostics.emit(
            "viewWillAppear",
            [
                "controller": KeyboardLifecycleDiagnostics.identity(self),
                "session": KeyboardLifecycleDiagnostics.identity(session),
                "ready": session?.controller != nil ? "1" : "0",
                "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
            ])
        // Record warm resume and cold start separately: whether a ready engine existed on entry, and whether this
        // process has ever been ready. Diagnostics must not call either "resume".
        let hadReadyEngineAtEntry: Bool = {
            guard let session else { return false }
            if case .ready = session.phase { return session.controller != nil }
            return false
        }()
        let bootKind = KeyboardBootClassification(
            hadReadyEngineAtEntry: hadReadyEngineAtEntry,
            processHasEverBeenReady: Self.processHasEverBeenReady)
        appearanceBootClassification = bootKind
        appearanceEntryMonotonic = KeyboardLifecycleDiagnostics.monotonic
        restartedDuringAppearance = false
        // A fresh view controller subscribes to the process-owned session in
        // viewDidLoad. Combine immediately replays `.ready` before this appearance
        // is classified; record it as an already-ready engine, not a new cold boot.
        if hadReadyEngineAtEntry { Self.processHasEverBeenReady = true }
        KeyboardLifecycleDiagnostics.emit(
            "appearanceBootKind",
            [
                "controller": KeyboardLifecycleDiagnostics.identity(self),
                "boot": bootKind.rawValue,
                "cold": bootKind.isCold ? "1" : "0",
                "hadReadyEngine": hadReadyEngineAtEntry ? "1" : "0",
                "processHasEverBeenReady": Self.processHasEverBeenReady ? "1" : "0",
                "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
            ])
        // Key feedback: declare this process's capabilities (system click and haptics both need Full Access in a
        // keyboard extension; playInputClick without it has public reports of blocking the main thread) and refresh
        // the shared preferences so host-app changes apply. Warm-up happens in the panel's onAppear.
        // Each `hasFullAccess` read is a TCC IPC on the main thread.
        let fullAccess = hasFullAccess
        KeyboardFeedbackService.shared.setProcessCapabilities(
            keyClicksAllowed: fullAccess,
            hapticsAllowed: fullAccess)
        // Without Full Access the App Group is read-only: choices stay in memory for the session.
        KeyboardRecipeStore.canWriteSharedContainer = fullAccess
        KeyboardFeedbackService.shared.refreshPreferences()
        // Appearance (skin + candidate-area layout) is re-read via the `hostBindingTick` increment below
        // (the panel's `onChange(of: hostBindingTick)`); no separate notification, or each appearance would read twice.
        // Ownership transfer must precede any shared-composition clear. A previous
        // controller's callbacks may still be installed on the process-shared session;
        // clearing while it is still the active controller could synchronously re-enter
        // its writers and touch a `textDocumentProxy` that may already be invalid
        // (lock screen, host suspension). Assigning `self` first makes any such
        // re-entry fail its `activeController === self` guard.
        let previousController = Self.activeController
        let isSameLiveHost = previousController === self
        Self.activeController = self
        retireReplacedPanels()
        session.setHostVisibility(true)
        syncPresentationSizeClass()
        if let previousController, !isSameLiveHost {
            previousController.endPresentationGeometry()
            previousController.detachFromHostWithoutUsingProxy()
        }
        hostResumeTask?.cancel()
        // Issue the token before any await. A former controller's queued resume
        // cannot publish over this appearance or reopen a session after host loss.
        let appearanceBackend = session.backend
        let appearanceToken = appearanceBackend?.beginHostAppearance()
        hostAppearanceToken = appearanceToken
        // Rebinding a **valid** host must never reuse the previous host's librime
        // composition — disappear→appear, cross-app return, and keyboard dismissed then
        // raised all leave `activeController == nil` (the previous controller already
        // unbound during `viewWillDisappear`). The old implementation only cleared when
        // a *different* controller was still active, so those regular paths kept stale
        // composition that then followed the new host. Clearing is correct only here,
        // on the appear path with a live document, and after `Self.activeController = self`;
        // the teardown / host-loss paths never clear composition and never touch an
        // invalid proxy.
        let wasComposingOnRebind = session.controller?.snapshot.isComposing ?? false
        if wasComposingOnRebind && !isSameLiveHost {
            if session.backend?.hostInputIsReady != false {
                KeyboardLifecycleDiagnostics.emit(
                    "compositionClearedOnRebind",
                    [
                        "controller": KeyboardLifecycleDiagnostics.identity(self),
                        "wasComposing": "1",
                        "sameLiveHost": isSameLiveHost ? "1" : "0",
                    ])
                clearComposition()
            } else {
                KeyboardLifecycleDiagnostics.emit(
                    "compositionDiscardedWithSuspendedSession",
                    [
                        "controller": KeyboardLifecycleDiagnostics.identity(self)
                    ])
            }
        } else if wasComposingOnRebind {
            // Visible even when no clear is needed (same live host), so a real run can
            // tell "there was nothing to clear" apart from "the clear never ran".
            KeyboardLifecycleDiagnostics.emit(
                "compositionKeptOnRebind",
                [
                    "controller": KeyboardLifecycleDiagnostics.identity(self),
                    "sameLiveHost": isSameLiveHost ? "1" : "0",
                ])
        }
        // A resumed session is refreshed only when the queued work has completed.
        // The old snapshot is not evidence that the suspended engine is usable.
        // Explicit host-binding event, replacing the app-active notification that never fires in an extension;
        // drives the panel to re-read appearance/layout (unlock, cross-app return, new controller takeover).
        route.hostBindingTick &+= 1
        session.resetHostContext()
        fullAccessAtWillAppear = fullAccess
        refreshLayoutRegistry()
        refreshPublishedKeyboards()
        // A ready engine is never restarted just because the view reappeared: the refresh re-resolves only when
        // the shared record names another generation or selection. The record is readable without Full Access.
        refreshRouteOncePerAppearance()
        session.onDispatchCommit = { [weak self] text in
            guard let self, Self.activeController === self,
                self.session.backend?.hostInputIsReady != false
            else { return false }
            guard let document = self.writableDocument() else { return false }
            _ = self.observeMarkedEcho()
            _ = self.observeCancelledMarkedEcho()
            guard self.expectedContext == self.proxyContext else {
                // The engine already committed: this text is dropped. Logged so a host whose
                // context lags our own writes can be told apart from a real outside edit.
                KeyboardLifecycleDiagnostics.emit(
                    "commitRefused", ["marked": self.pendingMarked == nil ? "0" : "1"])
                self.checkDocumentOwnership()
                return false
            }
            if self.commitOverEchoedMarked(text, document: document) {
                self.session.quickInsert.recordCommitted(text)
                return true
            }
            self.cancelOwnedMarked()
            // The payload belongs to `document`; cancelling can find another one.
            guard self.stillOwns(document) else { return false }
            self.cancelledMarkedEcho = nil
            self.keyboardOnlyComposition = false
            self.writeProxy { self.textDocumentProxy.insertText(text) }
            self.session.quickInsert.recordCommitted(text)
            return true
        }
        session.hostContextIdentifier = { [weak self] in
            guard let self, Self.activeController === self else { return nil }
            return self.writableDocument()?.uuidString
        }
        session.asyncInsertionContext = { [weak self] in
            guard let self, Self.activeController === self else { return nil }
            return self.writableDocument().map { AnyHashable($0) }
        }
        session.onMarkedComposition = { [weak self] in self?.updateMarked($0) }
        session.remembersLayoutSwitch = { [weak self] in self?.switchOutlivesPresentation ?? true }
        session.onSelectionChanged = { [weak self] change in
            guard let self, Self.activeController === self else { return }
            self.selectionSaveGeneration &+= 1
            let requestGeneration = self.selectionSaveGeneration
            Self.layoutSaveGeneration &+= 1
            let layoutGeneration = Self.layoutSaveGeneration
            guard let backend = self.session.backend else { return }
            // Classify the running identity before touching the shared store. A session
            // on the bundled fallback (`prebuiltDirectory == nil`) is not a publication: its
            // layout is remembered by the session itself, and only a temporary switch away
            // from a publication is worth a notice. `saveSelection` keeps its own identity
            // check for direct callers.
            guard backend.prebuiltDirectory != nil else {
                if Self.rescuedRoute != nil { self.route.notice = self.temporaryBuiltinSelectionNotice }
                Self.diagnosticLogger.info(
                    """
                    selection save skipped: temporary runtime \
                    schema=\(change.schemaID, privacy: .public) layout=\(change.layout.rawValue, privacy: .public)
                    """)
                return
            }
            guard self.session.resourceSet?.publicationGeneration != nil else {
                self.route.notice = "已临时切换，但未能保存。下次呼出键盘时需重新选择。"
                Self.diagnosticLogger.error(
                    """
                    selection save skipped: missing publication identity \
                    schema=\(change.schemaID, privacy: .public) layout=\(change.layout.rawValue, privacy: .public)
                    """)
                return
            }
            // Read-only App Group: the running session already holds the choice.
            guard KeyboardRecipeStore.canWriteSharedContainer else {
                Self.diagnosticLogger.info("selection kept for this session: shared container is read-only")
                return
            }
            let runtimeIdentity = KeyboardRecipeStore.SelectionRuntimeIdentity.published
            let schemaID = change.schemaID
            let layout = change.layout
            let session: KeyboardPadSession = self.session
            Task { @MainActor [weak self, weak backend] in
                do {
                    let outcome = try await EngineOpQueue.async {
                        try KeyboardRecipeStore.saveSelection(
                            schemaID: schemaID, layout: layout,
                            runtimeIdentity: runtimeIdentity)
                    }
                    if outcome != .saved {
                        await Self.rememberSavedLayout(in: session, ifCurrent: layoutGeneration)
                    }
                    guard let self, let backend,
                        Self.activeController === self,
                        self.selectionSaveGeneration == requestGeneration,
                        self.session.backend === backend
                    else { return }
                    switch outcome {
                    case .saved:
                        Self.diagnosticLogger.info(
                            """
                            selection saved schema=\(schemaID, privacy: .public) layout=\(layout.rawValue, privacy: .public)
                            """)
                    case .notPublishedRuntime:
                        self.route.notice = self.inactivePublicationSelectionNotice
                        Self.diagnosticLogger.info(
                            """
                            selection save skipped: inactive publication \
                            schema=\(schemaID, privacy: .public) layout=\(layout.rawValue, privacy: .public)
                            """)
                    }
                } catch {
                    await Self.rememberSavedLayout(in: session, ifCurrent: layoutGeneration)
                    guard let self, let backend,
                        Self.activeController === self,
                        self.selectionSaveGeneration == requestGeneration,
                        self.session.backend === backend
                    else { return }
                    Self.diagnosticLogger.error(
                        "selection save failed: \(error.localizedDescription, privacy: .public)")
                    self.route.notice = "选择已在本次会话生效，但未能保存。下次呼出键盘时请重新选择。"
                }
            }
        }
        session.onReadDocumentContext = { [weak self] in
            guard let self, self.writableDocument() != nil,
                self.textDocumentProxy.selectedText?.isEmpty != false
            else { return nil }
            return self.textDocumentProxy.documentContextBeforeInput
        }
        session.onReplaceLiteralSuffix = { [weak self] expected, old, new in
            guard let self, self.writableDocument() != nil,
                self.textDocumentProxy.selectedText?.isEmpty != false,
                let before = self.textDocumentProxy.documentContextBeforeInput,
                String(before.suffix(T9PunctuationCycle.contextLimit)) == expected,
                before.hasSuffix(old)
            else { return false }
            self.writeProxy {
                for _ in old { self.textDocumentProxy.deleteBackward() }
                self.textDocumentProxy.insertText(new)
            }
            return true
        }
        session.onDeleteBackward = { [weak self] in
            guard let self, Self.activeController === self else { return }
            guard self.writableDocument() != nil else { return }
            self.writeProxy { self.textDocumentProxy.deleteBackward() }
        }
        session.onRefreshHostTraits = { [weak self] in self?.refreshHostTraits() }
        session.onMoveCursor = { [weak self] offset in
            guard let self, Self.activeController === self else { return }
            guard self.writableDocument() != nil else { return }
            self.writeProxy { self.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
        }
        session.onSwitchKeyboard = { [weak self] in
            guard let self, Self.activeController === self else { return }
            self.advanceToNextInputMode()
        }
        if let appearanceBackend, let appearanceToken,
            !appearanceBackend.hostInputIsReady
        {
            let resumeStarted = ProcessInfo.processInfo.systemUptime
            hostResumeTask = Task { @MainActor [weak self, weak appearanceBackend] in
                guard let self, let appearanceBackend,
                    Self.activeController === self,
                    self.hostAppearanceToken == appearanceToken,
                    self.session.backend === appearanceBackend
                else { return }
                let ready = await appearanceBackend.resumeSessionForHostAppearance(token: appearanceToken)
                guard Self.activeController === self,
                    self.hostAppearanceToken == appearanceToken,
                    self.session.backend === appearanceBackend
                else { return }
                self.hostResumeTask = nil
                let failed = appearanceBackend.inputUnavailableReason != nil
                if ready || failed {
                    KeyboardLifecycleDiagnostics.emit(
                        "engineSessionRestored",
                        [
                            "outcome": ready ? "ready" : "failed",
                            "ms": String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - resumeStarted) * 1000),
                        ])
                    self.session.controller?.session.refresh()
                    self.cancelOrphanedMarked()
                }
            }
        }
        Self.diagnosticLogger.debug(
            """
            session activated pid=\(KeyboardLifecycleDiagnostics.processIdentifier, privacy: .public) \
            controller=\(KeyboardLifecycleDiagnostics.identity(self), privacy: .public) \
            session=\(KeyboardLifecycleDiagnostics.identity(self.session), privacy: .public)
            """)
    }

    /// `needsInputModeSwitchKey` is answered by the proxy's controller state, so it
    /// waits for the host document attach like every other proxy read (device crash
    /// in `-[_UITextDocumentInterface _controllerState]` from `viewWillAppear`).
    /// Read once per appearance: in an extension UIKit logs "called before a connection
    /// was established" on every read (its forwarding interface is never set), though
    /// the controller state it returns is already current here.
    func syncInputModeSwitchKey() {
        guard !hostDocumentAttachPending, Self.activeController === self else { return }
        let needed = needsInputModeSwitchKey
        // The app validates new/imported layouts against this real requirement. Read once per
        // appearance; only a changed value is written, on a background queue.
        KeyboardSystemRequirements.recordNeedsInputModeSwitchKey(needed)
        if route.needsInputModeSwitchKey != needed { route.needsInputModeSwitchKey = needed }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hostDocumentAttachPending = false
        preparesNextPresentation = Self.activeController === self
        endPresentationGeometry()
        selectionSaveGeneration &+= 1
        hostAppearanceToken = nil
        hostResumeTask?.cancel()
        hostResumeTask = nil
        // The keyboard is about to hide: stop the learning-transfer poll (a transfer already running continues).
        stopLearningTransferPolling()
        routeRefreshedThisAppearance = false
        #if DEBUG
            stopTimingProbe()
        #endif
        // The panel loses its rendering host: in-process notification that cancels press/long-press gestures and ends
        // the Taptic session. Extension-safe replacement for `UIApplication.willResignActiveNotification`, which
        // never fires in a keyboard extension. Independent of the active guard: the own panel must stop gestures
        // even if this controller already yielded.
        panelHostLifetime.notifyDisappearance(name: .keyboardPanelHostWillDisappear)
        // Retire this controller's own tasks whether or not it is still active; only unbinding the shared
        // proxy/session is guarded (a new controller may already own the process-wide state).
        let isActive = Self.activeController === self
        KeyboardLifecycleDiagnostics.emit(
            "viewWillDisappear",
            [
                "controller": KeyboardLifecycleDiagnostics.identity(self),
                "active": isActive ? "1" : "0",
                "phase": phaseLabel(session?.phase),
                "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
            ])
        routeTask?.cancel()
        routeTask = nil
        layoutReadGate.invalidate()
        if isActive { unbindSharedProxy() }
        Self.diagnosticLogger.debug(
            """
            session deactivated pid=\(KeyboardLifecycleDiagnostics.processIdentifier, privacy: .public) \
            active=\(Self.activeController === self, privacy: .public)
            """)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        // A controller that claimed the keyboard in the meantime owns the next presentation.
        if preparesNextPresentation, Self.activeController == nil { prepareNextPresentationGeometry() }
        preparesNextPresentation = false
        if retiresPanelWhenHidden, Self.activeController !== self { retirePanelHost() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The keyboard window's system edge-gesture gate holds touch-down for keys in the
        // outer columns (the 9-key rails, Delete, Return) until it gives up on an edge
        // swipe, so those keys reacted late in fast typing. Keys must react at once.
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
        attachToHostDocument()
        checkDocumentOwnership()
        // A controller's initial trait can be unspecified until UIKit attaches
        // its input view to a host. Resolve once more while actually visible.
        syncSystemColorScheme(animated: true)
        syncPresentationSizeClass()
        // The live document/keyboard connection is now attached. Full Access
        // can resolve after willAppear; use its visible value for click feedback
        // rather than leaving this appearance pinned to an early false reading.
        let fullAccess = hasFullAccess
        KeyboardFeedbackService.shared.setProcessCapabilities(
            keyClicksAllowed: fullAccess,
            hapticsAllowed: fullAccess)
        KeyboardRecipeStore.canWriteSharedContainer = fullAccess
        // Lets the host app truthfully show "keyboard added with Full Access allowed".
        if fullAccess { KeyboardPresenceStamp.recordFullAccessSeen() }
        if let early = fullAccessAtWillAppear, early != fullAccess {
            KeyboardLifecycleDiagnostics.emit(
                "fullAccessResolvedAfterWillAppear",
                [
                    "early": early ? "1" : "0", "now": fullAccess ? "1" : "0",
                ])
            fullAccessAtWillAppear = fullAccess
        }
        refreshRouteOncePerAppearance()
        refreshHostTraits()
        KeyboardLifecycleDiagnostics.emit(
            "viewDidAppear",
            [
                "controller": KeyboardLifecycleDiagnostics.identity(self),
                "phase": phaseLabel(session?.phase),
                "route": session?.runningRouteKey?.diagnosticDescription ?? "-",
            ])
        KeyboardStallReport.appeared()
        pollFullAccess = fullAccess
        Self.diagnosticLogger.debug(
            """
            keyboard appeared hasFullAccess=\(self.pollFullAccess, privacy: .public) \
            needsInputModeSwitchKey=\(self.route.needsInputModeSwitchKey, privacy: .public)
            """)
        // The keyboard is now truly visible: start the learning-transfer poll (every 2 s, only while visible).
        hostInBackground = false
        startLearningTransferPolling()
        #if DEBUG
            startTimingProbeIfEnabled()
        #endif
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        // UIKit delivers these only once the host state has arrived, so the first one
        // may attach before viewDidAppear.
        attachToHostDocument()
        // A focus/field change (including switching into or out of a forced
        // light/dark field) is announced here; refresh so the keyboard surface
        // follows the newly focused field before the next key.
        checkDocumentOwnership()
        refreshHostTraits()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        attachToHostDocument()
        checkDocumentOwnership()
        refreshHostTraits()
        // Hosts that clear the field on send may report the change before `hasText`
        // reflects it; read once more on the next turn.
        scheduleHostTraitsRefresh()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        attachToHostDocument()
        checkDocumentOwnership()
        refreshHostTraits()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        logPanelGeometry("willLayout", deduplicate: true)
        // needsInputModeSwitchKey is synced at the host attach, not per layout:
        // every key re-lays out, and each read asked UIKit for the proxy state.
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncPresentedHeight()
        placeHostingView()
        logPanelGeometry("didLayout", deduplicate: true)
    }
}
