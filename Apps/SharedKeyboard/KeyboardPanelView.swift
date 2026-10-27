import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit

private struct KeyboardPanelHostLifetimeKey: EnvironmentKey {
    static var defaultValue: KeyboardPanelHostLifetime? { nil }
}

extension EnvironmentValues {
    var keyboardPanelHostLifetime: KeyboardPanelHostLifetime? {
        get { self[KeyboardPanelHostLifetimeKey.self] }
        set { self[KeyboardPanelHostLifetimeKey.self] = newValue }
    }
}

func rebindPanelHostObserver(
    _ observer: Any, selector: Selector,
    from old: KeyboardPanelHostLifetime?,
    to new: KeyboardPanelHostLifetime?
) {
    NotificationCenter.default.removeObserver(observer, name: .keyboardPanelHostWillDisappear, object: old)
    guard let new else { return }
    NotificationCenter.default.addObserver(
        observer, selector: selector,
        name: .keyboardPanelHostWillDisappear, object: new)
}

/// Shared by the host app and the extension; fixed 54pt key rows, the composition area grows upward, and the background extends into the safe area.
///
/// Keyboard pages (pure UI state; no engine state or user Chinese-layout choice changes):
///  - Letters: composition input for the current Chinese layout; in English mode letters commit directly (session semantics).
///  - 123: common digits and punctuation, all `.literal` -> `controller.insertLiteral`,
///    never entering the 9-key/shuangpin code tables; a key pressed mid-composition confirms the composition first (controller semantics, not duplicated in the UI).
///  - #+=: more symbols, also direct literal input.
public struct KeyboardPanelView: View {
    @ObservedObject var controller: KeyboardController
    @Environment(\.keyboardPanelHostLifetime) private var panelHostLifetime
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.keyboardAppearance) var appearance
    /// Shared key feedback (same service and switch as the host app; trigger points: handleKey/emitSelectionFeedback).
    var feedback: KeyboardFeedbackService { .shared }
    let onSelectLayout: ((KeyboardLayoutKind) -> Void)?
    /// Joint switch callback for an explicitly associated definition (input.schemaID): layout and bound schema are handed to the session together.
    let onSelectLayoutBound: ((KeyboardLayoutKind, String) -> Void)?
    let systemKeyboardSwitch: ((UIView, UIEvent) -> Void)?
    let keyAlternates: ((KeyCap) -> [KeyCap])?
    let layoutRegistry: LayoutRegistry?
    let selectedLayoutID: String?
    let allowsCursorMovement: Bool
    /// Host binding generation: incremented each time the extension gets a new host (`viewWillAppear`); stays 0 in the host app.
    /// Used to re-read host-dependent external state (quick symbols live in the App Group and may be rewritten by another process).
    let hostBindingTick: Int
    let shuangpinHints: ShuangpinHintSnapshot?
    let shuangpinHintRevision: UInt64
    let statusMessage: String?
    let onStatusDetails: (() -> Void)?
    let additionalTools: AnyView?
    /// Rows injected by the host into the "Insert" card (repeat last input, date/time).
    let insertTools: AnyView?
    private let asyncInsertionContext: (@MainActor () -> AnyHashable?)?
    private let pasteLiteral: (@MainActor (String) -> Bool)?
    /// Injected by the extension; nil in the app's own trial area (there the app is already open).
    let openHostApp: ((URL, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Extension-only real dismissal for the wide-screen header button. Nil in the app trial.
    let dismissKeyboard: (() -> Void)?
    @State private var quickPasteError: String?
    @State private var quickPasteSlot = QuickPasteSlotLease()
    /// Candidate-area presentation config (the third user-customizable layer: the candidate area beyond key layout and skin).
    /// The stored property is named apart from the same-named candidate bar view.
    private let candidateBarDefinition: CandidateBarDefinition
    @State private var popupSurface = UIView()
    @State var showsUtilitiesMenu = false
    @State var showsSymbolLibrary = false
    /// Set only when the system refused the hop to the app; nothing is claimed on success.
    @State var hostAppUnavailable = false
    @AccessibilityFocusState var utilitiesTitleFocused: Bool
    /// Reading-row height granted by the host (the host is the sole height owner; the panel only lays out to the granted value).
    let readingRowReserved: Bool
    private let candidateAreaReserved: Bool
    /// Key-row height chosen by the Host (standard size-class height, or the
    /// height that fills a viewport UIKit kept at an earlier budget). nil = size class.
    private let keyHeightOverride: CGFloat?
    /// Candidate-area height and blank top the Host fitted into the shared shell
    /// (`KeyboardPanelGeometry.fit`); nil/0 = the configured candidate budget.
    private let candidateBandHeight: CGFloat?
    private let topSlack: CGFloat
    private let readingRowBandHeight: CGFloat?
    /// Height cut off the top of the topmost band (`KeyboardPanelFit.topTrim`): that band
    /// draws its content this much taller, bottom-aligned, so only blank space goes.
    private let topTrim: CGFloat
    /// Reports eligibility facts (physical definition content) to the host, not heights.
    let onReadingRowReport: ((CandidateReadingRowReport) -> Void)?
    @State var page: KeyboardPage = .letters
    /// Panel-local symbol language chosen by a language/symbol key. It overrides the selected
    /// page's default and the controller punctuation state for this keyboard session only; the
    /// engine input mode and the current composition are never touched.
    @State var symbolMarksOverride: KeyboardNumericMarks?
    /// The symbol page's open category; every visit starts on 常用.
    @State var phoneSymbolCategoryID = SymbolPageTable.commonCategoryID
    /// 锁定 on the symbol page: stay there after a symbol. Session-only, never stored.
    @State var symbolPageLocked = false
    /// The user's choice of the categorized #+= page (`KeyboardSymbolPagePreferences`),
    /// re-read on each presentation.
    @State var prefersCategorySymbolPage = false
    /// Whether a symbol has been entered on the current number/symbol page (used to return to letters after space); reset on every page change.
    @State private var typedOnSymbolPage = false
    @StateObject var quickSymbols = T9QuickSymbolModel()
    /// The symbol library behind the 9-key symbol page's themed tabs and recents.
    /// Read only when that page opens; the page inserts through `handleKey` and
    /// only reports uses, so the model's own insert exit is never called.
    @StateObject var symbolLibrary = SymbolLibraryModel(onInsert: { _ in false }, loadsImmediately: false)
    /// Symbols typed on the open 9-key symbol page, recorded as recents when it closes.
    @State var pendingSymbolUses: [String] = []
    @State var showsAllCandidates = false
    @State var localLayoutID: String?
    /// Layout/scheme switch hint: consumes only the real-switch event token from controller.successfulChange,
    /// shows a brief sublabel that fades out; number/symbol page switches and view rebuilds do not trigger it.
    @State var layoutHintToken: UUID?
    @State var layoutHintName: String?
    /// Feedback lifecycle session token (returned by prepare; handed back to end(token:) on disappear).
    @State private var feedbackLifecycleToken = 0
    /// Last settled rail/reading-row choices, shown inert while the next key's
    /// engine queries are outstanding (see `displayedT9RailChoices`). Rail taps
    /// are validated after settlement; the separate reading row remains inert. A reference
    /// box on purpose: remembering them must not invalidate the panel (a `@State`
    /// write from `onChange` cost one extra full render per key); they are only
    /// read on the render the next key's controller update already causes.
    @State private var choiceHold = HeldReadingChoices()
    @State var keyAreaGeneration = 0
    /// A symbol page entered with a live composition keeps its candidate row for
    /// the whole visit (see `readingRowReport`).
    @State private var symbolPageKeepsCandidates = false
    var heldT9RailChoices: T9RailChoices? { choiceHold.rail }
    var heldReadingRowContent: CandidateReadingRowContent? { choiceHold.row }

    @State var definitionMemo = DefinitionResolutionMemo()
    @State var pageMemo = PageResolutionMemo()
    /// The real key-area width, recorded by the root GeometryReader before the panel body builds.
    @State var widthBox = KeyboardPanelWidthBox()
    /// Per-physical wide-screen dock, read at presentation/layout changes (never per key).
    @State private var contentDock: KeyboardContentDock

    /// Observation coordinator for definition changes (pure value): distinguishes "the panel's own explicit selection/reconciliation" from
    /// "external registry content replacement". The explicit path registers the expected (from, to) before acting; the observation callback
    /// consumes only that exact match and treats everything else as a real change.
    @State var definitionObservation = DefinitionObservationGate()

    public init(
        controller: KeyboardController, onSelectLayout: ((KeyboardLayoutKind) -> Void)? = nil,
        onSelectLayoutBound: ((KeyboardLayoutKind, String) -> Void)? = nil,
        systemKeyboardSwitch: ((UIView, UIEvent) -> Void)? = nil,
        keyAlternates: ((KeyCap) -> [KeyCap])? = nil,
        layoutRegistry: LayoutRegistry? = nil, selectedLayoutID: String? = nil,
        allowsCursorMovement: Bool = false, statusMessage: String? = nil,
        onStatusDetails: (() -> Void)? = nil, additionalTools: AnyView? = nil,
        insertTools: AnyView? = nil,
        asyncInsertionContext: (@MainActor () -> AnyHashable?)? = nil,
        pasteLiteral: (@MainActor (String) -> Bool)? = nil,
        openHostApp: ((URL, @escaping @MainActor (Bool) -> Void) -> Void)? = nil,
        dismissKeyboard: (() -> Void)? = nil,
        candidateBar candidateBarDefinition: CandidateBarDefinition = .systemDefault,
        hostBindingTick: Int = 0,
        shuangpinHints: ShuangpinHintSnapshot? = nil, shuangpinHintRevision: UInt64 = 0,
        readingRowReserved: Bool = false,
        candidateAreaReserved: Bool = true,
        keyHeight keyHeightOverride: CGFloat? = nil,
        candidateBandHeight: CGFloat? = nil,
        topSlack: CGFloat = 0,
        readingRowBandHeight: CGFloat? = nil,
        topTrim: CGFloat = 0,
        onReadingRowReport: ((CandidateReadingRowReport) -> Void)? = nil
    ) {
        self.controller = controller
        self.keyHeightOverride = keyHeightOverride
        self.candidateBandHeight = candidateBandHeight
        self.topSlack = topSlack
        self.readingRowBandHeight = readingRowBandHeight
        self.topTrim = topTrim
        self.readingRowReserved = readingRowReserved
        self.candidateAreaReserved = candidateAreaReserved
        self.onReadingRowReport = onReadingRowReport
        self.onSelectLayout = onSelectLayout
        self.onSelectLayoutBound = onSelectLayoutBound
        self.systemKeyboardSwitch = systemKeyboardSwitch
        self.keyAlternates = keyAlternates
        self.layoutRegistry = layoutRegistry
        self.selectedLayoutID = selectedLayoutID
        self.allowsCursorMovement = allowsCursorMovement
        self.hostBindingTick = hostBindingTick
        self.shuangpinHints = shuangpinHints
        self.shuangpinHintRevision = shuangpinHintRevision
        self.statusMessage = statusMessage
        self.onStatusDetails = onStatusDetails
        self.additionalTools = additionalTools
        self.insertTools = insertTools
        self.asyncInsertionContext = asyncInsertionContext
        self.pasteLiteral = pasteLiteral
        self.openHostApp = openHostApp
        self.dismissKeyboard = dismissKeyboard
        self.candidateBarDefinition = candidateBarDefinition
        // The host rebuilds this value on every pass; only the first one seeds the state. The
        // cache reads the shared defaults once per layout and process, so the first frame is
        // already docked without a read per host pass.
        _contentDock = State(initialValue: ContentDockCache.dock(for: controller.layout))
    }

    public var body: some View {
        GeometryReader { geometry in
            let rawWidth = geometry.size.width
            let isWideSurface = rawWidth > KeyboardSurfaceWidth.phoneMaximum
            let widePlan = KeyboardWideContentPolicy.plan(
                panelWidth: Double(rawWidth),
                maximumContentWidth: wideMaximumContentWidth(rawWidth: Double(rawWidth)),
                dock: contentDock)
            // A definition without a candidate area has no header to host the dismiss entry.
            // Wide-only fallback: reserve a real 44pt right rail outside the keys. Standard
            // pages with a header keep their full content width and use the header entry.
            let needsHeaderlessToolRail =
                isWideSurface && layoutPlan.headerHeight == 0 && dismissKeyboard != nil
            let availableWidth =
                needsHeaderlessToolRail ? max(0, rawWidth - 44) : rawWidth
            let baseContentWidth = widePlan.active ? CGFloat(widePlan.contentWidth) : availableWidth
            let contentWidth =
                needsHeaderlessToolRail ? min(baseContentWidth, availableWidth) : baseContentWidth
            let contentIsDocked = widePlan.active || needsHeaderlessToolRail
            let wideSignature = WideContentSignature(
                isWideSurface: isWideSurface, active: contentIsDocked,
                headerlessToolRail: needsHeaderlessToolRail, dock: contentDock)
            let _ = widthBox.record(contentWidth: contentWidth - 8, mainSplitWidth: rawWidth - 8)
            panelBody(isWide: isWideSurface)
                .frame(width: contentWidth, alignment: .topLeading)
                .disabled(showsUtilitiesMenu || showsSymbolLibrary)
                .accessibilityHidden(showsUtilitiesMenu || showsSymbolLibrary)
                // Hidden rather than painted over, so the covering panels can sit on the
                // keyboard's own surface instead of a second opaque sheet.
                .opacity(showsUtilitiesMenu || showsSymbolLibrary ? 0 : 1)
                .overlay {
                    // Overlays are pinned to the panel's own height. Without this the overlay
                    // grows to its intrinsic content height, so its inner ScrollView believes
                    // it already fits and never scrolls — the list is then merely clipped by
                    // the keyboard host and the last entries (e.g. the 9-key layout) become unreachable.
                    // Pinning keeps the menu a real scrollable surface inside the real panel,
                    // and deliberately adds no extra fixed bottom bar.
                    // Each carries the key area's invisible hit surface: iOS drops touches on
                    // fully transparent pixels of a keyboard extension, the panel beneath is at
                    // opacity 0, so on device a drag starting between cells never reached the scroll view.
                    if showsSymbolLibrary {
                        // A new controller identity (session reconnect) rebuilds the model wholesale, so no stale onInsert callback survives.
                        SymbolLibraryPanel(controller: controller) { showsSymbolLibrary = false }
                            .id(ObjectIdentifier(controller))
                            .frame(width: contentWidth, height: geometry.size.height)
                            .background(Color.black.opacity(0.001))
                            .clipped()
                    } else if showsUtilitiesMenu {
                        utilitiesPanel
                            .frame(width: contentWidth, height: geometry.size.height)
                            .background(Color.black.opacity(0.001))
                            .clipped()
                    }
                }
                // The covering overlay (tools / symbol library) swaps in immediately: no
                // outgoing menu is retained over the next immediately usable key, and this
                // is not a transition owner (the key-area cue owns page/language).
                //
                // The panel is **not** uniformly opaque, menus included. Under the
                // system-default appearance the product owns no keyboard surface: iOS
                // supplies it, its rounded corners and the bottom input-mode bar. Painting
                // our own panel here would be a second, disjoint background, which the
                // Apple contract forbids. A user-authored skin keeps painting its own
                // authored surface (see `KeyboardAppearance.panelBackground` / `drawsOwnSurface`).
                .background(appearance.panelBackground.ignoresSafeArea(edges: .bottom))
                // The blank side margins of a docked keyboard are not part of the key
                // surface: touches there must not route to an edge key.
                .background { WideContentFrameReporter(active: contentIsDocked) }
                .onChange(of: wideSignature) { _, _ in
                    // Docking moves every key under any retained touch; a plain width change
                    // only needs the route cleared, which the host does on every resize.
                    keyAreaGeneration &+= 1
                    choiceHold.rail = nil
                    choiceHold.row = nil
                    KeyboardRoutedTouch.clear()
                }
                .frame(width: availableWidth, alignment: wideDockAlignment)
                .frame(width: rawWidth, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    if needsHeaderlessToolRail { headerlessWideToolRail }
                }
        }
    }

    /// The main split comes from the same active definition the panel draws; page splits never
    /// change this host-level width.
    private func wideMaximumContentWidth(rawWidth: Double) -> Double? {
        KeyboardPanelRules.wideMaximumContentWidth(
            rawWidth: rawWidth, mainSplit: activeDefinition?.split, layout: controller.layout)
    }

    private var wideDockAlignment: Alignment {
        switch contentDock {
        case .left: return .topLeading
        case .center: return .top
        case .right: return .topTrailing
        }
    }

    private func finishPanelLifecycle() {
        if let panelHostLifetime {
            panelHostLifetime.cancelSharedSelection { controller.cancelRailSelection() }
        } else {
            // App-owned panels do not share an extension process session.
            controller.cancelRailSelection()
        }
        feedback.end(token: feedbackLifecycleToken)
    }

    /// Headerless pages have no band to host the dismiss entry. The fallback is a real
    /// 44pt strip outside the key content, so it never covers the first key row or changes
    /// the footer; those rare pages lose the same width from their usable key area.
    private var headerlessWideToolRail: some View {
        VStack(spacing: 0) {
            if let dismissKeyboard {
                Button(action: dismissKeyboard) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(appearance.font(appearance.controlIconSize))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(KeyboardPressStyle())
                .contentShape(Rectangle())
                .accessibilityLabel("收起键盘")
                .accessibilityIdentifier("keyboard.wideDismiss")
            }
            Spacer(minLength: 0)
        }
        .frame(width: 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// With a separate reading row above, the word row's content sits a little
    /// above center so the two text lines read as one group instead of being split
    /// by both rows' centering margins (hit areas stay full height).
    var candidateContentLift: Double {
        layoutPlan.readingRowHeight > 0 ? CandidateReadingRowPolicy.candidateLift : 0
    }

    /// Chinese mode: a single fixed candidate budget (set by configured height and skin font size; system default 40pt).
    /// Composition feedback is driven by `controller.keyboardCompositionFallback`:
    ///  - non-nil (inline off / not accepted by the host): a compact whole-composition text sits in the reserved right edge within the budget,
    ///    sharing it with the candidate row (explicit width cap; never covers candidate text, adds no row or height);
    ///  - nil (inline accepted): the host's marked text carries it; the keyboard does not repeat it.
    /// Idle / composing / after selection / error hints all share one total height, so geometry is stable.
    var headerHeight: CGFloat {
        panelGeometry.headerHeight
    }
    /// The candidate row fills the whole band: the spare height the shell gives it
    /// (`KeyboardPanelGeometry.fit`) is touch budget, and the centered text sits a
    /// little above the keys instead of on their edge.
    var candidateRowHeight: CGFloat { headerHeight + headerTopTrim }
    /// The ABC suggestion row, seated at the bottom of the candidate band so its words sit where
    /// the Chinese candidates do.
    var englishSuggestionRowHeight: CGFloat {
        min(
            candidateRowHeight,
            CGFloat(
                2
                    * KeyboardPanelGeometry.candidateTextCentreAboveKeys(
                        candidateHeight: candidateBarDefinition.collapsed.height,
                        candidateSize: appearance.skin.typography.candidateSize)))
    }
    /// `topTrim` lands on the reading row when there is one, else on the candidate row.
    var headerTopTrim: CGFloat { layoutPlan.readingRowHeight > 0 ? 0 : topTrim }

    // MARK: Candidate area presentation (CandidateKit default renderer; skin injected via environment, no separate palette)

    /// Renderer-agnostic state derived from the real snapshot; select always carries the real candidate.index.
    private var candidateState: CandidatePresentationState {
        CandidatePresentationState(snapshot: controller.snapshot, isEnglishMode: controller.isEnglishMode)
    }

    private var candidateTypography: CandidateTypography {
        CandidateTypography(
            candidateSize: appearance.skin.typography.candidateSize,
            secondarySize: appearance.skin.typography.secondarySize)
    }

    @ViewBuilder
    func candidateRendererView(expanded: Bool) -> some View {
        // All candidate-area actions go through this sink: select/paging are real input-session actions and emit
        // one selection feedback only once the action took effect (no-ops give none); expand/collapse are pure UI state
        // and give none (highlight is managed inside the renderer, also without feedback).
        let live = CandidateAreaActionSink.live(
            controller: controller,
            onExpand: { showsAllCandidates = true },
            onCollapse: { showsAllCandidates = false })
        // Both compact reading surfaces (the phone rail and the separate 14-key
        // reading row) filter the same real candidates; the filter only exists
        // on a verified compact structure.
        let filteringReadings =
            controller.usesAmbiguityPickerUI
            && controller.readingFilter.isFiltering && controller.snapshot.pageSize > 0
        let sink = CandidateAreaActionSink { action in
            switch action {
            case .loadMore where filteringReadings:
                controller.loadMoreReadings()
            case .select, .selectOnPage, .pageForward, .pageBackward, .loadMore:
                selectionFeedbackAfterEffect { live.perform(action) }
            case .expand, .collapse, .highlightNext, .highlightPrevious:
                live.perform(action)
            }
        }
        let readingEntries: [BrowserCandidate]? =
            filteringReadings
            ? controller.readingFilter.matches.map { entry in
                let pageSize = controller.snapshot.pageSize
                let slot = entry.index % pageSize
                let readings = entry.readingPaths?.map { $0.joined(separator: " ") }.joined(separator: " / ") ?? ""
                let annotation = [entry.comment, readings].filter { !$0.isEmpty }.joined(separator: " · ")
                return BrowserCandidate(
                    pageIndex: entry.index / pageSize, pageLocalIndex: slot,
                    candidate: Candidate(
                        index: slot, text: entry.text,
                        comment: annotation, selectKey: entry.selectKey,
                        selectLabel: entry.selectLabel))
            } : nil
        let context = CandidateAreaContext(
            state: candidateState,
            bar: candidateBarDefinition,
            actions: sink,
            typography: candidateTypography,
            browser: controller.candidateBrowser,
            isExpanded: showsAllCandidates,
            visibleEntries: readingEntries,
            visibleHasMore: filteringReadings ? controller.readingFilter.hasMore : nil,
            visibleFrontier: filteringReadings ? controller.readingFilter.nextIndex : nil,
            contentLift: candidateContentLift)
        if expanded {
            CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                .makeExpanded(context)
        } else {
            CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                .makeCollapsed(context)
        }
    }
    var mainRowCount: Int {
        if let pageDefinition { return max(1, pageDefinition.rows.count) }
        return usesConfiguredLayout && !usesStandardQwerty ? max(1, definitionMainRows.count) : 3
    }
    var keyHeight: CGFloat {
        keyHeightOverride ?? (verticalSizeClass == .compact ? 44 : 54)
    }
    var mainAreaHeight: CGFloat {
        panelGeometry.mainAreaHeight
    }
    /// Panel geometry: `headerHeight` is the configured fixed candidate budget (system default 40pt, grows with font size as content needs).
    private var panelGeometry: KeyboardPanelGeometry {
        KeyboardPanelGeometry(
            candidateHeight: candidateBarDefinition.collapsed.height,
            keyHeight: keyHeight, selectedMainRows: max(1, definitionMainRows.count),
            readingRowReserved: readingRowReserved,
            candidateSize: appearance.skin.typography.candidateSize,
            compactReadingRow: verticalSizeClass == .compact,
            fittedHeaderHeight: candidateBandHeight.map(Double.init),
            topSlack: Double(topSlack),
            fittedReadingRowHeight: readingRowBandHeight.map(Double.init))
    }

    /// Physical eligibility of the reading row depends only on definition content; height is granted separately by the host from the report.
    var readingRowEligibleNow: Bool { definitionFacts.readingRowEligible }

    /// ABC and 123/#+= are shared pages, not part of the Chinese definition: ABC always
    /// keeps one word-suggestion row (engine completions, or built-in next-word
    /// guesses), symbol pages keep candidates only for a live composition.
    /// Neither inherits a compact layout's reading row.
    var readingRowReport: CandidateReadingRowReport {
        let definitionPage = page == .letters && !controller.isEnglishMode
        return CandidateReadingRowReport(
            eligible: definitionPage && readingRowEligibleNow,
            definitionID: activeDefinition?.id,
            resolvedFromRegistry: layoutRegistry != nil,
            candidateAreaRequired: definitionPage
                ? definitionFacts.candidateAreaRequired
                : page == .letters || symbolPageKeepsCandidates,
            pageOverride: !definitionPage)
    }

    /// The Host grants this fixed capability after the layout source resolves.
    /// Composition/candidate changes only replace content inside the reserved surface.
    var layoutPlan: KeyboardPanelLayoutPlan {
        panelGeometry.layoutPlan(showsHeader: candidateAreaReserved)
    }

    /// The single pure policy for the header's **content kind** (shared by production and tests).
    /// Input assembly comes solely from `KeyboardController.headerVisibilityInput`; non-phone compact
    /// disambiguation shows only in the standalone reading row, and 9-key readings only in the left rail. The candidate row takes no reading width.
    /// Only real content (candidates, status, disambiguation, whole-composition fallback when the host's marked text is unavailable, 9-key candidate
    /// reading filter) occupies the candidate/status band; pure idle draws nothing (no fake caption bar).
    /// It never hides any real state.
    var headerShowsRealContent: Bool {
        CandidateHeaderVisibility.showsHeader(
            controller.headerVisibilityInput(
                statusMessage: statusMessage,
                hasAmbiguitySlot: false))
            || (!controller.isEnglishMode && controller.snapshot.isComposing
                && controller.snapshot.candidates.isEmpty)
            || t9QuickSymbolsError != nil
    }

    /// A real persistence error uses the already-reserved header, not a new
    /// row in the 9-key punctuation/reading rail or a taller keyboard shell.
    var t9QuickSymbolsError: String? {
        guard usesStandardT9, isBuiltinPhonePad, !controller.snapshot.isComposing else { return nil }
        return quickSymbols.error
    }

    // MARK: Key feedback (real trigger path: one feedback per action that actually took effect)

    /// Single exit for key actions: runs `controller.handle`, then emits one key feedback only if the action
    /// took effect (the input-effect token changed); no-ops and failures
    /// (engine error, unconfirmed composition, stale candidate index, ...) give none.
    /// The globe (.switchKeyboard) is the exception: the system owns sound/haptics for input-method switching,
    /// and a second one would double up, so it is forwarded silently.
    /// Literal keys skip the token comparison: confirming a composition may commit partially and still keep it,
    /// so a snapshot/count change does not prove this literal succeeded; only the real dispatch result of `insertLiteral`
    /// counts (false = partial commit / no valid host exit / input disabled, no feedback).
    /// Returns whether a literal was dispatched; other actions return false.
    @discardableResult
    func handleKey(_ action: KeyAction, emitFeedback: Bool = true) -> Bool {
        guard action != .switchKeyboard else {
            controller.handle(action)
            return false
        }
        if case .literal(let text) = action {
            guard controller.insertLiteral(text) else { return false }
            feedback.keyPressed()
            if page != .letters { typedOnSymbolPage = true }
            return true
        }
        // As on the system keyboard: pressing space after entering a symbol on the number/symbol page returns to the letters page.
        if action == .space, page != .letters, typedOnSymbolPage, controller.hostPreferredInput != .numeric {
            page = .letters
            typedOnSymbolPage = false
        }
        if !emitFeedback {
            controller.handle(action)
            return false
        }
        let before = controller.inputEffectToken()
        controller.handle(action)
        if KeyboardController.InputEffectToken.isEffect(before: before, after: controller.inputEffectToken()) {
            feedback.keyPressed()
        }
        return false
    }

    /// List/candidate selections (commit candidate, paging, layout list, tools menu item): selection haptic.
    func emitSelectionFeedback() { feedback.selectionChanged() }

    /// Panel-local supplement to the effect check: switching to a different DIY definition of the same builtin kind changes
    /// key positions but not the engine layout; fold it into the effect comparison.
    private var localEffectIdentity: String? { activeDefinition?.id }

    /// Runs a real session action that may fail (candidate select/paging/layout select) and emits one
    /// selection feedback only after it took effect; no-ops (stale candidate index, paging past the edge, reselecting the same item) give none.
    func selectionFeedbackAfterEffect(_ perform: () -> Void) {
        let before = controller.inputEffectToken()
        let definitionBefore = localEffectIdentity
        let readingBefore = controller.readingFilter.prefix
        perform()
        let changed =
            KeyboardController.InputEffectToken.isEffect(before: before, after: controller.inputEffectToken())
            || localEffectIdentity != definitionBefore
            || controller.readingFilter.prefix != readingBefore
        if changed { emitSelectionFeedback() }
    }

    /// Runs a key-type control action that may fail (CN/EN toggle, Shift, composition confirm) and emits one
    /// key feedback only after it took effect; none when a failed confirm leaves state unchanged.
    func keyFeedbackAfterEffect(_ perform: () -> Void) {
        let before = controller.inputEffectToken()
        let definitionBefore = localEffectIdentity
        perform()
        let changed =
            KeyboardController.InputEffectToken.isEffect(before: before, after: controller.inputEffectToken())
            || localEffectIdentity != definitionBefore
        if changed { feedback.keyPressed() }
    }

    /// Key-type pure UI actions (page switch and other control keys that cannot fail): key haptic (feedback on touch).
    func emitKeyFeedback() { feedback.keyPressed() }

    private var quickPasteIdleInput: QuickPasteIdleInput {
        QuickPasteIdleInput(
            isComposing: controller.snapshot.isComposing,
            hasPrediction: controller.snapshot.isPrediction,
            hasCandidates: !controller.snapshot.candidates.isEmpty
                || !controller.candidateBrowser.isEmpty || controller.candidateBrowser.hasIncompletePage
                || controller.candidateBrowser.needsEarlier,
            hasEnglishSuggestions: !controller.englishSuggestions.isEmpty,
            hasActiveEnglishInput: controller.hasActiveEnglishInput,
            hasStatus: statusMessage != nil || t9QuickSymbolsError != nil
                || controller.inputError != nil || controller.inputUnavailableReason != nil,
            hasCompositionFallback: controller.keyboardCompositionFallback != nil,
            hasReadingContent: controller.ambiguityPicker.showsPicker || controller.readingFilter.isFiltering,
            hasPendingQueries: controller.readingQueryPending || controller.ambiguityQueryPending,
            isExpanded: showsAllCandidates,
            isCovered: showsUtilitiesMenu || showsSymbolLibrary)
    }

    private func panelSurface(isWide: Bool) -> some View {
        let plan = layoutPlan
        let showsWideDismiss = isWide && dismissKeyboard != nil
        quickPasteSlot.observe(
            identity: ObjectIdentifier(controller),
            changes:
                controller.objectWillChange.merge(with: quickSymbols.objectWillChange).eraseToAnyPublisher())
        let idle = quickPasteIdleInput.allowsPaste
        quickPasteSlot.updateEligibility(idle && quickPasteError == nil && plan.headerHeight >= 44)
        return VStack(spacing: 0) {
            // While composing, the full original budget for candidates, readings, status and fallback badge is kept;
            // paste shows in the blank area only when strictly idle, without splitting candidate width.
            // Height belongs solely to `CandidateHeaderSurface` (`surfaceHeight == effectiveHeight`).
            // The standalone reading row is granted only for the selected definition and sits above the candidate row; phone structures use the left rail instead.
            // The topmost band lays out `topTrim` taller and hangs off the top edge: the cut
            // only removes blank space above its text (`KeyboardPanelFit.topTrim`).
            if plan.readingRowHeight > 0 {
                readingRow(height: plan.readingRowHeight + Double(topTrim))
                    .frame(height: CGFloat(plan.readingRowHeight), alignment: .bottom)
            }
            if plan.headerHeight > 0 {
                compositionArea
                    .padding(.trailing, showsWideDismiss ? 44 : 0)
                    .overlay(alignment: .trailing) {
                        if idle, plan.headerHeight >= 44 {
                            if let error = quickPasteError {
                                HStack(spacing: 8) {
                                    Text(error).font(appearance.font(min(appearance.skin.typography.secondarySize, 18)))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        quickPasteError = nil
                                    } label: {
                                        Image(systemName: "xmark").frame(width: 44, height: 44)
                                    }
                                    .accessibilityLabel("关闭粘贴提示")
                                }
                                .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                                .padding(.leading, 8)
                                .padding(.trailing, showsWideDismiss ? 44 : 0)
                                .frame(height: plan.headerHeight)
                            } else if let asyncInsertionContext {
                                QuickPasteView(
                                    inputContext: {
                                        guard quickPasteSlot.isCurrent(identity: ObjectIdentifier(controller)),
                                            quickPasteIdleInput.allowsPaste
                                        else { return nil }
                                        return quickPasteSlot.context(host: asyncInsertionContext())
                                    },
                                    insertLiteral: { [weak controller] text in
                                        guard let controller,
                                            quickPasteSlot.isCurrent(identity: ObjectIdentifier(controller)),
                                            quickPasteIdleInput.allowsPaste
                                        else { return false }
                                        if let pasteLiteral { return pasteLiteral(text) }
                                        return controller.insertExternalLiteral(text)
                                    }, foreground: appearance.text(on: "panel", secondary: true),
                                    onError: { error in
                                        guard quickPasteSlot.isCurrent(identity: ObjectIdentifier(controller)),
                                            quickPasteIdleInput.allowsPaste, let error
                                        else { return }
                                        quickPasteError = error
                                    },
                                    didDispatchUserPaste: { text in
                                        Task { @MainActor in
                                            let note = await SharedQuickContentStorage.recordExplicitPaste(text)
                                            guard quickPasteSlot.isCurrent(identity: ObjectIdentifier(controller)),
                                                quickPasteIdleInput.allowsPaste, let note
                                            else { return }
                                            quickPasteError = note
                                        }
                                    }
                                )
                                .id("\(ObjectIdentifier(controller))-\(hostBindingTick)")
                                .frame(width: 44, height: plan.headerHeight)
                                .padding(.trailing, showsWideDismiss ? 56 : 12)
                            }
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if showsWideDismiss, let dismissKeyboard {
                            Button(action: dismissKeyboard) {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(appearance.font(appearance.controlIconSize))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(KeyboardPressStyle())
                            .frame(width: 44, height: min(44, CGFloat(plan.headerHeight)))
                            .contentShape(Rectangle())
                            .accessibilityLabel("收起键盘")
                            .accessibilityIdentifier("keyboard.wideDismiss")
                        }
                    }
                    .frame(height: CGFloat(plan.headerHeight), alignment: .bottom)
            }
            VStack(spacing: 4) {
                if let pageDefinition, pageDefinition.chrome != nil {
                    // Authored page: rows, rails and footer all come from data, drawn by the same
                    // shell the preview uses. The gate takes the live return/clear-input state.
                    KeyAreaRenderGate(
                        token: keyAreaRenderToken(phone: nil, readsComposition: pageDefinitionReadsComposition)
                    ) {
                        authoredChromePage(pageDefinition)
                    }
                    .equatable()
                    .frame(
                        height: mainAreaHeight + KeyboardPanelGeometry.controlSpacing + keyHeight,
                        alignment: .top)
                } else if pageDefinition == nil && usesPhoneDefinition && page == .numeric {
                    phoneSymbolKeypad
                } else if showsCategorySymbolPage {
                    phoneCategorySymbolKeypad
                } else if usesStandardT9 {
                    standardT9Keypad
                } else {
                    VStack(spacing: 4) {
                        if showsAllCandidates && !controller.snapshot.candidates.isEmpty {
                            expandedCandidates
                        } else if CGFloat(mainRowCount) * (keyHeight + 4) - 4 > mainAreaHeight + 1 {
                            ScrollView {
                                gatedKeyRows
                            }
                            .sharpCandidateScrollEdges()
                            .frame(height: mainAreaHeight)
                        } else {
                            gatedKeyRows
                        }
                    }
                    .frame(height: mainAreaHeight, alignment: .top)
                    if usesConfiguredLayout && !usesStandardT9 && !definitionFacts.isBundledControlRowPolicy {
                        // Author layout bar: the declared control row is rendered with its actions,
                        // order, widths and long-press menus; shortcut injections are de-duplicated
                        // against entries the author already declared.
                        KeyAreaRenderGate(token: keyAreaRenderToken) { layoutUtilityBar }.equatable()
                    } else {
                        KeyAreaRenderGate(token: keyAreaRenderToken) { controlRow }.equatable()
                    }
                }
            }
            // Under the default skin the key area is transparent (system keyboard surface shows through); iOS does not deliver touches in fully transparent
            // areas to a keyboard extension, so taps in the gaps between keys would be lost entirely. Lay down an invisible hit surface, and the root input view
            // (FeedbackInputView.hitTest) hands gap touches to the adjacent key. It covers the key area only, not the root view.
            .id(keyAreaGeneration)
            .background(Color.black.opacity(0.001))
            // Switch pages in place. A keyframeAnimator/visualEffect around this
            // entire subtree also wrapped UIKit key views; even a 2pt settle
            // introduced a separate presentation surface and displaced the cap
            // while its touch owner stayed put. Only the individual key's release
            // animates; the key area and candidate header always rasterize at
            // their actual, untransformed positions.
        }
        .padding(.horizontal, 4)
        .padding(.top, CGFloat(plan.contentTop))
        .padding(.bottom, KeyboardPanelGeometry.verticalPadding)
        .environment(\.keyboardKeyHeight, keyHeight)
        .environment(\.keyboardPopupSurface, popupSurface)
        .environment(\.keyboardFlashSurface, popupSurface)
        .environment(
            \.candidateSkinToken,
            CandidateSkinToken(
                candidateColor: Color(uiColor: appearance.text(on: "panel")),
                secondaryColor: Color(uiColor: appearance.text(on: "panel", secondary: true)),
                accentColor: appearance.accentForeground,
                panelColor: appearance.color("panel"),
                fontFamily: appearance.skin.typography.family,
                fontWeight: appearance.skin.typography.weight)
        )
        .overlay { KeyboardPopupSurface(view: popupSurface).allowsHitTesting(false) }
        .background(appearance.panelBackground.ignoresSafeArea(edges: .bottom))
        .tint(appearance.accentForeground)
        // Text-bearing surfaces (status, candidate labels, tool rows) grow with the
        // user's text size. Key geometry stays fixed: keycaps use explicit metrics and
        // fixed fonts, and this surface is height-bounded by the panel budget, so an
        // accessibility size can never resize the key area.
        .dynamicTypeSize(.small ... .accessibility3)
    }

    /// The named modifier group keeps the SwiftUI type-checker from re-solving the
    /// whole panel surface and every lifecycle modifier as one expression.
    private func panelBody(isWide: Bool) -> some View {
        panelLifecycleModifiers(panelSurface(isWide: isWide))
    }

    private func panelLifecycleModifiers<Content: View>(_ content: Content) -> some View {
        let controllerEvents = observeControllerChanges(content)
        let inputEvents = observeInputContext(controllerEvents)
        let pageEvents = observePageChanges(inputEvents)
        let definitionEvents = observeDefinitionChanges(pageEvents)
        return observeFeedbackLifecycle(definitionEvents)
    }

    private func observeControllerChanges<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: controller.snapshot.isComposing) {
                if !controller.snapshot.isComposing {
                    showsAllCandidates = false
                    choiceHold.rail = nil
                    choiceHold.row = nil
                }
            }
            .onChange(of: settledT9RailChoices) { _, settled in
                if let settled { choiceHold.rail = settled }
            }
            .onChange(of: settledReadingRowContent) { _, settled in
                if let settled { choiceHold.row = settled }
            }
            .onChange(of: controller.layout) {
                showsAllCandidates = false
                clearSymbolMarksOverride()
                refreshContentDock()
            }
            .onReceive(NotificationCenter.default.publisher(for: .keyboardContentDockChanged)) { _ in
                refreshContentDock()
            }
    }

    private func observeInputContext<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: controller.selectedSchemaID) { clearSymbolMarksOverride() }
            .onChange(of: controller.inputMode) { clearSymbolMarksOverride() }
            // Observe the raw engine flags, not only the OR-composed usesASCIIPunctuation: English/URL
            // hosts can change isAsciiPunct while the composed value is already true.
            .onChange(of: controller.snapshot.isAsciiPunct) { clearSymbolMarksOverride() }
            .onChange(of: controller.snapshot.isAsciiMode) { clearSymbolMarksOverride() }
            // A same-schema/same-kind switch to another custom physical definition may not report
            // successfulChange; the real definition content and pairing values are the source of truth.
            .onChange(of: selectedComposition) { clearSymbolMarksOverride() }
            .onChange(of: controller.successfulChange) {
                consumeLayoutChange()
                clearSymbolMarksOverride()
            }
            .onChange(of: controller.snapshot.candidates.isEmpty) {
                if controller.snapshot.candidates.isEmpty { showsAllCandidates = false }
            }
            .onChange(of: authoredPageMissingInputModeSwitchFallback) { _, missing in
                if missing { showAuthoredPageNeedsGlobeHint() }
            }
    }

    private func observePageChanges<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: page) {
                controller.resetPunctuationCycle()
                showsAllCandidates = false
                typedOnSymbolPage = false
                if page == .letters { clearSymbolMarksOverride() }
                if authoredPageMissingInputModeSwitchFallback { showAuthoredPageNeedsGlobeHint() }
                // Decided once per visit: committing the composition with the first symbol
                // must not resize every key row under the finger.
                symbolPageKeepsCandidates = page != .letters && controller.snapshot.isComposing
            }
            .onChange(of: controller.keyboardType) { syncHostPage() }
            .onAppear { syncHostPage() }
            .onAppear { refreshContentDock() }
            .onAppear { prefersCategorySymbolPage = KeyboardSymbolPagePreferences.usesCategoryPage }
            .onChange(of: hostBindingTick) {
                prefersCategorySymbolPage = KeyboardSymbolPagePreferences.usesCategoryPage
                refreshContentDock()
                clearSymbolMarksOverride()
            }
            .onChange(of: quickPasteIdleInput) { _, input in
                if !input.allowsPaste { quickPasteError = nil }
            }
            .onDisappear { quickPasteSlot.updateEligibility(false) }
    }

    private func observeDefinitionChanges<Content: View>(_ content: Content) -> some View {
        content
            .onAppear { reconcileDefinition() }
            .onAppear { injectCompactSpellingCapability() }
            // Reading-row eligibility report (fact): the host grants/revokes height from it and records it as a cold-start hint.
            .onAppear { onReadingRowReport?(readingRowReport) }
            .onChange(of: readingRowReport) { onReadingRowReport?(readingRowReport) }
            // Definition/physical-structure change: observe **content** (LayoutDefinition is Equatable). An in-place
            // registry update under the same id must also go through the transaction, rather than flipping a Bool and leaving a stale lock usable across definitions.
            .onChange(of: activeDefinition) { old, new in
                keyAreaGeneration &+= 1
                choiceHold.rail = nil
                choiceHold.row = nil
                clearSymbolMarksOverride()
                handleActiveDefinitionObservation(from: old, to: new)
            }
            .onChange(of: layoutRegistry) { reconcileDefinition() }
            .onChange(of: selectedLayoutID) {
                reconcileDefinition()
            }
    }

    /// Presentation, layout and dock-change hooks only; never per key.
    private func refreshContentDock() {
        let dock = KeyboardContentDockPreferences.dock(for: controller.layout)
        ContentDockCache.docks[controller.layout] = dock
        if contentDock != dock { contentDock = dock }
    }

    private func observeFeedbackLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .onAppear {
                // Feedback lifecycle (token-paired): on appear, refresh shared preferences and warm up lightly
                // (process capabilities are already declared by the host); disappear ends with this session's token;
                // when the controller/view is replaced, a late disappear from the old view does not release the new view's warm-up.
                // The key path does no UserDefaults/lock I/O; composing the effect-token comparison and calling feedback
                // still have a cost, so zero overhead is not claimed.
                feedback.refreshPreferences()
                feedbackLifecycleToken = feedback.prepare()
            }
            .onDisappear(perform: finishPanelLifecycle)
    }

}

