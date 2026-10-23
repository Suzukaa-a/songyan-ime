import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

final class TypoCorrectionTests: XCTestCase {
    private func compiled(
        id: String, translators: [String] = ["script_translator"],
        alphabet: String? = "zyxwvutsrqponmlkjihgfedcba",
        namespace: String = "translator", extra: String = ""
    ) -> Data {
        var lines = ["schema:", "  schema_id: \(id)", "  name: Test", "engine:", "  translators:"]
        lines += translators.map { "    - \($0)" }
        lines.append("speller:")
        if let alphabet { lines.append("  alphabet: \(alphabet)") }
        lines.append("  algebra: []")
        lines += ["\(namespace):", "  dictionary: test_dict"]
        if !extra.isEmpty { lines.append(extra) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - Eligibility

    func testFullAlphabetScriptTranslatorIsEligibleOnItsPrimaryNamespace() {
        XCTAssertEqual(
            TypoCorrection.eligibility(compiled: compiled(id: "any_pinyin"), schemaID: "any_pinyin"),
            .eligible(.init(schemaID: "any_pinyin", namespace: "translator")))
        // Auxiliary entries never make the schema look mixed or move the namespace.
        let withAux = compiled(
            id: "p",
            translators: [
                "punct_translator", "script_translator",
                "table_translator@custom_phrase", "lua_translator@*date",
            ])
        XCTAssertEqual(TypoCorrection.eligibility(compiled: withAux, schemaID: "p").target?.namespace, "translator")
        // A named-only primary producer binds its own namespace, never a hard-coded `translator`.
        let named = compiled(id: "n", translators: ["script_translator@main"], namespace: "main")
        XCTAssertEqual(
            TypoCorrection.eligibility(compiled: named, schemaID: "n").target?.configKey,
            "main/enable_correction")
        // Missing speller/alphabet means librime's default full alphabet.
        XCTAssertNotNil(TypoCorrection.eligibility(compiled: compiled(id: "d", alphabet: nil), schemaID: "d").target)
        // Extra punctuation keys are fine as long as a–z are all present.
        XCTAssertNotNil(
            TypoCorrection.eligibility(
                compiled: compiled(id: "e", alphabet: "\"zyxwvutsrqponmlkjihgfedcba;'\""), schemaID: "e"
            ).target)
    }

    func testIneligibleSchemasFailClosed() {
        // table_translator primary (shape codes): not a script_translator.
        XCTAssertNil(
            TypoCorrection.eligibility(
                compiled: compiled(id: "t", translators: ["table_translator"]), schemaID: "t"
            ).target)
        // Mixed default provenance.
        XCTAssertNil(
            TypoCorrection.eligibility(
                compiled: compiled(id: "m", translators: ["script_translator", "table_translator"]), schemaID: "m"
            ).target)
        // Numeric (native 9-key) or merged (14-key) alphabets are not 26-key input.
        XCTAssertNil(
            TypoCorrection.eligibility(compiled: compiled(id: "nine", alphabet: "23456789"), schemaID: "nine").target)
        XCTAssertNil(
            TypoCorrection.eligibility(compiled: compiled(id: "c14", alphabet: "qwertyuiopasdfg"), schemaID: "c14")
                .target)
        // Identity mismatch, garbage and bad ids.
        XCTAssertNil(TypoCorrection.eligibility(compiled: compiled(id: "a"), schemaID: "b").target)
        XCTAssertNil(TypoCorrection.eligibility(compiled: Data("::: not yaml".utf8), schemaID: "a").target)
        XCTAssertNil(TypoCorrection.eligibility(compiled: compiled(id: "../x"), schemaID: "../x").target)
        // Compact companions, by minted id or by carried capability block.
        let companion = CompactSchemaAdapter.identifier(sourceID: "any_pinyin", fold: .merged14)
        XCTAssertTrue(CompactSchemaAdapter.isGeneratedCompanionID(companion))
        XCTAssertTrue(
            CompactSchemaAdapter.isGeneratedCompanionID(CompactSchemaAdapter.identifier(sourceID: "x", fold: .phone9)))
        XCTAssertFalse(CompactSchemaAdapter.isGeneratedCompanionID("keyboard_layout"))
        XCTAssertNil(TypoCorrection.eligibility(compiled: compiled(id: companion), schemaID: companion).target)
        XCTAssertNil(
            TypoCorrection.eligibility(
                compiled: compiled(id: "tpl", extra: "keyboard_rewrite:\n  version: 2"), schemaID: "tpl"
            ).target)
    }

    // MARK: - Recipe generation

    func testRecipePatchesOnlyTheNamedSchemasUnderOneManagedBlock() throws {
        let a = TypoCorrection.Target(schemaID: "alpha", namespace: "translator")
        let b = TypoCorrection.Target(schemaID: "beta", namespace: "main")
        let recipe = try TypoCorrection.make(enabling: [a], disabling: [b])
        XCTAssertEqual(recipe.declaredName, TypoCorrection.recipeName)
        XCTAssertTrue(recipe.installPatterns.isEmpty)
        XCTAssertTrue(recipe.downloads.isEmpty)
        XCTAssertEqual(recipe.patchTargets.sorted(), ["alpha.custom.yaml", "beta.custom.yaml"])
        XCTAssertThrowsError(try TypoCorrection.make(enabling: []))
        XCTAssertThrowsError(try TypoCorrection.make(enabling: [.init(schemaID: "../bad", namespace: "translator")]))
        XCTAssertThrowsError(try TypoCorrection.make(enabling: [.init(schemaID: "ok", namespace: "a/b")]))
        let companion = CompactSchemaAdapter.identifier(sourceID: "alpha", fold: .phone9)
        XCTAssertThrowsError(
            try TypoCorrection.make(enabling: [.init(schemaID: companion, namespace: "translator")]),
            "a compact companion is never patched on")

        let userCustom = Data("patch:\n  menu/page_size: 7\n".utf8)
        let existing: [String: Data] = [
            "alpha.schema.yaml": compiled(id: "alpha"),
            "beta.schema.yaml": compiled(id: "beta"),
            "alpha.custom.yaml": userCustom,
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/pkg",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [:], existingFiles: existing,
            userCustomBaseline: ["alpha.custom.yaml": userCustom])
        let alpha = try XCTUnwrap(String(data: plan.files["alpha.custom.yaml"]!, encoding: .utf8))
        XCTAssertTrue(alpha.contains("menu/page_size: 7"), "user custom content is preserved")
        XCTAssertTrue(alpha.contains("# Rx: \(TypoCorrection.rx(packageReference: "user/pkg")) {"))
        XCTAssertTrue(alpha.contains("translator/enable_correction: true"))
        let beta = try XCTUnwrap(String(data: plan.files["beta.custom.yaml"]!, encoding: .utf8))
        XCTAssertTrue(beta.contains("main/enable_correction: false"))
        XCTAssertEqual(plan.files["alpha.schema.yaml"], existing["alpha.schema.yaml"], "source schema untouched")

        // Re-running replaces the managed block instead of stacking a second one.
        let off = try TypoCorrection.make(enabling: [], disabling: [a])
        let replan = try DeclarativeRecipePlan(
            recipe: off, packageReference: "user/pkg",
            selectedRecipe: off.declaredName!, arguments: [], packageFiles: [:], existingFiles: plan.files)
        let again = try XCTUnwrap(String(data: replan.files["alpha.custom.yaml"]!, encoding: .utf8))
        XCTAssertEqual(again.components(separatedBy: "enable_correction").count - 1, 1)
        XCTAssertTrue(again.contains("translator/enable_correction: false"))
        XCTAssertTrue(again.contains("menu/page_size: 7"))
        XCTAssertFalse(
            TypoCorrection.userOwnsSetting(
                customYAML: replan.files["alpha.custom.yaml"],
                packageReference: "user/pkg"),
            "our own managed block is not a user setting")
        // The YAML Rime will read really carries the bool through `__patch`.
        let root = try XCTUnwrap(Yams.load(yaml: again) as? [String: Any])
        let patches = try XCTUnwrap(root["__patch"] as? [[String: Any]])
        let merged = patches.compactMap { $0["patch/+"] as? [String: Any] }
        XCTAssertEqual(merged.last?["translator/enable_correction"] as? Bool, false)
    }

    func testUserManagedSettingIsDetectedAndSkipped() {
        let own = Data("patch:\n  translator/enable_correction: false\n".utf8)
        XCTAssertTrue(TypoCorrection.userOwnsSetting(customYAML: own, packageReference: "p"))
        XCTAssertFalse(
            TypoCorrection.userOwnsSetting(
                customYAML: Data("# enable_correction note\npatch: {}\n".utf8),
                packageReference: "p"), "comments are not settings")
        XCTAssertFalse(TypoCorrection.userOwnsSetting(customYAML: nil, packageReference: "p"))
        let a = TypoCorrection.Target(schemaID: "a", namespace: "translator")
        let b = TypoCorrection.Target(schemaID: "b", namespace: "translator")
        let c = TypoCorrection.Target(schemaID: "c", namespace: "translator")
        XCTAssertEqual(
            TypoCorrection.changes(
                desired: true, targets: [c, a, b], current: ["b": true],
                userManaged: ["c"]), [a])
        XCTAssertEqual(
            TypoCorrection.changes(
                desired: false, targets: [a, b, c], current: ["b": true],
                userManaged: []), [b], "absent means off; only on values are cleared")
    }

    func testCompiledValueAndEnabledList() {
        let target = TypoCorrection.Target(schemaID: "x", namespace: "translator")
        XCTAssertNil(TypoCorrection.compiledValue(compiled: compiled(id: "x"), target: target))
        XCTAssertEqual(
            TypoCorrection.compiledValue(
                compiled: Data("translator:\n  dictionary: d\n  enable_correction: true\n".utf8), target: target), true)
        let defaults = Data("schema_list:\n  - schema: one\n  - schema: two\n  - schema: one\n".utf8)
        XCTAssertEqual(TypoCorrection.enabledSchemaIDs(compiledDefault: defaults), ["one", "two"])
        XCTAssertEqual(TypoCorrection.enabledSchemaIDs(compiledDefault: Data("x: 1\n".utf8)), [])
    }

    // MARK: - Compact companions never inherit the switch

    func testCompactCompanionsForceCorrectionOffWhenSourceEnablesIt() throws {
        let source = compiled(id: "src", extra: "  enable_correction: true")
        XCTAssertEqual(
            TypoCorrection.compiledValue(
                compiled: source,
                target: .init(schemaID: "src", namespace: "translator")), true)
        for nine in [false, true] {
            let data = try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "src", fold: nine ? .phone9 : .merged14,
                displayCapability: nil)
            let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
            let translator = try XCTUnwrap(root["translator"] as? [String: Any])
            XCTAssertEqual(translator["enable_correction"] as? Bool, false, "nineKey=\(nine)")
            let id = CompactSchemaAdapter.identifier(sourceID: "src", fold: nine ? .phone9 : .merged14)
            XCTAssertNil(TypoCorrection.eligibility(compiled: data, schemaID: id).target)
        }
        // A source without the switch yields a companion without the key (librime default off).
        let plain = try CompactSchemaAdapter.generate(
            compiled: compiled(id: "src"), sourceID: "src",
            fold: .merged14, displayCapability: nil)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("enable_correction"))
    }
}
