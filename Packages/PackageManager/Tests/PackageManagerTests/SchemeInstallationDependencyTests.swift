import XCTest
import Yams

@testable import PackageManager

final class SchemeInstallationDependencyTests: XCTestCase {
    func testModernLuaCommentsDoNotRequireLegacyEntryPoint() throws {
        let files = [
            "example.schema.yaml": Data(
                """
                engine:
                  translators: [lua_translator@*wanxiang.unicode_conversion]
                recognizer:
                  patterns:
                    unicode: '^U[a-f0-9]+' # 响应 lua_translator@unicode
                """.utf8),
            "lua/wanxiang/unicode_conversion.lua": Data("return {}".utf8),
        ]
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), [])
        var legacy = files
        legacy["example.schema.yaml"] = Data("engine:\n  translators: [lua_translator@unicode]\n".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(legacy), ["rime.lua"])
    }

    func testPresetVocabularyRequiresEssayButExplicitlyDisabledDoesNot() throws {
        let header = "---\nname: luna_pinyin\nuse_preset_vocabulary: true\n...\n月\tyue\n"
        XCTAssertEqual(
            try SchemeSourceCheck.missingDependencies(["luna_pinyin.dict.yaml": Data(header.utf8)]), ["essay.txt"])
        XCTAssertEqual(
            try SchemeSourceCheck.missingDependencies([
                "luna_pinyin.dict.yaml": Data(header.utf8), "essay.txt": Data("月\t10\n".utf8),
            ]), [])
        XCTAssertEqual(
            try SchemeSourceCheck.missingDependencies([
                "luna_pinyin.dict.yaml": Data(header.replacingOccurrences(of: "true", with: "false").utf8)
            ]), [])
    }

    func testModelRequirementsIgnoreCommentsAndUnconfiguredSchemes() {
        XCTAssertEqual(
            SchemeGrammarRequirements.paths(in: [
                "pure.schema.yaml": Data(
                    """
                    grammar:
                      language: wanxiang-lts-zh-hans
                    # grammar/language: imaginary
                    """.utf8)
            ]), ["wanxiang-lts-zh-hans.gram"])
        XCTAssertEqual(
            SchemeGrammarRequirements.paths(in: ["ice.schema.yaml": Data("translator:\n  dictionary: rime_ice\n".utf8)]
            ), [])
    }

    func testInactiveVariantDoesNotBlockSelectedSourceButCompanionsRemainRequired() throws {
        var files = [
            "default.yaml": Data("schema_list:\n  - schema: main\n".utf8),
            "main.schema.yaml": Data(
                "schema:\n  schema_id: main\n  dependencies: [reverse]\ntranslator:\n  dictionary: main\n".utf8),
            "main.dict.yaml": Data("name: main\n".utf8),
            "alternate.schema.yaml": Data("translator:\n  dictionary: requires-release-assembly\n".utf8),
        ]
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), ["reverse.schema.yaml"])
        files["reverse.schema.yaml"] = Data("schema:\n  schema_id: reverse\n".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), [])
        files["default.yaml"] = Data("schema_list:\n  - schema: alternate\n".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), ["requires-release-assembly.dict.yaml"])
        files["default.custom.yaml"] = Data("__patch:\n  - patch/+:\n      schema_list:\n        - schema: main\n".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), [])
    }

    func testExplicitDefaultRequiresEveryEnabledSchemaUnlessCustomReplacesList() throws {
        var files = [
            "default.yaml": Data("schema_list:\n  - schema: luna_pinyin\n  - schema: bopomofo\n".utf8),
            "luna_pinyin.schema.yaml": Data("schema:\n  schema_id: luna_pinyin\n".utf8),
        ]
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), ["bopomofo.schema.yaml"])
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(files)) { error in
            guard case RecipeInstallError.missingSchemaFiles(let paths) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(paths, ["bopomofo.schema.yaml"])
        }
        files["default.custom.yaml"] = Data("patch:\n  schema_list:\n    - schema: luna_pinyin\n".utf8)
        XCTAssertEqual(try SchemeSourceCheck.missingDependencies(files), [])
    }

    func testAutomaticPreludeSelectionDoesNotEnableUnacquiredDistributionPackages() throws {
        let files = [
            "default.yaml": Data(
                "config_version: '1'\nschema_list:\n  - schema: luna_pinyin\n  - schema: bopomofo\n".utf8),
            "luna_pinyin.schema.yaml": Data("schema:\n  schema_id: luna_pinyin\n".utf8),
        ]
        let recipe = try DeclarativeRecipe(
            path: "recipe.yaml",
            source: Data(
                "recipe:\n  description: selection regression\ninstall_files:\n  - default.yaml\n  - luna_pinyin.schema.yaml\n"
                    .utf8))
        var prelude = AcquiredRimeSource(
            order: try RimeSourceOrder("rime/rime-prelude"), revision: String(repeating: "a", count: 40),
            files: ["default.yaml": files["default.yaml"]!], models: [:], recipe: recipe)
        prelude.isDependency = true
        let luna = AcquiredRimeSource(
            order: try RimeSourceOrder("rime/rime-luna-pinyin"), revision: String(repeating: "b", count: 40),
            files: ["luna_pinyin.schema.yaml": files["luna_pinyin.schema.yaml"]!], models: [:], recipe: recipe)
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "rime/test", selectedRecipe: "", arguments: [], packageFiles: files,
            existingFiles: [:])
        let selected = try plan.selectingSourceEntry("", sources: [prelude, luna], isNewInstallation: true)
        let custom = String(decoding: selected.files["default.custom.yaml"]!, as: UTF8.self)
        XCTAssertTrue(custom.contains("luna_pinyin"))
        XCTAssertFalse(custom.contains("bopomofo"))
        XCTAssertEqual(selected.files["default.yaml"], files["default.yaml"])
        let update = try plan.selectingSourceEntry("", sources: [prelude, luna], isNewInstallation: false)
        XCTAssertNil(update.files["default.custom.yaml"])
    }

    private func selectionDeployment(custom: String?) throws -> (RecipeDeployment, resources: URL, user: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "schema-selection-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let user = root.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try Data("schema_list:\n  - schema: valid\n  - schema: unsupported\n".utf8)
            .write(to: resources.appendingPathComponent("default.yaml"))
        if let custom { try Data(custom.utf8).write(to: resources.appendingPathComponent("default.custom.yaml")) }
        let manifest = RecipeManifest(
            id: "test", repository: "user/import", revision: "rev",
            recipePath: "recipe.yaml", license: "test", schemaID: "valid",
            requiredComponents: [], files: [], origin: .userScheme)
        return (RecipeDeployment(manifest: manifest, resourceURL: resources, userDataURL: user), resources, user)
    }

    /// The schema_list carried by the last `__patch` entry, which Rime applies last.
    private func stagedSelection(_ text: String) throws -> [String] {
        let root = try XCTUnwrap(try Yams.load(yaml: text) as? [String: Any])
        let entries = try XCTUnwrap(root["__patch"] as? [Any])
        let last = try XCTUnwrap((entries.last as? [String: Any])?["patch/+"] as? [String: Any])
        let list = try XCTUnwrap(last["schema_list"] as? [[String: Any]])
        return list.compactMap { $0["schema"] as? String }
    }

    func testSupportedSchemaSelectionWithoutCustomFile() throws {
        let (deployment, resources, user) = try selectionDeployment(custom: nil)
        try SupportedSchemaSelection.stage(["valid"], deployment: deployment)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("default.custom.yaml").path))
        let staged = try String(contentsOf: user.appendingPathComponent("default.custom.yaml"), encoding: .utf8)
        XCTAssertEqual(try stagedSelection(staged), ["valid"])
    }

    func testSupportedSchemaSelectionKeepsPlainPatchUntouched() throws {
        let custom = "patch:\n  menu/page_size: 7\n  schema_list:\n    - schema: unsupported\n"
        let (deployment, resources, user) = try selectionDeployment(custom: custom)
        try SupportedSchemaSelection.stage(["valid"], deployment: deployment)
        XCTAssertEqual(
            try String(contentsOf: resources.appendingPathComponent("default.custom.yaml"), encoding: .utf8), custom)
        let staged = try String(contentsOf: user.appendingPathComponent("default.custom.yaml"), encoding: .utf8)
        XCTAssertTrue(staged.hasPrefix(custom), "the user's own patch stays byte for byte")
        XCTAssertEqual(try stagedSelection(staged), ["valid"])
    }

    func testSupportedSchemaSelectionAppendsToPlumPatchListKeepingComments() throws {
        let custom = """
            # encoding: utf-8
            #
            # Customization by recipe; 雾凇拼音
            __patch:
            # Rx: iDvel/rime-ice:others/recipes/full {
              - patch/+:
                  __include: rime_ice_suggestion:/
            # }
            # Rx: lotem/rime-octagram-data:config:schema=luna_pinyin {
              - luna_pinyin.custom:/patch?
            # }

            """
        let (deployment, _, user) = try selectionDeployment(custom: custom)
        try SupportedSchemaSelection.stage(["valid"], deployment: deployment)
        let staged = try String(contentsOf: user.appendingPathComponent("default.custom.yaml"), encoding: .utf8)
        XCTAssertTrue(staged.hasPrefix(String(custom.dropLast())), "plum's blocks and comments stay in place")
        XCTAssertTrue(staged.contains("# Customization by recipe; 雾凇拼音"))
        XCTAssertTrue(staged.contains("  - patch/+:\n      __include: rime_ice_suggestion:/\n# }"))
        XCTAssertEqual(try stagedSelection(staged), ["valid"])
    }

    func testSupportedSchemaSelectionRerunReplacesItsOwnBlockOnly() throws {
        let custom = "# keep me\n__patch:\n  - patch/+:\n      menu/page_size: 9\n"
        let (deployment, _, user) = try selectionDeployment(custom: custom)
        let url = user.appendingPathComponent("default.custom.yaml")
        try SupportedSchemaSelection.stage(["valid"], deployment: deployment)
        let first = try Data(contentsOf: url)
        try SupportedSchemaSelection.stage(["valid"], deployment: deployment)
        XCTAssertEqual(try Data(contentsOf: url), first, "staging the same selection again changes nothing")
        try SupportedSchemaSelection.stage(["unsupported", "valid"], deployment: deployment)
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(try stagedSelection(updated), ["unsupported", "valid"])
        XCTAssertEqual(updated.components(separatedBy: "# Rx: \(SupportedSchemaSelection.rx) {").count, 2)
        XCTAssertTrue(updated.hasPrefix(custom))
    }

    func testDeclaredEntryFallsBackOnlyForUserSources() throws {
        let user = RecipeManifest(
            id: "user", repository: "user/import", revision: "rev",
            recipePath: "recipe.yaml", license: "test", schemaID: "unsupported",
            requiredComponents: [], files: [], origin: .userScheme)
        let deployment = RecipeDeployment(
            manifest: user, resourceURL: URL(fileURLWithPath: "/tmp"),
            userDataURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(try deployment.declaredEntry(in: ["surviving"]), "surviving")
        XCTAssertEqual(try deployment.declaredEntry(in: ["surviving", "unsupported"]), "unsupported")
        let fixed = RecipeManifest(
            id: "fixed", repository: "source", revision: "rev",
            recipePath: "recipe.yaml", license: "test", schemaID: "unsupported",
            requiredComponents: [], files: [], origin: nil)
        let fixedDeployment = RecipeDeployment(
            manifest: fixed, resourceURL: URL(fileURLWithPath: "/tmp"),
            userDataURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try fixedDeployment.declaredEntry(in: ["surviving"]))
    }
}
