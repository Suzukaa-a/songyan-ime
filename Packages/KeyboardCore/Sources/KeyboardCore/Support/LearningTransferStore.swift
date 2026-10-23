import Darwin
import Foundation
import os

// MARK: - Learning backup request/receipt store (single slot, flock, CAS state machine)
//
// The host app and the keyboard extension negotiate one learning-data export or import across
// processes, without shared memory or a shared engine instance, through fixed file slots in one directory.
//
// Disk layout (slot names are fixed constants):
//   current.json        current request state (the sole authoritative state)
//   restore-input.json  archive carried by an import request (written before current)
//   backup-output.json  archive produced by an export request (written before setting succeeded)
//   safety-backup.json  safety backup taken before applying a restore (kept across requests until overwritten)
//   .lock               flock held for every read-modify-write of the state
//   .worker-lock        execution lease: long-held, proves "I may execute"
//
// Every worker write is a CAS (current UUID + running + `lease.id`), and every file is replaced atomically,
// so a late receipt from an old request or executor is rejected and readers never see a torn file.
//
// A worker write takes the `WorkerLease` itself: `lease.withHeldLease` puts "lease still held -> CAS read ->
// atomic write" into one critical section, so a concurrent `release()` waits for the write to finish.
// Lock order is fixed: lease.stateLock -> `.lock` flock.
public struct LearningTransferStore: Sendable {

