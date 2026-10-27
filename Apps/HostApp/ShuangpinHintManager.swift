import Combine
import Foundation
import KeyboardCore
import LayoutKit
import PackageManager

/// Posted after every host-side write (toggle, selection, edit, import, delete) so the keyboard
/// panel re-reads the snapshot it shows.
extension Notification.Name {
    public static let shuangpinHintsChanged = Notification.Name("keyboard.shuangpinHints.changed")
}

/// Where the hint settings live. Only the App Group container is readable by the keyboard.
enum ShuangpinHintStoreLocation: Equatable {
    case shared(URL)
    case local(URL)

    var url: URL {
        switch self {
        case .shared(let url), .local(let url): return url
        }
    }

    var isShared: Bool {
        if case .shared = self { return true }
        return false
    }
}

/// Host-side owner of the shuangpin hint presets; the only writer.
///
/// Storage is App Group "ShuangpinHints/hints.json" when the container exists, otherwise an
/// app-local directory the keyboard cannot read; the UI says which one is in use.
///
/// Fail-closed: a snapshot is written only when a validated one was read first, so a damaged file is
/// never overwritten by a default. Init touches no disk; reads and writes run on HostConfigIOQueue
/// with a latest-wins gate and a MainActor FIFO write slot.
@MainActor
final class ShuangpinHintManager: ObservableObject {
    static let shared = ShuangpinHintManager()

    /// Nil until a valid snapshot has been read.
    @Published private(set) var snapshot: ShuangpinHintSnapshot?
    @Published private(set) var location: ShuangpinHintStoreLocation?
    @Published private(set) var isLoading = true
    @Published private(set) var isBusy = false
    /// True when the last read finished without a usable snapshot (damaged or unreadable file).
    @Published private(set) var loadFailed = false
    /// The last failure, already phrased for the user.
    @Published private(set) var lastError: String?
    /// The last successful action ("已开启双拼提示。").
    @Published private(set) var message: String?

    private var store: ShuangpinHintStore?
    private var loadGate = LatestWinsReadGate()
    private var loadTask: Task<Void, Never>?
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    private init() { reload() }

    /// The built-in list until the first read, so the page never renders empty.
    var presets: [ShuangpinHintPreset] { snapshot?.presets ?? ShuangpinHintPresets.all }
    var isEnabled: Bool { snapshot?.enabled ?? false }
    var selectedPresetID: String? { snapshot?.selectedPresetID }
    /// Writes are refused until a valid snapshot is current.
    var canEdit: Bool { snapshot != nil }
    /// The keyboard can only read the shared container; without it the switch would control
    /// nothing, so it stays off while drafts and import/export keep working.
    var canToggleHints: Bool { canEdit && (location?.isShared ?? false) }

    // MARK: - Location

    /// App Group container first, app-local directory otherwise.
    nonisolated static func resolveStoreDirectory() -> ShuangpinHintStoreLocation {
        if let container = KeyboardRecipeStore.sharedContainerURL() {
            let url = container.appendingPathComponent(ShuangpinHintStore.directoryName, isDirectory: true)
            return .shared(url)
        }
        return .local(
            HostStorePaths.applicationSupport
                .appendingPathComponent("Rime\(ShuangpinHintStore.directoryName)", isDirectory: true))
    }

    // MARK: - Reading

