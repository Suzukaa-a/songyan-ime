import Foundation
import KeyboardCore
import RimeBridge
import os

// MARK: - Suspension-prevention assertion
//
// The execution lease is an App Group `flock`, and during a merge the engine also holds
// file locks on the learning store in the shared container. After the keyboard view
// disappears the process may be suspended; being suspended while holding a shared-container
// file lock gets the process killed with 0xdead10cc and truncates the merge. The public
// `performExpiringActivity` asks not to be suspended until the work finishes; the system
// may still expire the assertion (expired callback), which behaves as if it was never requested.
final class ProcessActivityAssertion: Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let ended = OSAllocatedUnfairLock(initialState: false)

    init(reason: String) {
        ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { [done] expired in
            // The first callback (expired == false) blocks until end(); an expiry callback just returns.
            guard !expired else { return }
            done.wait()
        }
    }

    func end() {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        if first { done.signal() }
    }

    deinit { end() }
}

// MARK: - Dedicated file I/O queue for learning transfer
//
// Backup/merge of learning data does real disk I/O inside the keyboard extension process
// (reading and writing the `KeyboardLearning` slots under the App Group container, bounded
// archive reads). That I/O is separate from the engine lifecycle queue (`EngineOpQueue`):
// the file queue can be busy for a long time (a merge reads up to 8 MiB and writes several
// slots), and sharing the engine queue would stall the key/candidate path.
//
// Rules:
//  * a dedicated serial `.utility` queue, separate from `EngineOpQueue` and
//    `KeyboardResourceReadQueue`;
//  * results return through a continuation; the MainActor caller only applies the value;
//  * never re-enter this queue from itself (self-wait deadlock) and never call the engine here.
public enum LearningTransferIO {

    private static let queue = DispatchQueue(
        label: "app.songyan.learning.transfer.io",
        qos: .utility)

    /// Runs one piece of disk I/O on the dedicated file queue and awaits its result.
    public static func async<T>(_ body: @escaping @Sendable () throws -> T) async throws -> sending T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// MARK: - Failure reasons (fixed safe text, no paths/IDs/entries)

/// Failure reasons of the execution service. The text is fixed user-facing copy and never contains paths, slot names, dictionary names or identifiers.
public enum KeyboardLearningTransferError: Error, Equatable {
    /// No safety backup before restore (no backup-able dictionary, or the backup failed); the merge must abort.
    case safetyBackupUnavailable
    /// The user started typing while the request was waiting for exclusivity; the current keyboard must not step aside.
    case inputBecameBusy
}

// MARK: - Learning transfer execution service (keyboard extension process only)

/// Execution service for learning-data transfer on the keyboard-extension side.
///
/// The host only submits requests and reads receipts through `LearningTransferStore`; engine reads and
/// writes happen here, in the extension, the only process that can own the engine and `userDirectory`.
/// A request is claimed by the currently visible keyboard (`check` advances one step per call while
/// visible). Anything that cannot be proven (publication identity, resources, input state) fails closed:
/// nothing is written or merged, and success is never faked.
///
/// At most one attempt runs per process. It holds one `WorkerLease` for its whole lifetime, the only proof
/// that the previous executor is gone, and runs the native work under `EngineOwnershipCoordinator`,
/// which stops the serving engine first and restarts it afterwards.
@MainActor
public enum KeyboardLearningTransfer {

    /// Transfer directory name shared with the host (same directory under the App Group container).
    /// A pure constant: `nonisolated` lets container resolution on the file queue reference it safely.
    nonisolated public static let directoryName = "KeyboardLearning"

    /// The single in-process execution task. Cancelling the caller's polling does not affect it.
    private static var worker: Task<Void, Never>?

    /// Only the keyboard extension drives transfers; the host app is not an `.appex`.
    private static let isExtensionProcess = Bundle.main.bundleURL.pathExtension == "appex"

    // MARK: - Entry point

    /// Advances the transfer by one step. The caller may invoke it repeatedly every 1-2 s while visible.
    ///
    /// - Parameters:
    ///   - session: the keyboard session running in this process; resource directories come only from it.
    ///   - isVisibleController: "visible and current controller" check, evaluated once per call:
    ///     an invisible keyboard must not claim work or yield the engine.
    ///   - isFullAccessGranted: Full Access check, evaluated once per attempt and only when a request is
    ///     actually waiting (it is a TCC round trip). Changing Full Access terminates the extension, so it
    ///     is not re-checked mid-attempt.
    ///
    /// Returns immediately; an attempt that has started runs to completion even if the caller stops polling.
    public static func check(
        session: KeyboardPadSession,
        isVisibleController: @escaping @MainActor () -> Bool,
        isFullAccessGranted: @escaping @MainActor () -> Bool
    ) {
        guard isExtensionProcess, worker == nil, isVisibleController() else { return }
        worker = Task { @MainActor in
            defer { worker = nil }
            await attempt(session: session, isFullAccessGranted: isFullAccessGranted)
        }
    }

