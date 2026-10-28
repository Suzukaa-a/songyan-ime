import Darwin
import XCTest

@testable import PackageManager

final class BoundedLocalFileTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-local-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testExactBudgetAndEmptyFile() throws {
        let file = try directory().appendingPathComponent("source")
        try Data([0, 1, 255, 3]).write(to: file)
        XCTAssertEqual(try BoundedLocalFile.read(file, maximumBytes: 4), Data([0, 1, 255, 3]))
        XCTAssertThrowsError(try BoundedLocalFile.read(file, maximumBytes: 3))
        try Data().write(to: file)
        XCTAssertEqual(try BoundedLocalFile.read(file, maximumBytes: 0), Data())
    }

    func testDirectoryAndFIFORejectedWithoutBlocking() throws {
        let root = try directory()
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        for url in [root, fifo] {
            XCTAssertThrowsError(try BoundedLocalFile.read(url, maximumBytes: 64))
        }
    }

    func testSchemeAndDictionaryRejectOversizedSparseInputs() async throws {
        let root = try directory(), file = root.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let writer = try FileHandle(forWritingTo: file)
        try writer.truncate(atOffset: UInt64(RecipeResourceBudget.sourceFile + 1))
        try writer.close()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        XCTAssertThrowsError(try manager.prepareSchemeImport(files: [.init(path: "main.schema.yaml", location: file)]))
        do {
            _ = try await manager.inspectDictionary(.init(path: "main.dict.yaml", location: file))
            XCTFail("oversized dictionary accepted")
        } catch {}
    }

    static func sharesBlocks(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let key = URLResourceKey.fileContentIdentifierKey
        let left = try lhs.resourceValues(forKeys: [key]).fileContentIdentifier
        let right = try rhs.resourceValues(forKeys: [key]).fileContentIdentifier
        return left != nil && left == right
    }

    static func requireCloning(_ url: URL) throws {
        let supported = try url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]).volumeSupportsFileCloning
        if supported != true { throw XCTSkip("volume cannot clone files") }
    }

    func testCopyClonesWithOwnerOnlyModeAndNeverReplaces() throws {
        let root = try directory()
        try Self.requireCloning(root)
        let source = root.appendingPathComponent("model.gram")
        let bytes = Data((0..<(3 * RecipeResourceBudget.bufferBytes + 7)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: source)
        let target = root.appendingPathComponent("copy.gram")
        try BoundedLocalFile(source, maximumBytes: bytes.count).copy(to: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertTrue(try Self.sharesBlocks(source, target), "same-volume copies must clone, not rewrite")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value & 0o777, 0o600)
        try Data("kept".utf8).write(to: target)
        XCTAssertThrowsError(try BoundedLocalFile(source, maximumBytes: bytes.count).copy(to: target))
        XCTAssertEqual(try Data(contentsOf: target), Data("kept".utf8))
        XCTAssertThrowsError(try BoundedLocalFile(source, maximumBytes: bytes.count - 1))
    }

    func testCloneRejectsFileGrownPastBudgetAfterOpen() throws {
        let root = try directory()
        try Self.requireCloning(root)
        let source = root.appendingPathComponent("model.gram")
        try Data(count: 8).write(to: source)
        let file = try BoundedLocalFile(source, maximumBytes: 8)
        let writer = try FileHandle(forWritingTo: source)
        try writer.truncate(atOffset: 64)
        try writer.close()
        let target = root.appendingPathComponent("copy.gram")
        XCTAssertThrowsError(try file.copy(to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
