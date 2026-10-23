import XCTest

@testable import PackageManager

/// The ordinary-resource identity is frozen at acquisition from the exact bytes
/// (background, same execution as the bounded read), so Host plan fingerprints and
/// install-time re-checks only compare small identities. These tests pin the semantics
/// that make the install refusal correct:
/// - byte-identical content ⇒ identical identity (an unchanged plan stays valid);
/// - replacement content ⇒ different identity (a plan recorded against the old
///   identity must fail the install fingerprint comparison);
/// - the identity always derives from the bytes actually read — there is no
///   path-keyed cache that could keep a stale plan valid after content changed.
final class ProvidedOrdinaryResourceTests: XCTestCase {
    /// The Host PlanInputs fingerprint fields (path + sha256 + size) derived from a
    /// captured resource; the install-time recheck rebuilds these and compares.
    private struct Fingerprint: Equatable {
        let path: String, sha256: String, size: Int
        init(path: String, resource: ProvidedOrdinaryResource) {
            self.path = path
            self.sha256 = resource.sha256
            self.size = resource.size
        }
    }

    func testIdentityFollowsBytesNotAcquisition() {
        let first = ProvidedOrdinaryResource.capturing(Data("same".utf8))
        let reacquired = ProvidedOrdinaryResource.capturing(Data("same".utf8))
        XCTAssertEqual(
            first, reacquired, "byte-identical acquisitions share one identity: an unchanged plan stays valid")
        let replacement = ProvidedOrdinaryResource.capturing(Data("other".utf8))
        XCTAssertNotEqual(first, replacement, "replacement bytes change the identity: the stale plan must be refused")
        XCTAssertEqual(first.sha256.count, 64, "lowercase hex SHA256, same format as RecipeFileResource")
        XCTAssertEqual(first.size, 4)
        XCTAssertEqual(
            first.data, Data("same".utf8), "plan bytes are the same immutable capture the identity was fixed from")
    }

    func testReplacementChangesHostFingerprint() {
        // Simulates the Host comparison (PlanInputs.resources): the plan recorded the
        // identity at acquisition; the install click re-collects identities of the
        // CURRENT resources and compares as a whole set.
        func currentIdentities(_ resources: [String: ProvidedOrdinaryResource]) -> [Fingerprint] {
            resources.map { Fingerprint(path: $0.key, resource: $0.value) }.sorted { $0.path < $1.path }
        }
        var provided: [String: ProvidedOrdinaryResource] = [
            "notes.txt": .capturing(Data("v1".utf8)),
            "dict.yaml": .capturing(Data("dict".utf8)),
        ]
        let planned = currentIdentities(provided)
        XCTAssertEqual(planned, currentIdentities(provided), "unchanged resources keep the plan current")
        // Replacement with different bytes for the SAME path invalidates.
        provided["notes.txt"] = .capturing(Data("v2".utf8))
        XCTAssertNotEqual(planned, currentIdentities(provided), "replaced resource must invalidate the plan inputs")
        // Replacement with byte-identical content keeps the identity — correct, because
        // the plan's bytes are still exactly what the plan was built from.
        provided["notes.txt"] = .capturing(Data("v2".utf8))
        XCTAssertNotEqual(planned, currentIdentities(provided))
        provided["notes.txt"] = .capturing(Data("v1".utf8))
        XCTAssertEqual(planned, currentIdentities(provided), "identity is byte-equality, not a path-keyed cache")
        // Removal invalidates (identity set shrinks).
        provided["dict.yaml"] = nil
        XCTAssertNotEqual(planned, currentIdentities(provided), "removed resource must invalidate the plan inputs")
    }

    func testLocalAcquisitionIdentityDerivesFromActualBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provided-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("one".utf8).write(to: file)
        let captured = try RecipePackageManager.readLocalOrdinaryResource(file, maximumBytes: 1024)
        XCTAssertEqual(captured, .capturing(Data("one".utf8)), "identity fixed from the exact bounded-read bytes")
        // The underlying file's content changing changes the NEXT acquisition's identity:
        // no stale cached hash can keep an old plan valid against new content.
        try Data("two".utf8).write(to: file)
        let recaptured = try RecipePackageManager.readLocalOrdinaryResource(file, maximumBytes: 1024)
        XCTAssertNotEqual(captured, recaptured)
        XCTAssertEqual(recaptured.data, Data("two".utf8))
        XCTAssertEqual(recaptured.sha256, ProvidedOrdinaryResource.capturing(Data("two".utf8)).sha256)
    }

    func testLocalAcquisitionKeepsChunkedBudgetEnforcement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "provided-resource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.yaml")
        try Data(count: 2048).write(to: file)
        XCTAssertThrowsError(
            try RecipePackageManager.readLocalOrdinaryResource(file, maximumBytes: 2047),
            "the bounded chunked read (cap+1 growth probe) still rejects over-budget files")
        let accepted = try RecipePackageManager.readLocalOrdinaryResource(file, maximumBytes: 2048)
        XCTAssertEqual(accepted.size, 2048)
        XCTAssertEqual(accepted, .capturing(Data(count: 2048)))
    }
}
