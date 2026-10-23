import Combine
import Foundation
import KeyboardCore
import LayoutKit

/// DIY layout management (single-writer coordinator on the host app side).
///
/// Uses LayoutKit's LayoutStore + LayoutRegistry:
///  - the directory is resolved by RimePaths.layoutStoreDirectory() (App Group shared first, local fallback);
///  - every write goes through store.save (validated, atomic), with errors mapped to user-friendly text;
///  - at least one enabled layout is kept (checked by LayoutRegistry; the UI only shows a hint);
///  - built-in layouts are always available (LayoutStore falls back to BuiltinLayouts on first read or corruption).
///
/// Threading and disk discipline:
///  - init does no disk I/O (not a single FileManager call): it starts from the built-in layouts, and the
///    directory probe and `store.load()` run on the serial `HostConfigIOQueue`, with the main thread only
///    applying results; `location` is nil until the first load finishes (the UI shows "checking");
///  - reads use a latest-wins gate plus a cancellation gate; user writes invalidate in-flight reads first, so a
///    stale read never overwrites the registry just saved;
///  - writes (`store.save`) also run on `HostConfigIOQueue`, serialized by a MainActor FIFO write slot:
///    validate, persist in the background, replace the cache only on success.
@MainActor
final class LayoutManager: ObservableObject {
    static let shared = LayoutManager()

    @Published private(set) var registry: LayoutRegistry
    /// Resolved storage location; nil until the first background load finishes (the directory is not yet resolved).
    @Published private(set) var location: LayoutStoreLocation?
    @Published private(set) var lastError: String?
    @Published private(set) var isImporting = false

    /// Resolved store; nil until the first background load finishes (nothing is written meanwhile).
    private var store: LayoutStore?
    /// Latest-wins gate for reads: a late read must not overwrite a newer read or a completed user write.
    private var loadGate = LatestWinsReadGate()
    /// In-flight read task; `reload()` cancels it (only the result is dropped; the background I/O itself cannot be cancelled).
    private var loadTask: Task<Void, Never>?
    /// MainActor FIFO write slot: prevents interleaving between two awaits from losing updates.
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Init is purely in-memory: no FileManager or disk calls.
    /// Starts from the built-in layouts with an unresolved directory, then resolves it and loads the registry on the background queue.
    private init() {
        registry = Self.builtinRegistry()
        location = nil
        store = nil
        reload()
    }

    /// Built-in fallback (what LayoutStore.load yields for an empty or new directory).
    private nonisolated static func builtinRegistry() -> LayoutRegistry {
        do { return try LayoutRegistry() } catch { fatalError("Built-in layout defaults are invalid: \(error)") }
    }

    func clearError() {
        lastError = nil
    }

