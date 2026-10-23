import Combine
import Foundation

enum SymbolLibraryStorage {
    static var directory: URL!
    static let entered = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static var resolutions = 0
    nonisolated(unsafe) static var writable = true
    static func allowsWrites(to directory: URL) -> Bool { writable }
    static func defaultStoreDirectory() -> URL {
        precondition(!Thread.isMainThread, "default directory probe must run off main")
        resolutions += 1
        entered.signal()
        precondition(
            release.wait(timeout: .now() + 5) == .success, "initializer must not block waiting for directory I/O")
        return directory
    }
}

extension Bundle {
    static var module: Bundle {
        precondition(!Thread.isMainThread, "bundled JSON lookup/read must run off main")
        return Bundle(path: CommandLine.arguments[2])!
    }
}

func waitForSignal(_ semaphore: DispatchSemaphore) async {
    let signaled = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
    precondition(signaled, "background operation did not arrive")
}

final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var active = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func start(_ url: URL) -> Bool {
        precondition(!Thread.isMainThread)
        lock.lock()
        precondition(!active)
        active = true
        starts += 1
        let first = starts == 1
        lock.unlock()
        if first {
            entered.signal()
            precondition(release.wait(timeout: .now() + 5) == .success)
        }
        return true
    }
    func stop(_ url: URL) {
        precondition(!Thread.isMainThread)
        lock.lock()
        defer { lock.unlock() }
        precondition(active)
        active = false
        stops += 1
    }
    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return [starts, stops, active ? 1 : 0]
    }
}

@main struct Main {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        SymbolLibraryStorage.directory = directory
        let store = RecentSymbolStore(directory: directory)
        precondition(store.save(["seed"]) == nil)
        let a = SymbolItem(id: "a", text: "A", name: "Alpha", aliases: ["alpha"], category: "letters")
        let b = SymbolItem(id: "b", text: "B", name: "Beta", aliases: ["beta"], category: "letters")
        var allowInsert = true
        var inserted: [String] = []
        var feedback: [Bool] = []
        let model = SymbolLibraryModel(
            onInsert: {
                if allowInsert { inserted.append($0) }
                return allowInsert
            }, onInserted: { feedback.append($0) })
        precondition(model.isLoading && model.catalog.items.isEmpty && model.storeDirectory == nil)
        await waitForSignal(SymbolLibraryStorage.entered)
        model.beginSearch()
        model.searchKey(.character(" jian tou \n"))
        model.insert(a)
        precondition(model.query == "jiantou" && inserted == ["A"] && feedback == [true])
        precondition(model.recents.isEmpty, "an uncompleted save must not appear as persisted")
        SymbolLibraryStorage.release.signal()
        await model.reload().value
        precondition(!model.isLoading && model.storeDirectory == directory)
        precondition(SymbolLibraryStorage.resolutions == 1)
        precondition(model.catalog.items.count >= 80 && model.searchResults.contains { $0.text == "→" })
        precondition(model.recents.map(\.text) == ["A", "seed"] && store.read() == ["A", "seed"])
        print(
            "PASS first paint/search/insertion stay responsive while default resolution blocks; bundled catalog loads off main"
        )

        let readEntered = DispatchSemaphore(value: 0)
        let readRelease = DispatchSemaphore(value: 0)
        let blocker = Task {
            try await KeyboardResourceReadQueue.async {
                readEntered.signal()
                precondition(readRelease.wait(timeout: .now() + 5) == .success)
            }
        }
        await waitForSignal(readEntered)
        let oldRead = model.reload()
        model.insert(a)
        let clear = model.clearRecents()
        model.insert(b)
        let newestRead = model.reload()
        precondition(model.isLoading && inserted == ["A", "A", "B"])
        precondition(model.recents.map(\.text) == ["A", "seed"])
        readRelease.signal()
        try await blocker.value
        await oldRead.value
        await clear.value
        await newestRead.value
        precondition(!model.isLoading && model.recents.map(\.text) == ["B"] && store.read() == ["B"])
        print("PASS blocked old read plus insert/clear/insert/reload preserves touch order and latest disk/UI state")

        let writeEntered = DispatchSemaphore(value: 0)
        let writeRelease = DispatchSemaphore(value: 0)
        let writeBlocker = Task {
            await SymbolLibraryWriteQueue.async {
                writeEntered.signal()
                precondition(writeRelease.wait(timeout: .now() + 5) == .success)
            }
        }
        await waitForSignal(writeEntered)
        model.insert(a)
        model.insert(b)
        precondition(inserted.suffix(2) == ["A", "B"], "insert callbacks must not await writes")
        precondition(model.recents.map(\.text) == ["B"])
        writeRelease.signal()
        await writeBlocker.value
        await model.reload().value
        precondition(model.recents.map(\.text) == ["B", "A"] && store.read() == ["B", "A"])
        print("PASS consecutive writes do not block insertion and read-modify-write keeps both records in MRU order")

