import CandidateKit
import KeyboardCore
import OSLog
import QuickContentKit
import SwiftUI
import os

// MARK: - Storage directory resolution (same discipline as the layout/skin directories: shared container first, local fallback)

/// Symbol library directory resolution. Prefers the App Group shared container `KeyboardSymbols/`
/// (host writes, extension reads; same probe discipline as `RimePaths.layoutStoreDirectory`); if the
/// container is not writable, falls back to the process-local Application Support (the extension's own
/// container, which still persists recents). A keyboard without Full Access reads the shared
/// directory as is and never writes it.
public enum SymbolLibraryStorage {
    /// Caches the resolved result in-process: the probe (create directory + write/read/delete) runs once per process, not on every panel open.
    private static let cachedDirectory = OSAllocatedUnfairLock<URL?>(initialState: nil)

    public static func defaultStoreDirectory() -> URL {
        // Read-only, the host's library is read where it is, unprobed and uncached, so a
        // later writable process still probes it.
        if !KeyboardRecipeStore.canWriteSharedContainer, let shared = sharedDirectory() { return shared }
        return cachedDirectory.withLock { cached in
            if let cached { return cached }
            let resolved = resolveStoreDirectory()
            cached = resolved
            return resolved
        }
    }

    /// Whether this process may write `directory`: the shared one only with Full Access.
    static func allowsWrites(to directory: URL) -> Bool {
        KeyboardRecipeStore.canWriteSharedContainer || directory != sharedDirectory()
    }

    private static func sharedDirectory() -> URL? {
        KeyboardRecipeStore.sharedContainerURL()?
            .appendingPathComponent(SymbolCatalogStore.sharedDirectoryName, isDirectory: true)
    }

    private static func resolveStoreDirectory() -> URL {
        RimePaths.probedStoreDirectory(
            sharedName: SymbolCatalogStore.sharedDirectoryName,
            localName: SymbolCatalogStore.sharedDirectoryName, label: "symbol"
        ).url
    }
}

// MARK: - Serial symbol store (the main thread only publishes results)

/// Directory probes create files and recent mutations perform read-modify-write;
/// keep them off the read-only resource queue and serialize across panel models.
enum SymbolLibraryWriteQueue {
    private static let queue = SerialIOQueue(label: "app.songyan.symbolLibrary.write", qos: .utility)

    static func async<T>(_ body: @escaping @Sendable () -> T) async -> sending T {
        await queue.async(body)
    }
}

// `directory` is confined to SymbolLibraryWriteQueue.
private final class SymbolLibraryIOWorker: @unchecked Sendable {
    struct Outcome: Sendable {
        var directory: URL
        var catalog: SymbolCatalog?
        var catalogReadError: String?
        var texts: [String]?
        var persistenceNote: String?
        var updatesPersistenceNote = false
        var isRead = false
        /// Set when a use could not be stored because the directory is read-only.
        var unstoredUse: String?
    }

    /// Confined to SymbolLibraryWriteQueue, including first-use resolution.
    private var directory: URL?
    init(directory: URL?) { self.directory = directory }

    private func resolveDirectory() -> URL {
        if let directory { return directory }
        let resolved = SymbolLibraryStorage.defaultStoreDirectory()
        directory = resolved
        return resolved
    }

    func load() async -> Outcome {
        let directory = await SymbolLibraryWriteQueue.async { self.resolveDirectory() }
        do {
            return try await KeyboardResourceReadQueue.async {
                var catalogError: String?
                let catalog = SymbolCatalogStore(directory: directory).loadActive {
                    catalogError = $0.localizedDescription
                }
                var recentError: String?
                let texts = RecentSymbolStore(directory: directory).read {
                    recentError = "无法读取最近使用记录：\($0.localizedDescription)"
                }
                return Outcome(
                    directory: directory, catalog: catalog,
                    catalogReadError: catalogError, texts: texts,
                    persistenceNote: recentError, updatesPersistenceNote: recentError != nil, isRead: true)
            }
        } catch {
            return Outcome(
                directory: directory, catalogReadError: error.localizedDescription,
                persistenceNote: "无法读取符号库：\(error.localizedDescription)",
                updatesPersistenceNote: true, isRead: true)
        }
    }

    func record(_ text: String) async -> Outcome {
        await SymbolLibraryWriteQueue.async {
            let directory = self.resolveDirectory()
            // Read-only: the insert stands, the stored recents stay untouched and the
            // use is kept for this keyboard session only.
            guard SymbolLibraryStorage.allowsWrites(to: directory) else {
                return Outcome(directory: directory, unstoredUse: text)
            }
            let result = RecentSymbolStore(directory: directory).record(text)
            return Outcome(
                directory: directory, texts: result.saveError == nil ? result.texts : nil,
                persistenceNote: result.saveError.map { "未能保存最近使用记录，已保留原有记录：\($0.localizedDescription)" },
                updatesPersistenceNote: true)
        }
    }

