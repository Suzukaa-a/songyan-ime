import Foundation
import XCTest

@testable import LayoutKit

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

final class T9QuickSymbolBudgetTests: XCTestCase {
    private func withStore(_ body: (T9QuickSymbolStore, URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".scratch/review-ui/t9-budget-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(T9QuickSymbolStore(directory: directory), directory)
    }

    func testCombiningCharacterAndEncodedBudgetsPreserveSavedValue() throws {
        try withStore { store, _ in
            let saved = try store.replaceSymbolsResult("👍🏽!?").snapshot
            let before = try Data(contentsOf: store.fileURL)
            let oversized = "a" + String(repeating: "\u{0301}", count: 9000)
            XCTAssertEqual(oversized.count, 1)
            XCTAssertFalse(T9QuickSymbolStore.isValid(oversized))
            XCTAssertThrowsError(try store.replaceSymbolsResult(oversized))
            XCTAssertThrowsError(try store.replaceSlot(0, with: oversized))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
            XCTAssertEqual(try store.load(), saved)

            // The symbol fits its byte limit, but the JSON envelope pushes it over.
            let nearLimit = "a" + String(repeating: "\u{0301}", count: 8191)
            XCTAssertTrue(T9QuickSymbolStore.isValid(nearLimit))
            XCTAssertThrowsError(try store.replaceSymbolsResult(nearLimit))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
            let withinBudget = "a" + String(repeating: "\u{0301}", count: 8000)
            XCTAssertTrue(try store.replaceSymbolsResult(withinBudget).didWrite)
            XCTAssertLessThanOrEqual(try Data(contentsOf: store.fileURL).count, T9QuickSymbolStore.maximumFileBytes)
            XCTAssertEqual(try store.load().symbols, withinBudget)
        }
    }

    func testOversizeCanonicalCannotBeReadOrSilentlyReplaced() throws {
        try withStore { store, _ in
            var padded = try JSONEncoder().encode(T9QuickSymbolStore.Snapshot(symbols: "!?"))
            padded.append(Data(repeating: 0x20, count: T9QuickSymbolStore.maximumFileBytes + 1 - padded.count))
            try padded.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.replaceSymbolsResult("#"))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), padded)
        }
    }

    func testCanonicalRejectsNonRegularFiles() throws {
        try withStore { store, directory in
            XCTAssertEqual(mkfifo(store.fileURL.path, S_IRUSR | S_IWUSR), 0)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.replaceSymbolsResult("#"))
        }
        try withStore { store, directory in
            let lock = directory.appendingPathComponent("t9-quick-symbols.lock")
            XCTAssertEqual(mkfifo(lock.path, S_IRUSR | S_IWUSR), 0)
            XCTAssertThrowsError(try store.replaceSymbolsResult("#"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }
}
