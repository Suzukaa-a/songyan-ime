import XCTest

@testable import KeyboardCore

@MainActor
final class RefreshCoordinationTests: XCTestCase {

    // MARK: - Detail-page latest-wins refresh coordinator

    func testDetailCoordinatorInitialKeyIsZero() {
        let coordinator = DetailRefreshCoordinator()
        XCTAssertEqual(coordinator.key, 0)
    }

    /// The first frame runs only once: the key's initial value is stable and does not change before any request.
    func testDetailCoordinatorKeyStableUntilRequested() {
        let coordinator = DetailRefreshCoordinator()
        let first = coordinator.key
        // Simulate body re-evaluation producing no change.
        XCTAssertEqual(coordinator.key, first)
    }

    /// Each requestRefresh advances the key (re-runs `.task(id:)` once).
    func testDetailCoordinatorRequestAdvancesKey() {
        var coordinator = DetailRefreshCoordinator()
        coordinator.requestRefresh()
        XCTAssertEqual(coordinator.key, 1)
        coordinator.requestRefresh()
        XCTAssertEqual(coordinator.key, 2)
    }

    /// Consecutive triggers cancel old results: after a new read begins, the old token is no longer accepted.
    func testDetailCoordinatorLatestWinsRejectsStaleToken() {
        var coordinator = DetailRefreshCoordinator()
        let oldToken = coordinator.beginRead()
        XCTAssertTrue(coordinator.accepts(oldToken))
        // The view changes again -> a new read begins.
        coordinator.requestRefresh()
        let newToken = coordinator.beginRead()
        XCTAssertNotEqual(oldToken, newToken)
        XCTAssertFalse(coordinator.accepts(oldToken), "a late old read must not overwrite the new snapshot")
        XCTAssertTrue(coordinator.accepts(newToken))
    }

    /// The "Retry" button = requestRefresh -> a new generation; this is a new legitimate read generation.
    func testDetailCoordinatorRetryStartsNewGeneration() {
        var coordinator = DetailRefreshCoordinator()
        let first = coordinator.beginRead()
        // Retry: only increments the key, creates no Task.
        coordinator.requestRefresh()
        let retryToken = coordinator.beginRead()
        XCTAssertFalse(coordinator.accepts(first))
        XCTAssertTrue(coordinator.accepts(retryToken))
    }

    /// After the view disappears (.task cancelled), even if a read wants to write, latest-wins no longer accepts its token:
    /// the caller does not begin a new generation on disappear, so the old token naturally equals "current"; hence on disappear
    /// `Task.isCancelled` is the backstop; this verifies token semantics when no new begin follows disappearance.
    func testDetailCoordinatorTokenRemainsCurrentUntilNextBegin() {
        var coordinator = DetailRefreshCoordinator()
        let token = coordinator.beginRead()
        // View disappears: no new generation begins (the task is cancelled; after the read returns, Task.isCancelled intercepts it).
        XCTAssertTrue(coordinator.accepts(token))
        // Only the next appearance begins a new generation, invalidating the old token.
        let next = coordinator.beginRead()
        XCTAssertFalse(coordinator.accepts(token))
        XCTAssertNotEqual(token, next)
    }

    // MARK: - Structured refresh double gate (cancellation + latest-wins)

    /// After a read returns it may be applied only if `!isCancelled && accepted`: cancelled does not write, stale results do not write.
    func testStructuredRefreshOutcomeRequiresBothGates() {
        XCTAssertTrue(StructuredRefreshOutcome.shouldApply(isCancelled: false, accepted: true))
        XCTAssertFalse(
            StructuredRefreshOutcome.shouldApply(isCancelled: true, accepted: true),
            "nothing may be written after cancellation")
        XCTAssertFalse(
            StructuredRefreshOutcome.shouldApply(isCancelled: false, accepted: false),
            "an old result (token not accepted) must not be written")
        XCTAssertFalse(StructuredRefreshOutcome.shouldApply(isCancelled: true, accepted: false))
    }

    /// Cancellation propagation: after the parent task is cancelled the child read must not apply even if it returns (simulates the double gate).
    func testCancellationPropagatesBeforeApply() async {
        var gate = LatestWinsReadGate()
        let token = gate.begin()
        var applied = false
        let parent = Task {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)  // simulate read latency
            } catch {
                return
            }
            if StructuredRefreshOutcome.shouldApply(
                isCancelled: Task.isCancelled,
                accepted: gate.accepts(token))
            {
                applied = true
            }
        }
        parent.cancel()
        _ = await parent.value
        XCTAssertFalse(applied, "after the parent task is cancelled the read result must not be written")
    }

    /// latest-wins: when the old token is not accepted, it is not applied even if not cancelled.
    func testStaleTokenDoesNotApply() {
        var gate = LatestWinsReadGate()
        let stale = gate.begin()
        _ = gate.begin()  // a new intent invalidates the old token
        var applied = false
        if StructuredRefreshOutcome.shouldApply(isCancelled: false, accepted: gate.accepts(stale)) {
            applied = true
        }
        XCTAssertFalse(applied, "an old result must not overwrite the new value")
    }
}
