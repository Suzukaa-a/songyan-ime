import CryptoKit
import XCTest

@testable import PackageManager

final class RecipeInstallTests: XCTestCase {
    func testInstalledCatalogOptionalRecipesSingleStepRerunAndOriginalPool() async throws {
        let (root, original) = try fixture()
        let config = try DeclarativeRecipe(
            path: "config.recipe.yaml",
            source: Data(
                "recipe:\n  Rx: config\n  args:\n    - schema\npatch_files:\n  a.custom.yaml:\n    - test: ${schema:-a}\n"
                    .utf8))
        let optional = Data("recipe:\n  Rx: optional\n".utf8)
        let inputs = [
            "a.schema.yaml": original.files["a.schema.yaml"]!, "b.schema.yaml": original.files["b.schema.yaml"]!,
            "recipe.yaml": original.recipeSource, "config.recipe.yaml": config.source, "optional.recipe.yaml": optional,
        ]
        let args = [RecipeArgument("schema", ""), RecipeArgument("extra", "one"), RecipeArgument("extra", "two")]
        let plan = try DeclarativeRecipePlan(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: original.recipeSource),
            packageReference: "test", selectedRecipe: "", arguments: [], packageFiles: inputs, existingFiles: [:]
        )
        .appending(
            recipe: config, packageReference: "test", selectedRecipe: "config", arguments: args, packageFiles: inputs)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        try await manager.installRecipePlan(plan, packageID: "test", schemaID: "b", deploy: { try Self.deploy($0) })
        let active = try await manager.activeInstallation()!
        let sources = try RecipePackageManager.readInstalledRecipeSources(resources: active.resourceURL)
        XCTAssertEqual(sources.files, inputs)
        XCTAssertNil(sources.files["default.yaml"], "frontend supplement must not enter original pool")
        XCTAssertEqual(sources.receipts.last?.arguments, args)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: active.resourceURL.appendingPathComponent("optional.recipe.yaml").path))
        let workspace = try RecipePackageManager.readRecipeWorkspaceSnapshot(
            resources: active.resourceURL, userConfiguration: active.userDataURL)
        let rerun = try DeclarativeRecipePlan(
            recipe: config, packageReference: "test", selectedRecipe: "config", arguments: args,
            packageFiles: sources.files, existingFiles: workspace.files,
            expectedGeneration: active.installation.generation,
            userCustomBaseline: workspace.userCustomFiles)
        try await manager.installRecipePlan(rerun, packageID: "test", schemaID: "b", deploy: { try Self.deploy($0) })
        let next = try await manager.activeInstallation()!
        let catalog = try RecipePackageManager.readInstalledRecipeSources(resources: next.resourceURL)
        XCTAssertEqual(catalog.files, inputs)
        XCTAssertEqual(catalog.receipts.map(\.recipePath), ["recipe.yaml", "config.recipe.yaml"])
        XCTAssertEqual(catalog.receipts.last?.arguments, args)
        XCTAssertEqual(
            try Data(contentsOf: next.userDataURL.appendingPathComponent("a.custom.yaml")),
            workspace.userCustomFiles["a.custom.yaml"])
    }

    func testExplicitRecipeSourceWinsAndInvalidatesOnlyItsOldArguments() throws {
        let (_, plan) = try fixture()
        let old = InstalledRecipeSources.merging(nil, plan: plan)
        let replacement = Data("recipe:\n  Rx: replacement\n".utf8)
        let optional = try DeclarativeRecipe(
            path: "optional.recipe.yaml", source: Data("recipe:\n  Rx: optional\n".utf8))
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: optional, packageReference: "test", selectedRecipe: "optional", arguments: [],
                packageFiles: [optional.path: replacement], existingFiles: [:]))
        let update = try DeclarativeRecipePlan(
            recipe: optional, packageReference: "test", selectedRecipe: "optional", arguments: [],
            packageFiles: ["recipe.yaml": replacement], existingFiles: [:])
        let merged = InstalledRecipeSources.merging(old, plan: update)
        XCTAssertEqual(merged.files["recipe.yaml"], replacement)
        XCTAssertEqual(merged.receipts.map(\.recipePath), ["optional.recipe.yaml"])
        XCTAssertNil(merged.files["a.schema.yaml"], "removed original resources must not resurrect on update")
    }

    func testGenerationWithoutCatalogOnlyContributesItsRecipeFiles() async throws {
        let (root, plan) = try fixture()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        try await manager.installRecipePlan(plan, packageID: "test", schemaID: "b", deploy: { try Self.deploy($0) })
        let active = try await manager.activeInstallation()!
        let generation = active.resourceURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: generation.appendingPathComponent("recipe-catalog.json"))
        let sources = try RecipePackageManager.readInstalledRecipeSources(resources: active.resourceURL)
        XCTAssertTrue(sources.receipts.isEmpty)
        XCTAssertNil(sources.files["a.schema.yaml"])
    }

    /// Mirrors the compact-keyboard regeneration: a no-op recipe replanned from the installed
    /// generation must not rewrite the model, neither into resources nor into the recipe inputs.
    func testRegenerationClonesModelsInsteadOfRewritingThem() async throws {
        let (root, _) = try fixture()
        try BoundedLocalFileTests.requireCloning(root)
        let model = root.appendingPathComponent("model.gram")
        try Data((0..<(2 * RecipeResourceBudget.bufferBytes)).map { UInt8(truncatingIfNeeded: $0) }).write(to: model)
        let resource = try RecipeFileResource.reference(at: model)
        let recipeBytes = Data(
            "recipe:\n  Rx: all\ninstall_files: >-\n  a.schema.yaml\n  b.schema.yaml\n  model.gram\n".utf8)
        let inputs = [
            "recipe.yaml": recipeBytes, "a.schema.yaml": Data("schema: {schema_id: a}".utf8),
            "b.schema.yaml": Data("schema: {schema_id: b}".utf8),
        ]
        let first = try DeclarativeRecipePlan(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: recipeBytes), packageReference: "user/test",
            selectedRecipe: "", arguments: [], packageFiles: inputs, existingFiles: [:],
            packageFileResources: ["model.gram": resource])
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        try await manager.installRecipePlan(first, packageID: "test", schemaID: "b", deploy: { try Self.deploy($0) })
        let installed = try await manager.activeInstallation()
        let active = try XCTUnwrap(installed)
        let snapshot = try RecipePackageManager.readRecipeWorkspaceSnapshot(
            resources: active.resourceURL, userConfiguration: active.userDataURL)
        let sources = try RecipePackageManager.readInstalledRecipeSources(resources: active.resourceURL)
        XCTAssertNotNil(snapshot.fileResources["model.gram"])
        let recipe = try DeclarativeRecipe(
            path: "keyboard-adapters.recipe.yaml", source: Data("recipe:\n  Rx: keyboard-adapters\n".utf8))
        let again = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test", selectedRecipe: "keyboard-adapters", arguments: [],
            packageFiles: sources.files, existingFiles: snapshot.files, sourceRevision: active.installation.revision,
            expectedGeneration: active.installation.generation, packageFileResources: sources.fileResources,
            existingFileResources: snapshot.fileResources, userCustomBaseline: snapshot.userCustomFiles)
        try await manager.installRecipePlan(again, packageID: "test", schemaID: "b", deploy: { try Self.deploy($0) })
        let regenerated = try await manager.activeInstallation()
        let next = try XCTUnwrap(regenerated)
        XCTAssertNotEqual(next.installation.generation, active.installation.generation)
        let generation = next.resourceURL.deletingLastPathComponent()
        let copies = [
            next.resourceURL.appendingPathComponent("model.gram"),
            generation.appendingPathComponent("recipe-inputs/model.gram"),
        ]
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: model))
            XCTAssertTrue(try BoundedLocalFileTests.sharesBlocks(model, copy), copy.path)
        }
    }

    private func fixture(_ suffix: String = "") throws -> (URL, DeclarativeRecipePlan) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = Data("recipe:\n  Rx: all\ninstall_files: >-\n  a.schema.yaml\n  b.schema.yaml\n".utf8)
        let files = [
            "a.schema.yaml": Data("schema: {schema_id: a}".utf8), "b.schema.yaml": Data("schema: {schema_id: b}".utf8),
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: source),
            packageReference: "user/test", selectedRecipe: "", arguments: [], packageFiles: files, existingFiles: [:])
        return (root, plan)
    }

    private static func deploy(_ deployment: RecipeDeployment) throws -> RecipeDeploymentReceipt {
        let build = deployment.userDataURL.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("schema_list: [{schema: b}]".utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: b}".utf8).write(to: build.appendingPathComponent("b.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "b", validatedEnabledSchemaIDs: ["b"])
    }

    func testEffectiveEntryAndReceiptMismatch() async throws {
        let (root, plan) = try fixture()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let installed = try await manager.installRecipePlan(
            plan, packageID: "test", schemaID: "a", deploy: { try Self.deploy($0) })
        XCTAssertEqual(installed.schemaID, "b")
        let other = RecipePackageManager(rootURL: root.appendingPathComponent("other"))
        do {
            try await other.installRecipePlan(plan, packageID: "test", schemaID: "a") { deployment in
                _ = try Self.deploy(deployment)
                return .init(availableComponents: [], validatedSchemaID: "a", validatedEnabledSchemaIDs: ["a", "b"])
            }
            XCTFail("Must reject receipt not matching deployed enabled inventory")
        } catch {}
        let status = try await other.status()
        XCTAssertNil(status.active)
    }

    func testCompleteCustomDeletionAdditionAndIntentionalOverwrite() async throws {
        for mutation in ["delete", "add", "none"] {
            let (root, original) = try fixture()
            let user = root.appendingPathComponent("user")
            try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            let old = Data("patch: {menu/page_size: 9}".utf8)
            let custom = user.appendingPathComponent("a.custom.yaml")
            try old.write(to: custom)
            let baseline = try RecipePackageManager.readUserCustomFiles(at: user)
            var files = original.files
            files["a.custom.yaml"] = Data("patch: {menu/page_size: 5}".utf8)
            let recipe = try DeclarativeRecipe(
                path: "recipe.yaml", source: Data("recipe:\n  Rx: all\ninstall_files: >-\n  *.yaml\n".utf8))
            let plan = try DeclarativeRecipePlan(
                recipe: recipe, packageReference: "user/test", selectedRecipe: "", arguments: [],
                packageFiles: files, existingFiles: ["a.custom.yaml": old], userCustomBaseline: baseline)
            // Rename our fixture to model deletion without deleting any user-owned directory.
            if mutation == "delete" {
                try FileManager.default.moveItem(at: custom, to: user.appendingPathComponent("removed.txt"))
            }
            if mutation == "add" { try old.write(to: user.appendingPathComponent("extra.custom.yaml")) }
            let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
            do {
                _ = try await manager.installRecipePlan(
                    plan, packageID: "test", schemaID: "a", initialUserDataURL: user, deploy: { try Self.deploy($0) })
                XCTAssertEqual(mutation, "none")
                let active = try await manager.activeUserDataURL()!
                XCTAssertEqual(
                    try Data(contentsOf: active.appendingPathComponent("a.custom.yaml")), files["a.custom.yaml"])
            } catch {
                XCTAssertNotEqual(mutation, "none", "Intentional install_files overwrite must succeed: \(error)")
            }
            XCTAssertEqual(
                try Data(
                    contentsOf: user.appendingPathComponent(mutation == "delete" ? "removed.txt" : "a.custom.yaml")),
                old)
        }
    }

    func testCancellationBeforeCommitKeepsActiveEmpty() async throws {
        let (root, plan) = try fixture()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let task = Task {
            try await manager.installRecipePlan(plan, packageID: "test", schemaID: "a") { deployment in
                let receipt = try Self.deploy(deployment)
                withUnsafeCurrentTask { $0?.cancel() }
                return receipt
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled before commit")
        } catch is CancellationError {}
        let status = try await manager.status()
        XCTAssertNil(status.active)
    }

    func testSnapshotLeaseAndHashFailureReleaseOnlyOwnedFile() throws {
        let (root, _) = try fixture()
        let source = root.appendingPathComponent("source.gram")
        try Data("model fixture".utf8).write(to: source)
        let staging = root.appendingPathComponent("staging")
        var resource: RecipeFileResource? = try .snapshot(from: source, directory: staging)
        let url = resource!.url
        var retained = [resource!]
        resource = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(retained[0].url, url)
        retained.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try RecipeFileResource.snapshot(from: source, directory: staging, expectedSHA256: "bad"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testBuildPlaceholderSurvivesDirectoryImport() async throws {
        let (root, plan) = try fixture()
        for (path, bytes) in plan.files {
            let destination = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination)
        }
        let build = root.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data().write(to: build.appendingPathComponent(".gitkeep"))
        try Data("stale".utf8).write(to: build.appendingPathComponent("a.schema.yaml"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let prepared = try manager.prepareSchemeImport(directory: root)
        XCTAssertEqual(prepared.sourceFiles["build/.gitkeep"], Data())
        XCTAssertNil(prepared.sourceFiles["build/a.schema.yaml"])
    }

    /// Host wiring contract: a scheme-import receipt must report the FULL enabled
    /// inventory and an entry that belongs to it; a partial or superset receipt is rejected
    /// before commit, and the committed InstalledRecipe keeps the deployed entry.
    func testUserSchemeReceiptFullEnabledSet() async throws {
        let (root, _) = try fixture()
        let data = Data("fixture".utf8)
        let files = ["recipe.yaml", "LICENSE", "a.schema.yaml", "b.schema.yaml", "default.yaml"].map {
            RecipeManifest.File(
                path: $0, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        }
        let manifest = RecipeManifest(
            id: "pkg", repository: "user/import", revision: String(repeating: "a", count: 40),
            recipePath: "recipe.yaml", license: "test", schemaID: "a",
            requiredComponents: [], files: files, origin: .userScheme)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        func deploy(enabled: [String], entry: String) -> RecipePackageManager.Deploy {
            { deployment in
                let build = deployment.userDataURL.appendingPathComponent("build")
                try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                try Data("schema_list: [{schema: b}, {schema: a}]".utf8).write(
                    to: build.appendingPathComponent("default.yaml"))
                try data.write(to: build.appendingPathComponent("a.schema.yaml"))
                try data.write(to: build.appendingPathComponent("b.schema.yaml"))
                return .init(availableComponents: [], validatedSchemaID: entry, validatedEnabledSchemaIDs: enabled)
            }
        }
        // Superset receipt (claims a schema the config does not enable) must be rejected.
        do {
            _ = try await manager.installResources(
                manifest, initialUserDataURL: nil, deploy: deploy(enabled: ["a", "b", "ghost"], entry: "b"),
                read: { _ in data })
            XCTFail("Receipt with extra schema must be rejected")
        } catch {}
        let afterSuperset = try await manager.status()
        XCTAssertNil(afterSuperset.active)
        // userScheme commits the effective entry from the full deployed receipt.
        let installed = try await manager.installResources(
            manifest, initialUserDataURL: nil,
            deploy: deploy(enabled: ["a", "b"], entry: "b"), read: { _ in data })
        XCTAssertEqual(installed.schemaID, "b")
    }

    func testDeclaredEntrySurvivesReversedEnumerationAndMissingEntryAborts() async throws {
        let (root, _) = try fixture()
        let data = Data("fixture".utf8)
        let files = ["recipe.yaml", "LICENSE", "a.schema.yaml", "b.schema.yaml", "default.yaml"].map {
            RecipeManifest.File(
                path: $0, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        }
        let manifest = RecipeManifest(
            id: "pkg", repository: "user/recipe", revision: String(repeating: "b", count: 40),
            recipePath: "recipe.yaml", license: "test", schemaID: "b",
            requiredComponents: [], files: files, origin: .userRecipe)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        func deploy(_ enabled: [String]) -> RecipePackageManager.Deploy {
            { deployment in
                let entry = try deployment.declaredEntry(in: enabled)
                let build = deployment.userDataURL.appendingPathComponent("build")
                try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                try Data("schema_list: [{schema: a}, {schema: b}]".utf8).write(
                    to: build.appendingPathComponent("default.yaml"))
                for id in ["a", "b"] {
                    try Data("schema: {schema_id: \(id)}".utf8).write(
                        to: build.appendingPathComponent("\(id).schema.yaml"))
                }
                return .init(availableComponents: [], validatedSchemaID: entry, validatedEnabledSchemaIDs: enabled)
            }
        }
        do {
            _ = try await manager.installResources(
                manifest, initialUserDataURL: nil,
                deploy: deploy(["a"]), read: { _ in data })
            XCTFail("Missing declared entry must reject before committing")
        } catch {
            let status = try await manager.status()
            XCTAssertNil(status.active)
        }
        let installed = try await manager.installResources(
            manifest, initialUserDataURL: nil,
            deploy: deploy(["a", "b"]), read: { _ in data })
        let sourceURL = root.appendingPathComponent("store/versions/\(installed.generation)/source.json")
        let source = try JSONDecoder().decode(RecipeManifest.self, from: Data(contentsOf: sourceURL))
        XCTAssertEqual(source.schemaID, "b")
        XCTAssertEqual(installed.schemaID, source.schemaID)
    }

    func testDeclaredEntryUpdateRejectsMissingEntryWithoutReplacingActive() async throws {
        let (root, _) = try fixture()
        let data = Data("fixture".utf8)
        let files = ["recipe.yaml", "LICENSE", "a.schema.yaml", "b.schema.yaml", "default.yaml"].map {
            RecipeManifest.File(
                path: $0, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
        }
        func manifest(_ revision: String) -> RecipeManifest {
            RecipeManifest(
                id: "pkg", repository: "user/recipe", revision: String(repeating: revision, count: 40),
                recipePath: "recipe.yaml", license: "test", schemaID: "b",
                requiredComponents: [], files: files, origin: .userRecipe)
        }
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        func deploy(_ enabled: [String]) -> RecipePackageManager.Deploy {
            { deployment in
                let entry = try deployment.declaredEntry(in: enabled)
                let build = deployment.userDataURL.appendingPathComponent("build")
                try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                try Data("schema_list: [{schema: a}, {schema: b}]".utf8).write(
                    to: build.appendingPathComponent("default.yaml"))
                for id in ["a", "b"] {
                    try Data("schema: {schema_id: \(id)}".utf8).write(
                        to: build.appendingPathComponent("\(id).schema.yaml"))
                }
                return .init(availableComponents: [], validatedSchemaID: entry, validatedEnabledSchemaIDs: enabled)
            }
        }
        let original = try await manager.installResources(
            manifest("c"), initialUserDataURL: nil,
            deploy: deploy(["a", "b"]), read: { _ in data })
        XCTAssertEqual(original.schemaID, "b")
        do {
            _ = try await manager.installResources(
                manifest("d"), initialUserDataURL: nil,
                deploy: deploy(["a"]), read: { _ in data })
            XCTFail("An update without the declared entry must not replace the active installation")
        } catch {}
        let afterFailure = try await manager.status()
        XCTAssertEqual(afterFailure.active?.generation, original.generation)
        let updated = try await manager.installResources(
            manifest("d"), initialUserDataURL: nil,
            deploy: deploy(["a", "b"]), read: { _ in data })
        XCTAssertNotEqual(updated.generation, original.generation)
        XCTAssertEqual(updated.schemaID, "b")
        let sourceURL = root.appendingPathComponent("store/versions/\(updated.generation)/source.json")
        XCTAssertEqual(
            try JSONDecoder().decode(RecipeManifest.self, from: Data(contentsOf: sourceURL)).schemaID,
            updated.schemaID)
    }

    /// Host wiring contract: ordinary declared downloads flow as Data; omitted
    /// arguments stay omitted (empty value ≠ default expansion); a non-root recipe whose
    /// declared Rx mismatches its path stem is rejected before any install happens.
    func testOrdinaryDownloadsAndRxSemantics() throws {
        let grammar = try DeclarativeRecipe(
            path: "grammar.recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: grammar
                download_files:
                  - notes.txt::https://example.invalid/notes.txt
                install_files:
                  - notes.txt
                patch_files:
                  a.custom.yaml:
                    - patch/+:
                        x: ${v:-fallback}
                """.utf8))
        let sources = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8)]
        let plan = try DeclarativeRecipePlan(
            recipe: grammar, packageReference: "user/test",
            selectedRecipe: "grammar", arguments: [], packageFiles: sources, existingFiles: [:],
            providedDownloads: ["notes.txt": Data("bytes".utf8)])
        XCTAssertEqual(plan.files["notes.txt"], Data("bytes".utf8), "ordinary download bytes install like sources")
        XCTAssertNil(plan.fileResources["notes.txt"], "non-model downloads must not require file references")
        let custom = String(data: plan.files["a.custom.yaml"]!, encoding: .utf8)!
        XCTAssertTrue(
            custom.contains("x: fallback"), "omitted arg must expand the :- default, not become explicit empty")
        // Explicit empty is distinct: ${v:-…} still falls back per plum, but Rx records the empty.
        let explicitEmpty = try DeclarativeRecipePlan(
            recipe: grammar, packageReference: "user/test",
            selectedRecipe: "grammar", arguments: [.init("v", "")], packageFiles: sources, existingFiles: [:],
            providedDownloads: ["notes.txt": Data("bytes".utf8)])
        XCTAssertEqual(explicitEmpty.rx, "user/test:grammar:v=", "explicit empty argument is preserved in Rx")
        // Mismatched Rx (plum check_recipe_info): file stem != declared Rx rejects.
        let misnamed = try DeclarativeRecipe(
            path: "grammar.recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: something_else
                install_files: >-
                  a.schema.yaml
                """.utf8))
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: misnamed, packageReference: "user/test",
                selectedRecipe: "grammar", arguments: [], packageFiles: sources, existingFiles: [:],
                providedDownloads: [:])
        ) { error in
            XCTAssertTrue("\(error)".contains("配置文件路径不一致"), "expected Rx mismatch error, got: \(error)")
        }
    }

    /// Host wiring contract: the UI's omit / explicit-empty / explicit-value tristate
    /// maps onto three distinct plans. The Rx fingerprint distinguishes them, so an install
    /// fingerprint check (PlanInputs) rejects running a stale plan after an edit: any change
    /// of the argument list changes the Rx, and ordered duplicate declarations stay ordered.
    func testArgumentTristateDistinctRxAndOrderedDuplicates() throws {
        let recipe = try DeclarativeRecipe(
            path: "config.recipe.yaml",
            source: Data(
                """
                recipe:
                  Rx: config
                  args:
                    - schema=a
                    - schema=b
                patch_files:
                  a.custom.yaml:
                    - patch/+:
                        x: ${schema:-fallback}
                """.utf8))
        let sources = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8)]
        func plan(_ arguments: [RecipeArgument]) throws -> DeclarativeRecipePlan {
            try DeclarativeRecipePlan(
                recipe: recipe, packageReference: "user/test",
                selectedRecipe: "config", arguments: arguments, packageFiles: sources, existingFiles: [:])
        }
        // Omitted (UI switch off): not in Rx, :- fallback expands.
        let omitted = try plan([])
        XCTAssertEqual(omitted.rx, "user/test:config:", "omitted arguments are absent from the Rx fingerprint")
        XCTAssertTrue(String(data: omitted.files["a.custom.yaml"]!, encoding: .utf8)!.contains("x: fallback"))
        // Explicit empty (switch on, empty field): recorded as name= in Rx — a distinct plan.
        let explicitEmpty = try plan([.init("schema", "")])
        XCTAssertEqual(explicitEmpty.rx, "user/test:config:schema=")
        // Explicit value (switch on, value): a third distinct fingerprint; ${schema} expands.
        let explicitValue = try plan([.init("schema", "rime_ice")])
        XCTAssertEqual(explicitValue.rx, "user/test:config:schema=rime_ice")
        XCTAssertTrue(String(data: explicitValue.files["a.custom.yaml"]!, encoding: .utf8)!.contains("x: rime_ice"))
        XCTAssertNotEqual(omitted.rx, explicitEmpty.rx, "omit and explicit empty must be different plans")
        XCTAssertNotEqual(explicitEmpty.rx, explicitValue.rx)
        // The three states are unequal as whole receipts too (install fingerprint inputs).
        XCTAssertNotEqual(omitted.arguments, explicitEmpty.arguments)
        XCTAssertNotEqual(explicitEmpty.arguments, explicitValue.arguments)
        // Ordered duplicates: later same-name declaration wins expansion, Rx keeps declaration order.
        let duplicated = try plan([.init("schema", "b"), .init("schema", "a")])
        XCTAssertEqual(duplicated.rx, "user/test:config:schema=b,schema=a", "Rx preserves ordered duplicate arguments")
        XCTAssertTrue(String(data: duplicated.files["a.custom.yaml"]!, encoding: .utf8)!.contains("x: a"))
    }

    /// Host wiring contract: the recipe plan's predicted entry must exist in the plan
    /// output; a config recipe switching schema_list to a schema that IS in the plan must be
    /// installable with the receipt reporting the actually-enabled set.
    func testConfigSwitchedEntrySurvivesPlan() async throws {
        let (root, _) = try fixture()
        let sources = [
            "recipe.yaml": Data(
                "recipe:\n  Rx: all\ninstall_files: >-\n  a.schema.yaml\n  b.schema.yaml\n  default.yaml\n".utf8),
            "default.yaml": Data("config_version: '1'\nschema_list:\n  - schema: a\n".utf8),
            "a.schema.yaml": Data("schema: {schema_id: a}".utf8),
            "b.schema.yaml": Data("schema: {schema_id: b}".utf8),
            "others/recipes/config.recipe.yaml": Data(
                """
                recipe:
                  Rx: others/recipes/config
                patch_files:
                  default.custom.yaml:
                    - patch/+:
                        schema_list:
                          - schema: b
                """.utf8),
        ]
        let rootRecipe = try DeclarativeRecipe(path: "recipe.yaml", source: sources["recipe.yaml"]!)
        let config = try DeclarativeRecipe(
            path: "others/recipes/config.recipe.yaml", source: sources["others/recipes/config.recipe.yaml"]!)
        let plan = try DeclarativeRecipePlan(
            recipe: rootRecipe, packageReference: "user/test",
            selectedRecipe: "", arguments: [], packageFiles: sources, existingFiles: [:]
        )
        .appending(
            recipe: config, packageReference: "user/test",
            selectedRecipe: "others/recipes/config", arguments: [],
            packageFiles: sources)
        let custom = String(data: plan.files["default.custom.yaml"]!, encoding: .utf8)!
        XCTAssertTrue(custom.contains("schema: b"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let installed = try await manager.installRecipePlan(plan, packageID: "test", schemaID: "b") { deployment in
            let build = deployment.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("schema_list: [{schema: b}]".utf8).write(to: build.appendingPathComponent("default.yaml"))
            try Data("schema: {schema_id: b}".utf8).write(to: build.appendingPathComponent("b.schema.yaml"))
            return .init(availableComponents: [], validatedSchemaID: "b", validatedEnabledSchemaIDs: ["b"])
        }
        XCTAssertEqual(installed.schemaID, "b", "effective entry follows the switched schema_list, not source order")
    }
}
