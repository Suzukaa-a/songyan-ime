import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit
import os

/// Keyboard view controller: wraps `InputSession` so SwiftUI can observe it.
/// Shared by the host app's typing area and the keyboard extension so both behave the same.
/// The UI never mutates engine state directly; everything goes through the session.
/// The layout-to-schema mapping comes from `resourceSet` (nil = built-in package);
/// `availableLayouts` is the set of layouts that resource set offers, and layout cycling
/// and selection must stay within it.
@MainActor
public final class KeyboardController: ObservableObject {
    static let diagnosticLogger = Logger.keyboardController
    @Published public internal(set) var snapshot: EngineSnapshot
    /// Cross-page candidate accumulation (true page ownership, deduplicated by generation).
    /// The renderer shows more candidates continuously from it; `refresh()` absorbs the current
    /// page on every snapshot change, and a composition generation change resets it.
    @Published public internal(set) var candidateBrowser = CandidateBrowser()
    /// Only one read for a given frontier may be in flight. A changed composition
    /// may start its own read; the older result is discarded by generation below.
    var pendingCandidateRead: (generation: CandidateGeneration?, page: Int)?
    @Published public internal(set) var readingFilter = CandidateReadingFilter()
    @Published public internal(set) var readingBackendSupported = true
    /// A reading page for the live composition is scheduled or being read. The
    /// 9-key rail keeps its previous choices while the first batch is outstanding;
    /// taps wait for the live query and are validated before applying, rather than
    /// falling back to punctuation under the user's finger.
    @Published public internal(set) var readingQueryPending = false
    var retired = false
    var pendingReadingRead: (revision: Int, fromIndex: Int)?
    var readingDebounceTask: Task<Void, Never>?
    /// The (revision, frontier) the debounce task above was scheduled for.
    var scheduledReadingRead: (revision: Int, fromIndex: Int)?
    var readingNeedsRecheck = false
    enum RailSelection {
        case reading(String, prefix: [String])
        case spelling(String)
    }
    struct DeferredRailSelection {
        let choice: RailSelection
        let revision: Int
        let definition: LayoutRuntimeIdentity
        let engine: ObjectIdentifier
    }
    var deferredRailSelection: DeferredRailSelection?

    /// Resolve the rail against the same capability and composition used to validate taps.
    public var spellingRailChoices: SpellingRailChoices {
        SpellingRailChoices.resolve(
            eligible: ambiguityEligible, input: snapshot.rawInput,
            revision: session.compositionRevision, report: ambiguityPicker.report,
            reportRevision: ambiguityPicker.revision,
            lockedOption: ambiguityPicker.canUndoLock ? ambiguityPicker.lock?.chosenOption : nil,
            lockedInput: ambiguityPicker.lock?.rewrittenInput, readings: readingFilter)
    }

    public func selectRailReading(_ value: String, expectedPrefix: [String]) {
        selectRailChoice(.reading(value, prefix: expectedPrefix))
    }

    public func selectRailSpelling(_ value: String) {
        selectRailChoice(.spelling(value))
    }

    private func selectRailChoice(_ choice: RailSelection) {
        guard ambiguityEligible else { return }
        deferredRailSelection = DeferredRailSelection(
            choice: choice,
            revision: session.compositionRevision, definition: currentDefinitionIdentity,
            engine: ObjectIdentifier(session.engine))
        settleRailSelection()
    }

    public func cancelRailSelection() { deferredRailSelection = nil }

