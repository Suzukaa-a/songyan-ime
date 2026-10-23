import XCTest
import ZIPFoundation

@testable import PackageManager

final class RuntimeImportRegressionTests: XCTestCase {
    private var repository: URL {
        (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    }
    private var opencc: URL { repository.appendingPathComponent("Resources/EngineResources/opencc") }

    func testLibrimeReferencesUseParsedNodesAndExternalQualifier() throws {
        var files = [
            "sample.schema.yaml": Data(
                """
                schema: {schema_id: sample}
                algebra_common: [erase/^xx$/]
                algebra_rime_ice: {__include: algebra_common}
                speller: {__include: 'algebra_rime_ice'}
                __patch: [local_patch, ':/local_patch', 'external.yaml:/patch', {menu/page_size: 7}]
                local_patch: {__include: '/algebra_common'}
                optional: {__include: 'absent:/node?'}
                translator: {dictionary: null}
                literal: |
                  __include: not_a_dependency:/node
                """.utf8), "external.yaml": Data("patch: {__include: 'nested/config:/patch'}\n".utf8),
            "nested/config.yaml": Data("patch: {menu/page_size: 5}\n".utf8),
            "others/example.dict.yaml": Data("not a deployed dictionary\n".utf8),
            "others/example.schema.yaml": Data("__include: missing_example:/node\n".utf8),
        ]
        try SchemeSourceCheck.dependencies(files)
        try SchemeSourceCheck.dependencies([
            "sample.dict.yaml": Data("---\r\nname: sample\r\n... # header ends\r\n词\tci\t100\r\n".utf8)
        ])
        files["nested/config.yaml"] = nil
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(files)) { error in
            XCTAssertTrue(String(describing: error).contains("nested/config.yaml"))
            XCTAssertFalse(String(describing: error).contains("algebra_common.yaml"))
        }
        XCTAssertThrowsError(
            try SchemeSourceCheck.dependencies(["s.schema.yaml": Data("__patch: ['../escape:/node']".utf8)]))
    }

