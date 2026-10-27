import Darwin
import KeyboardCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Source summary

/// Host-side summary of the source currently in use: only the three identity fields a cross-process request needs.
///
/// The source identity comes only from the structured publication record (`activation.rosterKey`:
/// kind + packageID, independent of path/name). When nothing is enabled or the structured identity
/// is missing it returns nil; `resourceID`, a configuration display name or a schema name is never passed off as the source.
struct LearningBackupSource: Equatable {
    /// Structured source key. Used only for store requests and identity checks, never shown to the user.
    let sourceID: String
    /// Resource revision. Merging is allowed only if it matches the extension's publication record.
    let resourceRevision: String
    /// Display name of the source (safe to show, contains no internal IDs).
    let sourceName: String

    static func make(from activation: KeyboardRecipeStore.Activation) -> LearningBackupSource? {
        guard activation.recipeEnabled, let rosterKey = activation.rosterKey else { return nil }
        return LearningBackupSource(
            sourceID: rosterKey,
            resourceRevision: activation.revision,
            sourceName: activation.name)
    }
}

// MARK: - Failure reasons safe to display

/// This view's own failure reasons (the text never contains paths / ids / entries / slot names).
enum LearningBackupUserError: Error, Equatable {
    case noAppliedSource
    case containerUnavailable
    case unreadableFile

    var message: String {
        switch self {
        case .noAppliedSource:
            return "还没有正在使用的输入方案，请先在「我的键盘」中使用一个键盘。"
        case .containerUnavailable:
            // Reinstalling deletes the keyboard-private learning data, so it must never be offered as a routine recovery step.
            return "无法访问共享数据。请在系统设置中开启「允许完全访问」，然后重新打开此页。"
        case .unreadableFile:
            return "无法读取所选的备份文件，请重新选择。"
        }
    }
}

// MARK: - Background I/O facade

/// The only disk-access surface for learning-data transfer: everything goes through
/// `LearningTransferIO` (Shared-layer background queue), so the main thread never reads disk.
/// The container directory is also resolved on that queue (never fall back to a host-private
/// directory, or the keyboard extension would never see the request).
private enum LearningBackupIO {

    /// Resolves the container directory on the background queue and builds the store.
    static func withStore<T>(_ body: @escaping @Sendable (LearningTransferStore) throws -> T) async throws -> sending T
    {
        try await LearningTransferIO.async {
            guard
                let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: KeyboardRecipeStore.groupID)
            else {
                throw LearningBackupUserError.containerUnavailable
            }
            let directory = container.appendingPathComponent(
                KeyboardLearningTransfer.directoryName, isDirectory: true)
            return try body(LearningTransferStore(directory: directory))
        }
    }

    /// Reads the current publication snapshot in the background and derives the source summary; nil if nothing is applied or the structured identity is missing.
    static func readSource() async throws -> LearningBackupSource? {
        try await LearningTransferIO.async {
            guard let snapshot = try KeyboardRecipeStore.snapshot() else { return nil }
            return LearningBackupSource.make(from: snapshot.activation)
        }
    }

    /// Reads a user-picked backup file off the main thread, rejecting non-regular files (a FIFO would
    /// block the transfer queue) and oversized ones before decoding and validating.
    static func readArchive(at url: URL) async throws -> LearningBackupArchive {
        try await LearningTransferIO.async {
            guard url.isFileURL else { throw LearningBackupUserError.unreadableFile }
            let resolved = url.resolvingSymlinksInPath()
            guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { throw LearningBackupUserError.unreadableFile }
            if let size = values.fileSize, size > LearningBackupArchive.maximumEncodedBytes {
                throw LearningBackupArchiveError.encodedTooLarge(bytes: size)
            }
            guard let data = try? Data(contentsOf: resolved) else { throw LearningBackupUserError.unreadableFile }
            return try LearningBackupArchive.decode(data)
        }
    }

    /// Encoding for export (also done on the background queue; the main thread does no serialization).
    static func encode(_ archive: LearningBackupArchive) async throws -> Data {
        try await LearningTransferIO.async { try archive.encoded() }
    }
}