    func settleRailSelection() {
        guard let pending = deferredRailSelection else { return }
        guard ambiguityEligible, pending.revision == session.compositionRevision,
            pending.engine == ObjectIdentifier(session.engine),
            pending.definition.isProvablySame(as: currentDefinitionIdentity)
        else {
            deferredRailSelection = nil
            return
        }
        guard !ambiguityQueryPending, !awaitsFirstReadingPage else { return }
        deferredRailSelection = nil
        switch pending.choice {
        case .reading(let value, let prefix):
            guard readingFilter.prefix == prefix, readingFilter.options.contains(value) else { return }
            selectReading(value)
        case .spelling(let value):
            guard
                ambiguityPicker.accepts(
                    option: value, revision: pending.revision,
                    input: snapshot.rawInput)
            else { return }
            selectAmbiguityOption(value)
        }
    }
    /// Readings are prefetched automatically only for the leading candidates.
    /// A view's end-of-list sentinel stays visible whenever the loaded readings do
    /// not fill it (few distinct syllables across many candidates); without a limit it
    /// would chain reads through the *entire* candidate list after every key, and each
    /// read holds the engine queue that the next key's `processKey` waits on while each
    /// append re-renders the whole panel. Filtering still reads on until a match.
    public static let automaticReadingPrefetchLimit = 64
    /// Matches that fill the filtered candidate row; a filtered batch stops early here.
    static let filteredReadingRowTarget = 12
    /// True once the automatic reading prefetch for this composition is complete.
    public var readingPrefetchSatisfied: Bool {
        !readingFilter.isFiltering && readingFilter.entries.count >= Self.automaticReadingPrefetchLimit
    }
    /// The first reading page of the live composition has not arrived yet.
    public var awaitsFirstReadingPage: Bool {
        readingQueryPending && readingFilter.entries.isEmpty && canLoadReadings
    }
    var canLoadReadings: Bool {
        !retired && snapshot.isComposing && !isEnglishMode && session.compactSpellingLayout
            && readingFilter.hasMore && readingBackendSupported && !readingFilter.readFailed
    }
    /// Composition spelling disambiguation picker (independent of the reading filter). The engine
    /// is queried only in Chinese mode, while composing, when the physical layout definition
    /// supports compact spelling; 26-key and English make zero calls.
    @Published public internal(set) var ambiguityPicker = AmbiguitySpellingPicker()
    /// An ambiguity report for the live composition is still outstanding
    /// (mirrors `ambiguityReadID`); the 9-key rail holds its choices until it lands
    /// so spelling options do not appear later and push readings under a finger.
    @Published public private(set) var ambiguityQueryPending = false
    var lastAmbiguityDiagnostic = ""
    struct AmbiguityReportSource: Equatable {
        let engine: ObjectIdentifier
        let schemaID: String
        let layout: KeyboardLayoutKind
        let definitionIdentity: LayoutRuntimeIdentity
    }
    var ambiguityReportSource: AmbiguityReportSource?
    var ambiguityReadID: UUID? {
        didSet {
            liveAmbiguityRead.set(ambiguityReadID)
            let pending = ambiguityReadID != nil
            if ambiguityQueryPending != pending { ambiguityQueryPending = pending }
        }
    }
    /// What the engine queue checks before it starts a queued query: one the user has
    /// typed past is skipped instead of holding the engine for the next key's decode.
    let liveAmbiguityRead = EngineQueryStamp<UUID>()
    let liveCompositionRevision = EngineQueryStamp<Int>()
    var ambiguityDebounceTask: Task<Void, Never>?

    // MARK: Post-key completion coalescing state (see KeyboardController+Readings.swift)

    var completionWaiters: [CheckedContinuation<Void, Never>] = []
    var completionBarrier: Task<Void, Never>?

    // MARK: Composition disambiguation state (see KeyboardController+Ambiguity.swift)

    /// Content-level identity of the current physical definition (injected by the panel from the real `LayoutDefinition`).
    ///
    /// Tags ambiguity reports so one read cannot be applied under a different definition.
    var currentDefinitionIdentity: LayoutRuntimeIdentity = .absent
    /// Letter → compact key of the current physical definition (empty = unbounded).
    var readingKeyMap: [Character: Character] = [:]
    /// True while a layout switch or configuration-change confirmation runs synchronously on the main
    /// thread. Session callbacks mid-switch must not drop a picker lock that a failed switch keeps.
    var layoutSwitchInFlight = false

    @Published public internal(set) var layout: KeyboardLayoutKind { didSet { definitionInputsRevision &+= 1 } }
    @Published public internal(set) var engineKind: EngineBackendKind
    @Published public internal(set) var options: [EngineOptionState] = []
    @Published public internal(set) var optionError: String?
    @Published public internal(set) var inputError: String?
    @Published public internal(set) var inputUnavailableReason: String?
    @Published public internal(set) var selectedSchemaID: String { didSet { definitionInputsRevision &+= 1 } }
    /// Plain counter (not @Published) bumped on every assignment of `layout` / `selectedSchemaID`.
    /// The key area consults the layout-resolution cache hundreds of times per render; comparing this
    /// integer is much cheaper than reading two @Published values through Combine (the Published
    /// getter measured as a significant share of main-thread key-press time).
    public private(set) var definitionInputsRevision: UInt64 = 0
    @Published public internal(set) var successfulChange: KeyboardSelectionChange?
    public var availableSchemas: [KeyboardSchemaDescriptor] {
        // Minimal cache of schema metadata (including alphabet): the first access enumerates once through
        // the backend (`RimeBackend.availableSchemas` is a synchronous bridge call reading native
        // schemas/schemaValue per schema); afterwards the controller uses the cache for its lifetime.
        // The controller is rebuilt with each engine/resource generation (`KeyboardPadSession` creates a
        // new one on every boot), so nothing is cached across generations or in any global location;
        // the schema list is immutable for a given engine instance.
        if let cached = cachedSchemaDescriptors { return cached }
        let loaded = (session.engine as? RimeBackend)?.availableSchemas ?? []
        cachedSchemaDescriptors = loaded
        return loaded
    }
    private var cachedSchemaDescriptors: [KeyboardSchemaDescriptor]?