    func clear() async -> Outcome {
        await SymbolLibraryWriteQueue.async {
            let directory = self.resolveDirectory()
            guard SymbolLibraryStorage.allowsWrites(to: directory) else {
                return Outcome(
                    directory: directory,
                    persistenceNote: "未能清空最近使用记录，请在系统设置中打开「允许完全访问」后重试",
                    updatesPersistenceNote: true)
            }
            do {
                try RecentSymbolStore(directory: directory).clear()
                return Outcome(directory: directory, texts: [], updatesPersistenceNote: true)
            } catch {
                return Outcome(
                    directory: directory,
                    persistenceNote: "未能清空最近使用记录：\(error.localizedDescription)",
                    updatesPersistenceNote: true)
            }
        }
    }
}

// MARK: - Panel state model (render-independent; search isolation lives here)

/// Symbol panel state: catalog data, query buffer, category selection, recents.
/// Search state is independent of the Chinese composition: this model holds no controller/session reference.
@MainActor
public final class SymbolLibraryModel: ObservableObject {
    /// Query key (the exact interface for a host-injected external search action; the internal keyboard uses it too).
    public enum SearchKey: Equatable, Sendable {
        /// Appends characters (may be several; whitespace and newlines are dropped). Chinese can be injected too; matching is by name.
        case character(String)
        case backspace
        case clear
    }

    /// Recent entry (text + its catalog name; the name is nil if the catalog lacks the text, and it can
    /// still be tapped to insert, since recents record the inserted text and do not depend on an entry id).
    public struct RecentEntry: Identifiable, Equatable, Sendable {
        public let text: String
        public let name: String?
        public var id: String { text }
    }

    @Published public private(set) var catalog: SymbolCatalog
    @Published public private(set) var catalogReadError: String?
    @Published public private(set) var recents: [RecentEntry] = []
    /// Non-blocking note for a persistence problem (a failed save keeps the old data and the panel stays usable).
    @Published public private(set) var persistenceNote: String?
    /// Query buffer (private to the panel; normalized comparison is in SymbolCatalog.search).
    @Published public private(set) var query: String = ""
    @Published public private(set) var selectedCategory: String?
    /// Whether the internal ASCII query keyboard is shown (inside the panel only, not a resident bottom key).
    @Published public private(set) var searchKeyboardVisible = false

    @Published public private(set) var storeDirectory: URL?
    @Published public private(set) var isLoading = true
    private let worker: SymbolLibraryIOWorker
    /// Register the predecessor synchronously on MainActor before any Task can
    /// yield: file operation order must follow gestures, not Task scheduling.
    private var pendingOperation: Task<Void, Never>?
    private var requestToken = 0
    private var appliedToken = 0
    private var latestReloadToken = 0
    private var persistenceNoteFromRead = false
    /// The last recents read from or written to the store.
    private var storedRecents: [String] = []
    /// Uses that could not be stored (no Full Access): shown first for the life of
    /// this keyboard process, never written.
    private var sessionRecents: [String] = []
    private let onInsert: (String) -> Bool
    /// Optional report of whether the insert succeeded: the host uses it for "feedback only on real success" side effects.
    /// Timing: called once after onInsert returns true and before recents are recorded.
    private let onInserted: ((Bool) -> Void)?

    /// - Parameters:
    ///   - storeDirectory: Injected user directory (nil = resolve automatically, see SymbolLibraryStorage).
    ///     Host and extension processes can share the custom catalog and recents by using the same directory.
    ///   - onInsert: Insert exit; the host wires `controller.insertLiteral`, which does the composition
    ///     confirmation, so this panel never restarts the engine. The return value says whether this
    ///     literal was dispatched to a valid host exit (false for a partial composition commit, no host
    ///     exit, or input disabled); true does not guarantee the host document accepted it (the public
    ///     proxy gives no receipt). On false, recents are not recorded.
    ///   - onInserted: Optional report of the insert result (called once, before recents are recorded).
    ///   - loadsImmediately: false defers the first read to an explicit `reload()`, for owners
    ///     created with the keyboard that may never show the library.
    public init(
        storeDirectory: URL? = nil,
        onInsert: @escaping (String) -> Bool,
        onInserted: ((Bool) -> Void)? = nil,
        loadsImmediately: Bool = true
    ) {
        self.storeDirectory = storeDirectory
        self.worker = SymbolLibraryIOWorker(directory: storeDirectory)
        self.onInsert = onInsert
        self.onInserted = onInserted
        // Even bundledDefault() reads JSON. First paint must not touch disk.
        self.catalog = SymbolCatalog(categories: [], items: [])
        if loadsImmediately { reload() } else { isLoading = false }
    }

