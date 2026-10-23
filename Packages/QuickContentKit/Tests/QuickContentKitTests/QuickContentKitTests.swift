import XCTest

@testable import QuickContentKit

final class QuickContentKitTests: XCTestCase {
    private var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qck-test-\(UUID().uuidString)")
    }

    // MARK: Catalog coding and default data

    func testBundledDefaultDecodesAndSearches() throws {
        let catalog = try SymbolCatalog.bundledDefault()
        try catalog.validate()
        XCTAssertGreaterThanOrEqual(catalog.items.count, 80)
        // Searching jiantou / pingfangmi finds the arrow / square-metre symbols.
        let jiantou = catalog.search("jiantou")
        XCTAssertFalse(jiantou.isEmpty)
        XCTAssertTrue(jiantou.contains { $0.text == "→" })
        let pingfangmi = catalog.search("pingfangmi")
        XCTAssertFalse(pingfangmi.isEmpty)
        XCTAssertTrue(pingfangmi.contains { $0.text == "㎡" })
        // Search by Chinese name.
        XCTAssertTrue(catalog.search("箭头").contains { $0.text == "→" })
        XCTAssertTrue(catalog.search("平方米").contains { $0.text == "㎡" })
        // The symbol text itself matches.
        XCTAssertTrue(catalog.search("≤").contains { $0.text == "≤" })
        // Case / whitespace / full-width normalization.
        XCTAssertTrue(catalog.search(" JianTou ").contains { $0.text == "→" })
        XCTAssertTrue(catalog.search("ＰＩＮＧＦＡＮＧＭＩ").contains { $0.text == "㎡" })
        // Name prefix outranks alias contains: deterministic ordering.
        let ranked = catalog.search("箭头")
        XCTAssertEqual(ranked.first?.text, "→")
        // Empty query returns no results (the panel shows category browsing).
        XCTAssertTrue(catalog.search("   ").isEmpty)
        // Every item sits in an ordered category; no data is dropped.
        let categoryIDs = Set(catalog.orderedCategories.map(\.id))
        XCTAssertTrue(catalog.items.allSatisfy { categoryIDs.contains($0.category) })
    }

    func testStrictDecodeRejectsUnknownAndInvalid() throws {
        let valid =
            #"{"version":1,"items":[{"id":"x-1","text":"→","name":"右箭头","aliases":["jiantou"],"category":"arrows"}]}"#
        XCTAssertNoThrow(try SymbolCatalog.decode(Data(valid.utf8)))
        // Omitting categories is valid (unknown categories sort last).
        let decoded = try SymbolCatalog.decode(Data(valid.utf8))
        XCTAssertEqual(decoded.orderedCategories.map(\.id), ["arrows"])
        for json in [
            #"{"version":2,"items":[]}"#,
            #"{"version":1,"extra":1,"items":[]}"#,
            #"{"version":1,"items":[{"id":"a b","text":"→","name":"箭头","aliases":[],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"","name":"箭头","aliases":[],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"","aliases":[],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"箭头","aliases":[],"category":""}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"箭头","aliases":[""],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"箭头","aliases":[],"category":"x"},{"id":"a","text":"←","name":"左箭头","aliases":[],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"箭头","aliases":[],"category":"x"},{"id":"b","text":"→","name":"箭头","aliases":[],"category":"x"}]}"#,
            #"{"version":1,"items":[{"id":"a","text":"→","name":"箭头","aliases":[],"category":"x","surprise":1}]}"#,
        ] {
            XCTAssertThrowsError(try SymbolCatalog.decode(Data(json.utf8)), json)
        }
        // Re-encoding and re-importing round-trips.
        let round = try SymbolCatalog.decode(Data(valid.utf8))
        XCTAssertEqual(try SymbolCatalog.decode(try round.encoded()), round)
    }

    // MARK: Catalog store: failed import keeps the old file

    func testImportFailureKeepsOldCatalog() throws {
        let directory = tempDirectory
        let store = SymbolCatalogStore(directory: directory)
        let first =
            #"{"version":1,"categories":[{"id":"c","name":"测试","order":1}],"items":[{"id":"a","text":"→","name":"右箭头","aliases":["jiantou"],"category":"c"}]}"#
        try store.importCatalog(Data(first.utf8))
        XCTAssertEqual(store.loadActive().items.first?.text, "→")
        XCTAssertTrue(store.hasCustomCatalog)
        // Corrupt JSON import throws and keeps the old catalog.
        XCTAssertThrowsError(try store.importCatalog(Data("not json".utf8)))
        XCTAssertThrowsError(
            try store.importCatalog(
                Data(
                    #"{"version":1,"items":[{"id":"a","text":"?","name":"x","aliases":[],"category":"c"}],"oops":0}"#
                        .utf8)))
        XCTAssertEqual(store.loadActive().items.count, 1)
        XCTAssertEqual(store.loadActive().items.first?.text, "→")
        // An export can be re-imported.
        let exported = try store.exportActive()
        XCTAssertNoThrow(try store.importCatalog(exported))
        // After deleting the custom catalog, the bundled default returns.
        try store.removeCustomCatalog()
        XCTAssertFalse(store.hasCustomCatalog)
        XCTAssertGreaterThanOrEqual(store.loadActive().items.count, 80)
    }

    func testCatalogFileImportBudgetPreservesActiveOnOversize() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("input.json")
        let store = SymbolCatalogStore(directory: directory.appendingPathComponent("store"))
        let json = Data(
            #"{"version":1,"items":[{"id":"x","text":"→","name":"箭头","aliases":[],"category":"arrows"}]}"#.utf8)
        var exact = json
        exact.append(Data(repeating: 0x20, count: 256 * 1024 - exact.count))
        try exact.write(to: source)
        XCTAssertEqual(try store.importCatalog(from: source).items.first?.text, "→")
        let active = store.directory.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: active)
        exact.append(0x20)
        try exact.write(to: source)
        XCTAssertThrowsError(try store.importCatalog(from: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("256KB"))
        }
        XCTAssertEqual(try Data(contentsOf: active), before)
        XCTAssertEqual(store.loadActive().items.first?.text, "→")
    }

    func testCorruptCatalogExportReportsFailureInsteadOfFallback() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let active = directory.appendingPathComponent("catalog.json")
        let damaged = Data("broken".utf8)
        try damaged.write(to: active)
        let store = SymbolCatalogStore(directory: directory)
        XCTAssertGreaterThanOrEqual(store.loadActive().items.count, 80)
        XCTAssertThrowsError(try store.exportActive())
        XCTAssertEqual(try Data(contentsOf: active), damaged)
    }

    func testCorruptCustomFallsBackToBundled() throws {
        let directory = tempDirectory
        let store = SymbolCatalogStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        var reported: [Error] = []
        let catalog = store.loadActive { reported.append($0) }
        XCTAssertEqual(reported.count, 1)
        XCTAssertGreaterThanOrEqual(catalog.items.count, 80, "corrupt custom catalog falls back to the bundled default")
    }

    // MARK: Recents: dedupe, ordering, persistence, keep old file on failure

    func testRecentDedupOrderAndPersistence() throws {
        let directory = tempDirectory
        let store = RecentSymbolStore(directory: directory, limit: 3)
        XCTAssertEqual(store.read(), [])
        var result = store.record("→")
        XCTAssertEqual(result.texts, ["→"])
        result = store.record("㎡")
        XCTAssertEqual(result.texts, ["㎡", "→"])
        // The same text is deduped and moved to the front.
        result = store.record("→")
        XCTAssertEqual(result.texts, ["→", "㎡"])
        result = store.record("℃")
        result = store.record("№")
        XCTAssertEqual(result.texts.count, 3, "trimmed to the limit")
        XCTAssertEqual(result.texts, ["№", "℃", "→"])
        // Blank text is not recorded.
        result = store.record("   ")
        XCTAssertEqual(result.texts, ["№", "℃", "→"])
        XCTAssertNil(result.saveError)
        // Persistence: a new instance reads back the same list.
        XCTAssertEqual(RecentSymbolStore(directory: directory).read(), ["№", "℃", "→"])
        // Clear.
        try store.clear()
        XCTAssertEqual(store.read(), [])
        XCTAssertEqual(RecentSymbolStore(directory: directory).read(), [])
    }

    func testRecentClearFailureKeepsCurrentWhenBackupRemovalFails() throws {
        let directory = tempDirectory
        let backup = directory.appendingPathComponent("recent-last.json", isDirectory: true)
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.path)
            try? fm.removeItem(at: directory)
        }
        let store = RecentSymbolStore(directory: directory)
        XCTAssertNil(store.save(["keep"]))
        let active = directory.appendingPathComponent("recent.json")
        let before = try Data(contentsOf: active)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("locked child".utf8).write(to: backup.appendingPathComponent("child"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: backup.path)
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try Data(contentsOf: active), before)
        XCTAssertEqual(store.read(), ["keep"])
    }

    func testRecentClearCommitsEmptyWithoutRetainingRecoverableHistory() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentSymbolStore(directory: directory)
        XCTAssertNil(store.save(["recoverable"]))
        XCTAssertNil(store.save(["damaged next"]))
        let active = directory.appendingPathComponent("recent.json")
        try Data("broken".utf8).write(to: active)
        XCTAssertEqual(store.read(), ["recoverable"])
        try store.clear()
        XCTAssertEqual(store.read(), [])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: active)), [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("recent-last.json").path))
    }

    func testRecentReadReportsCorruptionAndKeepsBackupRecovery() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentSymbolStore(directory: directory)
        var errors: [Error] = []
        XCTAssertEqual(store.read { errors.append($0) }, [])
        XCTAssertTrue(errors.isEmpty, "missing files are an ordinary empty recent list")
        XCTAssertNil(store.save(["old"]))
        XCTAssertNil(store.save(["new"]))
        try Data("broken".utf8).write(to: directory.appendingPathComponent("recent.json"))
        XCTAssertEqual(store.read { errors.append($0) }, ["old"])
        XCTAssertEqual(errors.count, 1, "recovery must still report the corrupt active file")
        try Data(repeating: 0x20, count: 16 * 1024 + 1)
            .write(to: directory.appendingPathComponent("recent-last.json"))
        errors = []
        XCTAssertEqual(store.read { errors.append($0) }, [])
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.last?.localizedDescription.contains("大小限制") == true)
    }

    func testRecentCorruptFallsBackToBackup() throws {
        let directory = tempDirectory
        let store = RecentSymbolStore(directory: directory)
        _ = store.record("→")
        _ = store.record("㎡")  // at this point recent-last.json = ["→"]
        XCTAssertEqual(store.read(), ["㎡", "→"])
        // Corrupt current file: fall back to the backup.
        try Data("broken".utf8).write(to: directory.appendingPathComponent("recent.json"), options: .atomic)
        XCTAssertEqual(store.read(), ["→"])
        // Backup corrupt too: return empty, no crash, no file writes.
        try Data("broken".utf8).write(to: directory.appendingPathComponent("recent-last.json"), options: .atomic)
        XCTAssertEqual(store.read(), [])
        // Writing works again afterwards.
        let result = store.record("≤")
        XCTAssertEqual(result.texts, ["≤"])
        XCTAssertEqual(RecentSymbolStore(directory: directory).read(), ["≤"])
    }

    func testRecentRecoveryPreservesLastValidBackup() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentSymbolStore(directory: directory)
        XCTAssertNil(store.record("→").saveError)
        XCTAssertNil(store.record("㎡").saveError)
        let active = directory.appendingPathComponent("recent.json")
        let backup = directory.appendingPathComponent("recent-last.json")
        let goodBackup = try Data(contentsOf: backup)
        try Data("broken".utf8).write(to: active, options: .atomic)

        XCTAssertNil(store.record("≤").saveError)
        XCTAssertEqual(store.read(), ["≤", "→"])
        XCTAssertEqual(try Data(contentsOf: backup), goodBackup)
        // A second damaged active file can still recover the last known good copy.
        try Data("broken again".utf8).write(to: active, options: .atomic)
        XCTAssertEqual(store.read(), ["→"])
    }

    func testRecentOversizeSavePreservesBothCopies() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentSymbolStore(directory: directory)
        XCTAssertNil(store.record("→").saveError)
        XCTAssertNil(store.record("㎡").saveError)
        let active = directory.appendingPathComponent("recent.json")
        let backup = directory.appendingPathComponent("recent-last.json")
        let previous = try Data(contentsOf: active)
        let previousBackup = try Data(contentsOf: backup)
        // Combining marks can make even one Character larger than the byte budget.
        let oversized = "a" + String(repeating: "\u{0301}", count: 9000)
        XCTAssertEqual(oversized.count, 1)
        XCTAssertNotNil(store.record(oversized).saveError)
        XCTAssertNotNil(store.save(Array(repeating: "→", count: 101)))
        XCTAssertEqual(try Data(contentsOf: active), previous)
        XCTAssertEqual(try Data(contentsOf: backup), previousBackup)
        XCTAssertEqual(store.read(), ["㎡", "→"])
    }

    func testRecentOversizeActiveFallsBackWithoutChangingFiles() throws {
        let directory = tempDirectory
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecentSymbolStore(directory: directory)
        XCTAssertNil(store.record("→").saveError)
        XCTAssertNil(store.record("㎡").saveError)
        let active = directory.appendingPathComponent("recent.json")
        let oversized = Data(repeating: 0x20, count: 32 * 1024)
        try oversized.write(to: active, options: .atomic)
        XCTAssertEqual(store.read(), ["→"])
        XCTAssertEqual(try Data(contentsOf: active), oversized)
    }

    func testRecentSaveFailureKeepsOldFile() throws {
        // Replace the directory with a file to force a write failure; the old file must survive.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("qck-block-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        let store = RecentSymbolStore(directory: blocker)
        let result = store.record("→")
        XCTAssertNotNil(result.saveError, "a write failure must be reported")
        XCTAssertEqual(result.texts, ["→"], "the in-memory expected value is still returned for immediate display")
        try FileManager.default.removeItem(at: blocker)
    }
}