    /// The real alphabet declared by the current source schema; empty string if not found. Long-press
    /// policy fails closed on it and never guesses sendable codes from layout names or key caps.
    public var activeSchemaAlphabet: String {
        if let source = session.resourceSet?.schemas.first(where: { $0.id == selectedSchemaID }) {
            return source.alphabet
        }
        return availableSchemas.first(where: { $0.id == selectedSchemaID })?.alphabet ?? ""
    }

    /// What a sideways pick of `letter` sends to the engine. A merged key's own letter
    /// is also its tap code, which the companion reads as any letter of the key, so the
    /// exact pick sends the fold's exact token when the running schema accepts it.
    public func exactPickCode(_ letter: String) -> String {
        guard !isEnglishMode, !snapshot.isAsciiMode, letter.count == 1, let character = letter.first,
            let token = layout.compactFold?.exactTokens[character],
            runningAlphabet?.contains(token) == true
        else { return letter }
        return String(token)
    }

    /// The running schema's alphabet. A host-added keyboard runs an adapter that is not in
    /// schema_list, so the backend reads it apart from `availableSchemas`.
    private var runningAlphabet: String? {
        session.engine.spellerAlphabet(schemaID: snapshot.schemaID)
    }

    /// Exact token → its letter, for reading what was typed back as letters.
    var exactTokenLetters: [Character: Character] {
        guard let tokens = layout.compactFold?.exactTokens else { return [:] }
        return Dictionary(uniqueKeysWithValues: tokens.map { ($1, $0) })
    }

    public var availableCombinations: [KeyboardResourceSet.Combination] {
        if let resources = session.resourceSet { return resources.availableCombinations }
        return KeyboardLayoutKind.allCases.compactMap { layout in
            guard let schemaID = BuiltinTemplateSchemas.defaultSchemaID(for: layout),
                let schema = availableSchemas.first(where: { $0.id == schemaID })
            else { return nil }
            return .init(schemaID: schema.id, engineSchemaID: schema.id, layout: layout, name: schema.name)
        }
    }
    public var onSelectionChanged: ((KeyboardSelectionChange) -> Void)?
    /// Menu level one: source schemes, never a flat list of generated combinations.
    public var inputSchemeChoices: [KeyboardSchemaDescriptor] {
        guard let resources = session.resourceSet else { return availableSchemas }
        if !resources.schemas.isEmpty { return resources.inputSchemeChoices }
        // Builtin resources declare enabled schemas through layoutEntries.
        // An empty descriptor list is not an empty enabled list in that contract.
        // Read names from this running engine, restricted to the declared pairs.
        let enabled = Set(resources.availableCombinations.map(\.schemaID))
        return availableSchemas.filter { enabled.contains($0.id) }
    }
    /// Human-readable display name of the current input method; nil when the resource descriptor has no real name.
    ///
    /// General policy: only the structured resource descriptor's human-readable `name` is trusted, with
    /// no special-casing by schema/source ID or brand; when missing it returns nil, the view omits it,
    /// and a bare ID is never shown.
    public var currentInputMethodDisplayName: String? {
        let source = session.resourceSet?.sourceSchemaID(selectedSchemaID) ?? selectedSchemaID
        return inputSchemeChoices.first { $0.id == source }?.humanReadableName
    }
    /// Menu level two: keyboards for the current scheme only. No cross-scheme fallback.
    public var currentSchemeKeyboards: [KeyboardResourceSet.Combination] {
        let source = session.resourceSet?.sourceSchemaID(selectedSchemaID) ?? selectedSchemaID
        return availableCombinations.filter { $0.schemaID == source }
    }
    /// Explicit runnable pairs from this loaded source, including other enabled schemes.
    /// A menu tap binds both schema and layout; never infer a cross-source fallback.
    public var layoutSwitchChoices: [KeyboardResourceSet.Combination] {
        let source = session.resourceSet?.sourceSchemaID(selectedSchemaID) ?? selectedSchemaID
        let order: [KeyboardLayoutKind] = [.merged14, .merged18, .qwerty26, .phone9]
        let enabled = Set(inputSchemeChoices.map(\.id))
        let groups = order.map { layout in
            availableCombinations.filter { $0.layout == layout && enabled.contains($0.schemaID) }
                .sorted { lhs, rhs in
                    if (lhs.schemaID == source) != (rhs.schemaID == source) { return lhs.schemaID == source }
                    return lhs.schemaID < rhs.schemaID
                }
        }
        // Keep every physical layout within the leading buttons, even when
        // this source enables many schemas. Remaining explicit pairs follow.
        return groups.compactMap(\.first) + groups.flatMap { Array($0.dropFirst()) }
    }
    public func layoutSwitchSchemeName(_ pair: KeyboardResourceSet.Combination) -> String {
        inputSchemeChoices.first { $0.id == pair.schemaID }?.displayName ?? pair.name
    }
    public func selectCurrentSchemeKeyboard(_ layout: KeyboardLayoutKind) {
        let source = session.resourceSet?.sourceSchemaID(selectedSchemaID) ?? selectedSchemaID
        selectLayout(layout, boundSchemaID: source)
    }

