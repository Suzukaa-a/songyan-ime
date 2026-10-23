import XCTest
import os

@testable import KeyboardCore

/// `DiskLogWriter`: disk log writes must be asynchronous, serial and non-blocking for the caller.
final class DiskLogWriterTests: XCTestCase {

    func testAppendDoesNotBlockCallerAndWritesOnBackgroundQueue() {
        let done = expectation(description: "written")
        let seen = OSAllocatedUnfairLock(initialState: (onMainThread: Bool?.none, received: [String]()))
        let writer = DiskLogWriter(label: "test.disklog") { line, _ in
            let onMainThread = Thread.isMainThread
            seen.withLock {
                $0.onMainThread = onMainThread
                $0.received.append(line)
            }
            done.fulfill()
        }
        let url = URL(fileURLWithPath: "/tmp/ignored.log")
        writer.append("hello", to: url)
        // append returns immediately: nothing has been written yet on this (main) thread.
        wait(for: [done], timeout: 5)
        XCTAssertEqual(seen.withLock { $0.onMainThread }, false, "the actual write must not happen on the main thread")
        XCTAssertEqual(seen.withLock { $0.received }, ["hello"])
    }

    /// The serial queue guarantees write order == call order.
    func testAppendPreservesOrder() {
        let all = expectation(description: "all")
        all.expectedFulfillmentCount = 50
        let received = OSAllocatedUnfairLock(initialState: [Int]())
        let writer = DiskLogWriter(label: "test.disklog.order") { line, _ in
            received.withLock { $0.append(Int(line)!) }
            all.fulfill()
        }
        let url = URL(fileURLWithPath: "/tmp/ignored.log")
        for i in 0..<50 { writer.append(String(i), to: url) }
        wait(for: [all], timeout: 10)
        XCTAssertEqual(received.withLock { $0 }, Array(0..<50), "the serial queue must preserve order")
    }

    /// A nil URL schedules no writes.
    func testNilURLWritesNothing() {
        let notCalled = expectation(description: "no write")
        notCalled.isInverted = true
        let writer = DiskLogWriter(label: "test.disklog.nil") { _, _ in notCalled.fulfill() }
        writer.append("x", to: nil)
        wait(for: [notCalled], timeout: 0.3)
    }

    /// The default sink really writes to disk and can be read back (uses a temp file).
    func testDefaultSinkWritesToDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disklog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.log")

        let written = expectation(description: "written")
        // Wrap the default sink to learn when it completes.
        let writer = DiskLogWriter(label: "test.disklog.disk") { line, target in
            DiskLogWriter.defaultSink(line, target)
            written.fulfill()
        }
        writer.append("line-1", to: url)
        wait(for: [written], timeout: 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "line-1\n")
    }

    func testDefaultSinkRotatesAndClearsWithoutBackingUpDiagnostics() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disklog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recipe-install.log")
        let previous = url.appendingPathExtension("previous")
        let writer = DiskLogWriter(label: "test.disklog.rotation")
        for index in 0..<135 {
            writer.append("\(index):" + String(repeating: "x", count: 4095), to: url)
        }
        let recent = await writer.tail(url)
        XCTAssertTrue(recent?.contains("134:") == true)
        for file in [url, previous] {
            let properties = try file.resourceValues(forKeys: [.fileSizeKey, .isExcludedFromBackupKey])
            XCTAssertLessThanOrEqual(properties.fileSize ?? .max, DiskLogWriter.maximumLogBytes)
            XCTAssertEqual(properties.isExcludedFromBackup, true)
        }
        let cleared = await writer.clear(url)
        XCTAssertTrue(cleared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testOversizedLogIsNotKeptAsRotatedBackup() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("disklog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recipe-install.log")
        try Data(repeating: 0x78, count: DiskLogWriter.maximumLogBytes + 1).write(to: url)
        let writer = DiskLogWriter(label: "test.disklog.oversized")
        writer.append("new entry", to: url)
        let recent = await writer.tail(url)
        XCTAssertEqual(recent, "new entry\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("previous").path))
    }
}