    /// Re-reads from disk when the management page opens (picks up external changes and corruption recovery).
    ///
    /// Directory resolution (including the read/write probe) runs only on the first load; later reloads reuse the same store.
    func reload() {
        let existing = store
        let currentLocation = location
        let currentRegistry = registry
        let token = loadGate.begin()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let outcome: LayoutLoadOutcome
            if let existing {
                outcome = await Self.reread(store: existing, location: currentLocation, current: currentRegistry)
            } else {
                outcome = await Self.initialLoad()
            }
            // Cancellation gate + latest-wins gate: apply only if both pass.
            guard let self,
                StructuredRefreshOutcome.shouldApply(
                    isCancelled: Task.isCancelled,
                    accepted: self.loadGate.accepts(token))
            else { return }
            self.apply(outcome)
        }
    }

    /// Applies the background load result on the main thread.
    private func apply(_ outcome: LayoutLoadOutcome) {
        location = outcome.isShared ? .shared(outcome.directoryURL) : .local(outcome.directoryURL)
        store = outcome.store
        registry = outcome.registry
        lastError = outcome.error
    }

    /// First load (or when a store is needed before a write): resolve the directory (with read/write probe), build the store, read;
    /// on failure fall back to the built-in layouts without overwriting user files.
    private nonisolated static func initialLoad() async -> LayoutLoadOutcome {
        do {
            return try await HostConfigIOQueue.async {
                let location = RimePaths.layoutStoreDirectory()
                let store = LayoutStore(directoryURL: location.url)
                do {
                    return LayoutLoadOutcome(
                        directoryURL: location.url, isShared: location.isShared,
                        store: store, registry: try store.load(), error: nil)
                } catch {
                    // If the directory is corrupt or unreadable, do not overwrite user files: temporarily use the built-in layouts and show a notice.
                    return LayoutLoadOutcome(
                        directoryURL: location.url, isShared: location.isShared, store: store,
                        registry: builtinRegistry(),
                        error: "读取布局目录失败：\(friendly(error))（已临时显示内置布局，未更改你的文件）")
                }
            }
        } catch {
            let fallback = RimePaths.layoutStoreReadLocation()
            return LayoutLoadOutcome(
                directoryURL: fallback.url, isShared: fallback.isShared,
                store: LayoutStore(directoryURL: fallback.url),
                registry: builtinRegistry(),
                error: "读取布局目录失败：\(friendly(error))（已临时显示内置布局，未更改你的文件）")
        }
    }

    /// Reload: reuses the resolved store; on failure keeps the current display (does not replace it with built-ins).
    private nonisolated static func reread(
        store: LayoutStore, location: LayoutStoreLocation?,
        current: LayoutRegistry
    ) async -> LayoutLoadOutcome {
        let resolved = location ?? RimePaths.layoutStoreReadLocation()
        do {
            return try await HostConfigIOQueue.async {
                LayoutLoadOutcome(
                    directoryURL: resolved.url, isShared: resolved.isShared,
                    store: store, registry: try store.load(), error: nil)
            }
        } catch {
            return LayoutLoadOutcome(
                directoryURL: resolved.url, isShared: resolved.isShared,
                store: store, registry: current,
                error: "读取失败：\(friendly(error))（当前内容可能不是最新）")
        }
    }

    // MARK: - Operations (in memory, then validate + persist in background, replace cache only on success)

    /// Acquires the single write slot (MainActor FIFO). While held, no second write may re-read the registry,
    /// otherwise two concurrent writes would each compute from a stale snapshot and lose an update.
    private func acquireWriteSlot() async {
        if !writeInFlight {
            writeInFlight = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeWaiters.append(continuation)
        }
    }

    private func releaseWriteSlot() {
        if writeWaiters.isEmpty {
            writeInFlight = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    @discardableResult
    private func persist(_ mutate: (inout LayoutRegistry) throws -> Void) async -> Bool {
        await acquireWriteSlot()
        defer { releaseWriteSlot() }
        // A queued write must retire reads only once it owns the slot; a reload
        // may also begin while store.save awaits the background queue.
        loadGate.invalidate()
        loadTask?.cancel()

        // If the first load has not finished (or never happened), resolve the directory and read the baseline first; otherwise the write would go to the wrong place.
        if store == nil {
            let outcome = await Self.initialLoad()
            location = outcome.isShared ? .shared(outcome.directoryURL) : .local(outcome.directoryURL)
            store = outcome.store
            registry = outcome.registry
            lastError = outcome.error
        }
        guard let store else {
            lastError = "布局存储位置尚未就绪，请稍后重试。"
            return false
        }
        do {
            var updated = registry
            try mutate(&updated)
            // No change, no write (avoids a pointless atomic write).
            if updated == registry {
                lastError = nil
                return true
            }
            // Persisting runs on the serial background queue; the main thread does not touch disk.
            try await HostConfigIOQueue.async { [updated] in try store.save(updated) }
            loadGate.invalidate()
            loadTask?.cancel()
            // store.save has already validated and written atomically; the cache is replaced only on success.
            registry = updated
            lastError = nil
            return true
        } catch {
            lastError = Self.friendly(error)
            return false
        }
    }

    /// Enable (appended to the end of the enabled list) / disable; disabling the last one is rejected by validation with a friendly notice.
    func setEnabled(_ id: String, on: Bool) async {
        await persist { reg in
            var ids = reg.enabledIDs
            if on {
                if !ids.contains(id) { ids.append(id) }
            } else {
                ids.removeAll { $0 == id }
            }
            try reg.setEnabledIDs(ids)
        }
    }

    /// Drag-reorder enabled layouts (order is the keyboard's switching order).
    ///
    /// The order is computed inside the `persist` closure from the registry at that time: if the first background load
    /// has not landed, `persist` reads the disk baseline first, so reordering never overwrites custom layouts' enabled state with the built-in order.
    func moveEnabled(from source: IndexSet, to destination: Int) async {
        await persist { reg in
            var ids = reg.enabledIDs
            ids.move(fromOffsets: source, toOffset: destination)
            guard ids != reg.enabledIDs else { return }
            try reg.setEnabledIDs(ids)
        }
    }

    func remove(_ id: String) async {
        await persist { reg in
            try reg.remove(id: id)
        }
    }

    /// Re-adds a built-in layout to the directory (appended to the enabled list by default).
    func addBuiltin(_ layout: LayoutDefinition) async {
        guard let data = try? layout.encoded() else {
            lastError = "内置布局编码失败"
            return
        }
        await persist { reg in
            try reg.install(data)
        }
    }

    /// Read into a draft. Import never writes until the user chooses save/replace/copy.
    /// The MainActor owns the busy flag and scope lifetime; the queue performs all
    /// file inspection, bounded reading, decoding and validation before scope release.
    func readImport(_ url: URL) async throws -> LayoutDefinition {
        guard !isImporting else { throw LayoutError.invalid("正在导入布局，请稍候…") }
        isImporting = true
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
            isImporting = false
        }
        let draft = try await HostConfigIOQueue.async { try LayoutDefinition.read(from: url) }
        try Task.checkCancellation()
        return draft
    }

    @discardableResult
    func saveDraft(_ draft: LayoutDefinition, asCopy: Bool = false) async -> Bool {
        await persist { reg in
            if asCopy {
                try reg.copy(draft)
            } else if reg.layout(id: draft.id) != nil {
                try reg.replace(draft)
            } else {
                try reg.install(draft.encoded(), enable: false)
            }
        }
    }

    /// Exports a single layout as JSON (to be edited externally and re-imported). Pure in-memory encoding, no disk access.
    func exportData(for id: String) -> Data? {
        guard let layout = registry.layout(id: id) else { return nil }
        return try? layout.encoded()
    }

    // MARK: - Error messages

    nonisolated static func friendly(_ error: Error) -> String {
        if let layoutError = error as? LayoutError {
            switch layoutError {
            case .lastEnabledLayout:
                return "请至少保留一个启用的布局。请先启用其他布局，再停用或移除当前布局。"
            case .duplicateID(let id):
                return "已存在相同标识的键盘布局（\(id)），请替换或另存为副本。"
            case .unknownID(let id):
                return "找不到键盘布局：\(id)"
            case .invalid(let reason):
                return "键盘布局文件无效：\(reason)"
            }
        }
        return error.localizedDescription
    }
}

/// Background load result (Sendable values; passed across queues, the closure holds no MainActor objects).
private struct LayoutLoadOutcome: Sendable {
    /// Layout directory URL and whether it is shared; the main thread uses it to rebuild `LayoutStoreLocation`.
    var directoryURL: URL
    var isShared: Bool
    var store: LayoutStore
    var registry: LayoutRegistry
    var error: String?
}
