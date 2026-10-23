import XCTest
import Yams

@testable import PackageManager

final class SourceAndModelTests: XCTestCase {
    func testOfficialSourceExpressionsAndLiteralConfigurationRejectShell() throws {
        XCTAssertEqual(try RimeSourceOrder("luna-pinyin").repository, "rime/rime-luna-pinyin")
        XCTAssertEqual(try RimeSourceOrder("rime-luna-pinyin").repository, "rime/rime-luna-pinyin")
        let order = try RimeSourceOrder("someone/input@release/v2:others/config:schema=one,schema=,unused=ok")
        XCTAssertEqual(order.ref, "release/v2")
        XCTAssertEqual(order.recipe, "others/config")
        XCTAssertEqual(order.arguments, [.init("schema", "one"), .init("schema", ""), .init("unused", "ok")])
        let conf = "#!/usr/bin/env bash\npackage_list+=(\n  prelude\n  'luna-pinyin' essay # comment\n)\n"
        XCTAssertEqual(
            try RimeSourceOrder.parseConfiguration(conf).map(\.expression), ["prelude", "luna-pinyin", "essay"])
        for text in [
            conf + "touch file\n", "package_list=(\n $(command)\n)\n", "source other.conf", "package_list=(\n prelude",
        ] {
            XCTAssertThrowsError(try RimeSourceOrder.parseConfiguration(text))
        }
        XCTAssertThrowsError(try RimeSourceOrder("owner/repo:config:a=$(command)"))
        XCTAssertThrowsError(try RimeSourceOrder("owner/repo@../bad"))
    }

