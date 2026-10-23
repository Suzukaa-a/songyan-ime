import XCTest
import Yams

@testable import PackageManager

final class GrammarModelManagementTests: XCTestCase {
    private var originals: [String: Data] {
        [
            "default.yaml": Data("schema_list: [{schema: a}, {schema: b}]\n".utf8),
            "a.schema.yaml": Data(
                "schema: {schema_id: a}\ngrammar: {language: upstream, collocation_max_length: 7}\ntranslator: {contextual_suggestions: false}\n"
                    .utf8),
            "b.schema.yaml": Data("schema: {schema_id: b}\n".utf8),
            "upstream.gram": Data("upstream fixture".utf8), "one.gram": Data("one fixture".utf8),
            "two.gram": Data("two fixture".utf8),
        ]
    }

    private func binding(
        _ model: String, _ ids: [String], existing: [String: Data],
        sources: InstalledRecipeSources? = nil
    ) throws -> DeclarativeRecipePlan {
        let recipe = try GrammarModelRecipe.make(modelPath: model, bindingSchemaIDs: ids)
        var inputs = originals
        inputs.merge(sources?.files ?? [:], uniquingKeysWith: { _, archived in archived })
        inputs[recipe.path] = recipe.source
        return try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: inputs, existingFiles: existing, managedGrammar: true)
    }

    private func restore(
        _ ids: [String], existing: [String: Data], sources: InstalledRecipeSources,
        generation: String? = nil, baseline: [String: Data] = [:],
        resources: [String: RecipeFileResource] = [:]
    ) throws -> DeclarativeRecipePlan {
        let removals = try GrammarModelRecipe.restorationOverrides(
            schemaIDs: ids, sources: sources,
            files: existing, packageReference: "test")
        let recipe = try GrammarModelRecipe.restorationRecipe(schemaIDs: ids)
        var inputs = sources.files
        inputs[recipe.path] = recipe.source
        return try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: inputs, existingFiles: existing, expectedGeneration: generation,
            packageFileResources: sources.fileResources, existingFileResources: resources,
            userCustomBaseline: baseline, restoringGrammarOverrides: removals)
    }

    private func directory() throws -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        root.appendPathComponent(".scratch/grammar-management/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testResourceOnlyPreservesRecipeGrammarAndTranslatorOptions() throws {
        let recipe = try GrammarModelRecipe.make(modelPath: "upstream.gram", bindingSchemaIDs: [])
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: originals, existingFiles: originals, managedGrammar: true)
        XCTAssertEqual(plan.files["a.schema.yaml"], originals["a.schema.yaml"])
        XCTAssertNil(plan.files["a.custom.yaml"])
        XCTAssertTrue(plan.grammarOverrides.isEmpty)
        XCTAssertEqual(SchemeGrammarRequirements.discover(in: plan.files).paths, ["upstream.gram"])
    }

    func testRestoreRemovesAllOwnedModelsButKeepsUserPatchAndOtherSchema() throws {
        var files = originals
        let user = Data(
            "# my comment\npatch:\n  translator/contextual_suggestions: false\n  translator/enable_user_dict: false\n"
                .utf8)
        files["a.custom.yaml"] = user
        let first = try binding("one.gram", ["a", "b"], existing: files)
        let firstSources = InstalledRecipeSources.merging(nil, plan: first)
        let second = try binding("two.gram", ["a"], existing: first.files, sources: firstSources)
        let secondSources = InstalledRecipeSources.merging(firstSources, plan: second)
        let result = try restore(["a"], existing: second.files, sources: secondSources)
        XCTAssertEqual(result.files["a.custom.yaml"], user)
        XCTAssertEqual(result.files["b.custom.yaml"], second.files["b.custom.yaml"])
        XCTAssertEqual(result.files["a.schema.yaml"], originals["a.schema.yaml"])
        XCTAssertEqual(result.changedPaths, ["a.custom.yaml"])
        XCTAssertEqual(result.receipt.changes.map(\.path), ["a.custom.yaml"])
        XCTAssertNotEqual(result.receipt.changes.first?.beforeSHA256, result.receipt.changes.first?.afterSHA256)
        XCTAssertEqual(result.restoredGrammarOverrides.count, 2)
        XCTAssertEqual(SchemeGrammarRequirements.discover(in: result.files).paths, ["one.gram", "upstream.gram"])
        let retained = InstalledRecipeSources.merging(secondSources, plan: result)
        XCTAssertEqual(retained.grammarOverrides.map(\.schemaID), ["b"])
    }

    func testIncrementalSameModelDoesNotLoseEarlierTargetProvenance() throws {
        let first = try binding("one.gram", ["a"], existing: originals)
        let firstSources = InstalledRecipeSources.merging(nil, plan: first)
        let second = try binding("one.gram", ["b"], existing: first.files, sources: firstSources)
        let sources = InstalledRecipeSources.merging(firstSources, plan: second)
        XCTAssertEqual(Set(sources.grammarOverrides.map(\.schemaID)), Set(["a", "b"]))
        let result = try restore(["a"], existing: second.files, sources: sources)
        XCTAssertEqual(result.files["b.custom.yaml"], second.files["b.custom.yaml"])
        XCTAssertNotNil(
            try Yams.load(yaml: String(decoding: result.files["a.custom.yaml"]!, as: UTF8.self)) as? [String: Any])
    }

    func testDisableNeedsNoModelFileAndRestoreExposesSourceDefault() throws {
        let recipe = try GrammarModelRecipe.disabling(schemaIDs: ["a"])
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: originals, existingFiles: originals, managedGrammar: true)
        XCTAssertTrue(recipe.installPatterns.isEmpty)
        XCTAssertEqual(plan.grammarOverrides.count, 1)
        XCTAssertTrue(SchemeGrammarRequirements.discover(in: plan.files).paths.isEmpty)
        let sources = InstalledRecipeSources.merging(nil, plan: plan)
        let result = try restore(["a"], existing: plan.files, sources: sources)
        XCTAssertEqual(SchemeGrammarRequirements.discover(in: result.files).paths, ["upstream.gram"])
        XCTAssertFalse(String(decoding: result.files["a.custom.yaml"]!, as: UTF8.self).contains("grammar/language"))
    }

    func testForeignModelPrefixAndUserEditedBlockAreNeverRemoved() throws {
        let foreign = Data(
            "__patch:\n# Rx: foreign:model-one: {\n  - patch/+:\n      grammar/language: foreign\n# }\n".utf8)
        var files = originals
        files["a.custom.yaml"] = foreign
        let bound = try binding("one.gram", ["a"], existing: files)
        let sources = InstalledRecipeSources.merging(nil, plan: bound)
        let result = try restore(["a"], existing: bound.files, sources: sources)
        XCTAssertEqual(result.files["a.custom.yaml"], foreign)
        var edited = bound.files
        edited["a.custom.yaml"] = Data(
            String(decoding: bound.files["a.custom.yaml"]!, as: UTF8.self)
                .replacingOccurrences(of: "grammar/language: \"one\"", with: "grammar/language: user-changed").utf8)
        XCTAssertThrowsError(try restore(["a"], existing: edited, sources: sources))
        let editedSources = InstalledRecipeSources(
            files: sources.files, fileResources: sources.fileResources,
            receipts: sources.receipts, grammarOverrides: sources.grammarOverrides)
        XCTAssertEqual(GrammarModelRecipe.overrides(in: editedSources, files: edited).count, 1)
    }

    func testUnicodeSubdirectoryReferenceIsPreserved() throws {
        let path = "models/中文模型.gram"
        let recipe = try GrammarModelRecipe.make(modelPath: path, bindingSchemaIDs: ["a"])
        var inputs = originals
        inputs[path] = Data("fixture".utf8)
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: inputs, existingFiles: originals, managedGrammar: true)
        XCTAssertNotNil(plan.files[path])
        XCTAssertEqual(SchemeGrammarRequirements.discover(in: plan.files).paths, [path])
        XCTAssertEqual(plan.grammarOverrides.count, 1)
    }

    func testBindingSupportUsesActualTranslatorNamespaceAndDoesNotForceContextualSuggestions() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtures: [(String, String, GrammarBinding.Support)] = [
            (
                "script", "engine: {translators: [script_translator]}\ntranslator: {contextual_suggestions: false}\n",
                .supported
            ),
            (
                "table",
                "engine: {translators: [table_translator]}\ntranslator: {enable_sentence: false, sentence_over_completion: false, contextual_suggestions: false}\n",
                .unsupported
            ),
            (
                "named",
                "engine: {translators: [table_translator@words]}\nwords: {enable_sentence: true}\ntranslator: {enable_sentence: false}\n",
                .supported
            ),
            ("custom", "engine: {translators: [lua_translator@custom]}\n", .unknown),
            ("empty", "engine: {translators: ['']}\n", .unknown),
        ]
        for (id, text, support) in fixtures {
            try Data(text.utf8).write(to: root.appendingPathComponent(id + ".schema.yaml"))
            let result = try GrammarBinding.read(schemaID: id, buildDirectory: root)
            XCTAssertEqual(result.support, support)
            XCTAssertFalse(result.contextualSuggestions)
        }
    }

    func testScalarShapedLanguageNamesRemainExactStrings() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["true", "false", "123", "2026-01-01"] {
            try Data("grammar: {language: \(name)}\nengine: {translators: [script_translator]}\n".utf8)
                .write(to: root.appendingPathComponent("scalar.schema.yaml"))
            XCTAssertEqual(try GrammarBinding.read(schemaID: "scalar", buildDirectory: root).language, name)
            let recipe = try GrammarModelRecipe.make(modelPath: name + ".gram", bindingSchemaIDs: ["a"])
            XCTAssertTrue(String(decoding: recipe.source, as: UTF8.self).contains("grammar/language: \"\(name)\""))
        }
    }

    func testManagedGrammarIntentSurvivesResourceOnlyAndRestorePlans() throws {
        let recipe = try GrammarModelRecipe.make(modelPath: "one.gram", bindingSchemaIDs: [])
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: recipe.declaredName!,
            arguments: [], packageFiles: originals, existingFiles: originals, managedGrammar: true)
        XCTAssertTrue(plan.managesGrammar)
        let bound = try binding("one.gram", ["a"], existing: originals)
        let sources = InstalledRecipeSources.merging(nil, plan: bound)
        XCTAssertTrue(try restore(["a"], existing: bound.files, sources: sources).managesGrammar)
    }

    func testRestoreTransactionOverwritesCopiedUserCustomAndCatalogRoundTrips() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = RecipePackageManager(rootURL: root)
        let bound = try binding("one.gram", ["a"], existing: originals)
        let deploy: RecipePackageManager.Deploy = { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list: [{schema: a}, {schema: b}]\n".utf8).write(
                to: build.appendingPathComponent("default.yaml"))
            for id in ["a", "b"] {
                try Data("schema: {schema_id: \(id)}\n".utf8).write(
                    to: build.appendingPathComponent(id + ".schema.yaml"))
            }
            return .init(availableComponents: [], validatedSchemaID: "a", validatedEnabledSchemaIDs: ["a", "b"])
        }
        _ = try await manager.installRecipePlan(bound, packageID: "test", schemaID: "a", deploy: deploy)
        let currentInstallation = try await manager.activeInstallation()
        let active = try XCTUnwrap(currentInstallation)
        let sources = try RecipePackageManager.readInstalledRecipeSources(resources: active.resourceURL)
        XCTAssertEqual(sources.grammarOverrides.count, 1)
        let snapshot = try RecipePackageManager.readRecipeWorkspaceSnapshot(
            resources: active.resourceURL, userConfiguration: active.userDataURL)
        let result = try restore(
            ["a"], existing: snapshot.files, sources: sources,
            generation: active.installation.generation, baseline: snapshot.userCustomFiles,
            resources: snapshot.fileResources)
        _ = try await manager.installRecipePlan(result, packageID: "test", schemaID: "a", deploy: deploy)
        let nextInstallation = try await manager.activeInstallation()
        let next = try XCTUnwrap(nextInstallation)
        let user = try String(contentsOf: next.userDataURL.appendingPathComponent("a.custom.yaml"), encoding: .utf8)
        XCTAssertFalse(user.contains("grammar/language"))
        XCTAssertNotNil(try Yams.load(yaml: user) as? [String: Any])
        XCTAssertTrue(
            try RecipePackageManager.readInstalledRecipeSources(resources: next.resourceURL).grammarOverrides.isEmpty)
    }
}
