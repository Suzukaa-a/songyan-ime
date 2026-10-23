import Foundation
import XCTest

@testable import RimeBridge

final class RimeLearningBackupTests: XCTestCase {
    private func snapshot(
        _ name: String = "proof", user: String = "source",
        body: String = "x \tA\tc=3 d=100 t=0\n"
    ) -> RimeLearningSnapshot {
        RimeLearningSnapshot(
            name: name,
            data: Data(
                ("# Rime user dictionary\n" + "#@/db_name\t\(name)\n#@/db_type\tuserdb\n#@/rime_version\t1.17.0\n"
                    + "#@/tick\t200\n#@/user_id\t\(user)\n" + body).utf8))
    }

    func testParseReadsIdentityAndEntryCount() throws {
        let parsed = try RimeLearningFormat.parse(snapshot(body: "x \tA\tc=3 d=1 t=0\ny \tB\tc=1 d=1 t=0\n"))
        XCTAssertEqual(parsed.name, "proof")
        XCTAssertEqual(parsed.userID, "source")
        XCTAssertEqual(parsed.version, "1.17.0")
        XCTAssertEqual(parsed.entryCount, 2)
        XCTAssertEqual(try RimeLearningFormat.parse(snapshot(body: "")).entryCount, 0)
    }

    func testWrongDictionaryOrMetadataIsRejected() {
        let text = String(decoding: snapshot().data, as: UTF8.self)
        for (from, to) in [
            ("#@/db_name\tproof", "#@/db_name\tother"),
            ("#@/db_type\tuserdb", "#@/db_type\ttabledb"),
            ("#@/user_id\tsource\n", ""),
        ] {
            let changed = RimeLearningSnapshot(
                name: "proof", data: Data(text.replacingOccurrences(of: from, with: to).utf8))
            XCTAssertThrowsError(try RimeLearningFormat.parse(changed)) {
                XCTAssertEqual($0 as? RimeLearningBackupError, .identityMismatch)
            }
        }
        XCTAssertThrowsError(
            try RimeLearningFormat.parse(RimeLearningSnapshot(name: "proof", data: Data("junk\n".utf8))))
    }

    func testSizeAndCountCaps() {
        XCTAssertThrowsError(
            try RimeLearningFormat.parse(
                RimeLearningSnapshot(
                    name: "proof",
                    data: Data(repeating: 65, count: RimeLearningFormat.maximumBytes + 1))))
        XCTAssertThrowsError(try RimeLearningFormat.parseBatch([]))
        XCTAssertThrowsError(try RimeLearningFormat.parseBatch((0..<33).map { snapshot("p\($0)") }))
        let body = "x \t" + String(repeating: "a", count: 3 * 1_024 * 1_024) + "\tc=1 d=1 t=0\n"
        XCTAssertThrowsError(try RimeLearningFormat.parseBatch(["a", "b", "c"].map { snapshot($0, body: body) }))
    }

    func testNamesCannotEscapeOrCollide() {
        for name in ["", ".temp", "../x", "x/y", "x\\y", "x.userdb"] {
            XCTAssertThrowsError(try RimeLearningFormat.validateName(name))
        }
        XCTAssertThrowsError(try RimeLearningFormat.parseBatch([snapshot("proof"), snapshot("PROOF")]))
    }

    func testFailedBackupPutsPreviousSyncSnapshotBack() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RimeLearningSnapshotFiles(directory: directory)
        let target = files.target("proof")
        try Data("old".utf8).write(to: target)

        try files.setAside("proof")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try Data("new".utf8).write(to: target)
        try files.settle("proof", keepNew: false)
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))

        try files.setAside("proof")
        try Data("new".utf8).write(to: target)
        try files.settle("proof", keepNew: true)
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["proof.userdb.txt"])
    }

    func testInterruptedBackupLeftoverIsRecovered() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = RimeLearningSnapshotFiles(directory: directory)
        try Data("old".utf8).write(to: files.target("proof"))
        try files.setAside("proof")
        try Data("partial".utf8).write(to: files.target("proof"))
        // A new run starts without settling the first one.
        try files.setAside("proof")
        try files.settle("proof", keepNew: false)
        XCTAssertEqual(try Data(contentsOf: files.target("proof")), Data("old".utf8))
    }
}