    // MARK: ABC word guessing state (see KeyboardController+EnglishSuggestions.swift)

    /// Word suggestions for the English word being typed (at most three slots).
    @Published public internal(set) var englishSuggestions: [String] = []
    /// nil = not probed for the current scheme yet; false = the scheme mounts no
    /// English translator, so the ABC page reserves no candidate row.
    @Published public internal(set) var englishSuggestionsSupported: Bool?
    /// Letters committed in English since the last word boundary. Kept from our
    /// own commits, not by reading the host document.
    @Published public private(set) var hasActiveEnglishInput = false
    var englishWord = "" {
        didSet {
            let active = isEnglishMode && !englishWord.isEmpty
            if hasActiveEnglishInput != active { hasActiveEnglishInput = active }
        }
    }
    /// Invalidates captured edit state even if a host reset leaves the same text.
    var englishDocumentGeneration: UInt64 = 0
    var externalLiteralDepth = 0
    /// The last finished English word (followed by a space); drives next-word
    /// guesses while no new word is being typed. nil after punctuation or a reset.
    var previousEnglishWord: String?
    var nextWords = EnglishNextWordModel()
    /// The row shows next-word guesses (commit as is), not completions of `englishWord`.
    var englishSuggestionsArePredictions = false
    /// The row shows the engine's post-commit predictions (page-local candidate indices,
    /// same order as `englishSuggestions`); tapping one selects it in the engine.
    var englishEnginePredictionIndices: [Int] = []
    /// Last engine prediction texts the ABC row was built from.
    var englishEnginePredictionTexts: [String] = []
    var englishQueryTask: Task<Void, Never>?
    var englishProbeSchemaID: String?
    /// The schema ABC queries: the first one the source scheme mounts (or the scheme
    /// itself) that really completes a common English prefix. None = fail closed.
    var englishWordSchemaID: String?
    var wasEnglishMode = false

    // MARK: Marked composition state (see KeyboardController+MarkedComposition.swift)

    public var onMarkedComposition: ((MarkedComposition?) -> Void)?
    /// Preserve schema preedit (including explicitly selected segments). A candidate
    /// preview is not the user's unconfirmed input and is never the default mark.
    public var usesChineseMarkedPreview = false
    /// Publishes only when the `.keyboard` fallback starts or stops: that is the only
    /// branch the panel renders. idle / awaitingHost / inline alternate on every key
    /// (host echo) and must not re-render the whole panel each time.
    public internal(set) var compositionPresentation: CompositionPresentation = .idle
    /// The composition last handed to the field, before the deferred-key echo.
    var publishedMarkedBase: MarkedComposition?
    /// How many deferred keys the last published composition already showed.
    var echoedPendingCodes = 0
    var pendingEchoWork: DispatchWorkItem?
    /// The engine-proven highlighted reading for the host field and keyboard fallback.
    /// Not `@Published`: it lands a turn after each key and only the field shows it, so
    /// publishing re-rendered the whole panel once more per key. The in-keyboard
    /// fallback is the one panel surface that draws it, so only it is notified.
    public internal(set) var highlightedReading = "" {
        willSet { if compositionPresentation.isKeyboardFallback { objectWillChange.send() } }
    }
    var highlightedReadSource: (revision: Int, snapshot: EngineSnapshot)?
    var highlightedReadInFlight: UUID?
    var highlightedReadCompleted = false
    /// Per-character readings the engine proved earlier in this keyboard session. A
    /// sentence's later characters (还 in 哦还) are never on the current code's first
    /// page, so without these the field guessed a syllable from frequency alone.
    /// Memory only, bounded; a guess source for display, never for commits.
    var knownCharacterReadings: [Character: [String]] = [:]

    // MARK: Input effect observation (feedback/recents fire once, only after a real effect)

    /// Snapshot of the "observable effects" around one action: host commit/delete counts, engine
    /// snapshot, input mode/Shift/layout. After a synchronous action, comparing with the earlier value
    /// tells whether it took effect: any field changed = effective; all unchanged = no-op or failure, no feedback.
    public struct InputEffectToken: Equatable {
        public let commitSequence: Int
        public let deleteSequence: Int
        public let snapshot: EngineSnapshot
        public let mode: InputMode
        public let shiftState: ShiftState
        public let layout: KeyboardLayoutKind
        /// A code key deferred to the engine queue (or taken back) is an effect too.
        public let pendingCodes: Int