    func reload() {
        message = nil
        lastError = nil
        isLoading = true
        loadFailed = false
        let token = loadGate.begin()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let outcome = await Self.readState()
            guard let self, !Task.isCancelled, self.loadGate.accepts(token) else { return }
            self.store = outcome.store
            self.snapshot = outcome.snapshot
            self.loadFailed = outcome.snapshot == nil
            self.location = outcome.location
            self.lastError = outcome.error
            self.isLoading = false
        }
    }

    private nonisolated static func readState() async -> ReadOutcome {
        do {
            return try await HostConfigIOQueue.async {
                let location = resolveStoreDirectory()
                let store = ShuangpinHintStore(directory: location.url)
                do {
                    // Reading never creates the directory, so "hints are off" stays distinguishable
                    // from "not saved yet".
                    return ReadOutcome(store: store, snapshot: try store.load(), location: location, error: nil)
                } catch {
                    return ReadOutcome(
                        store: store, snapshot: nil, location: location,
                        error: "暂时无法读取双拼提示，请重试。")
                }
            }
        } catch {
            return ReadOutcome(
                store: nil, snapshot: nil, location: nil,
                error: "暂时无法读取双拼提示，请重试。")
        }
    }

    // MARK: - Writes

    private func acquireWriteSlot() async {
        if !writeInFlight {
            writeInFlight = true
            return
        }
        await withCheckedContinuation { continuation in writeWaiters.append(continuation) }
    }

    private func releaseWriteSlot() {
        if writeWaiters.isEmpty { writeInFlight = false } else { writeWaiters.removeFirst().resume() }
    }

    /// Applies one validated change atomically; the in-memory value changes only after the write
    /// succeeded, so a failed write never appears saved.
    @discardableResult
    private func persist(
        _ mutate: (inout ShuangpinHintSnapshot) throws -> Void,
        success: String
    ) async -> Bool {
        await acquireWriteSlot()
        defer { releaseWriteSlot() }
        isBusy = true
        defer { isBusy = false }
        // Never write over a file we refused to read: the user may still repair or export it.
        guard let current = snapshot, let store else {
            lastError = "暂时无法读取双拼提示，请重试。"
            return false
        }
        loadGate.invalidate()
        loadTask?.cancel()
        do {
            var updated = current
            try mutate(&updated)
            updated = updated.ensuringBuiltinPreset()
            try updated.validate()
            if updated == current {
                lastError = nil
                return true
            }
            try await HostConfigIOQueue.async { [updated] in try store.save(updated) }
            snapshot = updated
            lastError = nil
            message = success
            NotificationCenter.default.post(name: .shuangpinHintsChanged, object: nil)
            return true
        } catch {
            lastError = Self.friendly(error)
            return false
        }
    }

    // MARK: - Operations

    /// Turns hint display on or off, keeping the current selection. Refused when the keyboard
    /// cannot read the store, so the page never reports a change the keyboard cannot see.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard canToggleHints else {
            lastError = "提示暂时无法用于键盘，你可以先导出文件保存。"
            return false
        }
        return await persist(
            { $0.enabled = enabled },
            success: enabled ? "已开启双拼提示。" : "已关闭双拼提示。")
    }

    func select(_ id: String) async {
        guard snapshot?.preset(id: id) != nil else {
            lastError = "找不到这个提示预设，请重新选择。"
            return
        }
        await persist({ $0.selectedPresetID = id }, success: "已切换提示预设。")
    }

    /// Saves an edited or imported preset. A new preset is appended; an existing one is replaced only
    /// when `replacing` is true.
    @discardableResult
    func savePreset(_ preset: ShuangpinHintPreset, replacing: Bool = false) async -> Bool {
        let value = preset.normalized()
        do { try value.validate() } catch {
            lastError = Self.friendly(error)
            return false
        }
        if !replacing, let existing = snapshot?.preset(id: value.id), !(snapshot?.isBuiltin(existing) ?? false) {
            lastError = "已有相同标识的提示预设，请改名或选择替换。"
            return false
        }
        return await persist(
            { snapshot in
                guard replacing || snapshot.preset(id: value.id) == nil else {
                    throw ShuangpinHintError("已有相同标识的提示预设，请复制一份后再保存。")
                }
                var presets = snapshot.presets.filter { $0.id != value.id }
                presets.append(value)
                snapshot.presets = presets
            }, success: "已保存提示预设「\(value.name)」。")
    }

    /// Deletes a user preset; the built-in preset is kept so the switch cannot point at nothing.
    @discardableResult
    func removePreset(id: String) async -> Bool {
        guard let preset = snapshot?.preset(id: id) else {
            lastError = "找不到这个提示预设，它可能已被删除。"
            return false
        }
        guard !(snapshot?.isBuiltin(preset) ?? false) else {
            lastError = "内置提示预设不能删除，可以复制一份再修改。"
            return false
        }
        return await persist(
            { snapshot in
                snapshot.presets.removeAll { $0.id == id }
                if snapshot.selectedPresetID == id {
                    snapshot = snapshot.ensuringBuiltinPreset()
                    snapshot.selectedPresetID = ShuangpinHintPresets.builtinID
                    snapshot.enabled = false
                }
            }, success: "已删除提示预设「\(preset.name)」。")
    }

    /// Recovery is offered only after a read finished with a refused file; a valid snapshot, or one
    /// still loading, is never replaced by the default.
    var canRecover: Bool { !isLoading && loadFailed && snapshot == nil }
    var recoveryFileURL: URL? { canRecover ? store?.catalogURL : nil }

    /// Explicit recovery for an unreadable settings file: replace it with the default (hints off).
    /// Only a user action does this; nothing overwrites the file automatically.
    @discardableResult
    func resetToDefault() async -> Bool {
        await acquireWriteSlot()
        defer { releaseWriteSlot() }
        guard canRecover else { return false }
        loadGate.invalidate()
        loadTask?.cancel()
        isBusy = true
        defer { isBusy = false }
        do {
            let location = await Self.resolveStore()
            let store = location.0
            let fresh = ShuangpinHintSnapshot.disabled
            try await HostConfigIOQueue.async { try store.save(fresh) }
            self.store = store
            self.location = location.1
            self.snapshot = fresh
            self.loadFailed = false
            self.isLoading = false
            self.lastError = nil
            self.message = "已恢复默认设置，双拼提示为关闭。"
            NotificationCenter.default.post(name: .shuangpinHintsChanged, object: nil)
            return true
        } catch {
            lastError = Self.friendly(error)
            return false
        }
    }

    private nonisolated static func resolveStore() async -> (ShuangpinHintStore, ShuangpinHintStoreLocation) {
        let location = resolveStoreDirectory()
        return (ShuangpinHintStore(directory: location.url), location)
    }

    // MARK: - Import / export

    /// Imports a preset document read from a local file. A colliding identity becomes a copy, so
    /// importing is additive.
    @discardableResult
    func importPreset(data: Data, fallbackName: String = "导入的提示") async -> Bool {
        let preset: ShuangpinHintPreset
        do {
            var decoded = try ShuangpinHintStore.decodePresetFile(data)
            if decoded.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                decoded = decoded.renamed(fallbackName)
            }
            preset = uniqueCopy(of: decoded)
        } catch {
            lastError = Self.friendly(error)
            return false
        }
        return await persist(
            { $0.presets.append(preset) },
            success: "已导入提示预设「\(preset.name)」。")
    }

    /// Imports a preset from a file the user picked; the security-scoped read runs on the background
    /// queue.
    @discardableResult
    func importPreset(fileAt url: URL) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await HostConfigIOQueue.async { try ShuangpinHintStore.readImportedFile(at: url) }
            return await importPreset(
                data: data,
                fallbackName: url.deletingPathExtension().lastPathComponent)
        } catch {
            lastError = Self.friendly(error)
            return false
        }
    }

    /// Imports from an HTTPS link through the shared bounded reader: an over-budget length is refused
    /// before any byte is buffered and a redirect off HTTPS is refused.
    @discardableResult
    func importPreset(address: String) async -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else {
            lastError = "请输入以 https:// 开头的链接。"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await RecipePackageManager.fetchHTTPBytes(
                url, maximumBytes: ShuangpinHintDocument.maximumBytes)
            try Task.checkCancellation()
            return await importPreset(
                data: data,
                fallbackName: url.deletingPathExtension().lastPathComponent)
        } catch is CancellationError {
            return false
        } catch {
            lastError = Self.downloadMessage(error)
            return false
        }
    }

    /// One preset exported as a standalone file the user can share.
    func exportData(for id: String) -> Data? {
        guard let preset = snapshot?.preset(id: id) else { return nil }
        do { return try ShuangpinHintStore.encodePreset(preset) } catch {
            lastError = Self.friendly(error)
            return nil
        }
    }

    /// The whole settings file (every preset plus the switch), for keeping a backup.
    func exportAllData() -> Data? {
        guard let snapshot else { return nil }
        do { return try ShuangpinHintStore.encodeSnapshot(snapshot) } catch {
            lastError = Self.friendly(error)
            return nil
        }
    }

    private func uniqueCopy(of preset: ShuangpinHintPreset) -> ShuangpinHintPreset {
        guard let snapshot, snapshot.preset(id: preset.id) != nil else { return preset }
        return preset.copy(name: preset.name + "（导入）")
    }

    // MARK: - Errors

    nonisolated static func friendly(_ error: Error) -> String {
        if let hintError = error as? ShuangpinHintError { return hintError.message }
        if let layoutError = error as? LayoutError { return ShuangpinHintStore.friendly(layoutError) }
        if let posixError = error as? POSIXError, posixError.code == .ENOENT {
            return "找不到这个文件，请重新选择。"
        }
        if error is POSIXError { return "提示文件无法读取，请重新选择文件。" }
        return "操作没有完成，请重试。"
    }

    /// Download failures read as one short sentence; the transport's own description is not shown.
    nonisolated static func downloadMessage(_ error: Error) -> String {
        if let hintError = error as? ShuangpinHintError { return hintError.message }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "网络未连接，请检查后重试。"
            case .timedOut: return "下载超时，请稍后重试。"
            case .cancelled: return "已取消。"
            default: break
            }
        }
        return "下载失败，请检查链接后重试。"
    }
}

/// Background read result: Sendable values only.
private struct ReadOutcome: Sendable {
    var store: ShuangpinHintStore?
    var snapshot: ShuangpinHintSnapshot?
    var location: ShuangpinHintStoreLocation?
    var error: String?
}
