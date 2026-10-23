import CryptoKit
import XCTest

@testable import PackageManager

/// Direct update of an installed scheme: the store compares the generation the update started from
/// before it writes anything, and the package identity comes from the files themselves.
final class SchemeImportUpdateTests: XCTestCase {
    /// A directory that installs cleanly: one schema, the enabled list and one byte marker that
    /// identifies the version of the content.
    private func sourceDirectory(declarationID: String?, marker: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheme-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try Data("schema:\n  schema_id: main\n  name: 主方案\n".utf8)
            .write(to: root.appendingPathComponent("main.schema.yaml"))
        try Data("schema_list:\n  - schema: main\n".utf8)
            .write(to: root.appendingPathComponent("default.yaml"))
        try Data(marker.utf8).write(to: root.appendingPathComponent("marker.txt"))
        if let declarationID {
            try JSONEncoder().encode(SchemePackageDeclaration(id: declarationID, name: "我的方案", bindings: []))
                .write(to: root.appendingPathComponent("keyboard-package.json"))
        }
        return root
    }

    /// Deploy result consistent with the scheme above: the entry that the enabled list contains.
    private static let deploy: RecipePackageManager.Deploy = { deployment in
        let build = deployment.userDataURL.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: main\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: main}\n".utf8).write(to: build.appendingPathComponent("main.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "main", validatedEnabledSchemaIDs: ["main"])
    }

    private func store() throws -> (URL, RecipePackageManager) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, RecipePackageManager(rootURL: root))
    }

    private func installedMarker(_ manager: RecipePackageManager) async throws -> String {
        let active = try await manager.activeInstallation()
        let installed = try XCTUnwrap(active)
        return String(
            decoding: try Data(contentsOf: installed.resourceURL.appendingPathComponent("marker.txt")), as: UTF8.self)
    }

    func testUpdateCommitsNewContentWhenBaselineMatches() async throws {
        let (_, manager) = try store()
        let first = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "first"))
        let installed = try await manager.installSchemeImport(first, deploy: Self.deploy)
        let firstMarker = try await installedMarker(manager)
        XCTAssertEqual(firstMarker, "first")

        let update = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "second")
        )
        .updatingInstallation(id: "pkg", name: "我的方案")
        let updated = try await manager.installSchemeImport(
            update, expectedGeneration: installed.generation,
            deploy: Self.deploy)
        XCTAssertEqual(updated.id, "pkg")
        XCTAssertNotEqual(updated.revision, installed.revision)
        XCTAssertNotEqual(updated.generation, installed.generation)
        let secondMarker = try await installedMarker(manager)
        XCTAssertEqual(secondMarker, "second")
        let afterUpdate = try await manager.activeInstallation()?.installation.generation
        XCTAssertEqual(afterUpdate, updated.generation)
    }

    func testStaleBaselineIsRefusedAndKeepsTheInstalledVersion() async throws {
        let (_, manager) = try store()
        let first = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "first"))
        let installed = try await manager.installSchemeImport(first, deploy: Self.deploy)
        let second = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "second")
        )
        .updatingInstallation(id: "pkg", name: "我的方案")
        let current = try await manager.installSchemeImport(
            second, expectedGeneration: installed.generation,
            deploy: Self.deploy)
        // An update that started before the version above was installed must be refused.
        let third = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "third")
        )
        .updatingInstallation(id: "pkg", name: "我的方案")
        do {
            _ = try await manager.installSchemeImport(
                third, expectedGeneration: installed.generation, deploy: Self.deploy)
            XCTFail("a stale baseline must not be accepted")
        } catch {
            // The refusal is the store's own comparison, not a generic failure.
            XCTAssertEqual(
                (error as? RecipeInstallError)?.errorDescription,
                "方案文件检查失败：安装期间配置状态已改变，请重试。")
        }
        let afterRefusal = try await manager.activeInstallation()?.installation.generation
        XCTAssertEqual(afterRefusal, current.generation)
        let refusedMarker = try await installedMarker(manager)
        XCTAssertEqual(refusedMarker, "second")
    }

    func testPackageWithAnotherIdentityIsNeverInstalled() async throws {
        let (_, manager) = try store()
        let installed = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try sourceDirectory(declarationID: "pkg", marker: "first")),
            deploy: Self.deploy)
        let foreign = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "another", marker: "foreign"))
        XCTAssertThrowsError(try foreign.updatingInstallation(id: "pkg", name: "我的方案"))
        let afterForeign = try await manager.activeInstallation()?.installation.generation
        XCTAssertEqual(afterForeign, installed.generation)
        let keptMarker = try await installedMarker(manager)
        XCTAssertEqual(keptMarker, "first")
    }

    func testFirstInstallStillWorksWithoutBaseline() async throws {
        let (_, manager) = try store()
        let first = try manager.prepareSchemeImport(
            directory: try sourceDirectory(declarationID: "pkg", marker: "first"))
        let installed = try await manager.installSchemeImport(first, deploy: Self.deploy)
        let afterFirst = try await manager.activeInstallation()?.installation.generation
        XCTAssertEqual(afterFirst, installed.generation)
    }

    /// Why the host can correctly say "already the latest version": reading the same content twice
    /// through the update path yields the same revision, so comparing revisions is enough to tell an
    /// update from a re-download.
    func testUnchangedContentKeepsTheRevision() async throws {
        let (_, manager) = try store()
        let seed = try await manager.installSchemeImport(
            try manager.prepareSchemeImport(directory: try sourceDirectory(declarationID: "pkg", marker: "first")),
            deploy: Self.deploy)
        let directory = try sourceDirectory(declarationID: "pkg", marker: "same")
        let update = try manager.prepareSchemeImport(directory: directory)
            .updatingInstallation(id: "pkg", name: "我的方案")
        let installed = try await manager.installSchemeImport(
            update, expectedGeneration: seed.generation,
            deploy: Self.deploy)
        let repeated = try manager.prepareSchemeImport(directory: directory)
            .updatingInstallation(id: "pkg", name: "我的方案")
        XCTAssertEqual(repeated.manifest.revision, installed.revision)
    }
}
