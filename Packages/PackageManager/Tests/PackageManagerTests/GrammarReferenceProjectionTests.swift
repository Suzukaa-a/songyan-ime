import XCTest

@testable import PackageManager

final class GrammarReferenceProjectionTests: XCTestCase {
    private let model = "wanxiang-lts-zh-hans.gram"
    private let entry = "schema: {schema_id: main, name: Projection, version: '1'}\n"

    func testScalarLanguageIncludeAndIncludedSchemaCustom() throws {
        let scalar = [
            "default.yaml": Data("schema_list: [{schema: main}]\n".utf8),
            "main.schema.yaml": Data((entry + "grammar:\n  language:\n    __include: grammar:/language\n").utf8),
            "grammar.yaml": Data("language: wanxiang-lts-zh-hans\n".utf8),
        ]
        let custom = [
            "default.yaml": scalar["default.yaml"]!,
            "main.schema.yaml": Data(("__include: base.schema:/\n" + entry).utf8),
            "base.schema.yaml": Data("schema: {schema_id: base, name: Base, version: '1'}\n".utf8),
            "base.custom.yaml": Data("patch:\n  grammar/language: wanxiang-lts-zh-hans\n".utf8),
        ]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providedURL = root.appendingPathComponent("selected.gram")
        try Data("identity fixture; compatibility must still be checked by native".utf8).write(to: providedURL)
        let supplied = try RecipeFileResource.snapshot(from: providedURL, directory: root)
        for (name, files) in [("scalar", scalar), ("custom", custom)] {
            let found = SchemeGrammarRequirements.discover(in: files)
            XCTAssertEqual(found.paths, [model], name)
            XCTAssertEqual(found.diagnostics, [], name)
            let source = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            for (path, data) in files { try data.write(to: source.appendingPathComponent(path)) }
            let manager = RecipePackageManager(rootURL: root.appendingPathComponent(name + "-store"))
            let prepared = try manager.prepareSchemeImport(directory: source)
            XCTAssertEqual(prepared.requiredModelPaths, [model], "Existing installer model row/gate input")
            XCTAssertThrowsError(try prepared.preparingModels([:]))
            let ready = try prepared.preparingModels([model: supplied])
            XCTAssertEqual(ready.fileResources[model]?.sha256, supplied.sha256)
            XCTAssertTrue(ready.manifest.files.contains { $0.path == model && $0.sha256 == supplied.sha256 })
        }
        var unrelated = custom
        unrelated["main.schema.yaml"] = Data(entry.utf8)  // base is now inventory only.
        unrelated["inactive.schema.yaml"] = scalar["main.schema.yaml"]
        unrelated["unused.recipe.yaml"] = Data(
            "recipe:\n  Rx: unused\npatch_files:\n  main.custom.yaml:\n    - patch/+:\n        grammar/language: unselected\n"
                .utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: unrelated), [])
        var overridden = custom
        overridden["main.custom.yaml"] = Data("patch:\n  grammar/language: ''\n".utf8)
        XCTAssertEqual(
            SchemeGrammarRequirements.paths(in: overridden), [],
            "Referencing schema custom is applied after base custom")
        var chain = scalar
        chain["grammar.yaml"] = Data("language:\n  __include: language:/name\n".utf8)
        chain["language.yaml"] = Data("name: wanxiang-lts-zh-hans\n".utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: chain), [model])
    }

    func testScalarIncludeCycleIsDiagnosticNotSilentAbsence() {
        let files = [
            "default.yaml": Data("schema_list: [{schema: main}]\n".utf8),
            "main.schema.yaml": Data((entry + "grammar:\n  language:\n    __include: grammar:/language\n").utf8),
            "grammar.yaml": Data("language:\n  __include: grammar:/language\n".utf8),
        ]
        let found = SchemeGrammarRequirements.discover(in: files)
        XCTAssertEqual(found.paths, [])
        XCTAssertFalse(found.diagnostics.isEmpty)
        var mapCycle = files
        mapCycle["main.schema.yaml"] = Data((entry + "grammar:\n  __include: grammar:/loop\n").utf8)
        mapCycle["grammar.yaml"] = Data("loop:\n  __include: grammar:/loop\n".utf8)
        XCTAssertFalse(SchemeGrammarRequirements.discover(in: mapCycle).diagnostics.isEmpty)
    }
}