        /// Whether before → after produced an effective change (an engine error leaves these fields unchanged, so it counts as ineffective).
        public static func isEffect(before: InputEffectToken, after: InputEffectToken) -> Bool {
            before.commitSequence != after.commitSequence
                || before.deleteSequence != after.deleteSequence
                || before.snapshot != after.snapshot
                || before.mode != after.mode
                || before.shiftState != after.shiftState
                || before.layout != after.layout
                || before.pendingCodes != after.pendingCodes
        }
    }

    /// Process-wide monotonic count of dispatches to a live host outlet; does not guarantee the document accepted them.
    public internal(set) var commitSequence = 0
    /// Process-wide monotonic count of host delete callbacks accepted (callback present) for empty-composition/English backspace.
    /// "Request accepted" is not "document actually deleted" (unobservable when the host document is empty); this boundary is recorded as is.
    public internal(set) var deleteSequence = 0

    /// Captures the current effect snapshot; take one before and one after a synchronous action and compare to judge effectiveness.
    public func inputEffectToken() -> InputEffectToken {
        InputEffectToken(
            commitSequence: commitSequence, deleteSequence: deleteSequence,
            snapshot: session.snapshot, mode: inputMode,
            shiftState: shiftState, layout: layout, pendingCodes: session.pendingCodesRevision)
    }

    // MARK: Selection state (see KeyboardController+Configuration.swift)

    public var onInputError: ((String) -> Void)?

    // MARK: Host traits state (see KeyboardController+HostTraits.swift)

    /// Input mode (Chinese composition / English direct input). The UI's 中/英 key updates it via `setInputMode`.
    @Published public internal(set) var inputMode: InputMode
    /// Three-state Shift for English direct input (the UI derives key-cap case/Shift key state from it).
    @Published public internal(set) var shiftState: ShiftState
    /// Host text-field traits. A forced English field temporarily overrides the
    /// remembered language; numeric fields only select the panel's literal page.
    @Published public internal(set) var keyboardType: UIKeyboardType = .default
    @Published public internal(set) var returnKeyType: UIReturnKeyType = .default
    @Published public internal(set) var keyboardAppearance: UIKeyboardAppearance = .default
    var hostRestoredMode: InputMode?
    var hostCapitalization: HostKeyboardTypePolicy.AutoCapitalization?
    var hostContextBeforeInput: String?
    var enablesReturnKeyAutomatically: Bool?
    var hostDocumentIsEmpty: Bool?
    var automaticShiftArmed = false
    /// Fires only when a host text-field trait actually changes (not on every keystroke),
    /// so appearance consumers can refresh without observing the whole snapshot.
    public let hostTraitsChanged = PassthroughSubject<Void, Never>()

    /// Layouts available in the current resource set (the layout cycle key switches only among these; upper-level pickers/menus should list only these).
    /// A nil resource set (built-in package) = all four layouts.
    public let availableLayouts: [KeyboardLayoutKind]

    // MARK: User keyboards (input method + keyboard layout combinations published by the main app)

    /// Published keyboard roster (injected by `KeyboardPadSession` after reading the publication record).
    /// The extension switches only among entries that are actually runnable with the current resources.
    @Published public private(set) var publishedKeyboards: [UserKeyboard] = []
    /// Reason the roster failed to load (nil = OK). A failure keeps the old roster and never silently clears it.
    @Published public private(set) var publishedKeyboardError: String?

    public let session: InputSession

    /// Keyboards listed on long-press of the ABC/中文 key: published roster ∩ combinations actually runnable
    /// with the current resources, in publication order. Only keyboards the user added; the 26/14/9 layouts themselves are never listed.
    public var userKeyboardChoices: [UserKeyboard] {
        UserKeyboardRoster.runnable(publishedKeyboards, combinations: availableCombinations)
    }

    /// Injects the published roster (the session calls it on ready/entering the keyboard; the same entry also reports the error).
    public func updatePublishedKeyboards(_ keyboards: [UserKeyboard], error: String? = nil) {
        if publishedKeyboards != keyboards { publishedKeyboards = keyboards }
        if publishedKeyboardError != error { publishedKeyboardError = error }
    }

    /// Switches to a published keyboard (input method + layout together, one transaction).
    /// If it is not in the runnable roster, does nothing and returns false.
    @discardableResult
    public func selectUserKeyboard(_ keyboard: UserKeyboard) -> Bool {
        guard userKeyboardChoices.contains(keyboard) else { return false }
        let previousLayout = layout
        let previousSchema = selectedSchemaID
        selectLayout(keyboard.layout, boundSchemaID: keyboard.inputMethodID)
        return layout != previousLayout || selectedSchemaID != previousSchema
    }

    /// Callback for engine commit text (host text field / text proxy insertion).
    public var onCommit: ((String) -> Void)?
    /// True means dispatched to a live outlet, not document acceptance.
    public var onDispatchCommit: ((String) -> Bool)?
    /// Callback when backspace is pressed with an empty composition (the host deletes an already-committed character).
    public var onRequestDeleteBackward: (() -> Void)?
    public var onReadDocumentContext: (() -> String?)?
    public var onReplaceLiteralSuffix: ((String, String, String) -> Bool)?
    var punctuationCycle = T9PunctuationCycle()

