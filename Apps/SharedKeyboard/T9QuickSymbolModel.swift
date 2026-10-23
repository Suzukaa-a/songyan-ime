import Combine
import Foundation
import LayoutKit

/// Darwin notifications carry no values. Every receiver reads the same atomic
/// App Group file; neither CFPreferences caches nor notification order are data.
private enum T9QuickSymbolNotifications {
    static let name = "app.songyan.t9QuickSymbols.changed"
    static let local = Notification.Name(name)
    static let install: Void = {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: T9QuickSymbolNotifications.local, object: nil)
            }, name as CFString, nil, .deliverImmediately)
    }()
    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

/// All App Group access lives here and runs only on the model's serial queue.
///
/// The keyboard extension can call `reload()` on `appear` and on every Darwin
/// notification while a slot save is still in flight. Running every store touch
/// on one serial queue means a read can never interleave with another process'
/// or the same process' read-modify-write, so no user edit is lost; the shared
/// file lock in `T9QuickSymbolStore` still serializes across processes.
private final class T9QuickSymbolIOWorker: Sendable {
    /// Result of one off-main store operation, applied back on the main actor.
    struct Outcome: Sendable {
        var resolved = false
        var shared = false
        var fileURL: URL?
        var applyFileURL = false
        var symbols: String?
        var errorMessage: String?
        var postChange = false
        var succeeded = false
    }

    private let sharedContainer: @Sendable () -> URL?
    private let canWrite: @Sendable () -> Bool

    init(sharedContainer: @escaping @Sendable () -> URL?, canWrite: @escaping @Sendable () -> Bool) {
        self.sharedContainer = sharedContainer
        self.canWrite = canWrite
    }

    /// A keyboard without Full Access can read the shared symbols but not save them.
    private func readOnlyOutcome() -> Outcome? {
        guard !canWrite() else { return nil }
        var outcome = Outcome()
        outcome.errorMessage = "快捷符号未保存，请在系统设置中打开「允许完全访问」后重试"
        return outcome
    }

    func load(applyFallback: Bool) -> Outcome {
        guard let store = resolveStore() else {
            // Never turn a missing shared container into a successful private save.
            var outcome = Outcome()
            outcome.shared = false
            outcome.applyFileURL = true
            outcome.fileURL = nil
            outcome.errorMessage = "无法访问共享数据，快捷符号未保存"
            if applyFallback {
                outcome.symbols = T9QuickSymbolStore.defaultSymbols
            }
            return outcome
        }
        do {
            let saved = try store.load()
            var outcome = Outcome()
            outcome.resolved = true
            outcome.shared = true
            outcome.fileURL = store.fileURL
            outcome.applyFileURL = true
            outcome.symbols = saved.symbols
            return outcome
        } catch {
            var outcome = Outcome()
            outcome.shared = false
            outcome.errorMessage = "无法读取快捷符号"
            return outcome
        }
    }

    func save(index: Int, symbol: String) -> Outcome {
        if let readOnly = readOnlyOutcome() { return readOnly }
        guard let store = resolveStore() else {
            var outcome = Outcome()
            outcome.shared = false
            outcome.applyFileURL = true
            outcome.fileURL = nil
            outcome.errorMessage = "无法访问共享数据，快捷符号未保存"
            return outcome
        }
        do {
            let edit = try store.replaceSlotResult(index, with: symbol)
            var outcome = Outcome()
            outcome.resolved = true
            outcome.shared = true
            outcome.fileURL = store.fileURL
            outcome.applyFileURL = true
            outcome.symbols = edit.snapshot.symbols
            outcome.postChange = edit.didWrite
            outcome.succeeded = edit.didWrite
            return outcome
        } catch {
            var outcome = Outcome()
            outcome.shared = false
            outcome.errorMessage = "快捷符号未保存，请重试"
            return outcome
        }
    }

    func replaceSymbols(_ symbols: String) -> Outcome {
        if let readOnly = readOnlyOutcome() { return readOnly }
        guard let store = resolveStore() else {
            var outcome = Outcome()
            outcome.shared = false
            outcome.applyFileURL = true
            outcome.fileURL = nil
            outcome.errorMessage = "无法访问共享数据，快捷符号未保存"
            return outcome
        }
        do {
            let edit = try store.replaceSymbolsResult(symbols)
            var outcome = Outcome()
            outcome.resolved = true
            outcome.shared = true
            outcome.fileURL = store.fileURL
            outcome.applyFileURL = true
            outcome.symbols = edit.snapshot.symbols
            outcome.postChange = edit.didWrite
            outcome.succeeded = edit.didWrite
            return outcome
        } catch T9QuickSymbolStore.StoreError.invalidSymbols {
            var outcome = Outcome()
            outcome.shared = false
            outcome.errorMessage = "符号须为 1 至 12 个不重复字符，不能包含空格或控制字符"
            return outcome
        } catch {
            var outcome = Outcome()
            outcome.shared = false
            outcome.errorMessage = "快捷符号未保存，原有数据已保留，请重试"
            return outcome
        }
    }

    private func resolveStore() -> T9QuickSymbolStore? {
        guard let shared = sharedContainer() else { return nil }
        return T9QuickSymbolStore(directory: shared.appendingPathComponent("KeyboardQuickSymbols", isDirectory: true))
    }
}

