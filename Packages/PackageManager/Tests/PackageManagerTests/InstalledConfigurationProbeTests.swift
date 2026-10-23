import XCTest

@testable import PackageManager

/// Startup probe of the installed configuration: only a strictly decodable valid receipt counts; leftover files don't skip first-run setup.
final class InstalledConfigurationProbeTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeActive(_ root: URL) throws {
        let active = InstalledRecipe(
            id: "user-scheme-generic", revision: String(repeating: "a", count: 40),
            generation: "g-1", schemaID: "cangjie5", activatedAt: Date())
        try JSONEncoder().encode(active).write(to: root.appendingPathComponent("active.json"))
    }

    func testResidualFilesAndEmptyDirsDoNotCount() async throws {
        let root = try tempRoot()
        try Data("not json".utf8).write(to: root.appendingPathComponent("active.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("staging-x"),
            withIntermediateDirectories: true)

        let residual = await InstalledConfigurationProbe.hasActiveInstallation(inStoreRoot: root)
        XCTAssertFalse(residual, "a bad-JSON leftover must not count as a valid install")

        let empty = try tempRoot()
        let emptyResult = await InstalledConfigurationProbe.hasActiveInstallation(inStoreRoot: empty)
        XCTAssertFalse(emptyResult)
    }

    func testValidActiveInstallationCounts() async throws {
        let root = try tempRoot()
        try writeActive(root)
        let result = await InstalledConfigurationProbe.hasActiveInstallation(inStoreRoot: root)
        XCTAssertTrue(result)
    }

    func testDirectoryStoreOnlyCountsStrictlyDecodedPackages() async throws {
        let root = try tempRoot()
        // A leftover subdirectory (no active.json) doesn't count.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("leftover"),
            withIntermediateDirectories: true)
        // A leftover top-level file doesn't count.
        try Data("log".utf8).write(to: root.appendingPathComponent("install.log"))
        let residual = await InstalledConfigurationProbe.hasAnyActiveInstallation(inPackageStoreRoot: root)
        XCTAssertFalse(residual)

        // A subdirectory with a strictly valid receipt counts.
        let package = root.appendingPathComponent("user-scheme-generic")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeActive(package)
        let found = await InstalledConfigurationProbe.hasAnyActiveInstallation(inPackageStoreRoot: root)
        XCTAssertTrue(found)
    }
}
