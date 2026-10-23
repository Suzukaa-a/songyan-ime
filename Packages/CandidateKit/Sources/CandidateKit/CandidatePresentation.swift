import Foundation
import KeyboardCore

// MARK: - Render-agnostic presentation model

/// Candidate area state consumed by renderers. Derived from EngineSnapshot and free of engine internals
/// (no schema technical info, no raw-text confirmation instructions); renderers cannot mutate it back.
public struct CandidatePresentationState: Equatable, Sendable {
    /// Real engine state version (the host increments it after every real engine action). Candidate-set
    /// identity uses it to detect real changes caused by schema/options/reconversion/learning/session.
    public let revision: Int
    /// Current engine schema id (part of the composition generation: a schema change must discard old pages).
    public let schemaID: String
    /// Current physical layout identity (part of the composition generation: a layout change must discard old pages).
    public let layout: String
    /// Preedit text for display (the text being composed; empty when not composing, the config decides whether to show the row).
    public let preedit: String
    /// The user's raw input (while composing).
    public let rawInput: String
    /// Real candidates of the current page (order and indices come from the engine).
    public let candidates: [Candidate]
    /// In-page index of the highlighted candidate (-1 = none).
    public let highlightedIndex: Int
    /// Current page (0-based).
    public let pageIndex: Int
    /// Candidates per page (0 = the engine does not page).
    public let pageSize: Int
    public let canPageBackward: Bool
    public let canPageForward: Bool
    /// Whether composing (not composing = candidate area not shown).
    public let isComposing: Bool
    /// A post-commit menu remains browseable without becoming marked composition.
    public let isPrediction: Bool
    public var hasCandidateMenu: Bool { isComposing || isPrediction }
    /// English direct-input mode (the candidate area is hidden entirely).
    public let isEnglishMode: Bool

    public init(
        snapshot: EngineSnapshot, isEnglishMode: Bool,
        preeditOverride: String? = nil, layout: String = "", revision: Int = 0
    ) {
        self.revision = revision
        self.schemaID = snapshot.schemaID
        self.layout = layout
        self.preedit = preeditOverride ?? snapshot.preedit
        self.rawInput = snapshot.rawInput
        self.candidates = snapshot.candidates
        self.highlightedIndex = snapshot.highlightedIndex
        self.pageIndex = snapshot.pageIndex
        self.pageSize = snapshot.pageSize
        self.canPageBackward = snapshot.canPageBackward
        self.canPageForward = snapshot.canPageForward
        self.isComposing = snapshot.isComposing
        self.isPrediction = snapshot.isPrediction
        self.isEnglishMode = isEnglishMode
    }

    public init(
        schemaID: String = "", preedit: String = "", rawInput: String = "",
        candidates: [Candidate] = [],
        highlightedIndex: Int = -1, pageIndex: Int = 0, pageSize: Int = 0,
        canPageBackward: Bool = false, canPageForward: Bool = false,
        isComposing: Bool = false, isEnglishMode: Bool = false,
        layout: String = "", revision: Int = 0, isPrediction: Bool = false
    ) {
        self.revision = revision
        self.schemaID = schemaID
        self.layout = layout
        self.preedit = preedit
        self.rawInput = rawInput
        self.candidates = candidates
        self.highlightedIndex = highlightedIndex
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.canPageBackward = canPageBackward
        self.canPageForward = canPageForward
        self.isComposing = isComposing
        self.isPrediction = isPrediction
        self.isEnglishMode = isEnglishMode
    }

    /// Whether the composition row is visible under the config (default composingOnly: hidden when there is no input).
    public func showsCompositionRow(_ bar: CandidateBarDefinition) -> Bool {
        switch bar.compositionRow.visible {
        case .hidden: return false
        case .composingOnly: return isComposing && !isEnglishMode
        case .composingWithIdleRaw: return !isEnglishMode
        }
    }

    /// Predictions have a candidate menu but no composition. English direct input
    /// supplies no menu; engine-backed English needs actual candidates.
    public var showsCandidateBar: Bool { hasCandidateMenu && (!isEnglishMode || !candidates.isEmpty) }
    public var showsExpandedArea: Bool { showsCandidateBar && !candidates.isEmpty }
}

// MARK: - Action interface

/// Candidate area actions. Renderers can only emit these; the host maps them onto the real session:
///   - `select(index)`: must be a real `Candidate.index` (index within the current page); the host forwards
///     `selectCandidate(index)` and never synthesizes fake candidates.
///   - `selectOnPage(page:index:)`: real ownership of cross-page accumulated candidates (page + in-page index);
///     the host commits by absolute index and never treats a concatenated-array position as an index.
///   - `pageForward/pageBackward`: real engine paging (explicit controls; moves the engine highlight).
///   - `loadMore`: a read-only request for the next unloaded page (pages before the real current page are
///     filled first, then the following ones); the host reads by offset with a candidate iterator without
///     changing the engine's current page, highlight or candidate selection, so marked text is unchanged.
///     Strictly distinct from real paging via pageForward.
///   - `highlightNext/Previous`: moves the highlight preference (render-time state; the engine's
///     highlightedIndex takes effect when space confirms; the host never fakes an engine selection).
///   - `expand/collapse`: expand the current page's candidates / collapse (render-time UI state).
public enum CandidateAreaAction: Equatable, Sendable {
    case select(Int)
    case selectOnPage(page: Int, index: Int)
    case highlightNext
    case highlightPrevious
    case pageForward
    case pageBackward
    case loadMore
    case expand
    case collapse
}