@MainActor
final class T9QuickSymbolModel: ObservableObject {
    @Published private(set) var symbols = T9QuickSymbolStore.defaultSymbols
    @Published private(set) var error: String?
    private(set) var fileURL: URL?
    private(set) var isShared = false
    private var subscriptions = Set<AnyCancellable>()

    private let worker: T9QuickSymbolIOWorker
    private let postChange: () -> Void
    /// Every store touch is dispatched here, never on the main actor.
    private let ioQueue = DispatchQueue(label: "app.songyan.t9QuickSymbols.io", qos: .userInitiated)
    /// Monotonic token plus serial I/O and ordered main-queue publications:
    /// background results cannot roll displayed symbols back to an older read.
    private var requestToken = 0
    private var appliedToken = 0
    /// Mirrors "activeStore != nil" for the missing-container fallback decision.
    private var hasResolvedStore = false

    init(
        sharedContainer: (@Sendable () -> URL?)? = nil,
        canWrite: @escaping @Sendable () -> Bool = { KeyboardRecipeStore.canWriteSharedContainer },
        observesNotifications: Bool = true,
        postChange: (() -> Void)? = nil
    ) {
        let container = sharedContainer ?? { KeyboardRecipeStore.sharedContainerURL() }
        self.postChange = postChange ?? T9QuickSymbolNotifications.post
        self.worker = T9QuickSymbolIOWorker(sharedContainer: container, canWrite: canWrite)
        if observesNotifications {
            _ = T9QuickSymbolNotifications.install
            // Cross-process changes are covered by the Darwin notification (`.local`). A keyboard extension has no app
            // lifecycle: `UIApplication.didBecomeActive/willEnterForeground` never fire inside an extension.
            NotificationCenter.default.publisher(for: T9QuickSymbolNotifications.local)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reload() }
                .store(in: &subscriptions)
        }
        reload()
    }

    /// Fire-and-forget refresh that never blocks the main thread. Callers that
    /// need the settled state (tests) may await the returned task.
    @discardableResult
    func reload() -> Task<Void, Never> {
        requestToken += 1
        let token = requestToken
        let worker = self.worker
        let queue = self.ioQueue
        let applyFallback = !hasResolvedStore
        // Enqueue *before* returning: creating a Task and enqueuing inside it
        // could let a later save overtake this read, so token order would no
        // longer describe the actual file operations.
        let (stream, completion) = AsyncStream<Void>.makeStream()
        queue.async { [weak self] in
            let outcome = worker.load(applyFallback: applyFallback)
            DispatchQueue.main.async { [weak self] in
                self?.apply(outcome, token: token)
                completion.yield()
                completion.finish()
            }
        }
        return Task {
            for await _ in stream { break }
        }
    }

    /// Persists one slot off the main thread. Returns `true` only when the store
    /// actually wrote and the fresh merged snapshot was accepted; the caller must
    /// give success feedback only on `true`. A failed save leaves `symbols`
    /// untouched and publishes a user-facing `error`.
    @discardableResult
    func replaceSlot(_ index: Int, with symbol: String) async -> Bool {
        await beginReplaceSlot(index, with: symbol).value
    }

    /// A touch callback must enqueue in touch order, before yielding to an
    /// unstructured Task. Otherwise two fast edits to the same slot can run in
    /// reversed Task scheduling order even though file writes are serialized.
    @discardableResult
    func beginReplaceSlot(_ index: Int, with symbol: String) -> Task<Bool, Never> {
        requestToken += 1
        let token = requestToken
        let worker = self.worker
        let queue = self.ioQueue
        let (stream, completion) = AsyncStream<Bool>.makeStream()
        queue.async { [weak self] in
            let outcome = worker.save(index: index, symbol: symbol)
            DispatchQueue.main.async { [weak self] in
                self?.apply(outcome, token: token)
                completion.yield(outcome.succeeded)
                completion.finish()
            }
        }
        return Task {
            for await succeeded in stream { return succeeded }
            return false
        }
    }

    /// Like slot edits, false means either an already saved value or failure.
    /// The caller must inspect error and the accepted symbols before showing success.
    @discardableResult
    func replaceSymbols(_ symbols: String) async -> Bool {
        await beginReplaceSymbols(symbols).value
    }

    @discardableResult
    func beginReplaceSymbols(_ symbols: String) -> Task<Bool, Never> {
        requestToken += 1
        let token = requestToken
        let worker = self.worker
        let queue = self.ioQueue
        let (stream, completion) = AsyncStream<Bool>.makeStream()
        queue.async { [weak self] in
            let outcome = worker.replaceSymbols(symbols)
            DispatchQueue.main.async { [weak self] in
                self?.apply(outcome, token: token)
                completion.yield(outcome.succeeded)
                completion.finish()
            }
        }
        return Task {
            for await succeeded in stream { return succeeded }
            return false
        }
    }

    private func apply(_ outcome: T9QuickSymbolIOWorker.Outcome, token: Int) {
        guard token > appliedToken else { return }
        appliedToken = token
        isShared = outcome.shared
        if outcome.applyFileURL { fileURL = outcome.fileURL }
        if outcome.resolved { hasResolvedStore = true }
        // Equal writes still notify the panel that owns this model; skip them.
        if let symbols = outcome.symbols, symbols != self.symbols { self.symbols = symbols }
        if error != outcome.errorMessage { error = outcome.errorMessage }
        if outcome.postChange { postChange() }
    }
}
