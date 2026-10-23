import Foundation
import KeyboardCore

// MARK: - Candidate paging browse model (real page ownership, read-only page reads, no fake candidates)
//
// The engine returns only pageSize candidates per page (librime menu/page_size). The collapsed strip's
// "continuous scroll loading" and the expanded area's "scroll to load more" need a cross-page accumulator:
// each page read **read-only** is recorded by real page number + in-page index for the renderer to show
// continuously; selection goes through the host with an absolute index (`EngineBackend.readCandidates` /
// `selectCandidateAbsolute`), never treating a concatenated-array position as a candidate index.
//
// Key rules:
//   * Browsing never calls nextPage/PageDown; the host reads pages read-only by offset with a candidate
//     iterator and leaves the engine's current page/highlight/user selection alone, so marked text and
//     the space-confirm target are unchanged.
//   * Composition identity = `revision` (incremented whenever a real engine state arrives) + schema + layout +
//     rawInput + pageSize + isComposing, **excluding preedit** (it changes with the highlighted candidate).
//   * `reset` rebuilds authoritatively when the identity changes; when it is unchanged a **display-only
//     (non-empty) refresh keeps browsing**, but an **empty candidate list is authoritative and must clear old
//     entries/frontier first** (it cannot be swallowed by a no-op); recovering to non-empty under the same
//     identity after a clear must rebuild, not stay a permanent no-op.
//   * The real engine current page is **always** the anchor: `enginePageIndex` records it, and earlier pages
//     (0...current-1) and later pages are both filled read-only through `nextPageToLoad`; candidates stay
//     sorted by absolute index and never reversed.
//   * EOF holds only for a **successful short read** on the real current page or later; a short/empty page
//     before the anchor and `.unavailable` are always incomplete: not sealed and kept retryable (no permanent
//     hole, and no endless onAppear loop because the sentinel id is unchanged).
//   * Identities use an unambiguous length-prefixed encoding, and the sentinel uses a structured Hashable
//     identity (no bare string concatenation).

/// Composition identity: the real engine state version. **Excludes preedit** (it changes with the highlighted candidate).
/// `Hashable`, so the renderer can bind the tail loading sentinel's identity to a specific composition (a new
/// composition with the same frontier retriggers loading instead of SwiftUI skipping onAppear because the id is unchanged).
public struct CandidateGeneration: Equatable, Hashable, Sendable {
    public let revision: Int
    public let schemaID: String
    public let layout: String
    public let rawInput: String
    public let pageSize: Int
    public let isComposing: Bool
    public let isPrediction: Bool
    public var hasCandidateMenu: Bool { isComposing || isPrediction }

    public init(
        revision: Int, schemaID: String, layout: String, rawInput: String,
        pageSize: Int, isComposing: Bool, isPrediction: Bool = false
    ) {
        self.revision = revision
        self.schemaID = schemaID
        self.layout = layout
        self.rawInput = rawInput
        self.pageSize = pageSize
        self.isComposing = isComposing
        self.isPrediction = isPrediction
    }

    /// Stable identity string reusable across refreshes (for debugging/compatibility; contains no pointers or random hash values).
    ///
    /// **Unambiguous encoding**: string fields use a "UTF-8 byte count + `:`" length prefix, numeric fields a fixed
    /// order, booleans 0/1. Merely swapping the `|` separator for another character cannot remove collisions: for
    /// example `schemaID:"s|l", layout:"x"` and `schemaID:"s", layout:"l|x"` collide under any plain concatenation
    /// scheme. The length prefix makes field boundaries uniquely parseable.
    public var stableID: String {
        let schema = Self.lengthPrefixed(schemaID)
        let layoutField = Self.lengthPrefixed(layout)
        let raw = Self.lengthPrefixed(rawInput)
        return
            "cg2|\(revision)|\(pageSize)|\(isComposing ? "1" : "0")|\(isPrediction ? "1" : "0")|\(schema)|\(layoutField)|\(raw)"
    }

    private static func lengthPrefixed(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }
}

/// **Structured** identity of the tail read-only loading sentinel: `CandidateGeneration?` + frontier + view kind.
///
/// Used directly as a SwiftUI `.id(...)` (the synthesized `Hashable` includes every field, so there is no string
/// concatenation ambiguity); the `stableID` string is only for debugging/compatibility and is not the sentinel's identity.
public struct CandidateSentinelIdentity: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// Collapsed strip tail sentinel.
        case collapsedTail
        /// Expanded list tail sentinel.
        case expandedTail
    }

    public let generation: CandidateGeneration?
    public let frontier: Int?
    public let kind: Kind

    public init(generation: CandidateGeneration?, frontier: Int?, kind: Kind) {
        self.generation = generation
        self.frontier = frontier
        self.kind = kind
    }
}

