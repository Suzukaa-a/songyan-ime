import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

final class PredictionTests: XCTestCase {
    private func compiled(
        id: String, processors: [String] = ["speller", "selector", "express_editor"],
        translators: [String] = ["script_translator"],
        alphabet: String? = "zyxwvutsrqponmlkjihgfedcba", extra: String = ""
    ) -> Data {
        var lines = ["schema:", "  schema_id: \(id)", "  name: Test", "engine:", "  processors:"]
        lines += processors.map { "    - \"\($0)\"" }
        lines.append("  translators:")
        lines += translators.map { "    - \"\($0)\"" }
        lines.append("speller:")
        if let alphabet { lines.append("  alphabet: \(alphabet)") }
        lines += ["translator:", "  dictionary: test_dict"]
        if !extra.isEmpty { lines.append(extra) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Byte layout of librime-predict `predict::Metadata` (format[32], checksum, two
    /// OffsetPtr+size pairs), with both regions placed right after the header.
    private func database(
        keyUnits: UInt32 = 4, valueBytes: UInt32 = 16, format: String = "Rime::Predict/1.0",
        truncate: Int = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 52)
        for (i, b) in format.utf8.prefix(31).enumerated() { bytes[i] = b }
        func put(_ value: UInt32, at: Int) {
            for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) }
        }
        let keyStart: UInt32 = 52, valueStart = 52 + keyUnits * 4
        put(keyStart - 36, at: 36)
        put(keyUnits, at: 40)
        put(valueStart - 44, at: 44)
        put(valueBytes, at: 48)
        bytes += [UInt8](repeating: 1, count: Int(keyUnits * 4 + valueBytes))
        return Data(bytes.dropLast(truncate))
    }

    func testDatabaseHeaderIsStructurallyChecked() throws {
        let valid = database()
        XCTAssertNoThrow(try Prediction.validateHeader(valid.prefix(52), fileSize: valid.count))
        let bad = database(format: "Rime::Table/4.0")
        XCTAssertThrowsError(try Prediction.validateHeader(bad.prefix(52), fileSize: bad.count))
        let truncated = database(truncate: 1)
        XCTAssertThrowsError(try Prediction.validateHeader(truncated.prefix(52), fileSize: truncated.count))
        let emptyTrie = database(keyUnits: 0)
        XCTAssertThrowsError(try Prediction.validateHeader(emptyTrie.prefix(52), fileSize: emptyTrie.count))
        XCTAssertThrowsError(try Prediction.validateHeader(Data("Rime::Predict/".utf8), fileSize: 14))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try valid.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNoThrow(try Prediction.validateDatabase(at: url))
    }

    func testEligibilityIsSchemeAgnosticAndFailsClosed() {
        XCTAssertEqual(
            Prediction.eligibility(compiled: compiled(id: "any"), schemaID: "any"), .eligible(.init(schemaID: "any")))
        XCTAssertNotNil(
            Prediction.eligibility(compiled: compiled(id: "t", translators: ["table_translator"]), schemaID: "t").target
        )
        XCTAssertNotNil(
            Prediction.eligibility(compiled: compiled(id: "nine", alphabet: "23456789"), schemaID: "nine").target,
            "a native 9-key (digit) scheme predicts too")
        XCTAssertNil(
            Prediction.eligibility(compiled: compiled(id: "n", translators: ["echo_translator"]), schemaID: "n").target)
        XCTAssertNil(Prediction.eligibility(compiled: compiled(id: "a"), schemaID: "b").target)
        let companion = CompactSchemaAdapter.identifier(sourceID: "any", fold: .merged14)
        XCTAssertNil(Prediction.eligibility(compiled: compiled(id: companion), schemaID: companion).target)
        XCTAssertNil(
            Prediction.eligibility(compiled: compiled(id: "c", extra: "keyboard_adapter:\n  version: 1"), schemaID: "c")
                .target)
    }

