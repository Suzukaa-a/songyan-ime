import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    // MARK: Post-key completion coalescing

    /// Window in which background query results are gathered before being applied.
    static let completionCoalescingWindow: UInt64 = 8_000_000

    /// Every key starts several read-only engine queries on the same 50ms debounce
    /// (spelling report, first reading page, highlighted reading, candidate page).
    /// They finish a few milliseconds apart, and each published result re-rendered
    /// the whole panel: three extra full renders right when the next key tends to
    /// arrive. Each completion awaits this shared point after its engine hop, so
    /// the results resume back-to-back in one main-queue drain and SwiftUI renders
    /// once. Every caller re-checks its own staleness guards after resuming.
    func coalescedCompletionTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            completionWaiters.append(continuation)
            guard completionBarrier == nil else { return }
            completionBarrier = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.completionCoalescingWindow)
                self?.releaseCompletionWaiters()
            }
        }
    }

    private func releaseCompletionWaiters() {
        completionBarrier = nil
        let waiters = completionWaiters
        completionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    public func loadMoreReadings() {
        // Readings belong to a verified compact structure (phone rail or the
        // separate 14-key reading row), not a possibly mislabeled layout kind.
        // The UI and query use the same injected facts.
        guard canLoadReadings else { return }
        // The controller schedules the first page itself on every new composition
        // and several views ask again for the same frontier in the same frame;
        // restarting the debounce for an identical request only delays it.
        let request = (revision: session.compositionRevision, fromIndex: readingFilter.nextIndex)
        if pendingReadingRead?.revision == request.revision,
            pendingReadingRead?.fromIndex == request.fromIndex
        {
            return
        }
        if readingDebounceTask != nil, scheduledReadingRead?.revision == request.revision,
            scheduledReadingRead?.fromIndex == request.fromIndex
        {
            return
        }
        readingDebounceTask?.cancel()
        scheduledReadingRead = request
        setReadingQueryPending(true)
        readingDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            // A newer request may have replaced this task after the sleep ended.
            guard let self, !Task.isCancelled else { return }
            self.readingDebounceTask = nil
            self.scheduledReadingRead = nil
            self.startReadingRead()
        }
    }

    func setReadingQueryPending(_ value: Bool) {
        if readingQueryPending != value { readingQueryPending = value }
    }

    private func startReadingRead() {
        guard canLoadReadings, snapshot.pageSize > 0 else {
            if pendingReadingRead == nil { setReadingQueryPending(false) }
            return
        }
        if pendingReadingRead != nil {
            readingNeedsRecheck = true
            return
        }
        let revision = session.compositionRevision
        let fromIndex = readingFilter.nextIndex
        // Each hop holds the engine queue; a key landing mid-hop waits for it on the
        // main thread. Small hops keep that worst case short while typing.
        let quantum = min(snapshot.pageSize, 4)
        // Publish a row at a time, never cell by cell: the first composition batch
        // prefetches the leading candidates, and a filtered read keeps scanning (in
        // bounded hops) until a full row of matches exists or the list ends.
        let requested =
            !readingFilter.isFiltering && fromIndex < Self.automaticReadingPrefetchLimit
            ? Self.automaticReadingPrefetchLimit - fromIndex
            : (readingFilter.isFiltering ? Self.automaticReadingPrefetchLimit : quantum)
        let filter = readingFilter
        let rowTarget = filter.isFiltering ? Self.filteredReadingRowTarget : Int.max
        pendingReadingRead = (revision, fromIndex)
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        Task { @MainActor in
            let result: Result<[ReadingCandidate]?, Error>
            // A batch that stopped at a full row is not the end of the list.
            var stoppedAtRow = false
            do {
                result = .success(
                    try await CandidateReadingBatch.read(
                        fromIndex: fromIndex, count: requested, quantum: quantum,
                        isCurrent: {
                            session.engine === engine && canLoadReadings
                                && session.compositionRevision == revision
                        },
                        enough: { batch in
                            stoppedAtRow = filter.matchCount(in: batch) >= rowTarget
                            return stoppedAtRow
                        },
                        fetch: { [liveCompositionRevision] offset, count in
                            try await EngineOpQueue.async {
                                guard liveCompositionRevision.matches(revision) else { throw CancellationError() }
                                return try engine.readCandidatesWithReadings(fromIndex: offset, count: count)
                            }
                        }))
            } catch {
                result = .failure(error)
            }
            await coalescedCompletionTurn()
            pendingReadingRead = nil
            if session.engine === engine, canLoadReadings,
                session.compositionRevision == revision, readingFilter.revision == revision,
                readingFilter.nextIndex == fromIndex
            {
                switch result {
                case .success(let page?):
                    rememberCharacterReadings(page)
                    let firstMatch = readingFilter.matches.first?.index
                    readingFilter.append(
                        page, requested: stoppedAtRow ? page.count : requested,
                        revision: revision)
                    if readingFilter.isFiltering, readingFilter.matches.first?.index != firstMatch {
                        publishFilteredMarkedComposition()
                    } else if highlightedReadCompleted, highlightedReading.isEmpty, snapshot.hidesNumericTransportCode {
                        // New proven readings may now spell a sentence (`sentenceSpelling`).
                        publishFilteredMarkedComposition()
                    }
                case .success(nil): readingBackendSupported = false
                case .failure: readingFilter.failed()
                }
            }
            // Settle the flag in the same turn as the result; a recheck below
            // raises it again if it really schedules another page.
            if readingDebounceTask == nil { setReadingQueryPending(false) }
            settleRailSelection()
            if readingNeedsRecheck {
                readingNeedsRecheck = false
                loadMoreReadings()
            }
        }
    }
    public func selectReading(_ value: String) {
        guard session.compactSpellingLayout, snapshot.isComposing,
            readingFilter.revision == session.compositionRevision
        else { return }
        readingFilter.select(value)
        publishFilteredMarkedComposition()
    }
    public func undoReadingSelection() {
        guard session.compactSpellingLayout else { return }
        readingFilter.undoSelection()
        publishFilteredMarkedComposition()
    }
    /// The field follows the filter's first match (see `markedComposition`).
    private func publishFilteredMarkedComposition() {
        guard snapshot.isComposing, !holdsMarkedCompositionForReading else { return }
        publishMarked(markedComposition)
    }
    public func clearReadingSelection() { readingFilter.clearSelection() }
}
