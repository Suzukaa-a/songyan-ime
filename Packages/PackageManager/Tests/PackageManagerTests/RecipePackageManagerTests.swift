import CryptoKit
import XCTest

@testable import PackageManager

final class RecipePackageManagerTests: XCTestCase {
    func testActivationAndFailedUpdatePreserveUserData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recipe-test-\(UUID())")
        let initial = root.appendingPathComponent("initial")
        try FileManager.default.createDirectory(at: initial, withIntermediateDirectories: true)
        try Data("patch: {menu/page_size: 7}".utf8).write(to: initial.appendingPathComponent("default.custom.yaml"))
        try Data("learned words".utf8).write(to: initial.appendingPathComponent("test.userdb.txt"))
        let data = Data("fixture".utf8)
        let files = ["recipe.yaml", "LICENSE", "test.schema.yaml"].map {
            RecipeManifest.File(
                path: $0, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        }
        let manifest = RecipeManifest(
            id: "fixture", repository: "test/fixture", revision: String(repeating: "a", count: 40),
            recipePath: "recipe.yaml", license: "test", schemaID: "test", requiredComponents: ["lua_filter"],
            files: files)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"), fetch: { _ in data })
        let deploy: RecipePackageManager.Deploy = { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try data.write(to: build.appendingPathComponent("test.schema.yaml"))
            return RecipeDeploymentReceipt(availableComponents: ["lua_filter"], validatedSchemaID: "test")
        }
        let first = try await manager.install(manifest, initialUserDataURL: initial, deploy: deploy)
        let activeUser = try await manager.activeUserDataURL()
        let user = try XCTUnwrap(activeUser)
        XCTAssertEqual(try Data(contentsOf: user.appendingPathComponent("test.userdb.txt")), Data("learned words".utf8))
        try Data("new learned words".utf8).write(to: user.appendingPathComponent("test.userdb.txt"))
        do {
            try await manager.update(manifest) { _ in throw RecipeInstallError.deployment("injected failure") }
            XCTFail("Should retain active generation on failed deploy")
        } catch {}
        let failed = try await manager.status()
        XCTAssertEqual(failed.active?.generation, first.generation)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store/versions").path)
                .count, 1)
        let second = try await manager.update(manifest, deploy: deploy)
        XCTAssertNotEqual(second.generation, first.generation)
        let updatedUser = try await manager.activeUserDataURL()
        let updated = try XCTUnwrap(updatedUser)
        XCTAssertEqual(
            try Data(contentsOf: updated.appendingPathComponent("test.userdb.txt")), Data("new learned words".utf8))
        XCTAssertEqual(
            try Data(contentsOf: updated.appendingPathComponent("default.custom.yaml")),
            try Data(contentsOf: initial.appendingPathComponent("default.custom.yaml")))
        // Missing Lua must not activate, even when the bridge otherwise says deployment succeeded.
        do {
            try await manager.update(manifest) { _ in
                RecipeDeploymentReceipt(availableComponents: [], validatedSchemaID: "test")
            }
            XCTFail("Missing component must fail")
        } catch RecipeInstallError.missingComponents(let values) { XCTAssertEqual(values, ["lua_filter"]) }
        let afterMissing = try await manager.status()
        XCTAssertEqual(afterMissing.active?.generation, second.generation)
        // A new install keeps only the active generation and its own.
        let third = try await manager.update(manifest, deploy: deploy)
        let kept = try FileManager.default.contentsOfDirectory(
            atPath: root.appendingPathComponent("store/versions").path)
        XCTAssertEqual(Set(kept), [second.generation, third.generation])
    }

    func testUnsupportedNativeProcessorIsNotRewrittenBeforeDeployment() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("unsupported-component-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let initial = root.appendingPathComponent("initial")
        try fm.createDirectory(at: initial, withIntermediateDirectories: true)
        let marker = Data("user data".utf8)
        try marker.write(to: initial.appendingPathComponent("user.txt"))
        let schema = Data(
            "schema: {schema_id: t9}\nengine:\n  processors: [t9_processor, speller, express_editor]\n".utf8)
        let source = [
            "recipe.yaml": Data("recipe: {Rx: install}".utf8),
            "LICENSE": Data("fixture license".utf8), "t9.schema.yaml": schema,
        ]
        let records = source.keys.sorted().map { path in
            RecipeManifest.File(
                path: path,
                sha256: SHA256.hash(data: source[path]!).map { String(format: "%02x", $0) }.joined(),
                size: source[path]!.count)
        }
        let manifest = RecipeManifest(
            id: "unsupported", repository: "owner/unsupported",
            revision: String(repeating: "a", count: 40), recipePath: "recipe.yaml", license: "fixture",
            schemaID: "t9", requiredComponents: [], files: records)
        let manager = RecipePackageManager(
            rootURL: root.appendingPathComponent("store"),
            fetch: { url in
                guard let data = source[url.lastPathComponent] else {
                    throw RecipeInstallError.invalidResource(url.lastPathComponent)
                }
                return data
            })
        do {
            _ = try await manager.install(manifest, initialUserDataURL: initial) { deployment in
                XCTAssertEqual(
                    try Data(contentsOf: deployment.resourceURL.appendingPathComponent("t9.schema.yaml")), schema)
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath:
                            deployment.userDataURL.appendingPathComponent("t9.custom.yaml").path))
                throw RecipeInstallError.missingComponents(["t9_processor"])
            }
            XCTFail("Unavailable component must reject deployment")
        } catch RecipeInstallError.missingComponents(let missing) {
            XCTAssertEqual(missing, ["t9_processor"])
        }
        let status = try await manager.status()
        XCTAssertNil(status.active)
        XCTAssertEqual(try Data(contentsOf: initial.appendingPathComponent("user.txt")), marker)
    }

    /// The installed-package rerun UI path: replan on the captured workspace with the
    /// generation baseline, compose resource-then-config via appending, keep user custom.
    func testInstalledWorkspaceRerunComposesResourceThenConfig() throws {
        let resources = [
            "recipe.yaml": Data("recipe:\n  Rx: all\ninstall_files: >-\n  default.yaml\n  rime_ice.schema.yaml\n".utf8),
            "default.yaml": Data("config_version: '1'\nschema_list:\n  - schema: rime_ice\n".utf8),
            "rime_ice.schema.yaml": Data("schema:\n  schema_id: rime_ice\n".utf8),
            "others/recipes/config.recipe.yaml": Data(
                """
                recipe:
                  Rx: others/recipes/config
                  args:
                    - schema=rime_ice
                patch_files:
                  default.custom.yaml:
                    - patch/+:
                        schema_list:
                          - schema: ${schema:-rime_ice}
                """.utf8),
        ]
        let userCustom = "# user sentinel\npatch:\n  menu/page_size: 9\n"
        var workspace = resources
        workspace["default.custom.yaml"] = Data(userCustom.utf8)
        let generation = "gen-baseline-1"
        let root = try DeclarativeRecipe(path: "recipe.yaml", source: workspace["recipe.yaml"]!)
        let config = try DeclarativeRecipe(
            path: "others/recipes/config.recipe.yaml", source: workspace["others/recipes/config.recipe.yaml"]!)
        func compose(schema: String) throws -> DeclarativeRecipePlan {
            let base = try DeclarativeRecipePlan(
                recipe: root, packageReference: "user/pkg",
                selectedRecipe: "", arguments: [], packageFiles: resources, existingFiles: workspace,
                sourceRevision: "rev1", expectedGeneration: generation)
            return try base.appending(
                recipe: config, packageReference: "user/pkg",
                selectedRecipe: config.declaredName ?? "", arguments: [.init("schema", schema)],
                packageFiles: resources, sourceRevision: "rev1")
        }
        let plan = try compose(schema: "double_pinyin_flypy")
        XCTAssertEqual(plan.expectedGeneration, generation, "composed plan must retain the original baseline")
        XCTAssertEqual(plan.stageReceipts.count, 2, "both stages recorded")
        let custom = String(data: plan.files["default.custom.yaml"]!, encoding: .utf8)!
        XCTAssertTrue(
            custom.contains("# user sentinel") && custom.contains("page_size: 9"), "user custom bytes must be retained")
        XCTAssertTrue(custom.contains("schema: double_pinyin_flypy"), "config patch applied")
        // Same-parameter rerun is idempotent on the previous output (Rx managed block).
        var rerunWorkspace = workspace
        rerunWorkspace["default.custom.yaml"] = Data(custom.utf8)
        let rerunBase = try DeclarativeRecipePlan(
            recipe: root, packageReference: "user/pkg",
            selectedRecipe: "", arguments: [], packageFiles: resources, existingFiles: rerunWorkspace,
            sourceRevision: "rev1", expectedGeneration: generation)
        let rerun = try rerunBase.appending(
            recipe: config, packageReference: "user/pkg",
            selectedRecipe: config.declaredName ?? "", arguments: [.init("schema", "double_pinyin_flypy")],
            packageFiles: resources, sourceRevision: "rev1")
        XCTAssertEqual(
            rerun.files["default.custom.yaml"], plan.files["default.custom.yaml"], "same Rx rerun must be idempotent")
        // Changing the parameter on the ALREADY-CONFIGURED workspace keeps the old managed
        // block and appends the new one (different invocations are retained).
        var configured = workspace
        configured["default.custom.yaml"] = plan.files["default.custom.yaml"]
        let changedBase = try DeclarativeRecipePlan(
            recipe: root, packageReference: "user/pkg",
            selectedRecipe: "", arguments: [], packageFiles: resources, existingFiles: configured,
            sourceRevision: "rev1", expectedGeneration: generation)
        let changed = try changedBase.appending(
            recipe: config, packageReference: "user/pkg",
            selectedRecipe: config.declaredName ?? "", arguments: [.init("schema", "rime_ice")],
            packageFiles: resources, sourceRevision: "rev1")
        let changedCustom = String(data: changed.files["default.custom.yaml"]!, encoding: .utf8)!
        XCTAssertTrue(
            changedCustom.contains("user/pkg:others/recipes/config:schema=double_pinyin_flypy"),
            "previous Rx block retained")
        XCTAssertTrue(changedCustom.contains("user/pkg:others/recipes/config:schema=rime_ice"), "new Rx block applied")
        XCTAssertEqual(changed.retainedDifferentInvocations, ["default.custom.yaml"])
        XCTAssertTrue(
            changedCustom.contains("# user sentinel") && changedCustom.contains("page_size: 9"),
            "user bytes still retained after reparameterisation")
    }

    /// The fresh-import UI path: plan a package recipe against an empty workspace.
    /// Contract semantics verified here: patch-only recipes do NOT copy package sources into
    /// the output (only install_files/down­loads do), source snapshot is never mutated,
    /// downloads must be explicitly provided, and over-budget models are loudly rejected.
    func testFreshImportRecipePlanFromEmptyWorkspace() throws {
        let recipe = try DeclarativeRecipe(
            path: "others/recipes/config.recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: others/recipes/config
                  args:
                    - schema=rime_ice
                patch_files:
                  default.custom.yaml:
                    - patch/+:
                        schema_list:
                          - schema: ${schema:-rime_ice}
                """.utf8))
        let sourceFiles = [
            "default.yaml": Data("config_version: '1'\nschema_list:\n  - schema: rime_ice\n".utf8),
            "rime_ice.schema.yaml": Data("schema:\n  schema_id: rime_ice\n".utf8),
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/import",
            selectedRecipe: recipe.declaredName ?? "", arguments: [.init("schema", "double_pinyin_flypy")],
            packageFiles: sourceFiles, existingFiles: [:])
        let patched = plan.files["default.custom.yaml"]
        XCTAssertNotNil(patched)
        XCTAssertTrue(String(data: patched!, encoding: .utf8)!.contains("schema: double_pinyin_flypy"))
        // Patch-only recipes copy nothing from packageFiles: plum semantics.
        XCTAssertNil(plan.files["default.yaml"])
        XCTAssertNil(plan.files["rime_ice.schema.yaml"])
        // A root recipe installs sources through install_files.
        let root = try DeclarativeRecipe(
            path: "recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: all
                install_files: >-
                  default.yaml
                  rime_ice.schema.yaml
                """.utf8))
        let rootPlan = try DeclarativeRecipePlan(
            recipe: root, packageReference: "user/import",
            selectedRecipe: "", arguments: [], packageFiles: sourceFiles, existingFiles: [:])
        XCTAssertEqual(rootPlan.files["default.yaml"], sourceFiles["default.yaml"])
        XCTAssertEqual(rootPlan.files["rime_ice.schema.yaml"], sourceFiles["rime_ice.schema.yaml"])
        XCTAssertEqual(plan.rx, "user/import:others/recipes/config:schema=double_pinyin_flypy")
        // Grammar-style plans surface as a real prerequisite, not as an invented model state.
        let grammar = try DeclarativeRecipe(
            path: "grammar.recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: grammar
                download_files:
                  - model.gram::https://example.invalid/model.gram
                install_files:
                  - model.gram
                patch_files:
                  rime_ice.custom.yaml:
                    - patch/+:
                        grammar:
                          language: model
                """.utf8))
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: grammar, packageReference: "user/import",
                selectedRecipe: "grammar", arguments: [], packageFiles: sourceFiles, existingFiles: [:])
        ) { error in
            XCTAssertTrue("\(error)".contains("缺少配置所需的外部文件"), "missing download must be a loud error, got: \(error)")
        }
        // Contract: models must be supplied as file references, never as inline bytes
        // (sized like a real ~420 MB grammar model).
        let oversized = Data(count: 420_339_756)
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: grammar, packageReference: "user/import",
                selectedRecipe: "grammar", arguments: [], packageFiles: sourceFiles, existingFiles: [:],
                providedDownloads: ["model.gram": oversized])
        ) { error in
            XCTAssertTrue(
                "\(error)".contains("外部文件引用"), "oversized inline model must demand a file reference, got: \(error)")
        }
    }
}
