import CryptoKit
import XCTest

@testable import PackageManager

final class SharedRimePresetTests: XCTestCase {
    private let schema = Data(
        "schema:\n  schema_id: sample\nkey_binder:\n  import_preset: default\npunctuator:\n  import_preset: symbols\n"
            .utf8)

    func testPinnedDefaultsAreCompleteAndOnlySchemaListIsAdapted() throws {
        let original = try SharedRimePresets.bundled("default.yaml")
        XCTAssertEqual(
            SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined(),
            "0628ada16651d56c4cdfcb8e45ddba23d4d585cc8be0580a62c4e077c0bcc141")
        var files = ["sample.schema.yaml": schema]
        try SharedRimePresets.supplement(&files)
        try SchemeSourceCheck.dependencies(files)
        let text = String(decoding: try XCTUnwrap(files["default.yaml"]), as: UTF8.self)
        XCTAssertTrue(text.contains("key_bindings:/emacs_editing"))
        XCTAssertTrue(text.contains("punctuation:/full_shape"))
        XCTAssertTrue(text.contains("  - schema: sample\n"))
        XCTAssertFalse(text.contains("  - schema: luna_pinyin"))
        let tail = try XCTUnwrap(text.range(of: "switcher:"))
        let upstream = String(decoding: original, as: UTF8.self)
        XCTAssertEqual(
            String(text[tail.lowerBound...]),
            String(upstream[try XCTUnwrap(upstream.range(of: "switcher:")).lowerBound...]))
    }

    func testImportKeepsSourceSnapshotAndUserOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try schema.write(to: root.appendingPathComponent("sample.schema.yaml"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let prepared = try manager.prepareSchemeImport(directory: root)
        XCTAssertEqual(prepared.sourceFiles, ["sample.schema.yaml": schema])
        XCTAssertTrue(prepared.manifest.files.contains { $0.path == "key_bindings.yaml" })
        let defaults = Data("# own default\nkey_binder:\n  bindings: []\n".utf8)
        let custom = Data("patch:\n  menu/page_size: 9\n".utf8)
        var files = ["default.yaml": defaults, "default.custom.yaml": custom]
        try SharedRimePresets.supplement(&files)
        XCTAssertEqual(files["default.yaml"], defaults)
        XCTAssertEqual(files["default.custom.yaml"], custom)
    }

    func testPrivateDependenciesAreNotSuppliedByFrontend() throws {
        var files = [
            "sample.schema.yaml": Data(
                "schema:\n  dependencies: [luna_pinyin]\ntranslator:\n  dictionary: luna_pinyin\n".utf8)
        ]
        try SharedRimePresets.supplement(&files)
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(files)) { error in
            XCTAssertTrue(String(describing: error).contains("luna_pinyin.dict.yaml"))
            XCTAssertTrue(String(describing: error).contains("luna_pinyin.schema.yaml"))
        }
        files = ["sample.schema.yaml": Data("key_binder:\n  import_preset: private_keys\n".utf8)]
        try SharedRimePresets.supplement(&files)
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(files))
    }

    func testRecipeSupplementsOutputWithoutFalseSourceMatches() throws {
        func recipe(_ pattern: String) throws -> DeclarativeRecipe {
            try DeclarativeRecipe(
                path: "recipe.yaml", source: Data("recipe:\n  Rx: all\ninstall_files: >-\n  \(pattern)\n".utf8))
        }
        let plan = try DeclarativeRecipePlan(
            recipe: recipe("*.schema.yaml"), packageReference: "test/sample", selectedRecipe: "all", arguments: [],
            packageFiles: ["sample.schema.yaml": schema], existingFiles: [:])
        XCTAssertNotNil(plan.files["default.yaml"])
        try SchemeSourceCheck.dependencies(plan.files)
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: recipe("default.yaml"), packageReference: "test/sample", selectedRecipe: "all", arguments: [],
                packageFiles: ["sample.schema.yaml": schema], existingFiles: plan.files))
    }
}