/// Status polling interval: reads only a small fixed file (<= 16 KiB) and parses no resources.
private let learningTransferPollInterval: Duration = .seconds(1)

/// Displayable summary of the pre-restore backup in the container (source name + time only; no path/ID/entries).
struct LearningBackupSafetySummary: Equatable {
    let sourceName: String
    let createdAt: Date
}

// MARK: - View model

@MainActor
final class LearningBackupModel: ObservableObject {

    /// The three outcomes of reading the source: a read failure is never disguised as "no scheme".
    enum SourceState: Equatable {
        case loading
        case ready(LearningBackupSource)
        case missing
        case failed
    }

    // MARK: Output (the view only consumes it and never reads disk)

    @Published private(set) var sourceState: SourceState = .loading
    @Published private(set) var transfer: LearningTransferStore.State?
    @Published private(set) var isWorking = false
    @Published private(set) var notice: String?
    /// Explicit message when status polling fails to read (a failure is not treated as "no request").
    @Published private(set) var stateReadFailure: String?
    @Published private(set) var exportDocument = LearningBackupDocument(data: Data())
    @Published private(set) var exportFilename = ""
    /// Summary of the pre-restore backup that exists in the container (source name + time).
    ///
    /// Deliberately ignores the current request's `hasSafetyBackup`: the safety backup is a slot
    /// kept across requests. The next backup/merge replaces the current state with another request,
    /// but the archive in the slot still exists. Looking only at the current request's flag would
    /// hide a still-usable backup, and make it impossible to export, after a new request.
    @Published private(set) var safetyBackup: LearningBackupSafetySummary?
    /// Message when reading the safety backup fails (a read failure is not treated as "none").
    @Published private(set) var safetyBackupReadFailure: String?

    /// Presentation flags for `fileImporter` / `fileExporter` / confirmationDialog.
    @Published var importing = false
    @Published var exporting = false
    @Published var confirmingRestore = false

    // MARK: Internal

    private var pendingRestore: LearningBackupArchive?
    private var restoreSummary: String?
    private var pollTask: Task<Void, Never>?
    private var sourceTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    /// The request state last observed, so the safety-backup availability is refreshed only on a change.
    private var lastObservedStatus: LearningTransferStore.Status?

    // MARK: Derived (pure values; body never touches disk)

    var source: LearningBackupSource? {
        if case .ready(let source) = sourceState { return source }
        return nil
    }

    /// Availability of backup / import-merge requests: needs a provable source and no request in flight.
    var canStartTransfer: Bool {
        source != nil && !isWorking && !hasActiveRequest
    }

    var hasActiveRequest: Bool {
        transfer?.status == .pending || transfer?.status == .running
    }

    /// The temporary input field that waits for the keyboard exists only while a request is active.
    var showsKeyboardActivation: Bool { hasActiveRequest }

    var canCancelWaiting: Bool { transfer?.status == .pending && !isWorking }

    /// Only a successful backup that is still the current request produces something exportable.
    var canExportBackup: Bool {
        !isWorking && transfer?.operation == .backup && transfer?.status == .succeeded
    }

    /// Exportable whenever a pre-restore backup actually exists in the container, regardless of the current request.
    var canExportSafetyBackup: Bool { !isWorking && safetyBackup != nil }

    /// Description line for the pre-restore backup (source and time come from that archive itself, not the current request).
    var safetyBackupDetail: String? {
        guard let safetyBackup else { return nil }
        let date = safetyBackup.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "备份来源：\(safetyBackup.sourceName) · \(date)"
    }

    var restoreConfirmationMessage: String? { restoreSummary }

    // MARK: Lifecycle

    /// Entering the page / returning to the foreground: starts per-second status polling (reads only the small state file) and refreshes safety-backup availability once.
    func activate() {
        startPolling()
        refreshSafetyBackup()
    }