/// One accumulating real candidate: carries its engine page ownership and in-page index.
public struct BrowserCandidate: Identifiable, Equatable, Sendable {
    public let pageIndex: Int
    public let pageLocalIndex: Int
    public let candidate: Candidate

    public init(pageIndex: Int, pageLocalIndex: Int, candidate: Candidate) {
        self.pageIndex = pageIndex
        self.pageLocalIndex = pageLocalIndex
        self.candidate = candidate
    }

    /// Stable identity: page number + in-page index (candidate text can repeat, so text cannot be the identity).
    public var id: String { "\(pageIndex):\(pageLocalIndex)" }
    public var text: String { candidate.text }
    public var comment: String { candidate.comment }
    public var index: Int { candidate.index }
    /// Engine-authored visible slot marker. A declared display label wins; when
    /// absent, the engine's select key is shown. Neither is synthesized from the
    /// comment or absolute index.
    public var selectionBadge: String? {
        let label = candidate.selectLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let label, !label.isEmpty { return label }
        let key = candidate.selectKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var selectKey: String? { candidate.selectKey }
    public var selectLabel: String? { candidate.selectLabel }
}

/// Cross-page candidate accumulator. A pure value type, unit-testable; renderers only read it.
public struct CandidateBrowser: Equatable, Sendable {
    public private(set) var generation: CandidateGeneration?
    /// Accumulated candidates, ascending by (pageIndex, pageLocalIndex); continuous across pages, no placeholders, no fake candidates.
    public private(set) var entries: [BrowserCandidate] = []
    /// Page numbers fetched read-only so far.
    public private(set) var loadedPages: Set<Int> = []
    /// The real engine current page (reset anchor). Earlier pages 0...enginePageIndex-1 are considered present.
    public private(set) var enginePageIndex: Int = 0
    /// The next page to read read-only: fill earlier pages first, then continue past the loaded pages;
    /// nil = all reachable pages covered / not browsable.
    public private(set) var nextPageToLoad: Int?
    /// Whether unloaded candidate pages may remain.
    public private(set) var hasMore: Bool = false
    /// Whether the end page has been confirmed backward (a read returned less than a page, or the engine's canPageForward == false).
    private var forwardExhausted: Bool = false
    /// Pages known to be incompletely read (short/empty earlier pages or `.unavailable`). **Not in loadedPages**,
    /// so the frontier stays on them and they can be retried; never passed off as "fully covered".
    public private(set) var incompletePages: Set<Int> = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Whether the next page to read is "before the current page" (the user needs an entry to fill earlier pages).
    public var needsEarlier: Bool {
        guard let nextPageToLoad else { return false }
        return nextPageToLoad < enginePageIndex
    }

    private var maxKnownPage: Int { max(enginePageIndex, loadedPages.max() ?? enginePageIndex) }

    /// Called when a real engine state arrives (every refresh). Rules:
    ///   * not composing / English with no candidates: clear everything; English composition with engine candidates browses as usual;
    ///   * identity changed: rebuild authoritatively anchored on the real current page;
    ///   * identity unchanged + **current candidates empty**: an empty result is authoritative, so old entries /
    ///     loadedPages / frontier / hasMore are cleared first and an identity no-op must not retain old browsing;
    ///   * identity unchanged + non-empty and browsing was cleared: recover from empty and rebuild the anchor (not a permanent no-op);
    ///   * identity unchanged + non-empty with existing browsing: a display-only refresh, kept as-is (including preedit changes).
    /// `revision` is incremented by the host after every real action/state recomputation through the engine, so a
    /// candidate set changed by options/reconversion/learning/session under the same raw code is still invalidated.
    public mutating func reset(_ state: CandidatePresentationState) {
        let nextGeneration: CandidateGeneration?
        if state.hasCandidateMenu && (!state.isEnglishMode || !state.candidates.isEmpty) {
            nextGeneration = CandidateGeneration(
                revision: state.revision, schemaID: state.schemaID, layout: state.layout,
                rawInput: state.rawInput, pageSize: state.pageSize,
                isComposing: state.isComposing, isPrediction: state.isPrediction)
        } else {
            nextGeneration = nil
        }

        guard let nextGeneration else {
            // Engine has no active composition or genuine candidates.
            generation = nil
            clearBrowsing()
            enginePageIndex = state.pageIndex
            return
        }

        if generation != nextGeneration {
            generation = nextGeneration
            if state.candidates.isEmpty {
                // Authoritative empty result: register the real current page but do not auto-fill earlier pages; an empty
                // snapshot has nothing to anchor, so browsing ends and old pages/frontier are never carried over.
                clearBrowsing()
                enginePageIndex = state.pageIndex
                loadedPages.insert(state.pageIndex)
                forwardExhausted = !state.canPageForward
                nextPageToLoad = nil
                hasMore = false
                return
            }
            clearBrowsing()
            enginePageIndex = state.pageIndex
            installAnchorCandidates(state)
            loadedPages.insert(state.pageIndex)
            forwardExhausted = !state.canPageForward
            recomputeFrontier(pageSize: state.pageSize)
            return
        }

        // Identity unchanged: an empty result is authoritative and clears old state first; non-empty with no browsing recovers from empty.
        if state.candidates.isEmpty {
            clearBrowsing()
            enginePageIndex = state.pageIndex
            loadedPages.insert(state.pageIndex)
            forwardExhausted = !state.canPageForward
            nextPageToLoad = nil
            hasMore = false
            return
        }
        if entries.isEmpty {
            // Non-empty again under the same identity after a clear: rebuild the anchor to avoid a permanent no-op.
            clearBrowsing()
            enginePageIndex = state.pageIndex
            installAnchorCandidates(state)
            loadedPages.insert(state.pageIndex)
            forwardExhausted = !state.canPageForward
            recomputeFrontier(pageSize: state.pageSize)
        }
        // else: an ordinary non-empty display-only refresh keeps the cross-page browsing.
    }