    public func resetPunctuationCycle() { punctuationCycle.reset() }

    /// An empty field reports nil before-input context. Read that as "" so the
    /// first tap in an empty field arms the cycle; an unreadable field stays nil
    /// on the next tap too and so never replaces anything.
    private func readCycleContext() -> String { onReadDocumentContext?() ?? "" }

    /// Consecutive-tap rotation for the first key while idle.
    ///
    /// `symbols` is the real order from the fourth item on (the first three left-column items are not
    /// here). The caller passes it after applying the user's saved order + default fill + ASCII-mapping
    /// dedup, so key-cap titles, AX hints, and actual insertion cannot disagree. Replacement happens only
    /// under `T9PunctuationCycle`'s existing guards: within one short window, the same revision, and the
    /// document context still equal to the predicted text after the last write, the previously inserted
    /// symbol is replaced (not a newly invented delete rotation); any uncertainty degrades to a fresh direct insert.
    @discardableResult
    public func cycleT9Punctuation(symbols: [String]) -> Bool {
        guard !retired, !snapshot.isComposing else { return false }
        let now = CACurrentMediaTime()
        guard
            var edit = punctuationCycle.next(
                symbols: symbols, context: readCycleContext(),
                now: now, revision: commitSequence)
        else { return false }
        punctuationCycle.reset()
        let completed: Bool
        if let old = edit.replacing, let expected = edit.expectedContext,
            onReplaceLiteralSuffix?(expected, old, edit.text) == true
        {
            deleteSequence += old.count
            commitSequence += 1
            resetEnglishWord()
            completed = true
        } else {
            guard
                let initial = T9PunctuationCycle().next(
                    symbols: symbols, context: readCycleContext(), now: now, revision: commitSequence)
            else { return false }
            edit = initial
            completed = insertLiteral(edit.text)
        }
        if completed {
            punctuationCycle.record(
                edit, symbols: symbols, context: readCycleContext(),
                now: now, revision: commitSequence)
        }
        return completed
    }
    /// Re-reads the host field's traits (`hasText` etc.) now. The cached "document
    /// empty" flag goes stale when the keyboard's own writes fill the field without a
    /// UIKit callback, so a disabled-looking return key asks again before ignoring a tap.
    public var onRequestHostTraitsRefresh: (() -> Void)?
    /// Globe key callback (the extension should call advanceToNextInputMode; the main app shows a hint).
    public var onRequestSwitchKeyboard: (() -> Void)?
    /// Relative cursor move callback (parameter = relative character offset). Implemented by the host:
    /// the extension forwards to `textDocumentProxy.adjustTextPosition(byCharacterOffset:)`; the main
    /// app's typing area implements it only when it can move the selection precisely, otherwise it stays
    /// nil (nil = no move, never pretend). Calling `moveCursor(by:)` while composing first commits the
    /// composition with confirm semantics.
    public var onMoveCursor: ((Int) -> Void)?
    /// Layout change callback (`KeyboardPadSession` syncs its own layout and persists the selection from it).
    public var onLayoutChanged: ((KeyboardLayoutKind) -> Void)?

    /// Whether to show the demo-engine banner hint.
    public var showsDemoBanner: Bool { !engineKind.isRealRime }

    /// - Parameters:
    ///   - layout: initial layout (the caller should normalize it to a layout the resource set offers).
    ///   - engine: engine backend (production path = RimeBackend).
    ///   - resourceSet: resource-set mapping (nil = built-in mapping).
    public init(
        layout: KeyboardLayoutKind = .qwerty26, engine: EngineBackend,
        resourceSet: KeyboardResourceSet? = nil
    ) {
        self.layout = layout
        self.engineKind = engine.kind
        self.session = InputSession(engine: engine, layout: layout, resourceSet: resourceSet)
        self.selectedSchemaID = self.session.selectedSchemaID
        let available = self.session.resourceSet?.availableLayouts ?? KeyboardLayoutKind.allCases
        self.availableLayouts = available
        self.snapshot = session.snapshot
        self.inputMode = session.mode
        self.shiftState = session.shiftState
        // The engine's composition display request was already installed by `InputSession` for the actual layout; nothing to set here.
        session.onUpdate = { [weak self] in self?.refresh() }
        // Composing code keys decode on the engine queue (`InputSession.codeKeyQueue`);
        // the field echoes keys still decoding so none of them looks lost.
        if engine is RimeBackend {
            session.codeKeyQueue = EngineOpCodeKeyQueue.shared
            session.codeBatchLookaheadPages = Self.candidatePagesPerRead - 1
        }
        session.onPendingCodesChanged = { [weak self] in self?.publishPendingEcho() }
        session.onError = { [weak self] error in
            guard let self else { return }
            // The first reflective description is expensive (about 17ms measured on the simulator): format it in the background, off the key-press main thread.
            let diagnosticLogger = Self.diagnosticLogger
            DispatchQueue.global(qos: .utility).async {
                diagnosticLogger.error("input operation failed: \(String(describing: error), privacy: .private)")
            }
            let message = "输入操作未完成，请重试。"
            self.inputError = message
            self.onInputError?(message)
            self.refresh()
        }
        session.onDispatchCommit = { [weak self] text in
            self?.dispatchCommit(text) ?? false
        }
        session.onMoveCursor = { [weak self] offset in self?.onMoveCursor?(offset) }
        if let backend = engine as? RimeBackend {
            backend.onOptionPersistenceCompleted = { [weak self, weak backend] error in
                guard let self, let backend, !self.retired, self.session.engine === backend else { return }
                if let error {
                    Self.diagnosticLogger.error(
                        "option persistence failed: \(error.localizedDescription, privacy: .private)")
                    self.optionError = "选项已在本次会话生效，但未能保存，请重试。"
                } else {
                    self.optionError = nil
                }
            }
        }
        session.refresh()
        reloadOptions()
        probeEnglishSuggestions()
    }