    /// Re-reads the catalog and recents; returns a task for callers that need a stable result to await.
    /// Serialized with insert/clear records in call order, so an old read cannot pass a newer write.
    @discardableResult
    public func reload() -> Task<Void, Never> {
        isLoading = true
        latestReloadToken = requestToken + 1
        return enqueue { await $0.load() }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping (SymbolLibraryIOWorker) async -> SymbolLibraryIOWorker.Outcome) -> Task<
        Void, Never
    > {
        requestToken += 1
        let token = requestToken
        let previous = pendingOperation
        let worker = self.worker
        let task = Task { [weak self] in
            await previous?.value
            let outcome = await operation(worker)
            self?.apply(outcome, token: token)
        }
        pendingOperation = task
        return task
    }

    private func apply(_ outcome: SymbolLibraryIOWorker.Outcome, token: Int) {
        guard token > appliedToken else { return }
        appliedToken = token
        storeDirectory = outcome.directory
        if let catalog = outcome.catalog {
            self.catalog = catalog
            catalogReadError = outcome.catalogReadError
        }
        if let use = outcome.unstoredUse {
            sessionRecents = Array(([use] + sessionRecents.filter { $0 != use }).prefix(Self.recentLimit))
        }
        if let texts = outcome.texts { storedRecents = texts }
        if outcome.unstoredUse != nil || outcome.texts != nil || outcome.catalog != nil {
            let merged = sessionRecents + storedRecents.filter { !sessionRecents.contains($0) }
            recents = Self.recentEntries(texts: Array(merged.prefix(Self.recentLimit)), catalog: catalog)
        }
        if outcome.updatesPersistenceNote {
            persistenceNote = outcome.persistenceNote
            persistenceNoteFromRead = outcome.isRead
        } else if outcome.isRead && persistenceNoteFromRead {
            persistenceNote = nil
            persistenceNoteFromRead = false
        }
        if token == latestReloadToken { isLoading = false }
    }

    // MARK: Search (own buffer; never writes to the host or Rime)

    /// Single entry for query keys (the internal keyboard and host external actions share one buffer and its rules).
    public func searchKey(_ key: SearchKey) {
        switch key {
        case .character(let characters):
            let allowed = characters.filter { !$0.isWhitespace && !$0.isNewline }
            guard !allowed.isEmpty else { return }
            query += allowed
        case .backspace:
            if !query.isEmpty { query.removeLast() }
        case .clear:
            query = ""
        }
    }

    /// Entered from a panel search action: opens the internal query keyboard.
    public func beginSearch() { searchKeyboardVisible = true }

    /// Leaves search: clears the query buffer and hides the query keyboard (back to category browsing; the composition is untouched).
    public func endSearch() {
        query = ""
        searchKeyboardVisible = false
    }

    public var isSearching: Bool { !query.isEmpty }
    public var searchResults: [SymbolItem] { catalog.search(query) }

    // MARK: Browse

    public func selectCategory(_ id: String?) { selectedCategory = id }

    /// Categories that have items (empty ones are skipped to avoid empty header areas).
    public var visibleCategories: [SymbolCategory] {
        catalog.orderedCategories.filter { !catalog.items(in: $0.id).isEmpty }
    }

    public func categoryName(_ id: String) -> String? {
        catalog.categories.first(where: { $0.id == id })?.name
    }

    // MARK: Insert and recents

    /// Inserts a symbol: the only output closure + the recents record (dedupe and move to front, persist, keep old on failure).
    /// Recents are recorded only after the insert really took effect (onInsert returned true); the panel
    /// stays open, so several symbols can be inserted in a row.
    public func insert(_ item: SymbolItem) {
        insertText(item.text, name: item.name)
    }

    /// Inserts a recent entry (the catalog may no longer contain it; inserted by text only).
    public func insert(entry: RecentEntry) {
        insertText(entry.text, name: entry.name)
    }

    /// Private phrases and clipboard text never enter the symbol-recents file.
    public func insertQuickText(_ text: String) -> Bool {
        let inserted = onInsert(text)
        onInserted?(inserted)
        return inserted
    }

    private func insertText(_ text: String, name: String?) {
        let inserted = onInsert(text)
        onInserted?(inserted)
        guard inserted else { return }
        recordUse(text)
    }

    /// Records a symbol another surface (the 9-key symbol page) already inserted,
    /// so both share one recents list.
    public func recordUse(_ text: String) {
        enqueue { await $0.record(text) }
    }

    private static let recentLimit = 20

    /// Clears recents (keeps the old data and notes on failure); ordered after earlier insert records/refreshes.
    @discardableResult
    public func clearRecents() -> Task<Void, Never> {
        sessionRecents = []
        recents = Self.recentEntries(texts: storedRecents, catalog: catalog)
        return enqueue { await $0.clear() }
    }

    private static func recentEntries(texts: [String], catalog: SymbolCatalog) -> [RecentEntry] {
        texts.map { text in
            RecentEntry(text: text, name: catalog.items.first(where: { $0.text == text })?.name)
        }
    }
}
