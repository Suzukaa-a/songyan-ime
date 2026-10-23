import Foundation
import XCTest

@testable import QuickContentKit

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class QuickContentFileReaderTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A writer eventually releases a regressed blocking read, so a failure is
    /// reported by XCTest instead of leaving the test process stuck forever.
    private func fifo(_ url: URL, rescueData: Data) throws {
        guard mkfifo(url.path, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let descriptor = open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            rescueData.withUnsafeBytes { bytes in
                _ = write(descriptor, bytes.baseAddress, bytes.count)
            }
        }
    }

    func testCatalogRejectsFIFOAndDirectoryImportsWithoutChangingActive() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SymbolCatalogStore(directory: directory.appendingPathComponent("store"))
        let catalog = Data(
            #"{"version":1,"items":[{"id":"x","text":"→","name":"Arrow","aliases":[],"category":"arrows"}]}"#.utf8)
        try store.importCatalog(catalog)
        let active = store.directory.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: active)
        let pipe = directory.appendingPathComponent("pipe.json")
        try fifo(pipe, rescueData: catalog)
        for source in [pipe, directory] {
            XCTAssertThrowsError(try store.importCatalog(from: source))
            XCTAssertEqual(try Data(contentsOf: active), before)
            XCTAssertEqual(store.loadActive().items.first?.text, "→")
        }
    }

    func testRecentRejectsNonRegularActiveAndPreservesValidBackupOnSave() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = directory.appendingPathComponent("recent-last.json")
        let backupData = Data(#"["last valid"]"#.utf8)
        try backupData.write(to: backup)
        let active = directory.appendingPathComponent("recent.json")
        try fifo(active, rescueData: Data(#"["untrusted"]"#.utf8))
        let store = RecentSymbolStore(directory: directory)
        var errors: [Error] = []
        XCTAssertEqual(store.read { errors.append($0) }, ["last valid"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertNil(store.save(["new"]))
        XCTAssertEqual(store.read(), ["new"])
        XCTAssertEqual(try Data(contentsOf: backup), backupData)
    }

    func testRegularReadsHonorExactBudgetAndOversizePreservesBackup() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input")
        let exact = Data(repeating: 0x20, count: 16 * 1024)
        try exact.write(to: file)
        XCTAssertEqual(try QuickContentFileReader.read(file, maximumBytes: exact.count, sizeError: "too large"), exact)
        try (exact + Data([0x20])).write(to: file)
        XCTAssertThrowsError(try QuickContentFileReader.read(file, maximumBytes: exact.count, sizeError: "too large"))
        let backup = directory.appendingPathComponent("recent-last.json")
        let backupData = Data(#"["last valid"]"#.utf8)
        try backupData.write(to: backup)
        let active = directory.appendingPathComponent("recent.json")
        try (exact + Data([0x20])).write(to: active)
        let store = RecentSymbolStore(directory: directory)
        XCTAssertEqual(store.read(), ["last valid"])
        XCTAssertNil(store.save(["new"]))
        XCTAssertEqual(try Data(contentsOf: backup), backupData)
        XCTAssertEqual(store.read(), ["new"])
    }
}