    public func retire() {
        guard !retired else { return }
        retired = true
        deferredRailSelection = nil
        englishQueryTask?.cancel()
        readingDebounceTask?.cancel()
        ambiguityDebounceTask?.cancel()
        pendingEchoWork?.cancel()
        ambiguityReadID = nil
        ambiguityReportSource = nil
        highlightedReadInFlight = nil
        session.retire()
        onCommit = nil
        onDispatchCommit = nil
        onRequestDeleteBackward = nil
        onReadDocumentContext = nil
        onReplaceLiteralSuffix = nil
        punctuationCycle.reset()
        onRequestHostTraitsRefresh = nil
        onRequestSwitchKeyboard = nil
        onMoveCursor = nil
        onMarkedComposition = nil
        onSelectionChanged = nil
        onInputError = nil
        onLayoutChanged = nil
    }

    /// Key-cap action dispatch: the globe key and layout cycling go to the host/upper layer; space/return/backspace follow IME
    /// semantics; digit/symbol keys (`.literal`) go through the common direct-insert entry `insertLiteral`.
    public func handle(_ action: KeyAction) {
        guard !retired else { return }
        punctuationCycle.reset()
        let endStallWatch = KeyboardStallReport.begin(Self.actionKind(of: action))
        defer { endStallWatch() }
        #if DEBUG
            let endKeyInterval = DebugProbe.keyInterval(Self.actionKind(of: action))
            defer { endKeyInterval() }
        #endif
        // Double-space period applies only after an English letter/digit + one space; any other key cancels it.
        let wordCharBefore = lastEnglishInputWasWordChar
        let spaceArmedAt = doubleSpaceArmedAt
        let documentGeneration = englishDocumentGeneration
        lastEnglishInputWasWordChar = false
        doubleSpaceArmedAt = nil
        switch action {
        case .switchKeyboard:
            onRequestSwitchKeyboard?()
        case .cycleLayout:
            cycleLayout()
        case .literal(let text):
            _ = insertLiteral(text)
        case .space:
            if doubleSpacePeriodAllowed, let armed = spaceArmedAt,
                CACurrentMediaTime() - armed < 0.6
            {
                // One guarded host operation: a rejected delete must not be
                // followed by a commit into newly adopted document ownership.
                guard let context = onReadDocumentContext?(),
                    englishDocumentGeneration == documentGeneration,
                    context.hasSuffix(" "),
                    onReplaceLiteralSuffix?(
                        String(context.suffix(T9PunctuationCycle.contextLimit)),
                        " ", ". ") == true
                else {
                    resetEnglishWord()
                    break
                }
                deleteSequence += 1
                commitSequence += 1
                noteCommitForEnglishWord(". ")
                break
            }
            confirmOrInsert(commitWhenIdle: " ")
            if englishDocumentGeneration == documentGeneration,
                doubleSpacePeriodAllowed, wordCharBefore
            {
                doubleSpaceArmedAt = CACurrentMediaTime()
            }
        case .enter:
            if !isReturnKeyEnabled { onRequestHostTraitsRefresh?() }
            guard isReturnKeyEnabled else { break }
            if snapshot.isComposing, !session.compactSpellingLayout, !session.numericTransportLayout {
                // In 26-key composition, return goes to the engine (Rime's default commit_raw_input commits the raw
                // code, matching the system pinyin keyboard); the schema's own editor bindings still apply and the
                // front end does not guess.
                inputError = nil
                session.tap(.enter)
            } else {
                // On 14/9-key the raw code is merged key codes, not letters: keep confirming the candidate.
                confirmOrInsert(commitWhenIdle: "\n")
            }
        case .backspace:
            handleBackspaceTap()
        case .code(let value):
            // While locked, any ordinary Chinese code key first restores the original reduced input and is
            // processed only on success; on failure the key is not sent (never produce an alias/canonical + new-code mixed string).
            if ambiguityPicker.phase == .locked {
                guard restoreAmbiguityBeforeContinuedInput() else { return }
            }
            let shiftBefore = session.shiftState
            let commitBefore = commitSequence
            session.tap(.code(value))
            // InputSession consumes one-shot shift before calling the host. Restore
            // it only for a refused, same-document letter; never revive old focus state.
            if shiftBefore == .once, session.shiftState == .off,
                commitSequence == commitBefore, englishDocumentGeneration == documentGeneration,
                isEnglishMode, value.count == 1,
                let scalar = value.unicodeScalars.first, (97...122).contains(scalar.value)
            {
                session.setAutomaticShift(true)
            }
            if englishDocumentGeneration == documentGeneration, inputMode == .english,
                commitSequence != commitBefore
            {
                lastEnglishInputWasWordChar = value.first.map { $0.isLetter || $0.isNumber } ?? false
            }
            reconcileShiftAfterLetterInput()
        case .letterVariant(let text):
            let isLetter = isEnglishMode && text.count == 1 && text.first?.isLetter == true
            let consumesShift = isLetter && session.shiftState == .once
            let output = isLetter && session.shiftState.isActive ? text.uppercased() : text
            guard insertLiteral(output) else { break }
            if consumesShift, session.shiftState == .once { session.tapShift() }
            if englishDocumentGeneration == documentGeneration, inputMode == .english {
                lastEnglishInputWasWordChar = isLetter
            }
            reconcileShiftAfterLetterInput()
        }
    }