    /// Storage root. The store never creates it on a read path.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    fileprivate var rootPath: String {
        directory.standardizedFileURL.path
    }

    // MARK: - Fixed slots and limits

    /// Fixed file slots. File names are constants, never derived from caller input.
    enum Slot: String, CaseIterable {
        case current = "current.json"
        case restoreInput = "restore-input.json"
        case backupOutput = "backup-output.json"
        case safetyBackup = "safety-backup.json"
        case lock = ".lock"
        /// Execution lease: separate from `.lock` because it is held for a long time.
        case workerLock = ".worker-lock"

    }

    /// State file size limit.
    public static let maximumStateBytes = 16 * 1_024
    /// Archive slot limit: the archive's own encoded limit plus a little envelope overhead.
    public static let maximumArtifactBytes = LearningBackupArchive.maximumEncodedBytes + 4_096
    /// Limit for failure/interruption messages (the caller supplies user-facing text; the store only constrains length).
    public static let maximumMessageBytes = 512

    // MARK: - State model

    /// Request kind.
    public enum Operation: String, Codable, Sendable {
        case backup
        case restore
    }

    /// Request status.
    public enum Status: String, Codable, Sendable {
        case pending
        case running
        case succeeded
        case failed
        case cancelled
        case interrupted
    }

    /// Authoritative state of one request. Identity fields are validated on construction and decoding.
    public struct State: Codable, Equatable, Sendable {
        public let id: UUID
        public let operation: Operation
        public let status: Status
        public let sourceID: String
        public let resourceRevision: String
        public let sourceName: String
        public let createdAt: Date
        /// Identity of the current executor. Semantics: the execution lease identity (`WorkerLease.id`), not a process PID.
        /// Callers get a lease from `acquireWorkerLease()`, pass `lease.id` to the claim/complete/fail APIs,
        /// and keep a strong reference to the lease until all operations and receipt writes finish.
        public let processID: UUID?
        public let message: String?
        public let hasSafetyBackup: Bool

        /// Constructs and validates immediately (`createdAt` is normalized to whole seconds, matching the archive's ISO8601 whole-second wire format).
        public init(
            id: UUID, operation: Operation, status: Status,
            sourceID: String, resourceRevision: String, sourceName: String,
            createdAt: Date, processID: UUID?, message: String?,
            hasSafetyBackup: Bool
        ) throws {
            self.id = id
            self.operation = operation
            self.status = status
            self.sourceID = sourceID
            self.resourceRevision = resourceRevision
            self.sourceName = sourceName
            self.createdAt = LearningBackupArchive.normalizedTimestamp(createdAt)
            self.processID = processID
            self.message = message
            self.hasSafetyBackup = hasSafetyBackup
            try Self.validate(self)
        }

        /// Identity fields are bounded because they are shown in the UI and written into archives.
        static func validate(_ state: State) throws {
            try validateMetadata(state.sourceID, field: .sourceID)
            try validateMetadata(state.resourceRevision, field: .resourceRevision)
            try validateMetadata(state.sourceName, field: .sourceName)
            if let message = state.message { try validateMessage(message) }
        }

        // MARK: Codable (hand-written: a missing field fails, and decoded values are validated)

        private enum CodingKeys: String, CodingKey {
            case id, operation, status, sourceID, resourceRevision, sourceName
            case createdAt, processID, message, hasSafetyBackup
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func required<T: Decodable>(_ key: CodingKeys, _ type: T.Type) throws -> T {
                guard let value = try container.decodeIfPresent(T.self, forKey: key) else {
                    throw LearningTransferStoreError.malformedState
                }
                return value
            }
            try self.init(
                id: try required(.id, UUID.self),
                operation: try required(.operation, Operation.self),
                status: try required(.status, Status.self),
                sourceID: try required(.sourceID, String.self),
                resourceRevision: try required(.resourceRevision, String.self),
                sourceName: try required(.sourceName, String.self),
                createdAt: try required(.createdAt, Date.self),
                processID: try container.decodeIfPresent(UUID.self, forKey: .processID),
                message: try container.decodeIfPresent(String.self, forKey: .message),
                hasSafetyBackup: try required(.hasSafetyBackup, Bool.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(operation, forKey: .operation)
            try container.encode(status, forKey: .status)
            try container.encode(sourceID, forKey: .sourceID)
            try container.encode(resourceRevision, forKey: .resourceRevision)
            try container.encode(sourceName, forKey: .sourceName)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encodeIfPresent(processID, forKey: .processID)
            try container.encodeIfPresent(message, forKey: .message)
            try container.encode(hasSafetyBackup, forKey: .hasSafetyBackup)
        }
    }

    /// Archive slot envelope: pins the archive to one requestID so an old or foreign archive can't land on another request.
    /// The date codec is identical to `LearningBackupArchive`'s.
    struct ArtifactEnvelope: Codable, Equatable, Sendable {
        let requestID: UUID
        let archive: LearningBackupArchive

        private enum CodingKeys: String, CodingKey {
            case requestID, archive
        }

        init(requestID: UUID, archive: LearningBackupArchive) {
            self.requestID = requestID
            self.archive = archive
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Throws a standard DecodingError without the slot name; the reader fills in which slot, avoiding a wrong slot name.
            guard let requestID = try container.decodeIfPresent(UUID.self, forKey: .requestID) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.requestID,
                    DecodingError.Context(
                        codingPath: container.codingPath, debugDescription: "归档封装缺少 requestID"))
            }
            guard let archive = try container.decodeIfPresent(LearningBackupArchive.self, forKey: .archive) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.archive,
                    DecodingError.Context(
                        codingPath: container.codingPath, debugDescription: "归档封装缺少 archive"))
            }
            self.init(requestID: requestID, archive: archive)
        }
    }

    // MARK: - Read-only API

    /// Reads the current state. Returns nil if there is no state yet. Writes are atomic renames, so no lock is needed.
    public func read() throws -> State? {
        try readCurrentState()
    }

    /// Reads the latest safety backup kept across requests; nil if none.
    public func readLatestSafetyBackup() throws -> LearningBackupArchive? {
        try readEnvelopeIfPresent(slot: .safetyBackup)?.archive
    }

    /// Reads the input archive of an import request. The caller must be the request's running executor (`lease`),
    /// and the requestID enveloped in the slot must match the request.
    public func readRestoreInput(requestID: UUID, lease: WorkerLease) throws -> LearningBackupArchive {
        try withWorkerLease(lease) {
            let current = try self.runningOwner(requestID: requestID, owner: lease.id)
            let envelope = try self.readEnvelope(slot: .restoreInput)
            try self.verifyBinding(envelope, to: current, slot: .restoreInput)
            return envelope.archive
        }
    }

    /// Reads the output archive of an export request. The output slot is bound to the request, so an old request can't be read as a new result.
    public func readBackupOutput(requestID: UUID) throws -> LearningBackupArchive {
        try withLock {
            guard let current = try self.readCurrentState(), current.id == requestID else {
                throw LearningTransferStoreError.requestNotFound
            }
            switch current.status {
            case .running, .succeeded:
                break
            case .pending, .cancelled, .failed, .interrupted:
                throw LearningTransferStoreError.artifactUnavailable(Slot.backupOutput.rawValue)
            }
            let envelope = try self.readEnvelope(slot: .backupOutput)
            try self.verifyBinding(envelope, to: current, slot: .backupOutput)
            return envelope.archive
        }
    }

    // MARK: - Submission

    /// Creates an export request (the only entry point that may create a missing root directory).
    public func submitBackup(
        sourceID: String, resourceRevision: String,
        sourceName: String
    ) throws -> State {
        try withCreatedRoot {
            try self.rejectIfInProgress()
            let state = try State(
                id: UUID(), operation: .backup, status: .pending,
                sourceID: sourceID, resourceRevision: resourceRevision,
                sourceName: sourceName, createdAt: Date(), processID: nil,
                message: nil, hasSafetyBackup: false)
            try self.writeState(state)
            return state
        }
    }

    /// Creates an import request: writes the restore-input payload first, then publishes current.
    /// If a crash happens in between, current is still the old (terminal) request and the new payload is unusable because its requestID doesn't match.
    public func submitRestore(_ archive: LearningBackupArchive) throws -> State {
        try archive.validate()
        let requestID = UUID()
        let envelope = ArtifactEnvelope(requestID: requestID, archive: archive)
        return try withCreatedRoot {
            try self.rejectIfInProgress()
            let state = try State(
                id: requestID, operation: .restore, status: .pending,
                sourceID: archive.sourceID,
                resourceRevision: archive.resourceRevision,
                sourceName: archive.sourceName, createdAt: Date(),
                processID: nil, message: nil, hasSafetyBackup: false)
            try self.writeEnvelope(envelope, slot: .restoreInput)
            try self.writeState(state)
            return state
        }
    }

    // MARK: - Cancel and claim

    /// Cancels a request that is still pending. Mutually exclusive with `claim` under the lock: whoever takes the lock first wins.
    public func cancel(requestID: UUID) throws -> State {
        try withLock {
            guard let current = try self.readCurrentState(), current.id == requestID else {
                throw LearningTransferStoreError.requestNotFound
            }
            guard current.status == .pending else {
                throw LearningTransferStoreError.notCancellable(current.status)
            }
            let cancelled = try State(
                id: current.id, operation: current.operation,
                status: .cancelled, sourceID: current.sourceID,
                resourceRevision: current.resourceRevision,
                sourceName: current.sourceName, createdAt: current.createdAt,
                processID: nil, message: nil,
                hasSafetyBackup: current.hasSafetyBackup)
            try self.writeState(cancelled)
            return cancelled
        }
    }

    /// Claims a pending request and persists running plus the execution lease identity.
    ///
    /// The caller must pass the lease it holds: `lease.id` becomes `State.processID`, and the whole CAS
    /// read-modify-write runs inside the lease's critical section, so a concurrent `lease.release()`
    /// can't drop the OS worker lock between reading pending and writing running.
    ///
    /// - Returns nil: nothing claimable (missing, different ID, already cancelled/claimed by another process, or terminal).
    /// - Throws: source/resource revision mismatch with the request. The original data is left untouched and the request can still be claimed by a correct caller.
    public func claim(
        requestID: UUID, sourceID: String, resourceRevision: String,
        lease: WorkerLease
    ) throws -> State? {
        try withWorkerLease(lease) {
            try withLock {
                guard let current = try self.readCurrentState(),
                    current.id == requestID, current.status == .pending
                else { return nil }
                guard current.sourceID == sourceID,
                    current.resourceRevision == resourceRevision
                else {
                    throw LearningTransferStoreError.sourceIdentityMismatch
                }
                let running = try State(
                    id: current.id, operation: current.operation,
                    status: .running, sourceID: current.sourceID,
                    resourceRevision: current.resourceRevision,
                    sourceName: current.sourceName,
                    createdAt: current.createdAt,
                    processID: lease.id, message: nil,
                    hasSafetyBackup: current.hasSafetyBackup)
                try self.writeState(running)
                return running
            }
        }
    }

    /// Marks a running request left behind by a different execution lease as interrupted (no automatic redo; the safety backup is kept).
    ///
    /// Precondition: the caller must first have acquired and still hold this execution's `WorkerLease`. It is the only
    /// proof that the old executor is really gone: the kernel releases an old process's flock when it
    /// crashes, so being able to take the lease means the old one has vanished. Never infer this from PIDs, timestamps or timeouts.
    ///
    /// - Returns nil: no running request to handle (missing, terminal, or running with `processID`
    ///   equal to `lease.id`, i.e. this execution's own request).
    ///   This may safely be called repeatedly within one execution as a startup self-check.
    ///
    /// Cases covered (`processID` records the execution lease identity, not a PID):
    ///  * old process crashed: its lease was released by the kernel and a new lease can be taken -> old running becomes interrupted;
    ///  * orphan from the same process whose receipt write failed last time: its `processID` is the previous
    ///    lease id, different from the new one -> also marked interrupted.
    ///
    /// - Throws: the lease doesn't belong to this directory, was released, or the root is missing.
    public func recoverInterrupted(lease: WorkerLease) throws -> State? {
        try withWorkerLease(lease) {
            try withLock {
                guard let current = try self.readCurrentState() else { return nil }
                guard current.status == .running else { return nil }
                guard current.processID != lease.id else { return nil }
                let interrupted = try State(
                    id: current.id, operation: current.operation,
                    status: .interrupted, sourceID: current.sourceID,
                    resourceRevision: current.resourceRevision,
                    sourceName: current.sourceName,
                    createdAt: current.createdAt,
                    processID: current.processID, message: nil,
                    hasSafetyBackup: current.hasSafetyBackup)
                try self.writeState(interrupted)
                return interrupted
            }
        }
    }

    // MARK: - Worker writes (all CAS: current UUID + running + lease identity)

    /// Persists the safety backup: writes the full artifact first, and sets hasSafetyBackup to true only after that succeeds.
    public func saveSafetyBackup(
        requestID: UUID, lease: WorkerLease,
        archive: LearningBackupArchive
    ) throws {
        try withWorkerLease(lease) {
            try withLock {
                let current = try self.runningOwner(requestID: requestID, owner: lease.id)
                try self.writeEnvelope(
                    ArtifactEnvelope(requestID: current.id, archive: archive),
                    slot: .safetyBackup)
                guard !current.hasSafetyBackup else { return }
                let updated = try State(
                    id: current.id, operation: current.operation,
                    status: .running, sourceID: current.sourceID,
                    resourceRevision: current.resourceRevision,
                    sourceName: current.sourceName,
                    createdAt: current.createdAt,
                    processID: current.processID, message: nil,
                    hasSafetyBackup: true)
                try self.writeState(updated)
            }
        }
    }

    /// Completes an export: writes the output to backup-output.json first, then sets the state to succeeded.
    public func completeBackup(
        requestID: UUID, lease: WorkerLease,
        archive: LearningBackupArchive
    ) throws -> State {
        try withWorkerLease(lease) {
            try withLock {
                let current = try self.runningOwner(requestID: requestID, owner: lease.id)
                try self.writeEnvelope(
                    ArtifactEnvelope(requestID: current.id, archive: archive),
                    slot: .backupOutput)
                return try self.finish(current, status: .succeeded, message: nil)
            }
        }
    }

    /// Completes an import. A persisted safety backup is required, otherwise it is refused (fail closed, never claims false success).
    public func completeRestore(requestID: UUID, lease: WorkerLease) throws -> State {
        try withWorkerLease(lease) {
            try withLock {
                let current = try self.runningOwner(requestID: requestID, owner: lease.id)
                guard current.hasSafetyBackup else {
                    throw LearningTransferStoreError.safetyBackupRequired
                }
                return try self.finish(current, status: .succeeded, message: nil)
            }
        }
    }

    /// Marks failure. The caller supplies a fixed user-facing message; the store only enforces length/content bounds.
    public func fail(requestID: UUID, lease: WorkerLease, message: String) throws -> State {
        try LearningTransferStore.validateMessage(message)
        return try withWorkerLease(lease) {
            try withLock {
                let current = try self.runningOwner(requestID: requestID, owner: lease.id)
                return try self.finish(current, status: .failed, message: message)
            }
        }
    }

    private func finish(
        _ current: State, status: Status,
        message: String?
    ) throws -> State {
        let finished = try State(
            id: current.id, operation: current.operation, status: status,
            sourceID: current.sourceID,
            resourceRevision: current.resourceRevision,
            sourceName: current.sourceName, createdAt: current.createdAt,
            processID: current.processID, message: message,
            hasSafetyBackup: current.hasSafetyBackup)
        try writeState(finished)
        return finished
    }

    // MARK: - Worker lease

    /// An exclusive lease meaning "I may execute the request".
    ///
    /// A differing processID doesn't prove the old process is dead, so the lease is a kernel-held flock:
    ///  * lease = one successful non-blocking `LOCK_EX | LOCK_NB` on `.worker-lock`; contention fails immediately;
    ///  * it is a reference type and can be held strongly across `await`;
    ///  * the kernel releases the flock when the process crashes, so no heartbeat/timeout is needed;
    ///  * `deinit` releases the lock; an explicit `release()` is an optional early return.
    ///
    /// `descriptor` is guarded by its lock; store worker methods enter through `withHeldLease`, so
    /// `release()` can't slip in between "lease still held" and "write finished".
    public final class WorkerLease: Sendable {

        /// This lease's identity. The store writes it as `State.processID`.
        public let id: UUID

        /// Root of the store that issued this lease.
        fileprivate let rootPath: String

        /// The held flock descriptor; nil after release.
        private let descriptor: OSAllocatedUnfairLock<Int32?>

        fileprivate init(id: UUID, rootPath: String, descriptor: Int32) {
            self.id = id
            self.rootPath = rootPath
            self.descriptor = OSAllocatedUnfairLock(initialState: descriptor)
        }

        /// Runs `body` while holding the descriptor lock, requiring the lease to be unreleased and to belong to `path`.
        func withHeldLease<T>(rootPath path: String, _ body: () throws -> T) throws -> T {
            // Unchecked only because `body` is not @Sendable; it runs synchronously on this thread.
            try descriptor.withLockUnchecked { descriptor in
                guard rootPath == path, descriptor != nil else {
                    throw LearningTransferStoreError.invalidWorkerLease
                }
                return try body()
            }
        }

        /// Returns the lease (idempotent). Waits for a store method that is inside its critical section.
        public func release() {
            descriptor.withLock { descriptor in
                guard let held = descriptor else { return }
                _ = flock(held, LOCK_UN)
                close(held)
                descriptor = nil
            }
        }

        deinit { release() }
    }

    /// Tries to acquire the execution lease.
    ///
    /// - Returns: the lease on success; nil when another process/instance already holds it (contention, not an error).
    /// - Throws: `storeMissing` when the directory doesn't exist (it is not created).
    ///
    /// This does not take `.lock`: the lease is held for a long time and would block every state operation.
    public func acquireWorkerLease() throws -> WorkerLease? {
        let descriptor = open(slotURL(.workerLock).path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw errno == ENOENT
                ? LearningTransferStoreError.storeMissing
                : LearningTransferStoreError.ioFailure("无法打开执行租约文件。")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw LearningTransferStoreError.ioFailure("无法获取执行租约。")
        }
        return WorkerLease(id: UUID(), rootPath: rootPath, descriptor: descriptor)
    }

    /// The lease must belong to this directory and still be held while `body` runs.
    private func withWorkerLease<T>(
        _ lease: WorkerLease,
        _ body: () throws -> T
    ) throws -> T {
        try lease.withHeldLease(rootPath: rootPath, body)
    }

    // MARK: - Lock and file I/O

    /// Cross-process exclusive flock on `.lock` (one open file description per call, so it also excludes in-process callers).
    /// Throws `storeMissing` when the directory doesn't exist.
    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(slotURL(.lock).path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw errno == ENOENT
                ? LearningTransferStoreError.storeMissing
                : LearningTransferStoreError.ioFailure("无法打开存储锁文件。")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw LearningTransferStoreError.ioFailure("无法获得存储排它锁。")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Only submit may create the directory.
    private func withCreatedRoot<T>(_ body: () throws -> T) throws -> T {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LearningTransferStoreError.ioFailure("无法创建存储目录。")
        }
        return try withLock(body)
    }

    private func slotURL(_ slot: Slot) -> URL {
        directory.appendingPathComponent(slot.rawValue)
    }

    /// Reads one of the store's own files; nil if it doesn't exist. Oversized content is rejected.
    private func readData(_ slot: Slot, maximumBytes: Int) throws -> Data? {
        let data: Data
        do {
            data = try Data(contentsOf: slotURL(slot))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw LearningTransferStoreError.ioFailure("无法读取 \(slot.rawValue)。")
        }
        guard data.count <= maximumBytes else {
            throw LearningTransferStoreError.fileTooLarge(slot: slot.rawValue, bytes: data.count)
        }
        return data
    }

    private func writeData(_ data: Data, slot: Slot) throws {
        do {
            try data.write(to: slotURL(slot), options: [.atomic])
        } catch {
            throw LearningTransferStoreError.ioFailure("无法写入 \(slot.rawValue)。")
        }
    }

    // MARK: - State and archive coding

    private func readCurrentState() throws -> State? {
        guard let data = try readData(.current, maximumBytes: LearningTransferStore.maximumStateBytes) else {
            return nil
        }
        do {
            return try LearningBackupArchive.makeDecoder().decode(State.self, from: data)
        } catch let error as LearningTransferStoreError {
            throw error
        } catch {
            throw LearningTransferStoreError.malformedState
        }
    }

    private func writeState(_ state: State) throws {
        let data: Data
        do {
            data = try LearningBackupArchive.makeEncoder().encode(state)
        } catch {
            throw LearningTransferStoreError.malformedState
        }
        try writeData(data, slot: .current)
    }

    private func readEnvelopeIfPresent(slot: Slot) throws -> ArtifactEnvelope? {
        guard let data = try readData(slot, maximumBytes: LearningTransferStore.maximumArtifactBytes) else {
            return nil
        }
        do {
            return try LearningBackupArchive.makeDecoder().decode(ArtifactEnvelope.self, from: data)
        } catch {
            throw LearningTransferStoreError.malformedArtifact(slot.rawValue)
        }
    }

    private func readEnvelope(slot: Slot) throws -> ArtifactEnvelope {
        guard let envelope = try readEnvelopeIfPresent(slot: slot) else {
            throw LearningTransferStoreError.artifactMissing(slot.rawValue)
        }
        return envelope
    }

    private func writeEnvelope(_ envelope: ArtifactEnvelope, slot: Slot) throws {
        let data: Data
        do {
            data = try LearningBackupArchive.makeEncoder().encode(envelope)
        } catch {
            throw LearningTransferStoreError.malformedArtifact(slot.rawValue)
        }
        try writeData(data, slot: slot)
    }

    /// Artifact binding: the enveloped requestID must equal the current request, and the archive identity must match the request.
    private func verifyBinding(
        _ envelope: ArtifactEnvelope, to state: State,
        slot: Slot
    ) throws {
        guard envelope.requestID == state.id else {
            throw LearningTransferStoreError.artifactMismatch(slot.rawValue)
        }
        try envelope.archive.validateIdentity(
            sourceID: state.sourceID,
            resourceRevision: state.resourceRevision)
    }

    private func rejectIfInProgress() throws {
        guard let current = try readCurrentState() else { return }
        switch current.status {
        case .pending, .running:
            throw LearningTransferStoreError.requestInProgress(current.status)
        case .succeeded, .failed, .cancelled, .interrupted:
            return
        }
    }

    /// CAS: the current request must be exactly `requestID`, running, and owned by `owner` (the caller's `lease.id`).
    private func runningOwner(requestID: UUID, owner: UUID) throws -> State {
        guard let current = try readCurrentState() else {
            throw LearningTransferStoreError.requestNotFound
        }
        guard current.id == requestID else {
            throw LearningTransferStoreError.staleRequest
        }
        guard current.status == .running, current.processID == owner else {
            throw LearningTransferStoreError.ownerMismatch
        }
        return current
    }

    // MARK: - Field validation primitives

    /// Identity fields at the same scale as the archive's.
    enum MetadataField: String {
        case sourceID
        case resourceRevision
        case sourceName

        var archiveField: LearningBackupArchiveError.Field {
            switch self {
            case .sourceID: return .sourceID
            case .resourceRevision: return .resourceRevision
            case .sourceName: return .sourceName
            }
        }

        var limit: Int {
            switch self {
            case .sourceID: return LearningBackupArchive.maximumSourceIDBytes
            case .resourceRevision: return LearningBackupArchive.maximumResourceRevisionBytes
            case .sourceName: return LearningBackupArchive.maximumSourceNameBytes
            }
        }
    }

    /// Reuses the archive layer's rules and limits, mapping errors to the store's own type (errors contain no field values).
    static func validateMetadata(_ value: String, field: MetadataField) throws {
        do {
            try LearningBackupArchive.validateMetadata(
                value, field: field.archiveField,
                limit: field.limit)
        } catch {
            throw LearningTransferStoreError.invalidStateField(field.rawValue)
        }
    }

    /// Failure/interruption message: non-empty, bounded, no NUL. Message content isn't the store's concern.
    static func validateMessage(_ message: String) throws {
        let byteCount = message.utf8.count
        guard byteCount > 0, byteCount <= maximumMessageBytes,
            !message.contains("\0")
        else {
            throw LearningTransferStoreError.invalidMessage
        }
    }
}

