import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

final class LuaComponentsTests: XCTestCase {
    private func compiled(
        id: String = "s", processors: [String], translators: [String] = ["script_translator"],
        filters: [String] = [], extra: String = ""
    ) -> Data {
        var lines = ["schema:", "  schema_id: \(id)", "engine:", "  processors:"]
        lines += processors.map { "    - \"\($0)\"" }
        lines.append("  translators:")
        lines += translators.map { "    - \"\($0)\"" }
        if !filters.isEmpty {
            lines.append("  filters:")
            lines += filters.map { "    - \"\($0)\"" }
        }
        if !extra.isEmpty { lines.append(extra) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private let processors = ["lua_processor@*select_char", "speller", "selector"]
    private let filters = ["lua_filter@*charset*F", "uniquifier", "lua_filter@*emoji"]

    func testListsLuaComponentsInOrderAllEnabledByDefault() throws {
        let state = try XCTUnwrap(
            LuaComponents.state(compiled: compiled(processors: processors, filters: filters), schemaID: "s"))
        XCTAssertEqual(
            state.components.map(\.prescription),
            ["lua_processor@*select_char", "lua_filter@*charset*F", "lua_filter@*emoji"])
        XCTAssertTrue(state.components.allSatisfy(\.enabled))
        XCTAssertEqual(state.components.map(\.mayAffectBasicInput), [true, false, false])
        XCTAssertEqual(state.components[1].displayName, "charset*F")
        XCTAssertNil(LuaComponents.state(compiled: compiled(processors: processors), schemaID: "other"))
    }

    func testDisablingAssignsOnlyAffectedListsFromBaseline() throws {
        let state = try XCTUnwrap(
            LuaComponents.state(compiled: compiled(processors: processors, filters: filters), schemaID: "s"))
        let recipe = try LuaComponents.make(schemaID: "s", baseline: state.baseline, disabled: ["lua_filter@*emoji"])
        let text = String(decoding: recipe.source, as: UTF8.self)
        XCTAssertTrue(text.contains("engine/filters: [\"lua_filter@*charset*F\", \"uniquifier\"]"))
        XCTAssertFalse(text.contains("engine/processors:"), "a list that loses nothing is never pinned")
        XCTAssertTrue(text.contains("songyan_lua_managed: true"))
        XCTAssertThrowsError(try LuaComponents.make(schemaID: "s", baseline: state.baseline, disabled: ["uniquifier"]))

        // Round trip through the managed-block writer and the compiled read-back.
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "pkg", selectedRecipe: LuaComponents.recipeName,
            arguments: [], packageFiles: [:], existingFiles: [:])
        let custom = try XCTUnwrap(String(data: plan.files["s.custom.yaml"]!, encoding: .utf8))
        XCTAssertTrue(custom.contains("# Rx: pkg:lua_components: {"))
        XCTAssertFalse(LuaComponents.userOwnsSetting(customYAML: plan.files["s.custom.yaml"]))

        let deployed = compiled(
            processors: processors, filters: ["lua_filter@*charset*F", "uniquifier"],
            extra:
                "songyan_lua_managed: true\nsongyan_lua_baseline:\n  processors: [\"lua_processor@*select_char\", speller, selector]\n  translators: [script_translator]\n  filters: [\"lua_filter@*charset*F\", uniquifier, \"lua_filter@*emoji\"]"
        )
        let read = try XCTUnwrap(LuaComponents.state(compiled: deployed, schemaID: "s"))
        XCTAssertEqual(read.disabled, ["lua_filter@*emoji"])
        XCTAssertEqual(read.baseline, state.baseline)
        XCTAssertTrue(
            LuaComponents.matches(
                compiled: deployed, schemaID: "s", baseline: read.baseline, disabled: ["lua_filter@*emoji"]))
        XCTAssertFalse(LuaComponents.matches(compiled: deployed, schemaID: "s", baseline: read.baseline, disabled: []))

        // Restoring everything pins nothing.
        let restore = String(
            decoding: try LuaComponents.make(schemaID: "s", baseline: read.baseline, disabled: []).source, as: UTF8.self
        )
        XCTAssertTrue(restore.contains("songyan_lua_managed: false"))
        XCTAssertFalse(restore.contains("engine/"))
    }

    func testManagedPredictionComponentsStayOutOfTheBaseline() throws {
        let data = compiled(
            processors: ["predictor"] + processors, translators: ["predict_translator", "script_translator"],
            filters: filters, extra: "songyan_prediction: true")
        let state = try XCTUnwrap(LuaComponents.state(compiled: data, schemaID: "s"))
        XCTAssertEqual(state.baseline["processors"], processors)
        XCTAssertEqual(state.baseline["translators"], ["script_translator"])
        XCTAssertTrue(LuaComponents.matches(compiled: data, schemaID: "s", baseline: state.baseline, disabled: []))
        // A scheme's own predictor is part of its baseline.
        let own = try XCTUnwrap(
            LuaComponents.state(compiled: compiled(processors: ["predictor"] + processors), schemaID: "s"))
        XCTAssertEqual(own.baseline["processors"]?.first, "predictor")
    }

    func testUserEngineEditsAreUserManagedAndCompanionsRejected() {
        XCTAssertTrue(
            LuaComponents.userOwnsSetting(customYAML: Data("patch:\n  engine/filters/+:\n    - lua_filter@x\n".utf8)))
        XCTAssertTrue(LuaComponents.userOwnsSetting(customYAML: Data("patch:\n  engine:\n    filters: []\n".utf8)))
        XCTAssertFalse(LuaComponents.userOwnsSetting(customYAML: Data("patch:\n  menu/page_size: 7\n".utf8)))
        let companion = CompactSchemaAdapter.identifier(sourceID: "s", fold: .phone9)
        XCTAssertThrowsError(try LuaComponents.make(schemaID: companion, baseline: [:], disabled: []))
        XCTAssertEqual(LuaComponents.quoted("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }
}
