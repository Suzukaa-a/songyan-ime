import XCTest

@testable import PackageManager

final class SourceUpdateIdentityTests: XCTestCase {
    func testUpdatingImplicitPackageKeepsInstallationIdentityAndRebuildsRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("schema:\n  schema_id: sample\n  name: Sample\n".utf8)
            .write(to: root.appendingPathComponent("sample.schema.yaml"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let imported = try manager.prepareSchemeImport(directory: root)
        let update = try imported.updatingInstallation(id: "existing-package", name: "My Scheme")
        XCTAssertEqual(update.declaration.id, "existing-package")
        XCTAssertEqual(update.manifest.id, "existing-package")
        XCTAssertEqual(update.sourceFiles, imported.sourceFiles)
        XCTAssertNotEqual(update.manifest.revision, imported.manifest.revision)
        XCTAssertNotEqual(
            update.manifest.files.first { $0.path == "keyboard-package.json" }?.sha256,
            imported.manifest.files.first { $0.path == "keyboard-package.json" }?.sha256)
    }

    func testUpdatingDifferentExplicitPackageIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("schema:\n  schema_id: sample\n".utf8)
            .write(to: root.appendingPathComponent("sample.schema.yaml"))
        let declaration = SchemePackageDeclaration(id: "another-package", name: "Another", bindings: [])
        try JSONEncoder().encode(declaration).write(to: root.appendingPathComponent("keyboard-package.json"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let imported = try manager.prepareSchemeImport(directory: root)
        XCTAssertThrowsError(try imported.updatingInstallation(id: "existing-package", name: "Existing"))
    }
}
