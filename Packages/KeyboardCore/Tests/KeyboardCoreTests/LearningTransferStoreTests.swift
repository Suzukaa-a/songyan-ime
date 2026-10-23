import XCTest
import os

@testable import KeyboardCore

/// Behaviour tests for `LearningTransferStore`: the request state machine, the execution lease,
/// artifact binding to the request, and the safety backup.
final class LearningTransferStoreTests: XCTestCase {

    private var createdRoots: [URL] = []
    private let fixedDate = Date(timeIntervalSince1970: 1_767_225_600)

    override func tearDown() {
        for root in createdRoots { try? FileManager.default.removeItem(at: root) }
        createdRoots = []
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeRoot(create: Bool = true) throws -> URL {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-transfer-\(UUID().uuidString)", isDirectory: true)
        let root = container.appendingPathComponent("store", isDirectory: true)
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        createdRoots.append(container)
        return root
    }

    private func store(_ root: URL) -> LearningTransferStore { LearningTransferStore(directory: root) }

    private func archive(
        _ payload: String = "学习数据",
        sourceID: String = "rime-ice",
        resourceRevision: String = "rev-1"
    ) throws -> LearningBackupArchive {
        try LearningBackupArchive(
            sourceID: sourceID, resourceRevision: resourceRevision, sourceName: "雾凇拼音",
            engineVersion: "1.9.0", createdAt: fixedDate,
            dictionaries: [
                try LearningBackupArchive.DictionarySnapshot(
                    name: "words", data: Data(payload.utf8))
            ])
    }

    private func assertThrows<T>(
        _ expected: LearningTransferStoreError,
        file: StaticString = #filePath, line: UInt = #line,
        _ expression: @autoclosure () throws -> T
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? LearningTransferStoreError, expected,
                "actual error: \(error)", file: file, line: line)
        }
    }

    private func submitBackup(_ store: LearningTransferStore) throws -> LearningTransferStore.State {
        try store.submitBackup(sourceID: "rime-ice", resourceRevision: "rev-1", sourceName: "雾凇拼音")
    }

    private func claim(
        _ store: LearningTransferStore, _ state: LearningTransferStore.State,
        lease: LearningTransferStore.WorkerLease
    ) throws -> LearningTransferStore.State? {
        try store.claim(
            requestID: state.id, sourceID: state.sourceID,
            resourceRevision: state.resourceRevision, lease: lease)
    }

    /// Submits a request and moves it to running under a fresh lease.
    private func runningRequest(_ store: LearningTransferStore, restore: Bool = false)
        throws -> (LearningTransferStore.State, LearningTransferStore.WorkerLease)
    {
        let state = restore ? try store.submitRestore(try archive()) : try submitBackup(store)
        let lease = try XCTUnwrap(try store.acquireWorkerLease())
        _ = try XCTUnwrap(try claim(store, state, lease: lease))
        return (state, lease)
    }

    // MARK: - Reading and submitting

    func testReadWithoutRootOrStateReturnsNilAndCreatesNothing() throws {
        let missing = try makeRoot(create: false)
        XCTAssertNil(try store(missing).read())
        XCTAssertNil(try store(missing).readLatestSafetyBackup())
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(try store(try makeRoot()).read())
    }

    func testWorkerPathsFailWhenRootIsMissing() throws {
        let transfer = store(try makeRoot(create: false))
        assertThrows(.storeMissing, try transfer.acquireWorkerLease())
        assertThrows(.storeMissing, try transfer.cancel(requestID: UUID()))
        assertThrows(.storeMissing, try transfer.readBackupOutput(requestID: UUID()))
    }

    func testSubmitCreatesRootAndPersistsPending() throws {
        let transfer = store(try makeRoot(create: false))
        let state = try submitBackup(transfer)
        XCTAssertEqual(state.status, .pending)
        XCTAssertNil(state.processID)
        XCTAssertEqual(try transfer.read(), state)
    }

    func testSubmitRejectsInvalidMetadata() throws {
        let transfer = store(try makeRoot())
        XCTAssertThrowsError(try transfer.submitBackup(sourceID: "", resourceRevision: "rev-1", sourceName: "x"))
        XCTAssertThrowsError(try transfer.submitBackup(sourceID: "a", resourceRevision: "rev-1", sourceName: ""))
        XCTAssertNil(try transfer.read())
    }

    func testActiveRequestBlocksNewSubmitButTerminalStatesDoNot() throws {
        let transfer = store(try makeRoot())
        let pending = try submitBackup(transfer)
        assertThrows(.requestInProgress(.pending), try submitBackup(transfer))

        let lease = try XCTUnwrap(try transfer.acquireWorkerLease())
        _ = try XCTUnwrap(try claim(transfer, pending, lease: lease))
        assertThrows(.requestInProgress(.running), try submitBackup(transfer))

        _ = try transfer.fail(requestID: pending.id, lease: lease, message: "失败")
        let next = try submitBackup(transfer)
        XCTAssertNotEqual(next.id, pending.id)
    }

    // MARK: - Cancel and claim

    func testClaimMovesPendingToRunningOwnedByLease() throws {
        let transfer = store(try makeRoot())
        let state = try submitBackup(transfer)
        let lease = try XCTUnwrap(try transfer.acquireWorkerLease())
        let running = try XCTUnwrap(try claim(transfer, state, lease: lease))
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.processID, lease.id)
        XCTAssertNil(try claim(transfer, state, lease: lease), "a second claim finds nothing pending")
        XCTAssertNil(
            try transfer.claim(
                requestID: UUID(), sourceID: "rime-ice",
                resourceRevision: "rev-1", lease: lease))
    }

    func testClaimWithDifferentIdentityThrowsAndLeavesRequestPending() throws {
        let transfer = store(try makeRoot())
        let state = try submitBackup(transfer)
        let lease = try XCTUnwrap(try transfer.acquireWorkerLease())
        assertThrows(
            .sourceIdentityMismatch,
            try transfer.claim(
                requestID: state.id, sourceID: "other",
                resourceRevision: "rev-1", lease: lease))
        XCTAssertEqual(try transfer.read()?.status, .pending)
    }

    func testCancelWinsOnlyBeforeClaim() throws {
        let transfer = store(try makeRoot())
        let first = try submitBackup(transfer)
        XCTAssertEqual(try transfer.cancel(requestID: first.id).status, .cancelled)
        let lease = try XCTUnwrap(try transfer.acquireWorkerLease())
        XCTAssertNil(try claim(transfer, first, lease: lease), "a cancelled request cannot be claimed")
        lease.release()

        let second = try submitBackup(transfer)
        let claimLease = try XCTUnwrap(try transfer.acquireWorkerLease())
        _ = try claim(transfer, second, lease: claimLease)
        assertThrows(.notCancellable(.running), try transfer.cancel(requestID: second.id))
    }

    func testConcurrentClaimSucceedsExactlyOnce() throws {
        for _ in 0..<8 {
            let root = try makeRoot()
            let state = try submitBackup(store(root))
            let lease = try XCTUnwrap(try store(root).acquireWorkerLease())
            let results = LockedBox([LearningTransferStore.State?]())
            DispatchQueue.concurrentPerform(iterations: 4) { _ in
                let claimed = try? LearningTransferStore(directory: root).claim(
                    requestID: state.id, sourceID: state.sourceID,
                    resourceRevision: state.resourceRevision, lease: lease)
                results.mutate { $0.append(claimed ?? nil) }
            }
            XCTAssertEqual(results.value.compactMap { $0 }.count, 1)
        }
    }

    // MARK: - Execution lease

    func testWorkerLeaseIsExclusiveAndReleasedWithTheReference() throws {
        let root = try makeRoot()
        var held: LearningTransferStore.WorkerLease? = try XCTUnwrap(try store(root).acquireWorkerLease())
        XCTAssertNil(try store(root).acquireWorkerLease(), "a second holder is refused")
        held = nil
        XCTAssertNotNil(try store(root).acquireWorkerLease(), "dropping the lease frees it")
        _ = held
    }

    func testReleasedLeaseIsRejectedEvenWithMatchingIdentity() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer)
        lease.release()
        assertThrows(.invalidWorkerLease, try transfer.fail(requestID: state.id, lease: lease, message: "x"))
        XCTAssertEqual(try transfer.read()?.status, .running)
    }

    func testLeaseFromAnotherDirectoryIsRejected() throws {
        let owner = store(try makeRoot())
        let other = store(try makeRoot())
        let state = try submitBackup(other)
        let lease = try XCTUnwrap(try owner.acquireWorkerLease())
        assertThrows(.invalidWorkerLease, try claim(other, state, lease: lease))
    }

    func testRecoverInterruptedMarksOrphanedRunningAndKeepsSafetyBackup() throws {
        let root = try makeRoot()
        let crashed = store(root)
        let stateID: UUID
        do {
            let (state, lease) = try runningRequest(crashed, restore: true)
            try crashed.saveSafetyBackup(requestID: state.id, lease: lease, archive: try archive("旧安全备份"))
            stateID = state.id
        }  // the lease is dropped here, as if the old process died

        let restarted = store(root)
        XCTAssertEqual(try restarted.read()?.status, .running)
        let lease = try XCTUnwrap(try restarted.acquireWorkerLease())
        let interrupted = try XCTUnwrap(try restarted.recoverInterrupted(lease: lease))
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertTrue(interrupted.hasSafetyBackup)
        XCTAssertEqual(try restarted.readLatestSafetyBackup(), try archive("旧安全备份"))
        XCTAssertNil(try restarted.recoverInterrupted(lease: lease), "recovering twice changes nothing")
        XCTAssertNil(
            try restarted.claim(
                requestID: stateID, sourceID: "rime-ice",
                resourceRevision: "rev-1", lease: lease))
        XCTAssertEqual(try submitBackup(restarted).status, .pending, "a terminal state lets the user start over")
    }

    func testRecoverInterruptedLeavesOwnRunningRequestAlone() throws {
        let transfer = store(try makeRoot())
        let (_, lease) = try runningRequest(transfer)
        XCTAssertNil(try transfer.recoverInterrupted(lease: lease))
        XCTAssertEqual(try transfer.read()?.status, .running)
    }

    func testConcurrentReleaseAndCompleteNeverTearsTheState() throws {
        for iteration in 0..<40 {
            let transfer = store(try makeRoot())
            let (state, lease) = try runningRequest(transfer)
            let output = try archive("并发产出-\(iteration)")
            let outcome = LockedBox<Result<LearningTransferStore.State, Error>?>(nil)
            let group = DispatchGroup()
            DispatchQueue.global().async(group: group) {
                outcome.mutate {
                    $0 = Result { try transfer.completeBackup(requestID: state.id, lease: lease, archive: output) }
                }
            }
            DispatchQueue.global().async(group: group) { lease.release() }
            group.wait()

            switch try XCTUnwrap(outcome.value) {
            case .success(let finished):
                XCTAssertEqual(try transfer.read(), finished)
                XCTAssertEqual(try transfer.readBackupOutput(requestID: state.id), output)
            case .failure(let error):
                XCTAssertEqual(error as? LearningTransferStoreError, .invalidWorkerLease)
                XCTAssertEqual(try transfer.read()?.status, .running)
            }
        }
    }

    // MARK: - Artifacts and safety backup

    func testRestoreInputIsBoundToItsRequest() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer, restore: true)
        XCTAssertEqual(try transfer.readRestoreInput(requestID: state.id, lease: lease), try archive())
        assertThrows(.staleRequest, try transfer.readRestoreInput(requestID: UUID(), lease: lease))
    }

    func testStaleRestoreInputIsNotUsedByANewRequest() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer, restore: true)
        _ = try transfer.fail(requestID: state.id, lease: lease, message: "失败")
        lease.release()

        // A new backup request must not be able to read the previous restore payload as its own.
        let next = try submitBackup(transfer)
        let nextLease = try XCTUnwrap(try transfer.acquireWorkerLease())
        _ = try claim(transfer, next, lease: nextLease)
        XCTAssertThrowsError(try transfer.readRestoreInput(requestID: next.id, lease: nextLease))
    }

    func testBackupOutputIsWrittenBeforeSucceededAndBoundToRequest() throws {
        let transfer = store(try makeRoot())
        let state = try submitBackup(transfer)
        assertThrows(.artifactUnavailable("backup-output.json"), try transfer.readBackupOutput(requestID: state.id))

        let lease = try XCTUnwrap(try transfer.acquireWorkerLease())
        _ = try claim(transfer, state, lease: lease)
        let output = try archive("产出")
        let done = try transfer.completeBackup(requestID: state.id, lease: lease, archive: output)
        XCTAssertEqual(done.status, .succeeded)
        XCTAssertEqual(try transfer.readBackupOutput(requestID: state.id), output)
        assertThrows(.requestNotFound, try transfer.readBackupOutput(requestID: UUID()))

        lease.release()
        _ = try submitBackup(transfer)
        assertThrows(.requestNotFound, try transfer.readBackupOutput(requestID: state.id))
    }

    func testRestoreCompletionRequiresSafetyBackup() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer, restore: true)
        assertThrows(.safetyBackupRequired, try transfer.completeRestore(requestID: state.id, lease: lease))
        try transfer.saveSafetyBackup(requestID: state.id, lease: lease, archive: try archive("安全"))
        XCTAssertTrue(try XCTUnwrap(try transfer.read()).hasSafetyBackup)
        XCTAssertEqual(try transfer.completeRestore(requestID: state.id, lease: lease).status, .succeeded)
    }

    func testSafetyBackupOutlivesTheRequestUntilReplaced() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer, restore: true)
        try transfer.saveSafetyBackup(requestID: state.id, lease: lease, archive: try archive("第一份"))
        _ = try transfer.completeRestore(requestID: state.id, lease: lease)
        lease.release()

        _ = try submitBackup(transfer)
        XCTAssertEqual(try transfer.readLatestSafetyBackup(), try archive("第一份"))
    }

    func testWriteFromAnOldRequestOrOwnerIsRejected() throws {
        let transfer = store(try makeRoot())
        let (old, lease) = try runningRequest(transfer)
        _ = try transfer.fail(requestID: old.id, lease: lease, message: "失败")
        let fresh = try submitBackup(transfer)
        assertThrows(.staleRequest, try transfer.fail(requestID: old.id, lease: lease, message: "迟到"))
        XCTAssertEqual(try transfer.read()?.id, fresh.id)

        assertThrows(.ownerMismatch, try transfer.fail(requestID: fresh.id, lease: lease, message: "未认领"))
        assertThrows(
            .ownerMismatch,
            try transfer.completeBackup(
                requestID: fresh.id, lease: lease,
                archive: try archive()))
    }

    func testFailRejectsInvalidMessages() throws {
        let transfer = store(try makeRoot())
        let (state, lease) = try runningRequest(transfer)
        assertThrows(.invalidMessage, try transfer.fail(requestID: state.id, lease: lease, message: ""))
        assertThrows(
            .invalidMessage,
            try transfer.fail(
                requestID: state.id, lease: lease,
                message: String(repeating: "x", count: 600)))
        let failed = try transfer.fail(requestID: state.id, lease: lease, message: "备份失败")
        XCTAssertEqual(failed.message, "备份失败")
    }

    // MARK: - Corrupt and oversized files

    func testCorruptOrOversizedStateIsRejected() throws {
        let root = try makeRoot()
        let transfer = store(root)
        let url = root.appendingPathComponent("current.json")

        try Data("{not json".utf8).write(to: url)
        assertThrows(.malformedState, try transfer.read())

        try Data(count: LearningTransferStore.maximumStateBytes + 1).write(to: url)
        assertThrows(
            .fileTooLarge(slot: "current.json", bytes: LearningTransferStore.maximumStateBytes + 1),
            try transfer.read())
    }

    func testCorruptOrOversizedArtifactIsRejected() throws {
        let root = try makeRoot()
        let transfer = store(root)
        let url = root.appendingPathComponent("safety-backup.json")

        try Data("{}".utf8).write(to: url)
        assertThrows(.malformedArtifact("safety-backup.json"), try transfer.readLatestSafetyBackup())

        let size = LearningTransferStore.maximumArtifactBytes + 1
        try Data(count: size).write(to: url)
        assertThrows(.fileTooLarge(slot: "safety-backup.json", bytes: size), try transfer.readLatestSafetyBackup())
    }

    func testStateDecodeRejectsMissingFields() throws {
        let root = try makeRoot()
        try Data("{\"id\":\"\(UUID().uuidString)\"}".utf8)
            .write(to: root.appendingPathComponent("current.json"))
        assertThrows(.malformedState, try store(root).read())
    }

    func testStateRoundtripsThroughTheCodec() throws {
        let state = try LearningTransferStore.State(
            id: UUID(), operation: .restore, status: .failed, sourceID: "rime-ice",
            resourceRevision: "rev-1", sourceName: "雾凇拼音", createdAt: fixedDate,
            processID: UUID(), message: "失败", hasSafetyBackup: true)
        let data = try LearningBackupArchive.makeEncoder().encode(state)
        XCTAssertEqual(
            try LearningBackupArchive.makeDecoder().decode(LearningTransferStore.State.self, from: data), state)
    }

    func testErrorDescriptionsDoNotLeakSourceNames() throws {
        let transfer = store(try makeRoot())
        _ = try submitBackup(transfer)
        do { _ = try submitBackup(transfer) } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("雾凇拼音"))
        }
    }
}

private final class LockedBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    var value: Value { lock.withLock { $0 } }
    func mutate(_ change: @Sendable (inout Value) -> Void) { lock.withLock { change(&$0) } }
}