    func testRealOpenCCClosureAndSourcePoolIsolation() throws {
        let schema = Data("schema: {schema_id: sample}\nsimplifier: {opencc_config: s2t.json}\n".utf8)
        let source = ["sample.schema.yaml": schema]
        let recipe = try DeclarativeRecipe(
            path: "recipe.yaml", source: Data("recipe:\n  Rx: all\ninstall_files: >-\n  *.schema.yaml\n".utf8))
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "test/sample", selectedRecipe: "", arguments: [], packageFiles: source,
            existingFiles: [:], sharedOpenCCDirectory: opencc)
        try SchemeSourceCheck.dependencies(plan.files)
        XCTAssertEqual(plan.files["opencc/s2t.json"], try Data(contentsOf: opencc.appendingPathComponent("s2t.json")))
        var broken = plan.files
        broken["opencc/STPhrases.ocd2"] = nil
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(broken))
        let override = Data("{\"conversion_chain\":[{\"dict\":{\"type\":\"text\",\"file\":\"private.txt\"}}]}".utf8)
        var custom = source.merging(["opencc/s2t.json": override]) { _, new in new }
        try SharedRimePresets.supplement(&custom, openCCDirectory: opencc)
        XCTAssertEqual(custom["opencc/s2t.json"], override)
        XCTAssertThrowsError(try SchemeSourceCheck.dependencies(custom))
        custom["opencc/private.txt"] = Data("简\t簡\n".utf8)
        try SchemeSourceCheck.dependencies(custom)
        let missingSource = try DeclarativeRecipe(
            path: "recipe.yaml", source: Data("recipe:\n  Rx: all\ninstall_files: >-\n  opencc/s2t.json\n".utf8))
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: missingSource, packageReference: "test/sample", selectedRecipe: "", arguments: [],
                packageFiles: source, existingFiles: plan.files, sharedOpenCCDirectory: opencc))
    }

    func testUnicodeArchivePathsAndTraversalBoundaries() throws {
        for path in ["others/asserts/基础-Emoji_compressed.webp", "说明/输入 方案😀.txt"] {
            XCTAssertTrue(SchemeSourceCheck.safe(path))
        }
        for path in ["../escape", "/absolute", "a/../../b", "C:/drive", "a\\b", "a//b", "a/./b", "a\u{0}b"] {
            XCTAssertFalse(SchemeSourceCheck.safe(path))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: url, accessMode: .create)
        let data = Data("target".utf8)
        try archive.addEntry(
            with: "link", type: .symlink, uncompressedSize: Int64(data.count),
            provider: { position, count in data.subdata(in: Int(position)..<(Int(position) + count)) })
        XCTAssertThrowsError(
            try RecipePackageManager(rootURL: url.deletingLastPathComponent()).prepareSchemeArchive(url))
    }

    func testSingleRepositoryWrapperImportsCompleteScheme() throws {
        let root = repository.appendingPathComponent(".scratch/wrapped-scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("rime-example-master.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let files: [String: Data] = [
            "default.yaml": Data("schema_list:\n  - schema: main\n".utf8),
            "main.schema.yaml": Data("schema: {schema_id: main, name: Main}\ntranslator: {dictionary: main}\n".utf8),
            "main.dict.yaml": Data("---\nname: main\nversion: '1'\n...\n你\tni\t100\n".utf8),
        ]
        for (path, bytes) in files {
            try archive.addEntry(
                with: "rime-example-master/" + path, type: .file,
                uncompressedSize: Int64(bytes.count),
                provider: { position, count in
                    bytes.subdata(in: Int(position)..<(Int(position) + count))
                })
        }
        let prepared = try RecipePackageManager(rootURL: root.appendingPathComponent("store"))
            .prepareSchemeArchive(zip)
        XCTAssertTrue(prepared.schemaIDs.contains("main"))
        XCTAssertEqual(prepared.sourceFiles["main.schema.yaml"], files["main.schema.yaml"])
        XCTAssertNil(prepared.sourceFiles["rime-example-master/main.schema.yaml"])
    }

    /// The package display name comes from the first scheme listed in default.yaml, not the first file by name.
    func testPackageNameFollowsPrimaryListedSchema() throws {
        let root = repository.appendingPathComponent(".scratch/named-scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("named.zip")
        let archive = try Archive(url: zip, accessMode: .create)
        let files: [String: Data] = [
            "default.yaml": Data("schema_list:\n  - schema: main\n  - schema: alpha\n".utf8),
            "main.schema.yaml": Data(
                "schema:\n  schema_id: main\n  name: 主方案\ntranslator: {dictionary: shared}\n".utf8),
            "alpha.schema.yaml": Data(
                "schema:\n  schema_id: alpha\n  name: 次要双拼\ntranslator: {dictionary: shared}\n".utf8),
            "shared.dict.yaml": Data("---\nname: shared\nversion: '1'\n...\n你\tni\t100\n".utf8),
        ]
        for (path, bytes) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(bytes.count),
                provider: { position, count in
                    bytes.subdata(in: Int(position)..<(Int(position) + count))
                })
        }
        let prepared = try RecipePackageManager(rootURL: root.appendingPathComponent("store")).prepareSchemeArchive(zip)
        XCTAssertEqual(prepared.declaration.name, "主方案")
        XCTAssertEqual(prepared.manifest.schemaID, "main")
    }

    /// Exact acceptance artifacts are intentionally external to the source/test bundle.
    func testExactAcceptanceArchivesRecognizeAndPlanResourcesThenConfig() throws {
        guard let fixturesPath = ProcessInfo.processInfo.environment["ACCEPTANCE_FIXTURES_DIR"],
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: fixturesPath).appendingPathComponent("ice-fixed.zip").path)
        else { throw XCTSkip("Set ACCEPTANCE_FIXTURES_DIR to a directory containing the pinned acceptance ZIPs") }
        let fixtures = URL(fileURLWithPath: fixturesPath)
        for (name, hash) in [
            ("ice-fixed.zip", "4c6b9c84115e9aa24cfaf55e389363785451943fe70e4e7670b2ec59fc0056d3"),
            ("ice-recipe-runtime.zip", "9acdfb581a5c25a5a8da97851d4049a5e70c57538c450f9a534cd979f93213c5"),
        ] {
            let url = fixtures.appendingPathComponent(name)
            XCTAssertEqual(SchemeSourceCheck.hash(try Data(contentsOf: url)), hash)
            let manager = RecipePackageManager(
                rootURL: fixtures.appendingPathComponent("unused-store"), sharedOpenCCDirectory: opencc)
            let prepared = try manager.prepareSchemeArchive(url)
            XCTAssertNil(prepared.sourceFiles["opencc/s2t.json"])
            XCTAssertTrue(prepared.schemaIDs.contains("rime_ice"))
            if name == "ice-fixed.zip" {
                XCTAssertNotNil(prepared.sourceFiles["others/asserts/基础-Emoji_compressed.webp"])
            }
            let root = try DeclarativeRecipe(
                path: "recipe.yaml", source: XCTUnwrap(prepared.sourceFiles["recipe.yaml"]))
            var plan = try DeclarativeRecipePlan(
                recipe: root, packageReference: "iDvel/rime-ice", selectedRecipe: "", arguments: [],
                packageFiles: prepared.sourceFiles, existingFiles: [:], sharedOpenCCDirectory: opencc)
            try SchemeSourceCheck.dependencies(plan.files)
            let configPath = "others/recipes/config.recipe.yaml"
            let config = try DeclarativeRecipe(path: configPath, source: XCTUnwrap(prepared.sourceFiles[configPath]))
            plan = try plan.appending(
                recipe: config, packageReference: "iDvel/rime-ice", selectedRecipe: "others/recipes/config",
                arguments: [], packageFiles: prepared.sourceFiles)
            try SchemeSourceCheck.dependencies(plan.files)
            // A source's optional native processor stays in its original schema;
            // the engine validator reports unavailable components for enabled schemes.
            XCTAssertEqual(plan.files["t9.schema.yaml"], prepared.sourceFiles["t9.schema.yaml"])
            XCTAssertNil(plan.files["t9.custom.yaml"])
            try SchemeSourceCheck.dependencies(plan.files)
            let grammarPath = "others/recipes/grammar.recipe.yaml"
            let grammar = try DeclarativeRecipe(path: grammarPath, source: XCTUnwrap(prepared.sourceFiles[grammarPath]))
            XCTAssertEqual(grammar.downloads.map(\.path), ["wanxiang-lts-zh-hans.gram"])
            XCTAssertThrowsError(
                try plan.appending(
                    recipe: grammar, packageReference: "iDvel/rime-ice", selectedRecipe: "others/recipes/grammar",
                    arguments: [], packageFiles: prepared.sourceFiles)
            ) { error in
                XCTAssertTrue(String(describing: error).contains("需显式提供 recipe 外部资源"))
            }
            if let modelPath = ProcessInfo.processInfo.environment["ACCEPTANCE_GRAMMAR_MODEL"],
                FileManager.default.fileExists(atPath: modelPath)
            {
                let modelURL = URL(fileURLWithPath: modelPath)
                let model = try RecipeFileResource.reference(
                    at: modelURL, expectedSHA256: "654d7f1fe4b1bf3d425f8c0a44ac61423ded58c784267b4df03256030d72233f")
                plan = try plan.appending(
                    recipe: grammar, packageReference: "iDvel/rime-ice", selectedRecipe: "others/recipes/grammar",
                    arguments: [], packageFiles: prepared.sourceFiles,
                    providedDownloadFiles: ["wanxiang-lts-zh-hans.gram": model])
                try SchemeSourceCheck.dependencies(plan.files)
                XCTAssertEqual(plan.stageReceipts.count, 3)
                XCTAssertEqual(plan.fileResources["wanxiang-lts-zh-hans.gram"]?.size, 420339756)
                print(
                    "EXACT THREE-STAGE PLAN PASS \(name) model=\(model.sha256) bytes=\(model.size); static preparation only, no engine invocation"
                )
            }
        }
    }
}