        allowInsert = false
        let previousData = try Data(contentsOf: directory.appendingPathComponent("recent.json"))
        model.insert(a)
        await model.reload().value
        precondition(feedback.last == false && model.recents.map(\.text) == ["B", "A"])
        let afterRejectedInsert = try Data(contentsOf: directory.appendingPathComponent("recent.json"))
        precondition(afterRejectedInsert == previousData)
        allowInsert = true
        let tooLarge = SymbolItem(
            id: "large", text: String(repeating: "x", count: 17_000), name: "Large", aliases: [], category: "letters")
        model.insert(tooLarge)
        await model.reload().value
        precondition(model.recents.map(\.text) == ["B", "A"] && store.read() == ["B", "A"])
        precondition(model.persistenceNote?.contains("未能保存") == true)
        model.insert(a)
        await model.reload().value
        precondition(model.persistenceNote == nil && model.recents.map(\.text) == ["A", "B"])
        print(
            "PASS rejected inserts never write; failed writes keep prior UI/disk and visible diagnostics until a successful write"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await model.clearRecents().value
        let failedClearKeptState =
            model.recents.map(\.text) == ["A", "B"] && model.persistenceNote?.contains("未能清空最近使用记录") == true
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        precondition(failedClearKeptState, "failed clear must keep visible records and report failure")
        await model.clearRecents().value
        precondition(model.recents.isEmpty && model.persistenceNote == nil && store.read().isEmpty)
        print(
            "PASS real filesystem clear failure keeps old visible state; successful retry clears both disk and warning")

        precondition(store.save(["backup"]) == nil)
        precondition(store.save(["active"]) == nil)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("recent.json"))
        await model.reload().value
        precondition(model.recents.map(\.text) == ["backup"] && model.persistenceNote?.contains("无法读取") == true)
        precondition(store.save(["recovered"]) == nil)
        await model.reload().value
        precondition(model.recents.map(\.text) == ["recovered"] && model.persistenceNote == nil)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        await model.reload().value
        precondition(model.catalog.items.count >= 80 && model.catalogReadError != nil)
        let custom = SymbolCatalog(
            categories: [SymbolCategory(id: "letters", name: "Letters", order: 0)], items: [a, b])
        _ = try SymbolCatalogStore(directory: directory).importCatalog(try custom.encoded())
        await model.reload().value
        precondition(model.catalog == custom && model.catalogReadError == nil && model.query == "jiantou")
        print(
            "PASS corrupt recent/catalog files report read errors, retain fallback data, and successful reloads recover without resetting search"
        )

        let access = AccessProbe()
        let manager = SymbolCatalogManagementModel(
            storeDirectory: directory,
            startAccess: access.start, stopAccess: access.stop)
        precondition(manager.isBusy && manager.itemCount == 0)
        await manager.reload()?.value
        precondition(!manager.isBusy && manager.itemCount == 2 && manager.sourceText == "自定义")
        let imported = SymbolCatalog(categories: custom.categories, items: [a])
        let input = directory.appendingPathComponent("import.json")
        try imported.encoded().write(to: input)
        let importTask = manager.importCatalog(from: input)!
        precondition(manager.isBusy && manager.restoreDefault() == nil && manager.exportCatalog() == nil)
        await waitForSignal(access.entered)
        precondition(access.counts == [1, 0, 1] && manager.itemCount == 2)
        let catalogStore = SymbolCatalogStore(directory: directory)
        precondition(catalogStore.loadActive() == custom, "blocked importer must not have published or written success")
        access.release.signal()
        await importTask.value
        precondition(access.counts == [1, 1, 0])
        precondition(!manager.isBusy && manager.error == nil && manager.itemCount == 1 && manager.sourceText == "自定义")
        precondition(catalogStore.loadActive() == imported)
        print(
            "PASS management initialization is asynchronous; busy gating preserves prior UI while security scope spans the real import"
        )

        await manager.exportCatalog()?.value
        precondition(manager.showingExporter && manager.error == nil)
        let exported = try SymbolCatalog.decode(manager.exportData!)
        precondition(exported == imported)
        manager.showingExporter = false
        try Data(repeating: 0x20, count: 256 * 1024 + 1).write(to: input)
        await manager.importCatalog(from: input)?.value
        precondition(access.counts == [2, 2, 0], "failed imports must close their security scope")
        precondition(
            manager.error?.contains("无法导入") == true && manager.itemCount == 1 && catalogStore.loadActive() == imported)
        precondition(!manager.showingExporter)
        print(
            "PASS export returns accepted catalog bytes; oversized import stays bounded, closes scope, and preserves old catalog/UI"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await manager.restoreDefault()?.value
        let restoreKeptState =
            manager.hasCustomFile && manager.itemCount == 1 && manager.error?.contains("恢复失败") == true
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        precondition(restoreKeptState)
        await manager.restoreDefault()?.value
        precondition(
            !manager.hasCustomFile && manager.sourceText == "默认" && manager.itemCount >= 80 && manager.error == nil)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        await manager.reload()?.value
        precondition(manager.hasCustomFile && manager.sourceText == "默认" && manager.error != nil)
        await manager.exportCatalog()?.value
        precondition(manager.error?.contains("无法导出") == true && !manager.showingExporter)
        precondition(manager.hasCustomFile && manager.sourceText == "默认")
        await manager.restoreDefault()?.value
        precondition(!manager.hasCustomFile && manager.error == nil)
        print(
            "PASS restore failure keeps accepted state; corrupt custom files remain removable but are labelled default and cannot silently export fallback"
        )

        // Without Full Access: inserts stand, the stored recents are shown and never written.
        let shared = directory.appendingPathComponent("read-only", isDirectory: true)
        let sharedRecents = RecentSymbolStore(directory: shared)
        precondition(sharedRecents.save(["X"]) == nil)
        SymbolLibraryStorage.writable = false
        let readOnly = SymbolLibraryModel(storeDirectory: shared, onInsert: { _ in true })
        await readOnly.reload().value
        precondition(readOnly.recents.map(\.text) == ["X"])
        readOnly.insert(a)
        await readOnly.reload().value
        precondition(readOnly.recents.map(\.text) == ["X"] && sharedRecents.read() == ["X"])
        await readOnly.clearRecents().value
        precondition(sharedRecents.read() == ["X"] && readOnly.persistenceNote?.contains("允许完全访问") == true)
        SymbolLibraryStorage.writable = true
        print("PASS without Full Access recents are read from the shared directory and never written")
    }
}