    private mutating func clearBrowsing() {
        entries.removeAll(keepingCapacity: true)
        loadedPages.removeAll(keepingCapacity: true)
        incompletePages.removeAll(keepingCapacity: true)
        forwardExhausted = false
        nextPageToLoad = nil
        hasMore = false
    }

    private mutating func installAnchorCandidates(_ state: CandidatePresentationState) {
        entries = state.candidates.map {
            BrowserCandidate(pageIndex: state.pageIndex, pageLocalIndex: $0.index, candidate: $0)
        }
    }

    /// Result of one read-only page read. "Successful read (possibly short)" is kept explicitly apart from
    /// "unavailable/failed": upstream `InputSession.readCandidatePage` propagates errors with `throws` instead of
    /// collapsing failures into `[]`; `reading(_:)` maps a throw to `.unavailable` and a successful return (including
    /// empty/short) to `.page`, and `append` decides the real EOF.
    public enum CandidatePageReadResult: Equatable, Sendable {
        /// A successful read, possibly shorter than pageSize. A short read at the tail = real EOF; a short read before
        /// the anchor = incomplete (not sealed). An empty array = no candidates at that position (EOF or normal end).
        case page([Candidate])
        /// Unsupported / read failed (threw). **Never treated as EOF** and the page is not sealed, so it stays retryable.
        case unavailable

        /// Maps a possibly throwing read-only read to a read result: **a throw = unavailable** (kept retryable,
        /// never mistaken for EOF); a successful return (including empty/short) = a successful read, and `append` decides EOF.
        /// This is the decision point of the production path `KeyboardController.loadMoreCandidates`, which gets the
        /// real error through the `throws` surface of `InputSession.readCandidatePage`.
        public static func reading(_ read: () throws -> [Candidate]) -> Self {
            do { return .page(try read()) } catch { return .unavailable }
        }
    }

    /// Result of `append`.
    public enum BrowserAppendResult: Equatable, Sendable {
        /// A complete page (or a real tail EOF) is sealed.
        case appended
        /// Incomplete read / temporarily unavailable: not sealed, kept retryable, the frontier stays on that page.
        case incomplete
        /// Rejected: no active engine candidate identity / already loaded / invalid arguments.
        case rejected
    }

    /// Appends one page read-only (the host reads by offset with a candidate iterator, without engine paging).
    ///
    /// EOF holds only for a successful short read on **the real current page or later**; a short/empty page before
    /// the anchor counts as an incomplete read, not sealed and not skipped (otherwise it would be a permanent hole).
    /// `.unavailable` is never EOF at any position. On `.incomplete` the frontier still points at that page and the
    /// host may retry; since the sentinel identity includes the frontier, a failure leaves the identity unchanged and `onAppear` is not retriggered endlessly.
    @discardableResult
    public mutating func append(
        pageIndex: Int, result: CandidatePageReadResult,
        pageSize: Int
    ) -> BrowserAppendResult {
        guard generation?.hasCandidateMenu == true, pageIndex >= 0, pageSize > 0 else { return .rejected }
        guard !loadedPages.contains(pageIndex) else { return .rejected }

        switch result {
        case .unavailable:
            // Failed/unsupported: clearly retryable, not mistaken for EOF and not sealed.
            incompletePages.insert(pageIndex)
            recomputeFrontier(pageSize: pageSize)
            return .incomplete

        case .page(let candidates):
            let isComplete = candidates.count >= pageSize
            if isComplete {
                loadedPages.insert(pageIndex)
                incompletePages.remove(pageIndex)
                replaceEntries(pageIndex: pageIndex, candidates: candidates)
                recomputeFrontier(pageSize: pageSize)
                return .appended
            }
            // Short or empty page.
            if pageIndex >= enginePageIndex {
                // A successful short read at the tail = real EOF.
                loadedPages.insert(pageIndex)
                incompletePages.remove(pageIndex)
                replaceEntries(pageIndex: pageIndex, candidates: candidates)
                forwardExhausted = true
                recomputeFrontier(pageSize: pageSize)
                return .appended
            }
            // Short page before the anchor: an incomplete read, kept retryable.
            incompletePages.insert(pageIndex)
            replaceEntries(pageIndex: pageIndex, candidates: candidates)
            recomputeFrontier(pageSize: pageSize)
            return .incomplete
        }
    }