    func testSchemesWithTheirOwnPredictionAreLeftAlone() {
        XCTAssertEqual(
            Prediction.eligibility(compiled: compiled(id: "p", processors: ["predictor", "speller"]), schemaID: "p"),
            .sourceManaged)
        XCTAssertEqual(
            Prediction.eligibility(
                compiled: compiled(id: "q", translators: ["predict_translator", "script_translator"]),
                schemaID: "q"), .sourceManaged)
        XCTAssertEqual(
            Prediction.eligibility(
                compiled: compiled(id: "r", processors: ["predictor@custom", "speller"]),
                schemaID: "r"), .sourceManaged)
        // Our own managed block is not "the scheme's own" prediction.
        let ours = compiled(
            id: "o", processors: ["predictor", "speller"], translators: ["predict_translator", "script_translator"],
            extra: "songyan_prediction: true\npredictor:\n  db: songyan-predict.db")
        XCTAssertEqual(Prediction.eligibility(compiled: ours, schemaID: "o"), .eligible(.init(schemaID: "o")))
        XCTAssertTrue(Prediction.compiledEnabled(compiled: ours))
        XCTAssertFalse(
            Prediction.compiledEnabled(
                compiled: compiled(id: "x", processors: ["predictor"], translators: ["predict_translator"])))
    }

    func testRecipeWiresComponentsInstallsDatabaseAndDisablesByReplacement() throws {
        let recipe = try Prediction.make(
            enabling: [.init(schemaID: "b"), .init(schemaID: "a")],
            disabling: [.init(schemaID: "c")], installDatabase: true)
        let text = String(decoding: recipe.source, as: UTF8.self)
        XCTAssertEqual(recipe.installPatterns, [Prediction.databasePath])
        XCTAssertEqual(recipe.patchTargets, ["a.custom.yaml", "b.custom.yaml", "c.custom.yaml"])
        XCTAssertTrue(text.contains("engine/processors/@before 0: predictor"))
        XCTAssertTrue(text.contains("engine/translators/@before 0: predict_translator"))
        XCTAssertTrue(text.contains("switches/@next: {name: prediction, reset: 1}"))
        XCTAssertTrue(text.contains("predictor/db: songyan-predict.db"))
        XCTAssertTrue(text.contains("  c.custom.yaml:\n    - patch/+:\n        songyan_prediction: false\n"))
        XCTAssertThrowsError(try Prediction.make(enabling: []))
        XCTAssertThrowsError(
            try Prediction.make(enabling: [
                .init(schemaID: CompactSchemaAdapter.identifier(sourceID: "a", fold: .phone9))
            ]))
        XCTAssertNoThrow(try Prediction.make(enabling: [], installDatabase: true))

        // The patch body is valid for the shared managed-block writer; re-running replaces it.
        let plan = try DeclarativeRecipePlan(
            recipe: try Prediction.make(enabling: [.init(schemaID: "a")]),
            packageReference: "pkg", selectedRecipe: Prediction.recipeName, arguments: [],
            packageFiles: [:], existingFiles: ["a.custom.yaml": Data("patch:\n  menu/page_size: 7\n".utf8)])
        let custom = String(decoding: plan.files["a.custom.yaml"]!, as: UTF8.self)
        XCTAssertTrue(custom.contains("# Rx: pkg:prediction: {"))
        let off = try DeclarativeRecipePlan(
            recipe: try Prediction.make(enabling: [], disabling: [.init(schemaID: "a")]),
            packageReference: "pkg", selectedRecipe: Prediction.recipeName, arguments: [],
            packageFiles: [:], existingFiles: plan.files)
        let disabled = String(decoding: off.files["a.custom.yaml"]!, as: UTF8.self)
        XCTAssertFalse(disabled.contains("predictor"))
        XCTAssertTrue(disabled.contains("menu/page_size: 7"))
        XCTAssertFalse(Prediction.userOwnsSetting(customYAML: plan.files["a.custom.yaml"], packageReference: "pkg"))
        XCTAssertTrue(
            Prediction.userOwnsSetting(
                customYAML: Data("patch:\n  engine/processors/@before 0: predictor\n".utf8),
                packageReference: "pkg"))
    }

