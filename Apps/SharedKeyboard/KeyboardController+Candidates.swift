import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    // MARK: Confirm / candidates

    /// Unified space/return semantics (real librime compatibility; the front end does not guess engine key behavior):
    ///   - Composing: `session.commitComposition()` confirms the highlighted/first candidate if any;
    ///     with no candidates the engine's return commits the raw composition text (the engine owns it, the key is never swallowed).
    ///   - Empty composition: inserts the space/newline directly.
    public func confirmOrInsert(commitWhenIdle: String) {
        if snapshot.isComposing {
            commitComposition()
        } else {
            session.insertLiteral(commitWhenIdle)
        }
    }

    public func selectCandidate(_ index: Int) {
        let endStallWatch = KeyboardStallReport.begin("select")
        defer { endStallWatch() }
        session.selectCandidate(index)
    }

    /// Real commit for cross-page accumulated candidates: page number + in-page index → engine absolute index.
    /// With an unpaged engine (pageSize == 0) it degrades to in-page selection on the current page, never guessing.
    public func selectCandidate(pageIndex: Int, pageLocalIndex: Int) {
        guard
            let absolute = BrowserCandidate.absoluteIndex(
                pageIndex: pageIndex, pageLocalIndex: pageLocalIndex, pageSize: snapshot.pageSize)
        else {
            selectCandidate(pageLocalIndex)
            return
        }
        // The tapped text lets a selection made while code keys still decode find the
        // candidate again even when it came from a browsed page.
        let seen = candidateBrowser.entries.first {
            $0.pageIndex == pageIndex && $0.pageLocalIndex == pageLocalIndex
        }?.text
        let endStallWatch = KeyboardStallReport.begin("select")
        defer { endStallWatch() }
        session.selectCandidateAbsolute(absolute, seenText: seen)
    }

    public func selectCandidateAbsolute(_ index: Int) {
        let endStallWatch = KeyboardStallReport.begin("select")
        defer { endStallWatch() }
        session.selectCandidateAbsolute(index)
    }

    /// Loads the next unloaded page read-only during continuous browsing: reads by offset through the engine's
    /// candidate iterator, without calling nextPage/PageDown and without changing the engine's current
    /// page/highlight or marked; no-op on the last page or an unpaged engine.
    ///
    /// Failure and EOF are kept apart: the read runs on the engine's serial background queue at the real
    /// offset. An unavailable engine or a thrown read yields `.unavailable`, and `CandidateBrowser` keeps
    /// the page retryable, never posing as EOF; success (including an empty/short tail read) yields `.page`,
    /// and the model decides true EOF. An engine without read-only browsing returns `[]` from
    /// `readCandidatePage` (normal termination), so there is no endless retry. On failure the frontier /
    /// generation stay unchanged and the tail sentinel identity is stable, so `onAppear` does not re-fire
    /// unboundedly; the user can retry manually via the previous/next page entries.
    public func loadMoreCandidates() {
        guard !retired else { return }
        guard let page = candidateBrowser.nextPageToLoad,
            candidateBrowser.hasMore, snapshot.isComposing || snapshot.isPrediction
        else { return }
        let size = snapshot.pageSize
        guard size > 0, candidateBrowser.canAppend(pageIndex: page) else { return }
        let generation = candidateBrowser.generation
        if let pendingCandidateRead, pendingCandidateRead.generation == generation,
            pendingCandidateRead.page == page
        {
            return
        }
        guard session.supportsReadOnlyBrowsing, session.engine.inputUnavailableReason == nil else {
            candidateBrowser.append(pageIndex: page, result: .unavailable, pageSize: size)
            return
        }
        pendingCandidateRead = (generation, page)
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        let pageCount = Self.candidateBrowsePagesPerRead
        Task { @MainActor in
            // Several pages per engine hop, appended in one turn: a short row fills
            // in one update instead of growing page by page under the user's eyes.
            let results: [CandidateBrowser.CandidatePageReadResult]
            do {
                let candidates = try await EngineOpQueue.async {
                    try engine.readCandidates(fromIndex: page * size, count: size * pageCount)
                }
                results = Self.pageResults(candidates, pageSize: size, pageCount: pageCount)
            } catch {
                results = [.unavailable]
            }
            await coalescedCompletionTurn()
            guard !retired, session.engine === engine, candidateBrowser.generation == generation,
                snapshot.isComposing || snapshot.isPrediction,
                snapshot.pageSize == size
            else { return }
            if pendingCandidateRead?.generation == generation && pendingCandidateRead?.page == page {
                pendingCandidateRead = nil
            }
            // One publish per read: each page assigned on its own re-renders the bar again mid-fling.
            var browser = candidateBrowser
            for (offset, result) in results.enumerated() {
                guard browser.canAppend(pageIndex: page + offset) else { break }
                browser.append(pageIndex: page + offset, result: result, pageSize: size)
            }
            candidateBrowser = browser
        }
    }

    static let candidatePagesPerRead = 3
    /// Pages per read while the user scrolls. Off the key path, so it can be larger:
    /// a fling outruns a small batch and stalls at the loaded end.
    static let candidateBrowsePagesPerRead = 6

    /// Split one contiguous read into page-local pages; a short page is the real end.
    static func pageResults(
        _ candidates: [Candidate], pageSize: Int,
        pageCount: Int
    ) -> [CandidateBrowser.CandidatePageReadResult] {
        var results: [CandidateBrowser.CandidatePageReadResult] = []
        for index in 0..<pageCount {
            let chunk = candidates.dropFirst(index * pageSize).prefix(pageSize).enumerated().map {
                Candidate(
                    index: $0.offset, text: $0.element.text, comment: $0.element.comment,
                    selectKey: $0.element.selectKey, selectLabel: $0.element.selectLabel)
            }
            results.append(.page(Array(chunk)))
            if chunk.count < pageSize { break }
        }
        return results
    }

    public func nextPage() { session.nextPage() }
    public func previousPage() { session.previousPage() }

    /// Backspace (may be called repeatedly by UI long-press; idempotent):
    ///  - Compact-layout reading filter/composition lock: first undoes the latest choice (there is no separate undo button);
    ///  - English direct input: always delegates to the host to delete committed characters;
    ///  - Chinese composing: the engine deletes a code;
    ///  - Empty composition: delegates to the host.
    public func handleBackspaceTap() {
        guard inputUnavailableReason == nil else { return }
        // The newest press first: a key the engine has not decoded yet is just taken back.
        if session.removeLastPendingCode() { return }
        // Locked: the first press only restores and releases the lock without sending Backspace; the next press does the normal delete.
        // The newest choice is undone first: a reading narrowed after the lock.
        if snapshot.isComposing, session.compactSpellingLayout, readingFilter.isFiltering,
            readingFilter.revision == session.compositionRevision
        {
            undoReadingSelection()
            return
        }
        if ambiguityPicker.phase == .locked, ambiguityEligible {
            _ = undoAmbiguityLock()
            return
        }
        if inputMode == .english || !snapshot.isComposing {
            // Post-commit predictions close first; the same tap still deletes like idle.
            if session.snapshot.isPrediction, !session.dismissPrediction() { return }
            if onRequestDeleteBackward != nil {
                deleteSequence += 1
                onRequestDeleteBackward?()
                if !englishWord.isEmpty {
                    englishWord.removeLast()
                    scheduleEnglishSuggestions()
                } else if let previous = previousEnglishWord {
                    // The space after the finished word is gone: that word is being
                    // typed again, so its completions come back.
                    previousEnglishWord = nil
                    englishWord = previous
                    scheduleEnglishSuggestions()
                } else if !englishSuggestions.isEmpty {
                    scheduleEnglishSuggestions()
                }
            }
        } else {
            session.tap(.backspace)
        }
    }

    /// Cycles keyboards. Only within `userKeyboardChoices` (published roster ∩ runnable with current resources):
    /// the layout key and the long-press switcher share the same criterion (`UserKeyboardRoster.cycleTarget`).
    /// With an empty roster, or a roster of one that is the current entry, it is a safe no-op; it never falls back to
    /// `availableLayouts` / the 26/14/9 layouts themselves (those are not user-added keyboards).
    public func cycleLayout() {
        guard
            let next = UserKeyboardRoster.cycleTarget(
                currentSchemaID: selectedSchemaID,
                currentLayout: layout,
                in: userKeyboardChoices)
        else { return }
        _ = selectUserKeyboard(next)
    }

    func refresh() {
        guard !retired else { return }
        #if DEBUG
            let endRefreshInterval = DebugProbe.refreshInterval()
            defer {
                endRefreshInterval()
                DebugProbe.writeSnapshot(
                    role: DebugProbe.currentRole,
                    [
                        "layout": layout.rawValue,
                        "schemaID": selectedSchemaID,
                        "engineKind": String(describing: engineKind),
                        "isComposing": snapshot.isComposing,
                        "candidateCount": snapshot.candidates.count,
                        "inputUnavailableReason": inputUnavailableReason ?? NSNull(),
                        "inputError": inputError != nil,
                    ])
            }
        #endif
        // `@Published` notifies on every assignment, equal or not; every
        // subscriber (including the whole panel) then re-evaluates. Only write
        // values that actually changed.
        if readingFilter.revision != session.compositionRevision {
            deferredRailSelection = nil
            readingFilter.reset(revision: session.compositionRevision)
            syncReadingCoverage()
        }
        if !readingBackendSupported { readingBackendSupported = true }
        let s = session.snapshot
        liveCompositionRevision.set(session.compositionRevision)
        if snapshot != s {
            if inputError != nil { inputError = nil }
            snapshot = s
        }
        if inputUnavailableReason != session.inputUnavailableReason {
            inputUnavailableReason = session.inputUnavailableReason
        }
        if engineKind != session.engine.kind { engineKind = session.engine.kind }
        if options != session.options { options = session.options }
        let prevLayout = layout
        let previousSchema = selectedSchemaID
        if layout != session.layout { layout = session.layout }
        if selectedSchemaID != session.selectedSchemaID { selectedSchemaID = session.selectedSchemaID }
        if inputUnavailableReason == nil && (prevLayout != layout || previousSchema != selectedSchemaID) {
            reportSuccessfulSelectionChange()
        }
        if previousSchema != selectedSchemaID {
            // Another scheme may bring another (or no) English dictionary.
            if englishSuggestionsSupported != nil { englishSuggestionsSupported = nil }
            probeEnglishSuggestions()
        }
        refreshHighlightedReading(for: s)
        if !(s.isComposing && holdsMarkedCompositionForReading) {
            reportCompositionPresentation(
                s.isComposing
                    ? (onMarkedComposition == nil ? .keyboard(reason: "输入框暂不可用") : .awaitingHost) : .idle)
            publishMarked(s.isComposing ? markedComposition : nil)
        }
        if layout != prevLayout {
            if let message = (session.engine as? RimeBackend)?.lastErrorText {
                Self.diagnosticLogger.error("option refresh after layout change failed: \(message, privacy: .private)")
                optionError = "无法读取当前方案的选项，请重试。"
            } else {
                optionError = nil
            }
            onLayoutChanged?(layout)
        }
        if inputMode != session.mode {
            inputMode = session.mode
        }
        if !isEnglishMode, !englishWord.isEmpty || previousEnglishWord != nil || !englishSuggestions.isEmpty {
            resetEnglishWord()
        }
        if isEnglishMode, englishSuggestionsSupported == nil { probeEnglishSuggestions() }
        if isEnglishMode, englishWord.isEmpty,
            ABCSuggestionSlots.enginePredictions(s, limit: Self.englishSuggestionLimit).map(\.text)
                != englishEnginePredictionTexts
        {
            scheduleEnglishSuggestions()
        }
        if !isEnglishMode, wasEnglishMode { releaseWordSession() }
        wasEnglishMode = isEnglishMode
        if shiftState != session.shiftState {
            shiftState = session.shiftState
        }
        // Candidate accumulation follows the real engine state as it arrives: always reset wholesale (even with empty
        // candidates), with the generation carrying session.compositionRevision, so a candidate set for the same
        // raw code genuinely invalidates when options/reconversion/learning/session change; preedit is excluded.
        // Reset a copy: mutating the `@Published` value in place republishes the
        // whole panel even when the browser state is unchanged.
        var browser = candidateBrowser
        browser.reset(
            CandidatePresentationState(
                snapshot: snapshot,
                isEnglishMode: isEnglishMode,
                layout: layout.rawValue,
                revision: session.compositionRevision))
        // Pages a deferred key batch already read with its decode land with the snapshot,
        // so the row fills in this render instead of a separate one after `loadMoreCandidates`.
        if let lookahead = session.candidateLookahead, s.pageIndex == 0, s.pageSize > 0,
            lookahead.pageSize == s.pageSize, lookahead.rawInput == s.rawInput
        {
            let results = Self.pageResults(
                lookahead.candidates, pageSize: s.pageSize,
                pageCount: Self.candidatePagesPerRead - 1)
            for (offset, result) in results.enumerated() {
                guard browser.canAppend(pageIndex: 1 + offset) else { break }
                browser.append(pageIndex: 1 + offset, result: result, pageSize: s.pageSize)
            }
        }
        if browser != candidateBrowser { candidateBrowser = browser }
        // Layout/schema changed, or a composition state that cannot be disambiguated: clear state.
        if prevLayout != layout || previousSchema != selectedSchemaID {
            ambiguityPicker.clear()
        }
        refreshAmbiguityPicker()
        // The first reading page of a new composition is requested here, in the
        // same turn as the snapshot, so `readingQueryPending` is already raised
        // on the first frame that shows the composition.
        if canLoadReadings, readingFilter.entries.isEmpty {
            loadMoreReadings()
        } else if !canLoadReadings, pendingReadingRead == nil {
            readingDebounceTask?.cancel()
            readingDebounceTask = nil
            scheduledReadingRead = nil
            setReadingQueryPending(false)
        }
    }

    public func dismissRecoverableError() {
        guard session.inputUnavailableReason == nil else { return }
        inputError = nil
    }
}