    /// Compatibility with old callers (the host passes `[Candidate]`).
    /// `false` = not sealed (duplicate/invalid/incomplete before the anchor/temporarily unavailable), complementary to `.appended`.
    @discardableResult
    public mutating func append(pageIndex: Int, candidates: [Candidate], pageSize: Int) -> Bool {
        append(pageIndex: pageIndex, result: .page(candidates), pageSize: pageSize) == .appended
    }

    /// Replaces a page's entries with its latest read result, so a retry does not accumulate the same page twice.
    private mutating func replaceEntries(pageIndex: Int, candidates: [Candidate]) {
        entries.removeAll { $0.pageIndex == pageIndex }
        guard !candidates.isEmpty else { return }
        entries.append(
            contentsOf: candidates.map {
                BrowserCandidate(pageIndex: pageIndex, pageLocalIndex: $0.index, candidate: $0)
            })
        entries.sort {
            $0.pageIndex != $1.pageIndex
                ? $0.pageIndex < $1.pageIndex
                : $0.pageLocalIndex < $1.pageLocalIndex
        }
    }

    /// Whether any page has been read but is incomplete (still waiting for a retry on the frontier).
    public var hasIncompletePage: Bool { !incompletePages.isEmpty }

    /// Whether the frontier is stopped on a page that is "before the anchor and incompletely read" (the renderer can offer a retry).
    public var hasIncompleteEarlierPage: Bool {
        guard let nextPageToLoad else { return false }
        return incompletePages.contains(nextPageToLoad) && nextPageToLoad < enginePageIndex
    }

    /// Whether the page can still be read read-only (for the host to check before starting a read).
    public func canAppend(pageIndex: Int) -> Bool {
        generation?.hasCandidateMenu == true && pageIndex >= 0 && !loadedPages.contains(pageIndex)
    }

    /// The real identity to commit when an accumulated candidate is selected (in-page index + page number).
    public func selection(for entry: BrowserCandidate) -> (pageIndex: Int, pageLocalIndex: Int) {
        (entry.pageIndex, entry.pageLocalIndex)
    }

    /// Recomputes the frontier: first fill the earliest unloaded page within 0...maxKnownPage, then consider the page after it.
    private mutating func recomputeFrontier(pageSize: Int) {
        guard generation != nil, pageSize > 0 else {
            nextPageToLoad = nil
            hasMore = false
            return
        }
        let top = maxKnownPage
        for page in 0...top where !loadedPages.contains(page) {
            nextPageToLoad = page
            hasMore = true
            return
        }
        if !forwardExhausted {
            nextPageToLoad = top + 1
            hasMore = true
            return
        }
        nextPageToLoad = nil
        hasMore = false
    }

    /// For tests/previews: builds an accumulation directly, without the engine.
    public init(entries: [BrowserCandidate]) {
        self.entries = entries
        self.generation = nil
        self.loadedPages = Set(entries.map(\.pageIndex))
        self.enginePageIndex = entries.map(\.pageIndex).max() ?? 0
        self.nextPageToLoad = nil
        self.hasMore = false
    }
}

public extension BrowserCandidate {
    /// Cross-page absolute index = page number x page size + in-page index. When the engine does not page (pageSize <= 0)
    /// returns nil; the caller must fall back to in-page selection on the current page and never guess.
    func absoluteIndex(pageSize: Int) -> Int? {
        Self.absoluteIndex(pageIndex: pageIndex, pageLocalIndex: pageLocalIndex, pageSize: pageSize)
    }

    static func absoluteIndex(pageIndex: Int, pageLocalIndex: Int, pageSize: Int) -> Int? {
        guard pageSize > 0, pageIndex >= 0, pageLocalIndex >= 0 else { return nil }
        return pageIndex * pageSize + pageLocalIndex
    }
}