    func testRepositoryArchiveKeepsBothOriginalRecipesAndInstallOrder() throws {
        let a = Data("recipe:\n  description: first\ninstall_files:\n  - shared.txt\n".utf8)
        let b = Data("recipe:\n  description: second\ninstall_files:\n  - shared.txt\n".utf8)
        let first = try DeclarativeRecipePlan(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: a),
            packageReference: "owner/a", selectedRecipe: "", arguments: [],
            packageFiles: ["recipe.yaml": a, "shared.txt": Data("first".utf8)], existingFiles: [:]
        )
        .archivingSources(prefix: "source-repositories/owner/a/")
        let result = try first.appending(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: b),
            packageReference: "owner/b", selectedRecipe: "", arguments: [],
            packageFiles: ["recipe.yaml": b, "shared.txt": Data("second".utf8)],
            sourceArchivePrefix: "source-repositories/owner/b/")
        XCTAssertEqual(result.files["shared.txt"], Data("second".utf8))
        XCTAssertEqual(result.sourceFiles["source-repositories/owner/a/recipe.yaml"], a)
        XCTAssertEqual(result.sourceFiles["source-repositories/owner/b/recipe.yaml"], b)
        XCTAssertEqual(Set(result.stageReceipts.map(\.recipePath)).count, 2)
        XCTAssertNil(result.files["source-repositories/owner/a/recipe.yaml"])
        let prior = InstalledRecipeSources(
            files: [
                "source-repositories/owner/a/deleted.txt": Data("old".utf8),
                "source-repositories/owner/b/untouched.dict.yaml": Data("dependency snapshot".utf8),
            ], fileResources: [:], receipts: [])
        let merged = InstalledRecipeSources.merging(prior, plan: first)
        XCTAssertNil(merged.files["source-repositories/owner/a/deleted.txt"], "更新仓库的原始快照不能混入已删除旧文件")
        XCTAssertEqual(
            merged.files["source-repositories/owner/b/untouched.dict.yaml"], Data("dependency snapshot".utf8),
            "未更新依赖的原始来源不能消失")
    }

    func testGrammarRecipeIsRealPatchWithExplicitOptionalDownload() throws {
        let url = URL(string: "https://example.org/language.gram")!
        let recipe = try GrammarModelRecipe.make(
            modelPath: "language.gram",
            bindingSchemaIDs: ["my_pinyin"], sourceURL: url)
        XCTAssertEqual(recipe.downloads, [.init(path: "language.gram", url: url)])
        XCTAssertEqual(recipe.patchTargets, ["my_pinyin.custom.yaml"])
        XCTAssertThrowsError(try GrammarModelRecipe.make(modelPath: "language.gram", bindingSchemaIDs: ["../bad"]))
        let unbound = try GrammarModelRecipe.make(modelPath: "language.gram", bindingSchemaIDs: [])
        XCTAssertEqual(unbound.installPatterns, ["language.gram"])
        XCTAssertTrue(unbound.patchTargets.isEmpty)
        let plan = try DeclarativeRecipePlan(
            recipe: unbound, packageReference: "user/recipe",
            selectedRecipe: unbound.declaredName!, arguments: [],
            packageFiles: ["language.gram": Data("model".utf8)], existingFiles: [:])
        XCTAssertEqual(plan.files["language.gram"], Data("model".utf8))
        let binding = try GrammarModelRecipe.make(modelPath: "language.gram", bindingSchemaIDs: ["input"])
        let later = try DeclarativeRecipePlan(
            recipe: binding, packageReference: "user/recipe",
            selectedRecipe: binding.declaredName!, arguments: [],
            packageFiles: ["language.gram": Data("model".utf8)],
            existingFiles: plan.files.merging(
                ["input.schema.yaml": Data("schema: {schema_id: input}\n".utf8)]) { _, new in new })
        XCTAssertEqual(later.files["language.gram"], plan.files["language.gram"])
        XCTAssertNotNil(later.files["input.custom.yaml"], "安装后再绑定应生成该输入方式的补丁")
    }

    func testPickedModelNamesDoNotRequireUserRenaming() throws {
        let chinese = "中文模型.gram"
        let installed = try XCTUnwrap(GrammarModelRecipe.installPath(for: chinese))
        XCTAssertTrue(GrammarModelRecipe.validModelPath(installed))
        let recipe = try GrammarModelRecipe.make(
            modelPath: installed,
            bindingSchemaIDs: ["arbitrary_schema"], displayName: chinese)
        let original = GrammarModelRecipe.displayName(for: installed, sources: [recipe.path: recipe.source])
        XCTAssertEqual(original, chinese)
        let nextBinding = try GrammarModelRecipe.make(
            modelPath: installed,
            bindingSchemaIDs: ["another_schema"], displayName: original)
        XCTAssertEqual(
            GrammarModelRecipe.displayName(
                for: installed,
                sources: [nextBinding.path: nextBinding.source]), chinese)
        XCTAssertEqual(recipe.installPatterns, [installed])
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/recipe",
            selectedRecipe: recipe.declaredName!, arguments: [],
            packageFiles: [installed: Data("fixture".utf8)],
            existingFiles: ["arbitrary_schema.schema.yaml": Data("schema: {schema_id: arbitrary_schema}\n".utf8)])
        let patch = try XCTUnwrap(String(data: plan.files["arbitrary_schema.custom.yaml"]!, encoding: .utf8))
        XCTAssertTrue(patch.contains("grammar/language: \"\(GrammarModelRecipe.modelName(for: installed))\""))
        let archived = InstalledRecipeSources.merging(nil, plan: plan)
        XCTAssertEqual(GrammarModelRecipe.displayName(for: installed, sources: archived.files), chinese)

        let normalized = try XCTUnwrap(GrammarModelRecipe.installPath(for: "my model.gram"))
        XCTAssertEqual(normalized, GrammarModelRecipe.installPath(for: "my model.gram"))
        XCTAssertTrue(GrammarModelRecipe.validModelPath(normalized))
        XCTAssertNotEqual(normalized, GrammarModelRecipe.installPath(for: "other model.gram"))
        XCTAssertNil(GrammarModelRecipe.installPath(for: "notes.txt"))
    }

    func testOneModelBindsManyInputMethodsWithoutDuplicatingTheModel() throws {
        let model = "wanxiang-lts-zh-hans.gram"
        let modelBytes = Data("model fixture".utf8)
        let recipe = try GrammarModelRecipe.make(
            modelPath: model,
            bindingSchemaIDs: ["luna_pinyin", "double_pinyin"])
        // One check-in of the model, one managed patch target per named input method.
        XCTAssertEqual(recipe.installPatterns, [model])
        XCTAssertEqual(recipe.patchTargets.sorted(), ["double_pinyin.custom.yaml", "luna_pinyin.custom.yaml"])
        XCTAssertEqual(recipe.declaredName, "songyan-models/model-wanxiang-lts-zh-hans")
        // A model identity is its file stem, independent of any schema.
        XCTAssertEqual(GrammarModelRecipe.modelName(for: model), "wanxiang-lts-zh-hans")

        let deployed = [
            "luna_pinyin.schema.yaml": Data("schema: {schema_id: luna_pinyin, name: 拼音}\n".utf8),
            "double_pinyin.schema.yaml": Data("schema: {schema_id: double_pinyin, name: 双拼}\n".utf8),
        ]
        let bindingPlan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/recipe",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [model: modelBytes],
            existingFiles: deployed)
        let boundSchemas = bindingPlan.files
            .filter { $0.key.hasSuffix(".custom.yaml") }
            .allSatisfy {
                String(data: $0.value, encoding: .utf8)!.contains("grammar/language: \"wanxiang-lts-zh-hans\"")
            }
        XCTAssertTrue(boundSchemas, "every named input method receives the model binding")

        // Unbinding exactly one input method only rewrites that schema's managed block.
        let clearRecipe = try GrammarModelRecipe.make(
            modelPath: model,
            bindingSchemaIDs: [], clearingSchemaIDs: ["luna_pinyin"])
        XCTAssertEqual(clearRecipe.patchTargets, ["luna_pinyin.custom.yaml"])
        let clearPlan = try DeclarativeRecipePlan(
            recipe: clearRecipe, packageReference: "user/recipe",
            selectedRecipe: clearRecipe.declaredName!, arguments: [],
            packageFiles: [model: modelBytes], existingFiles: bindingPlan.files)
        XCTAssertTrue(
            String(data: clearPlan.files["luna_pinyin.custom.yaml"]!, encoding: .utf8)!.contains(
                "grammar/language: \"\""))
        XCTAssertEqual(
            clearPlan.files["double_pinyin.custom.yaml"], bindingPlan.files["double_pinyin.custom.yaml"],
            "unbinding one input method must not touch the same model's other bindings")
        XCTAssertEqual(
            clearPlan.files["luna_pinyin.schema.yaml"], deployed["luna_pinyin.schema.yaml"]!,
            "the source schema is untouched; only its managed custom block changes")
    }

    func testGrammarBindingReadsTheRealDeployedRelation() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        try Data("schema: {schema_id: a, name: A}\ngrammar: {language: model}\n".utf8)
            .write(to: build.appendingPathComponent("a.schema.yaml"))
        try Data("schema: {schema_id: b, name: B}\ngrammar: {language: other}\n".utf8)
            .write(to: build.appendingPathComponent("b.schema.yaml"))
        try Data("schema: {schema_id: c, name: C}\n".utf8)
            .write(to: build.appendingPathComponent("c.schema.yaml"))
        let a = try GrammarBinding.read(schemaID: "a", buildDirectory: build)
        let b = try GrammarBinding.read(schemaID: "b", buildDirectory: build)
        let c = try GrammarBinding.read(schemaID: "c", buildDirectory: build)
        XCTAssertTrue(a.binds(modelPath: "model.gram"))
        XCTAssertFalse(b.binds(modelPath: "model.gram"))
        XCTAssertFalse(c.binds(modelPath: "model.gram"))
    }

}