    // MARK: - One attempt

    private static func attempt(
        session: KeyboardPadSession,
        isFullAccessGranted: @MainActor () -> Bool
    ) async {
        // Container resolution and store construction happen on the dedicated file queue; the main thread does no disk access.
        guard let store = await store() else { return }

        // 1. Read state. Both pending and running continue: running may be an orphan from a crashed
        //    process, and only the execution lease proves the old executor is gone. Terminal states return.
        guard let request = try? await LearningTransferIO.async({ try store.read() }),
            request.status == .pending || request.status == .running,
            isFullAccessGranted()
        else { return }

        // 2. Execution lease. Failing to get it means another executor is still running (contention, not an error).
        //    The activity assertion is created before the lease and released after it, so the process is never suspended while the lock is held.
        let activity = ProcessActivityAssertion(reason: "Songyan learning transfer")
        defer { activity.end() }
        guard let lease = try? await LearningTransferIO.async({ try store.acquireWorkerLease() }) else { return }
        defer { lease.release() }

        // 3. Holding the lease proves any old running request has stopped; mark it interrupted, then
        //    re-read: only a pending request proceeds.
        _ = try? await LearningTransferIO.async { try store.recoverInterrupted(lease: lease) }
        guard let current = try? await LearningTransferIO.async({ try store.read() }),
            current.status == .pending
        else { return }

        // 4. Verify publication identity. A proven mismatch is terminal and must fail visibly;
        //    an unreadable publication keeps the request pending for the next poll.
        guard let resources = session.resourceSet, let controller = session.controller else { return }
        switch await checkPublication(request: current, resources: resources) {
        case .mismatch:
            await failRequest(store, lease, current, message: "备份与当前输入方案不一致，已停止本次操作。")
            return
        case .unavailable:
            return
        case .verified:
            break
        }

        // 5. Run with the engine held exclusively. `beforeYield` is the one check that the keyboard can give
        //    up the engine now (idle input, same controller and resources); if not, the request stays pending
        //    and the user's in-progress input is never dropped. The request is claimed only inside the
        //    exclusive section, so a cancel that wins the race simply ends the attempt.
        //    The engine starts with exactly the resource set whose identity was verified above.
        var claimed: LearningTransferStore.State?
        do {
            try await EngineOwnershipCoordinator.shared.withExclusive(beforeYield: {
                guard session.resourceSet == resources, session.controller === controller,
                    canYieldEngine(session)
                else {
                    throw KeyboardLearningTransferError.inputBecameBusy
                }
            }) {
                guard
                    let state = try await LearningTransferIO.async({
                        try store.claim(
                            requestID: current.id, sourceID: current.sourceID,
                            resourceRevision: current.resourceRevision, lease: lease)
                    })
                else { return }
                claimed = state
                try await EngineOpQueue.asyncExclusive {
                    try await runExclusive(claimed: state, resources: resources, store: store, lease: lease)
                }
            }
        } catch {
            // Without a claim nothing was started (busy input, cancel, claim failure): stay as is.
            guard let claimed else { return }
            await failRequest(store, lease, claimed, message: "备份或合并未能完成，请重试。")
        }
    }

    /// Re-verifies the publication identity of the captured resource set on the file queue.
    private static func checkPublication(
        request: LearningTransferStore.State,
        resources: KeyboardResourceSet
    ) async
        -> PublicationCheck
    {
        let check = try? await LearningTransferIO.async {
            verifyPublication(request: request, resources: resources)
        }
        return check ?? .unavailable
    }

    /// Records a failure: claims a still-pending request first, then fails it. Every store step is a CAS,
    /// so a request that was cancelled or taken over is left alone. A failed write leaves the request running,
    /// and the next attempt marks it interrupted.
    nonisolated private static func failRequest(
        _ store: LearningTransferStore,
        _ lease: LearningTransferStore.WorkerLease,
        _ request: LearningTransferStore.State,
        message: String
    ) async {
        _ = try? await LearningTransferIO.async {
            if request.status == .pending {
                guard
                    try store.claim(
                        requestID: request.id, sourceID: request.sourceID,
                        resourceRevision: request.resourceRevision,
                        lease: lease) != nil
                else { return }
            }
            _ = try store.fail(requestID: request.id, lease: lease, message: message)
        }
    }

