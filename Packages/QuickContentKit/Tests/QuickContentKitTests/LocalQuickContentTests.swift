import Foundation
import XCTest

@testable import QuickContentKit

final class LocalQuickContentTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testDisabledByDefaultAndDoesNotCreateStorageWhenPasting() throws {
        let url = directory()
        let store = LocalQuickContentStore(directory: url)
        XCTAssertFalse(try store.read().clipboardEnabled)
        XCTAssertFalse(try store.recordExplicitPaste("secret"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExistingDisabledSettingsDoNotCreateLockOrRewriteFile() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bytes = try JSONEncoder().encode(LocalQuickContent())
        let file = url.appendingPathComponent("content.json")
        try bytes.write(to: file)
        let store = LocalQuickContentStore(directory: url)
        XCTAssertFalse(try store.read().clipboardEnabled)
        XCTAssertFalse(try store.recordExplicitPaste("private"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.path), ["content.json"])
    }

    func testBundledKaomojiSearchAndRoundTrip() throws {
        let catalog = try SymbolCatalog.bundledDefault()
        XCTAssertTrue(catalog.search("tanshou").contains { $0.category == "kaomoji" })
        XCTAssertTrue(catalog.search("你好").contains { $0.category == "kaomoji" })
        XCTAssertEqual(try SymbolCatalog.decode(catalog.encoded()), catalog)
    }

    func testHistoryIsBoundedDeduplicatedAndDisableErasesIt() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        try store.setClipboardEnabled(true)
        for index in 0..<25 { XCTAssertTrue(try store.recordExplicitPaste("item-\(index)")) }
        XCTAssertEqual(try store.read().clipboard.count, 20)
        XCTAssertTrue(try store.recordExplicitPaste("item-10"))
        XCTAssertEqual(try store.read().clipboard.first, "item-10")
        XCTAssertEqual(try store.read().clipboard.filter { $0 == "item-10" }.count, 1)
        try store.deleteClipboard("item-10")
        XCTAssertFalse(try store.read().clipboard.contains("item-10"))
        try store.clearClipboard()
        XCTAssertEqual(try store.read().clipboard, [])
        XCTAssertTrue(try store.read().clipboardEnabled)
        try store.recordExplicitPaste("private")
        try store.setClipboardEnabled(false)
        XCTAssertEqual(try store.read().clipboard, [])
        XCTAssertFalse(try store.recordExplicitPaste("later"))
        let bytes = try Data(contentsOf: url.appendingPathComponent("content.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private"))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: url.path).sorted(), [".lock", "content.json"])
    }

    func testPhraseTransferExcludesClipboardAndPreservesOptIn() throws {
        let url = directory(), otherURL = directory()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: otherURL)
        }
        let store = LocalQuickContentStore(directory: url)
        let phrase = CommonPhrase(text: "稍后回复你", shortcut: "sh")
        try store.savePhrase(phrase)
        try store.setClipboardEnabled(true)
        try store.recordExplicitPaste("private-history")
        let data = try store.exportPhrases()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-history"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("clipboard"))
        let other = LocalQuickContentStore(directory: otherURL)
        try other.importPhrases(data)
        XCTAssertEqual(try other.read().phrases, [phrase])
        let source = otherURL.appendingPathComponent("phrases.json")
        try data.write(to: source)
        XCTAssertEqual(try other.importPhrases(from: source).phrases, [phrase])
        try Data(repeating: 0x20, count: LocalQuickContentStore.maximumFileBytes + 1).write(to: source)
        XCTAssertThrowsError(try other.importPhrases(from: source))
        XCTAssertEqual(try other.read().phrases, [phrase])
        XCTAssertFalse(try other.read().clipboardEnabled)
        XCTAssertTrue(phrase.matches("ＳＨ"))
        try store.deletePhrase(phrase.id)
        XCTAssertEqual(try store.read().phrases, [])
    }

    func testLimitsAndCorruptionDoNotOverwriteAcceptedContent() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        try store.setClipboardEnabled(true)
        try store.recordExplicitPaste("kept")
        XCTAssertThrowsError(try store.recordExplicitPaste(String(repeating: "a", count: 4097)))
        XCTAssertFalse(LocalQuickContentStore.canRecord(String(repeating: "a", count: 4097)))
        XCTAssertFalse(LocalQuickContentStore.canRecord(" \n "))
        XCTAssertTrue(LocalQuickContentStore.canRecord("kept"))
        XCTAssertEqual(try store.read().clipboard, ["kept"])
        XCTAssertThrowsError(try store.savePhrase(CommonPhrase(text: "  ")))
        for index in 0..<100 { try store.savePhrase(CommonPhrase(text: "phrase \(index)")) }
        XCTAssertThrowsError(try store.savePhrase(CommonPhrase(text: "overflow")))
        XCTAssertEqual(try store.read().phrases.count, 100)
        let file = url.appendingPathComponent("content.json")
        let damaged = Data("broken".utf8)
        try damaged.write(to: file)
        XCTAssertThrowsError(try store.read())
        XCTAssertThrowsError(try store.recordExplicitPaste("not-saved"))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testDisableWinsAgainstConcurrentInFlightCaptures() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        try store.setClipboardEnabled(true)
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                if index == 10 {
                    try store.setClipboardEnabled(false)
                } else {
                    try store.recordExplicitPaste("concurrent")
                }
            } catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertFalse(try store.read().clipboardEnabled)
        XCTAssertEqual(try store.read().clipboard, [])
    }

    func testMalformedPhraseImportIsActionableAndPreservesContent() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LocalQuickContentStore(directory: url)
        try store.savePhrase(CommonPhrase(text: "kept"))
        XCTAssertThrowsError(try store.importPhrases(Data("broken".utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "文件不完整或格式不正确，请选择松烟导出的常用语文件")
        }
        XCTAssertEqual(try store.read().phrases.first?.text, "kept")
    }

    func testConcurrentWritersPreservePhrases() throws {
        let url = directory()
        defer { try? FileManager.default.removeItem(at: url) }
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            let store = LocalQuickContentStore(directory: url)
            do { _ = try store.savePhrase(CommonPhrase(text: "phrase \(index)")) } catch {
                XCTFail(error.localizedDescription)
            }
        }
        XCTAssertEqual(try LocalQuickContentStore(directory: url).read().phrases.count, 20)
    }
}