    private func reconcileShiftAfterLetterInput() {
        if hostCapitalization == .allCharacters {
            reconcileAutomaticShift()
        } else if automaticShiftArmed && session.shiftState == .off {
            automaticShiftArmed = false
        }
    }

    /// Action kind only, no character content.
    private static func actionKind(of action: KeyAction) -> String {
        switch action {
        case .switchKeyboard: return "switchKeyboard"
        case .cycleLayout: return "cycleLayout"
        case .literal: return "literal"
        case .space: return "space"
        case .enter: return "enter"
        case .backspace: return "backspace"
        case .code: return "code"
        case .letterVariant: return "letterVariant"
        }
    }

    // MARK: Direct input state (see KeyboardController+DirectInput.swift)

    /// Convenience toggle for the 中/英 key. If English state comes from Rime's own `ascii_mode`
    /// (key_binder/switch/options), it turns off that real option first; flipping only the front-end direct-input state is not enough.
    /// Double-space period state: whether the last English input was a letter/digit; time of the first space.
    var lastEnglishInputWasWordChar = false
    var doubleSpaceArmedAt: CFTimeInterval?
}

extension HostKeyboardTypePolicy.AutoCapitalization {
    init(_ type: UITextAutocapitalizationType) {
        switch type {
        case .none: self = .none
        case .words: self = .words
        case .sentences: self = .sentences
        case .allCharacters: self = .allCharacters
        @unknown default: self = .none
        }
    }
}

/// UIKit → UIKit-free policy mapping. The policy itself lives in LayoutKit so it can
/// be unit-tested on macOS without a simulator.
extension HostKeyboardTypeKind {
    init(_ type: UIKeyboardType) {
        switch type {
        case .asciiCapable: self = .asciiCapable
        case .numbersAndPunctuation: self = .numbersAndPunctuation
        case .URL: self = .url
        case .emailAddress: self = .emailAddress
        case .numberPad: self = .numberPad
        case .decimalPad: self = .decimalPad
        case .asciiCapableNumberPad: self = .asciiCapableNumberPad
        case .phonePad: self = .phonePad
        case .namePhonePad: self = .namePhonePad
        case .twitter: self = .twitter
        case .webSearch: self = .webSearch
        case .default: self = .unspecified
        @unknown default: self = .other
        }
    }
}

/// A main-actor value the engine queue reads to skip a query that is no longer wanted.
final class EngineQueryStamp<Value: Equatable & Sendable>: Sendable {
    private let value = OSAllocatedUnfairLock<Value?>(initialState: nil)

    func set(_ newValue: Value?) {
        value.withLock { $0 = newValue }
    }

    func matches(_ expected: Value) -> Bool {
        value.withLock { $0 == expected }
    }
}

/// `InputSession.codeKeyQueue` on the engine queue.
final class EngineOpCodeKeyQueue: EngineWorkQueue, Sendable {
    static let shared = EngineOpCodeKeyQueue()
    func async(_ work: @escaping @Sendable () -> Void) { EngineOpQueue.enqueue(work) }
}