// MARK: - Failure reasons

/// Failure reasons of the store. Messages describe only fields and slot names, never source names or dictionary content.
public enum LearningTransferStoreError: Error, LocalizedError, Equatable, Sendable {
    /// The storage directory doesn't exist.
    case storeMissing
    /// Slot content exceeds the limit.
    case fileTooLarge(slot: String, bytes: Int)
    /// State JSON can't be decoded.
    case malformedState
    /// Archive slot can't be decoded.
    case malformedArtifact(String)
    /// State field is invalid (only the field name is reported, not the value).
    case invalidStateField(String)
    /// A pending/running request already exists; a new one can't be created.
    case requestInProgress(LearningTransferStore.Status)
    /// The target request doesn't exist (or was superseded by a new one).
    case requestNotFound
    /// The request is no longer pending and can't be cancelled.
    case notCancellable(LearningTransferStore.Status)
    /// The caller's source/resource revision doesn't match the request.
    case sourceIdentityMismatch
    /// The writer isn't the running owner of the current request (old owner / old request).
    case staleRequest
    case ownerMismatch
    /// The execution lease is invalid: it doesn't belong to this directory, or was released.
    case invalidWorkerLease
    /// A safety backup must have been persisted before an import completes.
    case safetyBackupRequired
    /// The slot has no readable artifact yet.
    case artifactMissing(String)
    /// The artifact in the slot belongs to another request.
    case artifactMismatch(String)
    /// The current state doesn't allow reading this artifact.
    case artifactUnavailable(String)
    /// The failure/interruption message is invalid (empty, too long, or contains NUL).
    case invalidMessage
    /// Other I/O failure.
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .storeMissing:
            return "存储目录不存在。"
        case .fileTooLarge(let slot, _):
            return "\(slot) 超过大小上限。"
        case .malformedState:
            return "存储中的请求状态已损坏或格式不正确。"
        case .malformedArtifact(let slot):
            return "\(slot) 已损坏或格式不正确。"
        case .invalidStateField(let field):
            return "请求状态字段 \(field) 不合法。"
        case .requestInProgress(let status):
            switch status {
            case .pending: return "已有待处理的请求，请稍后再试。"
            case .running: return "已有正在进行的请求，请稍后再试。"
            case .succeeded, .failed, .cancelled, .interrupted:
                return "已有请求正在进行，请稍后再试。"
            }
        case .requestNotFound:
            return "要处理的请求不存在或已被新请求取代。"
        case .notCancellable:
            return "这个请求已经开始或结束，无法取消。"
        case .sourceIdentityMismatch:
            return "备份与当前输入方案或版本不一致，无法处理。"
        case .staleRequest:
            return "这次写入属于已过期的请求，已拒绝。"
        case .ownerMismatch:
            return "这次写入不是当前请求的运行者发起的，已拒绝。"
        case .invalidWorkerLease:
            return "执行租约无效或已释放，已拒绝。"
        case .safetyBackupRequired:
            return "应用恢复前必须先保存安全备份。"
        case .artifactMissing(let slot):
            return "还没有可读取的 \(slot)。"
        case .artifactMismatch(let slot):
            return "\(slot) 属于另一次请求，已拒绝。"
        case .artifactUnavailable(let slot):
            return "当前状态下不能读取 \(slot)。"
        case .invalidMessage:
            return "操作说明文案不合法。"
        case .ioFailure(let description):
            return description
        }
    }
}
