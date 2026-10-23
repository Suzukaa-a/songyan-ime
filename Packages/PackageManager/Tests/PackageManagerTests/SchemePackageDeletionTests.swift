import XCTest
import os

@testable import PackageManager

/// Behavior of the ordered delete (prune, rename into trash, delete) and of launch-time trash cleanup.
final class SchemePackageDeletionTests: XCTestCase {

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("scheme-deletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var storeRoot: URL { base.appendingPathComponent("SchemePackages", isDirectory: true) }
    private var layout: SchemePackageDeletion.Layout {
        SchemePackageDeletion.Layout(
            storeRoot: storeRoot,
            trashRoot: base.appendingPathComponent("SchemePackageTrash", isDirectory: true))
    }

    struct Boom: Error {}

    @discardableResult
    private func makePackage(_ id: String, in root: URL? = nil) throws -> URL {
        let directory = (root ?? storeRoot).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("versions/v1", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("versions/v1/resources.bin"))
        return directory
    }

    private func trashEntries() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: layout.trashRoot.path)) ?? []
    }

    func testFailureCopyHidesPathsAndKeepsNothingChangedWording() {
        let path = "/private/var/mobile/Containers/Shared/AppGroup/secret/SchemePackageTrash"
        let failures: [SchemePackageDeletion.Failure] = [
            .invalidTarget(path), .trashUnavailable(path), .moveFailed(path),
        ]
        for failure in failures {
            XCTAssertFalse(failure.userFacingDescription.contains(path))
        }
        XCTAssertEqual(SchemePackageDeletion.Failure.invalidTarget(path).failureState, .nothingCommitted)
        XCTAssertEqual(SchemePackageDeletion.Failure.trashUnavailable(path).failureState, .nothingCommitted)
        XCTAssertEqual(SchemePackageDeletion.Failure.moveFailed(path).failureState, .unknown)
        XCTAssertTrue(SchemePackageDeletion.Failure.invalidTarget(path).userFacingDescription.contains("未作任何更改"))
        XCTAssertTrue(SchemePackageDeletion.Failure.trashUnavailable(path).userFacingDescription.contains("未作任何更改"))
    }

    func testDeleteRemovesOnlyTheExactPackageAfterPrune() async throws {
        let target = try makePackage("wubi")
        let untouched = try makePackage("cangjie")
        let pruned = OSAllocatedUnfairLock(initialState: false)
        let outcome = try await SchemePackageDeletion.delete(packageID: "wubi", layout: layout) {
            // Ordering: the package must still exist when the published state is pruned.
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            pruned.withLock { $0 = true }
        }
        XCTAssertTrue(pruned.withLock { $0 })
        XCTAssertNil(outcome.leftoverTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.path))
        XCTAssertTrue(trashEntries().isEmpty)
    }

    func testPruneFailureLeavesPackageInPlace() async throws {
        let target = try makePackage("wubi")
        do {
            _ = try await SchemePackageDeletion.delete(packageID: "wubi", layout: layout) { throw Boom() }
            XCTFail("expected the prune error to propagate")
        } catch is Boom {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(trashEntries().isEmpty)
    }

    func testRejectsEscapesSymlinksAndMissingTargets() async throws {
        let outside = try makePackage("outside", in: base)
        try FileManager.default.createSymbolicLink(
            at: storeRoot.appendingPathComponent("link"),
            withDestinationURL: outside)
        try Data("x".utf8).write(to: storeRoot.appendingPathComponent("plainfile"))
        for id in ["../outside", "link", "plainfile", "missing", ""] {
            let pruned = OSAllocatedUnfairLock(initialState: false)
            do {
                _ = try await SchemePackageDeletion.delete(packageID: id, layout: layout) {
                    pruned.withLock { $0 = true }
                }
                XCTFail("\(id) should be rejected")
            } catch is SchemePackageDeletion.Failure {}
            XCTAssertFalse(pruned.withLock { $0 }, "prune must not run for an invalid target: \(id)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testPurgeRemovesLeftoverTrashAndNothingElse() throws {
        // Simulates a kill after the rename: a trash entry remains, the published package stays installed.
        let kept = try makePackage("cangjie")
        try makePackage("wubi-\(UUID().uuidString)", in: layout.trashRoot)
        try makePackage("pinyin-\(UUID().uuidString)", in: layout.trashRoot)
        XCTAssertEqual(trashEntries().count, 2)

        XCTAssertTrue(SchemePackageDeletion.purgeTrash(layout: layout).isEmpty)
        XCTAssertTrue(trashEntries().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    func testPurgeWithoutTrashRootIsANoOp() {
        XCTAssertTrue(SchemePackageDeletion.purgeTrash(layout: layout).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.trashRoot.path))
    }
}