/// Docking or undocking moves every key, so it cancels keys and recorded routes even before
/// the next touch. Width is deliberately absent: a live resize (Stage Manager) must not
/// recreate every key view per frame.
private struct WideContentSignature: Equatable {
    let isWideSurface: Bool
    let active: Bool
    let headerlessToolRail: Bool
    let dock: KeyboardContentDock
}

/// The dock each layout last resolved to in this process. A new panel value seeds its state
/// from here; `refreshContentDock` keeps it current.
@MainActor
private enum ContentDockCache {
    static var docks: [KeyboardLayoutKind: KeyboardContentDock] = [:]

    static func dock(for layout: KeyboardLayoutKind) -> KeyboardContentDock {
        if let dock = docks[layout] { return dock }
        let dock = KeyboardContentDockPreferences.dock(for: layout)
        docks[layout] = dock
        return dock
    }
}

/// Registers the docked content's live frame with `KeyboardRoutedTouch`, so a touch in the
/// blank margins is not routed to the nearest key. The frame is read at hit-test time, in
/// window coordinates, from this view; a removed or replaced reporter takes its region with it.
private struct WideContentFrameReporter: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.active = active
        return view
    }

    func updateUIView(_ view: ReporterView, context: Context) { view.active = active }

    static func dismantleUIView(_ view: ReporterView, coordinator: ()) { view.active = false }

    final class ReporterView: UIView {
        var active = false { didSet { if active != oldValue { register() } } }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            register()
        }

        private func register() {
            KeyboardRoutedTouch.registerWideContent(self, active: active && window != nil)
        }
    }
}

/// Non-observed width snapshot for split activation. The whole keyboard width decides a split
/// once; reading it through a reference keeps that value out of SwiftUI's invalidation set, while
/// every key-area geometry still sees the already-settled split.
final class KeyboardPanelWidthBox {
    private(set) var contentWidth: Double = 0
    private(set) var mainSplitWidth: Double = 0

    @discardableResult
    func record(contentWidth: CGFloat, mainSplitWidth: CGFloat) -> Bool {
        let next = Double(contentWidth)
        let nextMainSplit = Double(mainSplitWidth)
        guard next != self.contentWidth || nextMainSplit != self.mainSplitWidth else { return false }
        self.contentWidth = next
        self.mainSplitWidth = nextMainSplit
        return true
    }
}

/// Non-observed storage for `KeyboardPanelView.choiceHold`.
final class HeldReadingChoices {
    var rail: KeyboardPanelView.T9RailChoices?
    var row: CandidateReadingRowContent?
}
