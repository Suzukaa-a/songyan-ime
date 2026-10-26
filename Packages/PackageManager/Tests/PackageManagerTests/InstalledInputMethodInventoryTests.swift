import KeyboardCore
import XCTest

@testable import PackageManager

/// The inventory decides which page pairings still have a provider, so every incomplete read
/// must come back nil (keep everything) rather than as a smaller set.
final class InstalledInputMethodInventoryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("input-method-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("broken").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func inventory() -> Set<String>? {
        InstalledInputMethodInventory.declaredInputMethods(storeRoot: root)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func writeSchemaFile(_ id: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("schema".utf8).write(
            to: directory.appendingPathComponent(id + InstalledPackageLayout.schemaFileSuffix))
    }

    private func generation(_ packageID: String, _ name: String = "gen-1") -> URL {
        root.appendingPathComponent(packageID, isDirectory: true)
            .appendingPathComponent(InstalledPackageLayout.versionsDirectory, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func resources(_ packageID: String, _ name: String = "gen-1") -> URL {
        generation(packageID, name).appendingPathComponent(InstalledPackageLayout.resourcesDirectory)
    }

    private func writeMarker(_ packageID: String, generation: String = "gen-1", schemaID: String) throws {
        try write(
            ["id": packageID, "revision": "r1", "generation": generation, "schemaID": schemaID],
            to: root.appendingPathComponent(packageID).appendingPathComponent(InstalledPackageLayout.activeMarker))
    }

    private func descriptor(_ id: String) -> KeyboardSchemaDescriptor {
        KeyboardSchemaDescriptor(id: id, name: id, alphabet: "")
    }

    // MARK: Complete installs

    func testMissingStoreRootDeclaresOnlyBuiltInSchemes() {
        try? FileManager.default.removeItem(at: root)
        XCTAssertEqual(inventory(), Set(BuiltinTemplateSchemas.sourceSchemaIDs))
    }

    func testCompleteInstallDeclaresEnabledAndSourceOnlyMethods() throws {
        try writeSchemaFile("default_X", in: resources("full"))
        try write(
            [descriptor("default_X"), descriptor("other_Y")],
            to: resources("full").appendingPathComponent("keyboard-schemas.json"))
        try write(["unused_Z"], to: resources("full").appendingPathComponent("keyboard-source-schemas.json"))
        try writeMarker("full", schemaID: "default_X")
        let methods = try XCTUnwrap(inventory())
        XCTAssertTrue(methods.isSuperset(of: ["default_X", "other_Y", "unused_Z"]))
        XCTAssertTrue(methods.isSuperset(of: BuiltinTemplateSchemas.sourceSchemaIDs))
    }

    func testDeclarationsKeepAMethodWhoseSchemaFileIsGone() throws {
        try FileManager.default.createDirectory(at: resources("damaged"), withIntermediateDirectories: true)
        try write([descriptor("X")], to: resources("damaged").appendingPathComponent("keyboard-schemas.json"))
        try writeMarker("damaged", schemaID: "X")
        XCTAssertEqual(inventory()?.contains("X"), true)
    }

    func testRegistryMapsGeneratedCompanionBackToItsSource() throws {
        try write([descriptor("X")], to: resources("derived").appendingPathComponent("keyboard-schemas.json"))
        let build = generation("derived").appendingPathComponent("user/build", isDirectory: true)
        try writeSchemaFile("derived14", in: build)
        try write(
            [KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "Y", schemaID: "derived14", layout: .merged14)],
            to: build.appendingPathComponent(KeyboardResourceSet.adapterRegistryFileName))
        try writeMarker("derived", schemaID: "X")
        let methods = try XCTUnwrap(inventory())
        XCTAssertTrue(methods.contains("Y"))
        XCTAssertFalse(methods.contains("derived14"), "a companion's own id is not an input method")
    }

    func testRegistryLessBuildOfKnownSchemasStaysComplete() throws {
        try writeSchemaFile("plain26", in: resources("plain"))
        try writeSchemaFile("plain26", in: generation("plain").appendingPathComponent("user/build"))
        try writeMarker("plain", schemaID: "plain26")
        XCTAssertEqual(inventory()?.contains("plain26"), true)
    }

    func testInstallsWithoutAnyGenerationOrOutsideSlotsDeclareNothing() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("stray-file"))
        XCTAssertEqual(inventory(), Set(BuiltinTemplateSchemas.sourceSchemaIDs))
    }

    // MARK: Several installs and versions

    func testDeletingOneOfTwoInstallsKeepsTheSharedMethod() throws {
        try writeSchemaFile("shared", in: resources("a"))
        try writeSchemaFile("shared", in: resources("b"))
        XCTAssertEqual(inventory()?.contains("shared"), true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("a"))
        XCTAssertEqual(inventory()?.contains("shared"), true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b"))
        XCTAssertEqual(inventory()?.contains("shared"), false)
    }

    func testMarkedInstallReadsOnlyItsLiveGeneration() throws {
        try writeSchemaFile("old_method", in: resources("multi", "gen-1"))
        try writeSchemaFile("new_method", in: resources("multi", "gen-2"))
        try writeMarker("multi", generation: "gen-2", schemaID: "new_method")
        let methods = try XCTUnwrap(inventory())
        XCTAssertTrue(methods.contains("new_method"))
        XCTAssertFalse(methods.contains("old_method"))
    }

    func testUnmarkedInstallUnionsEveryGeneration() throws {
        try writeSchemaFile("first", in: resources("multi", "gen-1"))
        try writeSchemaFile("second", in: resources("multi", "gen-2"))
        let methods = try XCTUnwrap(inventory())
        XCTAssertTrue(methods.isSuperset(of: ["first", "second"]))
    }

    // MARK: Incomplete installs keep every pairing

    func testMarkerPointingAtMissingGenerationIsIncomplete() throws {
        try writeSchemaFile("V", in: resources("dangling"))
        try writeMarker("dangling", generation: "gone-gen", schemaID: "V")
        XCTAssertNil(inventory())
    }

    func testMarkerWithoutVersionsIsIncomplete() throws {
        try writeMarker("no-versions", schemaID: "V")
        XCTAssertNil(inventory())
    }

    func testLostResourcesDirectoryIsIncomplete() throws {
        try FileManager.default.createDirectory(at: generation("lost"), withIntermediateDirectories: true)
        try writeMarker("lost", schemaID: "default_X")
        XCTAssertNil(inventory())
    }

    func testEmptiedResourcesDirectoryIsIncomplete() throws {
        try FileManager.default.createDirectory(at: resources("emptied"), withIntermediateDirectories: true)
        try writeMarker("emptied", schemaID: "default_X")
        XCTAssertNil(inventory(), "the marker names only the default, so it must not stand in for the whole set")
    }

    func testCorruptDeclarationIsIncomplete() throws {
        try writeSchemaFile("Z", in: resources("badjson"))
        try writeMarker("badjson", schemaID: "Z")
        try Data("not json".utf8).write(to: resources("badjson").appendingPathComponent("keyboard-schemas.json"))
        XCTAssertNil(inventory())
    }

    func testCorruptMarkerIsIncomplete() throws {
        try writeSchemaFile("Z", in: resources("badmarker"))
        try Data("not json".utf8).write(
            to: root.appendingPathComponent("badmarker").appendingPathComponent(InstalledPackageLayout.activeMarker))
        XCTAssertNil(inventory())
    }

    func testCorruptAdapterRegistryIsIncomplete() throws {
        try writeSchemaFile("X", in: resources("badregistry"))
        let build = generation("badregistry").appendingPathComponent("user/build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: build.appendingPathComponent(KeyboardResourceSet.adapterRegistryFileName))
        try writeMarker("badregistry", schemaID: "X")
        XCTAssertNil(inventory())
    }

    func testUnattributableBuildSchemaIsIncomplete() throws {
        try writeSchemaFile("X", in: resources("unknown"))
        try writeSchemaFile("mystery", in: generation("unknown").appendingPathComponent("user/build"))
        try writeMarker("unknown", schemaID: "X")
        XCTAssertNil(inventory())
    }

    func testUnreadableInstallSlotIsIncomplete() throws {
        try writeSchemaFile("some_method", in: resources("broken"))
        let slot = root.appendingPathComponent("broken")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: slot.path)
        guard (try? FileManager.default.contentsOfDirectory(atPath: slot.path)) == nil else {
            throw XCTSkip("permissions are not enforced for this user")
        }
        XCTAssertNil(inventory())
    }
}
