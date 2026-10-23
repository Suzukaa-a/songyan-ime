import XCTest

@testable import PackageManager

final class InstallerRecoveryTests: XCTestCase {
    func testInitModulesUseActualPackagePathAndTraverseCycles() throws {
        var files = [
            "default.yaml": Data("schema_list: [{schema: main}]".utf8),
            "main.schema.yaml": Data("schema: {schema_id: main}\nengine:\n  translators: [lua_translator@*pkg]\n".utf8),
            "lua/pkg/init.lua": Data("return require('next')".utf8),
            "lua/next/init.lua": Data("require('pkg'); return require('missing')".utf8),
        ]
        let seeds = ["default.yaml", "main.schema.yaml"]
        let paths = try SchemeSourceCheck.expandingLocalDependencies(seeds, inventory: files)
        XCTAssertEqual(Set(paths), Set(files.keys))
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), ["lua/missing.lua"])
        files["lua/missing.lua"] = Data("return {}".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), [])
        // ?.lua takes precedence over ?/init.lua. The shadowed init must not
        // contribute missing dependencies when the module has a direct file.
        files["lua/pkg.lua"] = Data("return {}".utf8)
        XCTAssertEqual(
            Set(try SchemeSourceCheck.expandingLocalDependencies(seeds, inventory: files)), Set(seeds + ["lua/pkg.lua"])
        )
    }

    func testGrammarIsScopedToEnabledAndExecutedConfiguration() throws {
        var files = [
            "default.yaml": Data("schema_list: [{schema: main}]".utf8),
            "main.schema.yaml": Data("schema: {schema_id: main}".utf8),
            "variant.schema.yaml": Data("grammar: {language: unused}".utf8),
            "unused.recipe.yaml": Data(
                "recipe:\n  Rx: unused\npatch_files:\n  main.custom.yaml:\n    - patch/+:\n        grammar/language: not-selected\n"
                    .utf8),
        ]
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: files), [])
        let recipe = try DeclarativeRecipe(path: "unused.recipe.yaml", source: files["unused.recipe.yaml"]!)
        let executed = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test/source", selectedRecipe: "unused",
            arguments: [], packageFiles: files, existingFiles: files)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: executed.files), ["not-selected.gram"])
        files["main.custom.yaml"] = Data("__patch:\n  - patch/+:\n      grammar/language: selected\n".utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: files), ["selected.gram"])
        files["main.custom.yaml"] = Data("patch:\n  grammar/language: ''\n".utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: files), [])
        files["main.custom.yaml"] = Data("__patch: arbitrary-runtime-expression\n".utf8)
        let unknown = SchemeGrammarRequirements.discover(in: files)
        XCTAssertEqual(unknown.paths, [])
        XCTAssertFalse(unknown.diagnostics.isEmpty)
        files["main.custom.yaml"] = nil
        files["main.schema.yaml"] = Data("__include: base.schema:/\nschema: {schema_id: main}\n".utf8)
        files["base.schema.yaml"] = Data("grammar:\n  __include: grammar:/hans\n".utf8)
        files["grammar.yaml"] = Data("hans: {language: included}\nhant: {language: unrelated}\n".utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: files), ["included.gram"])
        files["main.custom.yaml"] = Data("patch:\n  grammar/language: ''\n".utf8)
        XCTAssertEqual(SchemeGrammarRequirements.paths(in: files), [])
    }

    func testPackagedModelCanBeReplacedWithoutReimportingScheme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("schema: {schema_id: main}\ngrammar: {language: model}\n".utf8).write(
            to: root.appendingPathComponent("main.schema.yaml"))
        try Data("bad model".utf8).write(to: root.appendingPathComponent("model.gram"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let initial = try manager.prepareSchemeImport(directory: root)
        let replacementURL = root.appendingPathComponent("replacement.gram")
        try Data("different bytes; native validation is still required".utf8).write(to: replacementURL)
        let replacement = try RecipeFileResource.snapshot(from: replacementURL, directory: root)
        let ready = try initial.preparingModels(["model.gram": replacement])
        XCTAssertEqual(ready.declaration.id, initial.declaration.id)
        XCTAssertEqual(ready.fileResources["model.gram"]?.sha256, replacement.sha256)
        XCTAssertNotEqual(ready.manifest.revision, initial.manifest.revision)
        XCTAssertNotEqual(initial.fileResources["model.gram"]?.sha256, replacement.sha256)
    }
}