    /// 14/9-key companions are generated from the compiled source and keep its prediction
    /// wiring unchanged; a source without prediction yields companions without it.
    func testCompanionsInheritThePredictionWiring() throws {
        let source = compiled(
            id: "src", processors: ["predictor", "speller", "selector", "express_editor"],
            translators: ["predict_translator", "script_translator"],
            extra:
                "songyan_prediction: true\npredictor:\n  db: songyan-predict.db\n  max_candidates: 8\nswitches:\n  - name: prediction\n    reset: 1"
        )
        XCTAssertTrue(Prediction.compiledEnabled(compiled: source))
        for nine in [false, true] {
            let data = try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "src", fold: nine ? .phone9 : .merged14, displayCapability: nil)
            XCTAssertTrue(Prediction.compiledEnabled(compiled: data), "nineKey=\(nine)")
            let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
            let engine = try XCTUnwrap(root["engine"] as? [String: Any])
            XCTAssertEqual((engine["processors"] as? [String])?.first, "predictor")
            XCTAssertEqual((engine["translators"] as? [String])?.first, "predict_translator")
            let id = CompactSchemaAdapter.identifier(sourceID: "src", fold: nine ? .phone9 : .merged14)
            XCTAssertNil(
                Prediction.eligibility(compiled: data, schemaID: id).target, "a companion is never patched itself")
        }
        let plain = try CompactSchemaAdapter.generate(
            compiled: compiled(id: "src"), sourceID: "src", fold: .phone9, displayCapability: nil)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("predict"))
        XCTAssertTrue(RecipeResourceBudget.isModel(Prediction.databasePath))
    }

    func testRootLevelDatabasesAreFileResources() {
        XCTAssertTrue(RecipeResourceBudget.isModel("predict.db"))
        XCTAssertTrue(Prediction.isDatabasePath("my_predict.db"))
        XCTAssertFalse(Prediction.isDatabasePath("lua/predict.db"))
        XCTAssertFalse(Prediction.isDatabasePath(".db"))
        XCTAssertFalse(Prediction.isDatabasePath("predict.db.yaml"))
    }

    /// A scheme package that mounts its own predictor and ships predict.db: the database is
    /// installed by reference (header-checked), and our managed patch stays off for it.
    func testSchemePackageShippingPredictDbIsCheckedAndKept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("predict-pkg-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let schema = compiled(
            id: "own", processors: ["predictor", "speller"],
            translators: ["predict_translator", "script_translator"], extra: "predictor:\n  db: predict.db")
        try schema.write(to: root.appendingPathComponent("own.schema.yaml"))
        try Data("---\nname: test_dict\nversion: \"1\"\n...\n你\tni\n".utf8).write(
            to: root.appendingPathComponent("test_dict.dict.yaml"))
        try database().write(to: root.appendingPathComponent("predict.db"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let prepared = try manager.prepareSchemeImport(directory: root)
        XCTAssertNotNil(prepared.fileResources["predict.db"], "predict.db travels as a file resource")
        XCTAssertNil(prepared.sourceFiles["predict.db"])
        XCTAssertTrue(prepared.manifest.files.contains { $0.path == "predict.db" })
        XCTAssertEqual(Prediction.eligibility(compiled: schema, schemaID: "own"), .sourceManaged)

        try Data("SQLite format 3\u{0}".utf8 + Data(repeating: 0, count: 64)).write(
            to: root.appendingPathComponent("predict.db"))
        XCTAssertThrowsError(try manager.prepareSchemeImport(directory: root), "a non-predict .db fails closed")
    }

    func testPlanRejectsInvalidSuppliedDatabase() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".db")
        try Data(repeating: 7, count: 128).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let resource = try RecipeFileResource.reference(at: url)
        XCTAssertThrowsError(
            try DeclarativeRecipePlan(
                recipe: try Prediction.make(enabling: [], installDatabase: true),
                packageReference: "pkg", selectedRecipe: Prediction.recipeName, arguments: [],
                packageFiles: [:], existingFiles: [:], packageFileResources: [Prediction.databasePath: resource]))
    }
}
