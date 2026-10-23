import XCTest

@testable import PackageManager

final class DictionaryImportTests: XCTestCase {
    func testSupplementaryCompatibilityHanThroughParser() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        // All 542 assigned characters, including both boundaries, retain their bytes.
        let rows = (0x2F800...0x2FA1D).map { "\(Unicode.Scalar($0)!)\tli\n" }.joined()
        let input = try source("name: compatibility\n...\n" + rows, name: "compatibility.dict.yaml", in: root)
        let prepared = try await manager.prepareDictionaryImport(root: input, builtinResources: templates(in: root))
        XCTAssertEqual(prepared.entryCount, 542)
        let generated = String(decoding: prepared.resources["songyan_imported.dict.yaml"]!, as: UTF8.self)
        for value in 0x2F800...0x2FA1D {
            XCTAssertTrue(generated.contains("\(Unicode.Scalar(value)!)\tli\t1\n"))
        }
        for value in [0x2F7FF, 0x2FA1E, 0x2FA1F, 0x2FA20] {
            let invalid = try source("name: a\n...\n\(Unicode.Scalar(value)!)\tli\n", name: "a.dict.yaml", in: root)
            do {
                _ = try await manager.inspectDictionary(invalid)
                XCTFail("Accepted hole U+\(String(value, radix: 16))")
            } catch {}
        }
    }

    func testUnicode17AssignedHanAndStrictValidation() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        for value: UInt32 in [
            0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xFA11, 0x20000, 0x2A6DF,
            0x2B81D, 0x2EE5D, 0x3134A, 0x323B0, 0x3339C, 0x33479,
        ] {
            let input = try source("name: a\n...\n\(Unicode.Scalar(value)!)\tchun\n", name: "a.dict.yaml", in: root)
            let info = try await manager.inspectDictionary(input)
            XCTAssertEqual(info.entryCount, 1)
        }
        for row in [
            "\u{4DC0}\tchun", "\u{2A6E0}\tchun", "\u{2EE5E}\tchun", "\u{3347A}\tchun",
            "😀\tchun", "A\tchun", "\u{E000}\tchun", "𳎜\txyz", "𳎜\tchun\tNaN", "𳎜\tchun chun",
        ] {
            let input = try source("name: a\n...\n\(row)\n", name: "a.dict.yaml", in: root)
            do {
                _ = try await manager.inspectDictionary(input)
                XCTFail("Accepted invalid row: \(row)")
            } catch {}
        }
        let file = root.appendingPathComponent("invalid.dict.yaml")
        for bytes in [Data([0xFF]), Data("name: a\n...\n𳎜\tchun\0\n".utf8)] {
            try bytes.write(to: file)
            do {
                _ = try await manager.inspectDictionary(.init(path: "invalid.dict.yaml", location: file))
                XCTFail("Accepted invalid encoding")
            } catch {}
        }
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictionary-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func source(_ text: String, name: String, in root: URL) throws -> DictionaryImportFile {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return DictionaryImportFile(path: name, location: url)
    }

    private func templates(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent("templates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in ["songyan_quanpin", "songyan_flypy"] {
            try Data(
                "schema:\n  schema_id: \(id)\ntranslator:\n  dictionary: songyan_basic\n  user_dict: songyan_shared\n"
                    .utf8
            )
            .write(to: directory.appendingPathComponent("\(id).schema.yaml"))
        }
        // The bundled compact companions and their schema_list entries must not be copied.
        try Data("schema: {schema_id: keyboard_bundled_14}\n".utf8)
            .write(to: directory.appendingPathComponent("keyboard_bundled_14.schema.yaml"))
        try Data("schema_list: [{schema: songyan_quanpin}, {schema: keyboard_bundled_14}]\n".utf8)
            .write(to: directory.appendingPathComponent("default.yaml"))
        try Data("name: songyan_basic\n...\n你\tni\t1\n".utf8).write(
            to: directory.appendingPathComponent("songyan_basic.dict.yaml"))
        return directory
    }

    func testDependenciesNormalizeAndFailurePreservesLearningAndSelection() async throws {
        let root = try workspace()
        let main = try source(
            "---\nname: main\nversion: '1'\nimport_tables:\n  - dicts/extra\n...\n", name: "main.dict.yaml", in: root)
        let extra = try source(
            "---\nname: extra\nversion: '1'\n...\n绿色\tlǜ sè\t12\n图书馆\ttu shu guan\t22\n", name: "dicts/extra.dict.yaml",
            in: root)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let info = try await manager.inspectDictionary(main)
        XCTAssertEqual(info.dependencies, ["dicts/extra.dict.yaml"])
        let template = try templates(in: root)
        do {
            _ = try await manager.prepareDictionaryImport(root: main, builtinResources: template)
            XCTFail("Dependencies must not be guessed/downloaded")
        } catch DictionaryImportError.missingDependencies(let values) {
            XCTAssertEqual(values, ["dicts/extra.dict.yaml"])
        }
        let prepared = try await manager.prepareDictionaryImport(
            root: main, dependencies: [extra], builtinResources: template)
        XCTAssertEqual(prepared.entryCount, 2)
        XCTAssertTrue(
            String(data: prepared.resources["songyan_imported.dict.yaml"]!, encoding: .utf8)!.contains("绿色\tlv se\t12"))
        XCTAssertTrue(
            String(data: prepared.resources["songyan_flypy.schema.yaml"]!, encoding: .utf8)!.contains(
                "user_dict: songyan_shared"))
        let initial = root.appendingPathComponent("initial")
        try FileManager.default.createDirectory(at: initial, withIntermediateDirectories: true)
        try Data("original learning".utf8).write(to: initial.appendingPathComponent("songyan_shared.userdb.txt"))
        let deploy: RecipePackageManager.Deploy = { d in
            let build = d.userDataURL.appendingPathComponent("build")
            try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
            try Data("compiled fixture".utf8).write(to: build.appendingPathComponent("songyan_quanpin.schema.yaml"))
            return RecipeDeploymentReceipt(
                availableComponents: ["script_translator"], validatedSchemaID: "songyan_quanpin")
        }
        let installed = try await manager.installDictionaryImport(prepared, initialUserDataURL: initial, deploy: deploy)
        let active = try await manager.activeInstallation()!
        XCTAssertEqual(
            try String(contentsOf: active.userDataURL.appendingPathComponent("songyan_shared.userdb.txt")),
            "original learning")
        do {
            try await manager.installDictionaryImport(prepared) { _ in throw RecipeInstallError.deployment("injected") }
            XCTFail("Invalid deployment must not activate")
        } catch {}
        let after = try await manager.activeInstallation()!
        XCTAssertEqual(after.installation.generation, installed.generation)
        XCTAssertEqual(
            try String(contentsOf: after.userDataURL.appendingPathComponent("songyan_shared.userdb.txt")),
            "original learning")

        // A redeploy rebuilds the same dictionary in a new generation and keeps the learning data.
        try Data("learned since".utf8).write(to: after.userDataURL.appendingPathComponent("songyan_shared.userdb.txt"))
        let rebuilt = try await manager.reinstallActiveDictionary(deploy: deploy)
        let redeployed = try await manager.activeInstallation()!
        XCTAssertEqual(rebuilt?.generation, redeployed.installation.generation)
        XCTAssertNotEqual(redeployed.installation.generation, installed.generation)
        XCTAssertEqual(redeployed.installation.revision, installed.revision)
        XCTAssertEqual(
            try Data(contentsOf: redeployed.resourceURL.appendingPathComponent("songyan_imported.dict.yaml")),
            prepared.resources["songyan_imported.dict.yaml"])
        XCTAssertEqual(
            try String(contentsOf: redeployed.userDataURL.appendingPathComponent("songyan_shared.userdb.txt")),
            "learned since")
        do {
            try await manager.reinstallActiveDictionary { _ in throw RecipeInstallError.deployment("injected") }
            XCTFail("A failed redeploy must not activate")
        } catch {}
        let kept = try await manager.activeInstallation()?.installation.generation
        XCTAssertEqual(kept, redeployed.installation.generation)
    }

    func testReinstallWithoutDictionaryIsANoOp() async throws {
        let manager = RecipePackageManager(rootURL: try workspace().appendingPathComponent("store"))
        let result = try await manager.reinstallActiveDictionary { _ in
            XCTFail("Nothing installed, nothing to deploy")
            throw RecipeInstallError.deployment("unexpected")
        }
        XCTAssertNil(result)
    }

    func testPreparedImportCopiesOnlyTheSchemesAndListsThemAlone() async throws {
        // The compact layouts are generated against the imported dictionary at install time.
        let root = try workspace()
        let main = try source("---\nname: main\nversion: '1'\n...\n你好\tni hao\t1\n", name: "main.dict.yaml", in: root)
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let prepared = try await manager.prepareDictionaryImport(root: main, builtinResources: templates(in: root))
        XCTAssertEqual(
            Set(prepared.resources.keys.filter { $0.hasSuffix(".schema.yaml") }),
            ["songyan_quanpin.schema.yaml", "songyan_flypy.schema.yaml"])
        for id in ["songyan_quanpin", "songyan_flypy"] {
            let schema = String(decoding: prepared.resources["\(id).schema.yaml"]!, as: UTF8.self)
            XCTAssertTrue(schema.contains("dictionary: songyan_imported"))
        }
        let defaults = String(decoding: prepared.resources["default.yaml"]!, as: UTF8.self)
        XCTAssertTrue(defaults.contains("  - schema: songyan_quanpin\n  - schema: songyan_flypy\n"))
        XCTAssertFalse(defaults.contains("keyboard_"))
    }

    func testGenericHTTPSUsesInjectedTransportAndPinsBytesBeforeInstall() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root) { url in
            XCTAssertEqual(url.host, "dictionary.example.org")
            return Data("name: words\nversion: 1\n...\n周末\tzhou1 mo4\t10\n".utf8)
        }
        let input = DictionaryImportFile(
            path: "words.dict.yaml", location: URL(string: "https://dictionary.example.org/data")!)
        let prepared = try await manager.prepareDictionaryImport(root: input, builtinResources: templates(in: root))
        XCTAssertEqual(prepared.entryCount, 1)
        XCTAssertEqual(prepared.sources[0].sha256.count, 64)
        XCTAssertTrue(
            String(data: prepared.resources["songyan_imported.dict.yaml"]!, encoding: .utf8)!.contains("zhou mo"))
    }

    func testRejectsUnsupportedAndUnsafeInputs() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        for (name, text) in [
            ("a.schema.yaml", "schema: {schema_id: a}"),
            ("a.dict.yaml", "name: a\n...\n天气\ttm qi\t1\n"),
            ("a.dict.yaml", "name: a\nimport_tables: [../outside]\n...\n"),
            ("a.dict.yaml", "name: a\n__include: evil\n...\n"),
            ("a.dict.yaml", "name: a\ncolumns: [text, weight]\n...\n天气\t1\n"),
            ("a.dict.yaml", "name: a\n...\n天气\ttian qi\tnan\n"),
        ] {
            let input = try source(text, name: name, in: root)
            do {
                _ = try await manager.inspectDictionary(input)
                XCTFail("Should reject \(text)")
            } catch {}
        }
        let insecure = DictionaryImportFile(
            path: "a.dict.yaml", location: URL(string: "http://example.org/a.dict.yaml")!)
        do {
            _ = try await manager.inspectDictionary(insecure)
            XCTFail("HTTP should fail before fetching")
        } catch {}
    }

    func testRejectsCyclesWithoutActivation() async throws {
        let root = try workspace()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let a = try source("name: a\nimport_tables: [b]\n...\n", name: "a.dict.yaml", in: root)
        let b = try source("name: b\nimport_tables: [a]\n...\n", name: "b.dict.yaml", in: root)
        do {
            _ = try await manager.prepareDictionaryImport(
                root: a, dependencies: [b], builtinResources: templates(in: root))
            XCTFail("Cycle must fail")
        } catch {}
        let status = try await manager.status()
        XCTAssertNil(status.active)
    }
}
