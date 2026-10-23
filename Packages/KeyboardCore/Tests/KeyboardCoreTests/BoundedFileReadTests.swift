import XCTest

@testable import KeyboardCore

final class BoundedFileReadTests: XCTestCase {

    private func temporaryFile() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bounded-\(UUID().uuidString).json")
    }

    func testRejectsOversizedFileWithoutLoadingIt() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // Sparse file: no real allocation.
        try handle.truncate(atOffset: UInt64(BoundedFileRead.maximumBytes + 4096))
        try handle.close()
        guard case .failure(.tooLarge(let observed)) = BoundedFileRead.read(url) else {
            return XCTFail("an over-limit file must be rejected")
        }
        XCTAssertGreaterThan(observed, BoundedFileRead.maximumBytes)
    }

    func testReadsContentWithinLimit() throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data(#"{"ok":true}"#.utf8)
        try payload.write(to: url)
        XCTAssertEqual(BoundedFileRead.read(url), .success(payload))
    }

    func testMissingFileIsMissing() {
        XCTAssertEqual(BoundedFileRead.read(try! temporaryFile()), .failure(.missing))
    }

    func testLimitIsInclusive() throws {
        let limit = 8
        let tooBig = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: tooBig) }
        try Data(repeating: 0x41, count: limit + 1).write(to: tooBig)
        XCTAssertEqual(BoundedFileRead.read(tooBig, maximumBytes: limit), .failure(.tooLarge(limit + 1)))

        let exact = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: exact) }
        try Data(repeating: 0x41, count: limit).write(to: exact)
        guard case .success(let data) = BoundedFileRead.read(exact, maximumBytes: limit) else {
            return XCTFail("equal to the limit should be accepted")
        }
        XCTAssertEqual(data.count, limit)
    }
}
