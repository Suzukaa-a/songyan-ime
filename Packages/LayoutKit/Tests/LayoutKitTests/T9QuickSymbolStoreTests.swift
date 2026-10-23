import Foundation
import XCTest

@testable import LayoutKit

final class T9QuickSymbolStoreTests: XCTestCase {
    func testFirstExplicitSameValueSaveCreatesBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9Explicit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = T9QuickSymbolStore(directory: directory)
        XCTAssertEqual(try host.load().symbols, T9QuickSymbolStore.defaultSymbols)
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.fileURL.path))
        let saved = try host.replaceSlot(0, with: "@")
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.fileURL.path))
        let extensionStore = T9QuickSymbolStore(directory: directory)
        XCTAssertEqual(try extensionStore.load(), saved)
        XCTAssertEqual(try extensionStore.replaceSlot(0, with: "@"), saved)
        let unchanged = try extensionStore.replaceSlotResult(0, with: "@")
        XCTAssertFalse(unchanged.didWrite, "a persisted identical slot is a no-op")
        XCTAssertEqual(unchanged.snapshot, saved)
    }

    func testStaleInstancesMergeSlotsIntoTheLatestSharedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9Shared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = T9QuickSymbolStore(directory: directory)
        let extensionStore = T9QuickSymbolStore(directory: directory)
        _ = try extensionStore.replaceSlot(0, with: "#")
        _ = try host.replaceSlot(1, with: "_")
        XCTAssertEqual(
            try extensionStore.load().symbols, "#_？！、…",
            "edit the latest shared snapshot, not the stale displayed string")
    }

    func testCorruptCanonicalDataIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9Invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = T9QuickSymbolStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let damaged = Data("{broken-user-data".utf8)
        try damaged.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.replaceSlot(0, with: "!"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), damaged)
    }

    func testFirstExplicitDefaultPersistsButRepeatingItDoesNotWriteAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9DefaultWrite-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = T9QuickSymbolStore(directory: directory)
        let symbol = String(T9QuickSymbolStore.defaultSymbols.first!)
        let first = try store.replaceSlotResult(0, with: symbol)
        XCTAssertTrue(first.didWrite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
        let second = try store.replaceSlotResult(0, with: symbol)
        XCTAssertFalse(second.didWrite)
        XCTAssertEqual(second.snapshot.revision, first.snapshot.revision)
    }

    func testWholeListDefaultPersistsOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9WholeDefault-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = T9QuickSymbolStore(directory: directory)
        _ = try store.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        let first = try store.replaceSymbolsResult(T9QuickSymbolStore.defaultSymbols)
        XCTAssertTrue(first.didWrite)
        let bytes = try Data(contentsOf: store.fileURL)
        let second = try store.replaceSymbolsResult(T9QuickSymbolStore.defaultSymbols)
        XCTAssertFalse(second.didWrite)
        XCTAssertEqual(second.snapshot, first.snapshot)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(try store.load(), first.snapshot)
    }

    func testWholeListRejectsDuplicateInvalidAndOverBudgetEditsWithoutChangingBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9WholeInvalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = T9QuickSymbolStore(directory: directory)
        let saved = try store.replaceSymbolsResult("!?[]{}")
        let bytes = try Data(contentsOf: store.fileURL)
        for symbols in ["", "AA", "A B", "A\nB", "\u{0}", "abcdefghijklm"] {
            XCTAssertThrowsError(try store.replaceSymbolsResult(symbols))
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
            XCTAssertEqual(try store.load(), saved.snapshot)
        }
        XCTAssertTrue(try store.replaceSymbolsResult("👍🏽!?").didWrite)
        XCTAssertEqual(try store.load().symbols.count, 3, "validation counts grapheme characters, not scalars")
        XCTAssertTrue(try store.replaceSymbolsResult("abcdefghijkl").didWrite)
    }

    func testWholeListExplicitlyReplacesLatestValueAndShortListStaysShort() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9WholeLatest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = T9QuickSymbolStore(directory: directory)
        let keyboard = T9QuickSymbolStore(directory: directory)
        _ = try host.load()
        _ = try keyboard.replaceSlot(0, with: "#")
        let edited = try host.replaceSymbolsResult("[]{}")
        XCTAssertEqual(try keyboard.load(), edited.snapshot)
        XCTAssertEqual(try keyboard.replaceSlot(0, with: "(").symbols, "(]{}")
        let short = try host.replaceSymbolsResult("!")
        XCTAssertEqual(short.snapshot.symbols, "!", "display fallback must never expand the saved list")
        let restored = try host.replaceSymbolsResult(T9QuickSymbolStore.defaultSymbols)
        XCTAssertTrue(restored.didWrite)
        XCTAssertNotEqual(restored.snapshot.revision, short.snapshot.revision)
        XCTAssertEqual(try keyboard.load(), restored.snapshot)
    }

    func testWholeListCannotReplaceCorruptCanonicalData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("T9WholeCorrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = T9QuickSymbolStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("{corrupt-user-data".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.replaceSymbolsResult("!?"))
        XCTAssertThrowsError(try store.replaceSymbolsResult(T9QuickSymbolStore.defaultSymbols))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testQuickSymbolSelectionRequiresLeavingInitialPopupCell() {
        var intent = ExplicitAlternateSelection()
        intent.begin(x: 20, y: 200, overlappingItem: 8)
        XCTAssertNil(
            intent.selection(x: 20, y: 200, hitItem: 8), "popup appearing under a stationary finger is not selection")
        XCTAssertNil(intent.selection(x: 24, y: 204, hitItem: 9), "small jitter cannot authorize preference writes")
        XCTAssertFalse(intent.hasDepartedInitialRegion, "auto-scroll must remain disarmed")
        XCTAssertNil(
            intent.selection(x: 40, y: 200, hitItem: 8),
            "movement inside the initially covered cell is not entering a choice")
        XCTAssertEqual(intent.selection(x: 65, y: 200, hitItem: 9), 9)
        XCTAssertTrue(intent.hasDepartedInitialRegion)
        XCTAssertEqual(
            intent.selection(x: 20, y: 200, hitItem: 8), 8,
            "the initial cell can be chosen after explicitly leaving and returning")
        XCTAssertNil(intent.selection(x: 200, y: 500, hitItem: nil), "release outside cancels")
        intent.begin(x: 20, y: 200, overlappingItem: nil)
        XCTAssertNil(
            intent.selection(x: 20, y: 200, hitItem: 3), "even a moved popup cannot select without finger movement")
        XCTAssertEqual(intent.selection(x: 50, y: 160, hitItem: 3), 3)
    }
}