    // MARK: - Real reads/writes inside the exclusive engine

    /// Runs inside the exclusive serial section of `EngineOpQueue`: creates one temporary engine to
    /// perform a single backup or restore, and always shuts it down on exit.
    ///
    /// Resource directories come only from the extension's running `resourceSet`, never from the host
    /// request or any string inside the archive.
    nonisolated private static func runExclusive(
        claimed: LearningTransferStore.State,
        resources: KeyboardResourceSet,
        store: LearningTransferStore,
        lease: LearningTransferStore.WorkerLease
    ) async throws {
        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: resources.sharedDirectory,
                userDirectory: resources.userDirectory,
                appName: "rime.songyan",
                prebuiltDirectory: resources.prebuiltDirectory))
        defer { engine.shutdown() }
        try engine.start()

        switch claimed.operation {
        case .backup:
            try await performBackup(claimed: claimed, engine: engine, store: store, lease: lease)
        case .restore:
            try await performRestore(claimed: claimed, engine: engine, store: store, lease: lease)
        }
    }

    /// Builds an archive of the engine's current learning data with the request's identity.
    nonisolated private static func snapshotArchive(
        claimed: LearningTransferStore.State,
        engine: RimeEngine
    ) throws -> LearningBackupArchive? {
        let snapshots = try engine.backupLearningData()
        guard !snapshots.isEmpty else { return nil }
        return try LearningBackupArchive(
            sourceID: claimed.sourceID,
            resourceRevision: claimed.resourceRevision,
            sourceName: claimed.sourceName,
            engineVersion: engine.engineVersion,
            createdAt: Date(),
            dictionaries: try snapshots.map {
                try LearningBackupArchive.DictionarySnapshot(name: $0.name, data: $0.data)
            })
    }

    /// Export: read the engine learning snapshot, write the artifact, then set succeeded.
    nonisolated private static func performBackup(
        claimed: LearningTransferStore.State,
        engine: RimeEngine,
        store: LearningTransferStore,
        lease: LearningTransferStore.WorkerLease
    ) async throws {
        let snapshot: LearningBackupArchive?
        do {
            snapshot = try snapshotArchive(claimed: claimed, engine: engine)
        } catch {
            try await fail(store, lease, claimed.id, message: "未能备份学习数据，未生成完整备份。")
            return
        }
        // Nothing to back up is an explicit failure, never an empty archive reported as success.
        guard let archive = snapshot else {
            try await fail(store, lease, claimed.id, message: "暂无可备份的学习数据。")
            return
        }
        _ = try await LearningTransferIO.async {
            try store.completeBackup(requestID: claimed.id, lease: lease, archive: archive)
        }
    }

    /// Merge: verify the input archive identity, write the pre-restore backup before any merge,
    /// run the native merge, then complete.
    ///
    /// The native merge is not atomic and cannot be rolled back once started; the pre-restore backup is
    /// for retention and manual inspection only. On failure, "validation failed (nothing modified)" is
    /// reported differently from "merge result unconfirmed, may be partially written".
    nonisolated private static func performRestore(
        claimed: LearningTransferStore.State,
        engine: RimeEngine,
        store: LearningTransferStore,
        lease: LearningTransferStore.WorkerLease
    ) async throws {
        let input: LearningBackupArchive
        do {
            input = try await LearningTransferIO.async {
                try store.readRestoreInput(requestID: claimed.id, lease: lease)
            }
        } catch {
            try await fail(store, lease, claimed.id, message: "备份内容无法读取，未做任何修改。")
            return
        }

        do {
            try input.validateIdentity(
                sourceID: claimed.sourceID,
                resourceRevision: claimed.resourceRevision)
        } catch {
            try await fail(store, lease, claimed.id, message: "备份与当前输入方案不一致，未做任何修改。")
            return
        }

        // The complete safety backup must be on disk, with the flag published, before the merge starts.
        do {
            guard let safety = try snapshotArchive(claimed: claimed, engine: engine) else {
                throw KeyboardLearningTransferError.safetyBackupUnavailable
            }
            try await LearningTransferIO.async {
                try store.saveSafetyBackup(requestID: claimed.id, lease: lease, archive: safety)
            }
        } catch {
            try await fail(store, lease, claimed.id, message: "未能保存恢复前备份，已中止合并。")
            return
        }

        // The bridge throws `.mergeUnverified` only after a native write was attempted; every other
        // error happens before any write.
        do {
            try engine.restoreLearningData(
                input.dictionaries.map {
                    RimeLearningSnapshot(name: $0.name, data: $0.data)
                })
        } catch RimeLearningBackupError.mergeUnverified {
            try await fail(store, lease, claimed.id, message: "合并结果未能确认完整，学习数据可能已部分改变。")
            return
        } catch {
            try await fail(store, lease, claimed.id, message: "备份内容无法使用，未做任何修改。")
            return
        }

        _ = try await LearningTransferIO.async {
            try store.completeRestore(requestID: claimed.id, lease: lease)
        }
    }

    nonisolated private static func fail(
        _ store: LearningTransferStore,
        _ lease: LearningTransferStore.WorkerLease,
        _ requestID: UUID,
        message: String
    ) async throws {
        _ = try await LearningTransferIO.async {
            try store.fail(requestID: requestID, lease: lease, message: message)
        }
    }

    /// Resolves the App Group container and builds the store on the dedicated file queue: the first
    /// `containerURL` call may do a real disk/daemon round trip that must not run on the MainActor.
    /// Returns nil (does nothing) when the container is unavailable.
    nonisolated private static func store() async -> LearningTransferStore? {
        try? await LearningTransferIO.async {
            guard let container = KeyboardRecipeStore.sharedContainerURL() else { return nil }
            return LearningTransferStore(
                directory: container.appendingPathComponent(directoryName, isDirectory: true))
        }
    }

    // MARK: - Preconditions (all fail closed)

    /// Whether the keyboard can safely yield the engine now: needs a ready session, a real
    /// resource set, no composition, no unfinished English input, and no input-recovery error.
    /// If temporarily unmet, stay pending until the next poll (input is not dropped).
    static func canYieldEngine(_ session: KeyboardPadSession) -> Bool {
        guard case .ready = session.phase else { return false }
        guard session.resourceSet != nil, let controller = session.controller else { return false }
        guard controller.inputUnavailableReason == nil else { return false }
        guard !controller.snapshot.isComposing else { return false }
        guard !controller.hasActiveEnglishInput else { return false }
        return true
    }

    /// Result of re-verifying the publication identity in the background
    /// (`KeyboardRecipeStore.snapshot(selectedOnly: true)`).
    ///
    /// "Proven mismatch" and "temporarily unreadable" must be distinguished: the former is
    /// terminal (the request can never succeed and must fail visibly, never sit silently in
    /// pending forever); the latter is transient and keeps pending for the next visible poll.
    nonisolated enum PublicationCheck: Equatable {
        /// All five checks hold; may proceed.
        case verified
        /// Cannot be proven for now (disk read failed / no publication record): keep pending, retry later.
        case unavailable
        /// Proven to differ from the current publication: terminal, execution is not allowed and a fixed failure must be recorded.
        case mismatch
    }

    /// Re-verifies the publication identity in the background.
    ///
    /// Returns `.verified` only when all five hold: the publication is enabled; its generation
    /// equals the running resource set's generation; its revision equals the running resource
    /// set's revision; its revision equals the request revision; and the structured source key
    /// (`rosterKey`) equals the request source. Never guess the source from `resourceID` or similar.
    ///
    /// `.mismatch` cases (all proven, and none can improve by retrying):
    ///  * a publication record was read but `recipeEnabled == false`;
    ///  * the running resource set lacks a generation / revision (no checkable identity);
    ///  * the generation differs from the running resource set (the source was republished; this run is on an old generation);
    ///  * the publication revision differs from the running resource set or from the request;
    ///  * the structured source key differs from the request source (including "the request source is not a structured identity").
    ///
    /// `.unavailable` cases: the snapshot read threw, or no publication record could be read. A
    /// mismatch cannot be proven then, so no terminal decision is made and it is retried next time.
    nonisolated static func verifyPublication(
        request: LearningTransferStore.State,
        resources: KeyboardResourceSet
    ) -> PublicationCheck {
        let snapshot: KeyboardRecipeStore.Snapshot
        do {
            guard let read = try KeyboardRecipeStore.snapshot(selectedOnly: true) else {
                // The extension is running a real resource set but no publication record can be read: this
                // is an inconsistency / temporary unavailability, not a "proven mismatch"; keep pending.
                return .unavailable
            }
            snapshot = read
        } catch {
            return .unavailable
        }
        let activation = snapshot.activation
        guard activation.recipeEnabled else { return .mismatch }
        guard let generation = resources.publicationGeneration,
            activation.generation == generation
        else { return .mismatch }
        guard let revision = resources.sourceRevision,
            activation.revision == revision
        else { return .mismatch }
        guard activation.revision == request.resourceRevision else { return .mismatch }
        guard let rosterKey = activation.rosterKey,
            rosterKey == request.sourceID
        else { return .mismatch }
        return .verified
    }
}
