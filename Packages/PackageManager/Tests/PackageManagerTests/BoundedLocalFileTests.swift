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
}