    /// Leaving the page / backgrounding: stops polling and voids all in-flight operations and reads.
    ///
    /// A `LearningTransferIO` continuation cannot be cancelled, so in-flight tasks may still return;
    /// gate invalidation plus task cancellation ensure they publish no UI side effects (no
    /// confirmation dialog, no export) and do not clear a later task's busy.
    func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        sourceTask?.cancel()
        sourceTask = nil
        operationTask?.cancel()
        operationTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        isWorking = false
    }

    // MARK: Operations

    /// Starts an operation. Returns false if one is already running.
    /// Leaving the page cancels the task; a cancelled task never publishes or clears busy.
    private func beginOperation() -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        return true
    }

    private func endOperation() {
        if !Task.isCancelled { isWorking = false }
    }

    /// Lands local authoritative state: invalidates in-flight status reads first, then writes this operation's result.
    private func applyLocal(_ state: LearningTransferStore.State) {
        stateReadFailure = nil
        let previous = lastObservedStatus
        transfer = state
        lastObservedStatus = state.status
        if previous != state.status { refreshSafetyBackup() }
    }

    // MARK: Safety-backup availability (own cadence, never part of the per-second polling)

    /// Reads in the background whether a pre-restore backup exists in the container. A read failure
    /// is not treated as "none": the last known conclusion is kept and the failure reported.
    func refreshSafetyBackup() {
        safetyTask?.cancel()
        safetyTask = Task { [weak self] in
            do {
                let archive = try await LearningBackupIO.withStore { try $0.readLatestSafetyBackup() }
                guard let self, !Task.isCancelled else { return }
                self.safetyBackup = archive.map {
                    LearningBackupSafetySummary(sourceName: $0.sourceName, createdAt: $0.createdAt)
                }
                self.safetyBackupReadFailure = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.safetyBackupReadFailure = "暂时无法确认恢复前备份，请稍后重试。"
            }
        }
    }

    // MARK: Source (read only on first appearance / return to foreground, never parse all resources every second)

    func refreshSource() {
        // Hide availability while reading (fail closed): don't start a request from a possibly stale source.
        sourceState = .loading
        sourceTask?.cancel()
        sourceTask = Task { [weak self] in
            do {
                let source = try await LearningBackupIO.readSource()
                guard let self, !Task.isCancelled else { return }
                self.sourceState = source.map { SourceState.ready($0) } ?? .missing
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.sourceState = .failed
            }
        }
    }

    // MARK: Request backup

    func requestBackup() {
        guard hasActiveRequest == false else { return }
        guard beginOperation() else { return }
        notice = nil
        operationTask = Task { [weak self] in
            defer { self?.endOperation() }
            do {
                // Re-read the current source before submitting: never start a request from a possibly stale source.
                let source = try await LearningBackupIO.readSource()
                guard let self, !Task.isCancelled else { return }
                self.sourceState = source.map { SourceState.ready($0) } ?? .missing
                guard let source else { throw LearningBackupUserError.noAppliedSource }
                let state = try await LearningBackupIO.withStore {
                    try $0.submitBackup(
                        sourceID: source.sourceID,
                        resourceRevision: source.resourceRevision,
                        sourceName: source.sourceName)
                }
                guard !Task.isCancelled else { return }
                self.applyLocal(state)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = Self.userMessage(for: error)
            }
        }
    }

    // MARK: Cancel waiting (pending only)

    func cancelWaiting() {
        guard let current = transfer, current.status == .pending else { return }
        guard beginOperation() else { return }
        notice = nil
        operationTask = Task { [weak self] in
            defer { self?.endOperation() }
            do {
                let state = try await LearningBackupIO.withStore {
                    try $0.cancel(requestID: current.id)
                }
                guard let self, !Task.isCancelled else { return }
                self.applyLocal(state)
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Report a failed cancel as failed (e.g. once the keyboard has claimed the request and it is running,
                // don't claim it was cancelled), and immediately re-read the real state.
                self.notice = Self.userMessage(for: error)
                await self.readTransferState()
            }
        }
    }

    // MARK: Import and merge

    func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            importArchive(from: url)
        case .failure(let error):
            // A user cancel is not a failure.
            let nsError = error as NSError
            guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
            notice = "无法打开所选的备份文件，请重新选择。"
        }
    }

    func importArchive(from url: URL) {
        notice = nil
        pendingRestore = nil
        restoreSummary = nil
        guard beginOperation() else { return }
        let scoped = url.isFileURL && url.startAccessingSecurityScopedResource()
        operationTask = Task { [weak self] in
            defer {
                // Security-scoped access must stop before its validity ends.
                if scoped { url.stopAccessingSecurityScopedResource() }
                self?.endOperation()
            }
            do {
                // Within the security-scoped validity window, do the bounded read + decode + full validation in the background.
                let archive = try await LearningBackupIO.readArchive(at: url)
                guard let self, !Task.isCancelled else { return }
                // Always compare identity against the just-read current source, not a value from the list that may be stale.
                let source = try await LearningBackupIO.readSource()
                guard !Task.isCancelled else { return }
                self.sourceState = source.map { SourceState.ready($0) } ?? .missing
                guard let source else { throw LearningBackupUserError.noAppliedSource }
                try archive.validateIdentity(
                    sourceID: source.sourceID,
                    resourceRevision: source.resourceRevision)
                guard !Task.isCancelled else { return }
                // The confirmation dialog may be shown only from this point.
                self.pendingRestore = archive
                self.restoreSummary = Self.restoreSummary(for: archive)
                self.confirmingRestore = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.pendingRestore = nil
                self.restoreSummary = nil
                self.notice = Self.userMessage(for: error)
            }
        }
    }

    func discardPendingRestore() {
        pendingRestore = nil
        restoreSummary = nil
        confirmingRestore = false
    }

    /// Submits the merge request only after the user confirms. The identity was checked at import time;
    /// the keyboard checks it again against its own publication before merging.
    func confirmRestore() {
        guard let archive = pendingRestore else { return }
        guard beginOperation() else { return }
        pendingRestore = nil
        restoreSummary = nil
        notice = nil
        operationTask = Task { [weak self] in
            defer { self?.endOperation() }
            do {
                let state = try await LearningBackupIO.withStore { try $0.submitRestore(archive) }
                guard let self, !Task.isCancelled else { return }
                self.applyLocal(state)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = Self.userMessage(for: error)
            }
        }
    }

    // MARK: Export (must be user-initiated)

    func prepareBackupExport() {
        guard let current = transfer, current.operation == .backup,
            current.status == .succeeded
        else {
            notice = "还没有可导出的学习备份。"
            return
        }
        guard beginOperation() else { return }
        notice = nil
        let requestID = current.id
        operationTask = Task { [weak self] in
            defer { self?.endOperation() }
            do {
                let archive = try await LearningBackupIO.withStore {
                    try $0.readBackupOutput(requestID: requestID)
                }
                guard let self, !Task.isCancelled else { return }
                let data = try await LearningBackupIO.encode(archive)
                guard !Task.isCancelled else { return }
                self.exportDocument = LearningBackupDocument(data: data)
                self.exportFilename = "松烟-学习备份-\(Self.dateStamp(archive.createdAt)).json"
                self.exporting = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = Self.userMessage(for: error)
            }
        }
    }

    /// Exports the pre-restore backup: re-reads the latest one (not the cached summary in the list),
    /// names the file from the archive's own source/time, and refreshes the summary to the one just read.
    func prepareSafetyBackupExport() {
        guard canExportSafetyBackup else {
            notice = "还没有恢复前备份。"
            return
        }
        guard beginOperation() else { return }
        notice = nil
        operationTask = Task { [weak self] in
            defer { self?.endOperation() }
            do {
                let archive = try await LearningBackupIO.withStore { try $0.readLatestSafetyBackup() }
                guard let self, !Task.isCancelled else { return }
                guard let archive else {
                    // Read succeeded but there is no archive: only this is a true "none".
                    self.safetyBackup = nil
                    self.notice = "还没有恢复前备份。"
                    return
                }
                let data = try await LearningBackupIO.encode(archive)
                guard !Task.isCancelled else { return }
                self.safetyBackup = LearningBackupSafetySummary(
                    sourceName: archive.sourceName,
                    createdAt: archive.createdAt)
                self.exportDocument = LearningBackupDocument(data: data)
                self.exportFilename = "松烟-恢复前备份-\(Self.dateStamp(archive.createdAt)).json"
                self.exporting = true
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.notice = Self.userMessage(for: error)
            }
        }
    }

    func reportExportFailure(_ error: Error) {
        // A user cancelling the export is not a failure.
        let nsError = error as NSError
        guard !(nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError) else { return }
        // The underlying localizedDescription is not used: it may include a file path.
        notice = "导出未完成，请重新选择保存位置后再试。"
    }

    // MARK: Status polling

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.readTransferState()
                if Task.isCancelled { return }
                do { try await Task<Never, Never>.sleep(for: learningTransferPollInterval) } catch { return }
            }
        }
    }

    private func readTransferState() async {
        do {
            let state = try await LearningBackupIO.withStore { try $0.read() }
            guard !Task.isCancelled else { return }
            let previous = lastObservedStatus
            transfer = state
            stateReadFailure = nil
            lastObservedStatus = state?.status
            // Refresh safety-backup availability only when the state changes (the backup has just appeared once a merge completes).
            if previous != state?.status { refreshSafetyBackup() }
        } catch {
            guard !Task.isCancelled else { return }
            // On a read failure don't treat the state as "no request": keep the last known state and say so.
            stateReadFailure = Self.userMessage(for: error)
        }
    }

    // MARK: Fixed user-facing text (contains no path / id / entries)

    static func statusText(for state: LearningTransferStore.State?) -> String {
        guard let state else { return "尚未传输过学习数据。" }
        switch state.status {
        case .pending:
            return "等待键盘响应：请调出「松烟」键盘一次。"
        case .running:
            return state.operation == .backup ? "正在备份学习数据…" : "正在合并学习数据…"
        case .succeeded:
            return state.operation == .backup ? "备份完成。" : "合并完成。"
        case .failed:
            return "操作失败：\(state.message ?? "原因未知")"
        case .cancelled:
            return "已取消。"
        case .interrupted:
            let suffix = state.message.map { "（\($0)）" } ?? ""
            return "上一次操作被中断，未能确认结果\(suffix)。请重新尝试。"
        }
    }

    static func restoreSummary(for archive: LearningBackupArchive) -> String {
        let date = archive.createdAt.formatted(date: .abbreviated, time: .shortened)
        return """
            备份来源：\(archive.sourceName)
            备份日期：\(date)
            开始合并前会先自动保存当前的学习数据；合并会保留现有学习，但开始后无法中途撤回。
            """
    }

    /// The file name uses the date (local time zone) and contains no internal identifier.
    static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func userMessage(for error: Error) -> String {
        if let user = error as? LearningBackupUserError { return user.message }
        if let archive = error as? LearningBackupArchiveError {
            return archive.errorDescription ?? "备份内容无法使用。"
        }
        if let store = error as? LearningTransferStoreError { return message(for: store) }
        return "操作未完成，请重试。"
    }

    /// Fixed user-facing text for store errors: never exposes slot names / paths / IDs.
    static func message(for error: LearningTransferStoreError) -> String {
        switch error {
        case .requestInProgress(.pending):
            return "已有请求正在等待键盘响应，请先取消或完成该请求。"
        case .requestInProgress:
            return "已有请求正在处理中，请等待其完成。"
        case .notCancellable:
            return "请求正在处理中，无法取消。"
        case .requestNotFound:
            return "请求已失效，请重新发起。"
        case .staleRequest, .ownerMismatch:
            return "请求已被新操作取代，请重新发起。"
        case .safetyBackupRequired:
            return "合并前自动保存当前学习数据失败，操作已中止。"
        case .sourceIdentityMismatch:
            return "备份与当前输入方案不一致，无法处理。"
        case .artifactMissing, .artifactMismatch, .artifactUnavailable:
            return "未找到可用的备份文件。"
        case .storeMissing:
            return "暂无学习数据记录。"
        default:
            // Everything else (directory/slot unavailable, out of bounds, corrupt state or artifacts, invalid text, I/O failure...)
            // gets fixed text: never exposes slot names / paths / IDs.
            return "读取或写入学习数据时出错，请重试。"
        }
    }
}