/// Action recipient abstraction: implemented by KeyboardController (production) and previews (echoing sample actions).
/// Renderers depend on this protocol, not on InputSession / EngineBackend. The keyboard UI renders on
/// the main thread, so the protocol is MainActor-isolated as a whole. Cross-page selection and the
/// read-only loadMore are protocol requirements (not just extension methods) so that generic/existential
/// calls dispatch dynamically to the real host instead of silently degrading to in-page select / paging.
@MainActor
public protocol CandidateActionRecipient {
    /// Commits a real candidate (the index comes from Candidate.index).
    func candidateAreaSelect(index: Int)
    /// Commits a cross-page accumulated candidate (real page number + in-page index).
    func candidateAreaSelect(page: Int, index: Int)
    func candidateAreaPageForward()
    func candidateAreaPageBackward()
    /// Read-only load of the next unloaded page; must not move the engine highlight or page.
    func candidateAreaLoadMore()
}

public extension CandidateActionRecipient {
    /// Cross-page accumulated candidates: defaults to in-page selection; the real host overrides it with absolute-index selection.
    func candidateAreaSelect(page: Int, index: Int) { candidateAreaSelect(index: index) }
    /// Read-only load of the next page: no-op by default (no fake paging). The real host overrides it to read pages by offset.
    func candidateAreaLoadMore() {}
}

/// Renderer context: state + config + action sink + skin bridge (colors/fonts are injected by the host;
/// CandidateKit ships no skin of its own, avoiding a third color system).
public struct CandidateAreaContext {
    public let state: CandidatePresentationState
    /// Cross-page accumulated candidates (with real page ownership). When empty, the renderer falls back to the single page `state.candidates`.
    public let browser: CandidateBrowser
    /// A read-only subset of actual engine candidates (e.g. verified pronunciation
    /// matches). Each entry retains its original page and slot for selection.
    public let visibleEntries: [BrowserCandidate]?
    /// The subset's own incremental frontier. Nil uses the ordinary browser.
    public let visibleHasMore: Bool?
    public let visibleFrontier: Int?
    /// Whether the area is expanded (the collapsed strip switches its expand/collapse icon and action accordingly).
    public let isExpanded: Bool
    public let bar: CandidateBarDefinition
    public let actions: CandidateAreaActionSink
    /// Candidate font size resolved from the skin (SkinKit typography.candidateSize etc.).
    public let typography: CandidateTypography
    /// Points by which the collapsed strip's content is shifted **up** from the row center (0 = centered).
    /// Passed when the host shows a reading row above the word row, so the two lines sit closer; only
    /// the drawing position moves, each cell's hit region stays the full row height.
    /// The value is clamped to the row's height slack (see `CandidateCollapsedFlow.clampedLift`).
    public let contentLift: Double
    public init(
        state: CandidatePresentationState, bar: CandidateBarDefinition,
        actions: CandidateAreaActionSink, typography: CandidateTypography,
        browser: CandidateBrowser = CandidateBrowser(), isExpanded: Bool = false,
        visibleEntries: [BrowserCandidate]? = nil,
        visibleHasMore: Bool? = nil, visibleFrontier: Int? = nil,
        contentLift: Double = 0
    ) {
        self.contentLift = contentLift
        self.state = state
        self.browser = browser
        self.visibleEntries = visibleEntries
        self.visibleHasMore = visibleHasMore
        self.visibleFrontier = visibleFrontier
        self.isExpanded = isExpanded
        self.bar = bar
        self.actions = actions
        self.typography = typography
    }
}

/// Typography injected by the skin (values come from SkinKit; only plain values are kept here to avoid inverting the dependency direction).
public struct CandidateTypography: Equatable, Sendable {
    public var candidateSize: Double
    public var secondarySize: Double
    public init(candidateSize: Double, secondarySize: Double) {
        self.candidateSize = candidateSize
        self.secondarySize = secondarySize
    }
    public static let standard = CandidateTypography(candidateSize: 20, secondarySize: 10)
}

/// Action entry/exit: the host implements perform; expand/collapse/highlight are owned by the renderer,
/// the remaining actions are forwarded to the session. Preview implementations only echo and produce no input.
public final class CandidateAreaActionSink {
    public typealias Handler = (CandidateAreaAction) -> Void
    private let handler: Handler
    public init(handler: @escaping Handler) { self.handler = handler }
    public func perform(_ action: CandidateAreaAction) { handler(action) }
}

// MARK: - Renderer extension point (source-level; user JSON can only choose parameters within the schema)
// The protocol and registry live in CandidateAreaRendering.swift (they need SwiftUI/AnyView).
