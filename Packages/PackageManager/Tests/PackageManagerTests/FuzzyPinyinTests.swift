import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

final class FuzzyPinyinTests: XCTestCase {
    /// A compiled schema shaped like the sources the feature is meant for.
    private func compiled(
        id: String, translators: [String] = ["script_translator"],
        alphabet: String? = "zyxwvutsrqponmlkjihgfedcba",
        namespace: String = "translator", algebra: [String]? = [],
        extra: String = ""
    ) -> Data {
        var lines = ["schema:", "  schema_id: \(id)", "  name: Test", "engine:", "  translators:"]
        lines += translators.map { "    - \($0)" }
        lines.append("speller:")
        if let alphabet { lines.append("  alphabet: \(alphabet)") }
        if let algebra {
            if algebra.isEmpty {
                lines.append("  algebra: []")
            } else {
                // Block-quoted: a rule such as `derive/^([zcs])h/$1/` carries a character
                // class, which YAML cannot read inside a flow sequence.
                lines.append("  algebra:")
                lines += algebra.map { "    - \"\($0)\"" }
            }
        }
        lines += ["\(namespace):", "  dictionary: test_dict"]
        if !extra.isEmpty { lines.append(extra) }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func source(id: String, algebra: [String]?, alphabet: String? = "zyxwvutsrqponmlkjihgfedcba") -> Data {
        var lines = ["schema:", "  schema_id: \(id)", "  name: Test"]
        if alphabet != nil || algebra != nil {
            lines.append("speller:")
            if let alphabet { lines.append("  alphabet: \(alphabet)") }
            if let algebra {
                if algebra.isEmpty {
                    lines.append("  algebra: []")
                } else {
                    lines.append("  algebra:")
                    lines += algebra.map { "    - \"\($0)\"" }
                }
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func target(_ id: String, namespace: String = "translator") -> FuzzyPinyin.Target {
        .init(schemaID: id, namespace: namespace)
    }

    // MARK: - Eligibility

    func testFullAlphabetScriptTranslatorIsEligible() {
        XCTAssertEqual(
            FuzzyPinyin.eligibility(compiled: compiled(id: "any_pinyin"), schemaID: "any_pinyin"),
            .eligible(target("any_pinyin")))
        // Auxiliary entries never make the schema look mixed or move the namespace.
        let withAux = compiled(
            id: "p",
            translators: [
                "punct_translator", "script_translator",
                "table_translator@custom_phrase", "lua_translator@*date",
            ])
        XCTAssertEqual(FuzzyPinyin.eligibility(compiled: withAux, schemaID: "p").target?.namespace, "translator")
        // The patched key is schema-level, whatever namespace the producer uses.
        XCTAssertEqual(target("n", namespace: "main").configKey, "speller/algebra")
        XCTAssertEqual(target("n").configKey, "speller/algebra")
        // Missing speller/alphabet means librime's default full alphabet.
        XCTAssertNotNil(FuzzyPinyin.eligibility(compiled: compiled(id: "d", alphabet: nil), schemaID: "d").target)
    }

    func testIneligibleSchemasFailClosed() {
        // Shape codes: a table_translator produces no pinyin readings.
        XCTAssertNil(
            FuzzyPinyin.eligibility(
                compiled: compiled(id: "t", translators: ["table_translator"]), schemaID: "t"
            ).target)
        // Mixed default provenance.
        XCTAssertNil(
            FuzzyPinyin.eligibility(
                compiled: compiled(id: "m", translators: ["script_translator", "table_translator"]), schemaID: "m"
            ).target)
        // Numeric (native 9-key) or merged (14-key) alphabets are not 26-key input.
        XCTAssertNil(
            FuzzyPinyin.eligibility(
                compiled: compiled(id: "nine", alphabet: "23456789"),
                schemaID: "nine"
            ).target)
        XCTAssertNil(
            FuzzyPinyin.eligibility(
                compiled: compiled(id: "c14", alphabet: "qwertyuiopasdfg"),
                schemaID: "c14"
            ).target)
        // Identity mismatch, garbage and bad ids.
        XCTAssertNil(FuzzyPinyin.eligibility(compiled: compiled(id: "a"), schemaID: "b").target)
        XCTAssertNil(FuzzyPinyin.eligibility(compiled: Data("::: not yaml".utf8), schemaID: "a").target)
        XCTAssertNil(FuzzyPinyin.eligibility(compiled: compiled(id: "../x"), schemaID: "../x").target)
        // A primary producer without a usable dictionary cannot produce readings.
        let noDict = Data(
            "schema:\n  schema_id: nodict\nengine:\n  translators:\n    - script_translator\ntranslator:\n  dictionary: \"\"\n"
                .utf8)
        XCTAssertNil(FuzzyPinyin.eligibility(compiled: noDict, schemaID: "nodict").target)
        // Compact companions, by minted id or by carried capability block.
        let companion = CompactSchemaAdapter.identifier(sourceID: "any_pinyin", fold: .merged14)
        XCTAssertNil(FuzzyPinyin.eligibility(compiled: compiled(id: companion), schemaID: companion).target)
        XCTAssertNil(
            FuzzyPinyin.eligibility(
                compiled: compiled(id: "tpl", extra: "keyboard_rewrite:\n  version: 2"), schemaID: "tpl"
            ).target)
        // An ineligible verdict always carries a reason a person can read.
        guard
            case .ineligible(let reason) = FuzzyPinyin.eligibility(
                compiled: Data("::: not yaml".utf8),
                schemaID: "a")
        else {
            return XCTFail("unreadable schema is not eligible")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - Pairs and their rule text

    func testPairsAreBoundedBidirectionalAndDeterministic() {
        XCTAssertEqual(FuzzyPinyin.allPairs.count, 8)
        XCTAssertEqual(
            FuzzyPinyin.allPairs.map(\.id),
            ["z-zh", "c-ch", "s-sh", "an-ang", "en-eng", "in-ing", "n-l", "f-h"])
        // The generated rules are a fixed set: every one of them is a native fuzz derivation.
        XCTAssertEqual(
            FuzzyPinyin.allPairs.flatMap(\.rules),
            [
                "fuzz/^zh/z/", "fuzz/^z(?!h)/zh/",
                "fuzz/^ch/c/", "fuzz/^c(?!h)/ch/",
                "fuzz/^sh/s/", "fuzz/^s(?!h)/sh/",
                "fuzz/an(?!g)/ang/", "fuzz/ang/an/",
                "fuzz/en(?!g)/eng/", "fuzz/eng/en/",
                "fuzz/in(?!g)/ing/", "fuzz/ing/in/",
                "fuzz/^n/l/", "fuzz/^l/n/",
                "fuzz/^f/h/", "fuzz/^h/f/",
            ])
        for pair in FuzzyPinyin.allPairs {
            XCTAssertEqual(pair.rules.count, 2, "\(pair.id) is bidirectional")
            XCTAssertTrue(pair.rules.allSatisfy { $0.hasPrefix("fuzz/") && $0.hasSuffix("/") })
            XCTAssertEqual(FuzzyPinyin.pair(id: pair.id), pair)
        }
        XCTAssertNil(FuzzyPinyin.pair(id: "zh-z"))

        // A set has no order of its own: the generated list must not depend on insertion order.
        XCTAssertEqual(
            FuzzyPinyin.rules(pairIDs: Set(FuzzyPinyin.allPairs.map(\.id))),
            FuzzyPinyin.allPairs.flatMap(\.rules))
        XCTAssertEqual(
            FuzzyPinyin.rules(pairIDs: Set(["f-h", "z-zh", "n-l"])),
            [
                "fuzz/^zh/z/", "fuzz/^z(?!h)/zh/", "fuzz/^n/l/", "fuzz/^l/n/",
                "fuzz/^f/h/", "fuzz/^h/f/",
            ])
        XCTAssertEqual(FuzzyPinyin.rules(pairIDs: []), [])
        XCTAssertNil(FuzzyPinyin.rules(pairIDs: ["bogus"]), "an unknown identifier is refused, never ignored")
        // Reading a block back only accepts exactly what we generate.
        XCTAssertEqual(FuzzyPinyin.pairIDs(rules: FuzzyPinyin.rules(pairIDs: ["an-ang"])!), ["an-ang"])
        XCTAssertEqual(FuzzyPinyin.pairIDs(rules: []), [])
        XCTAssertNil(FuzzyPinyin.pairIDs(rules: ["fuzz/^x/y/"]), "an edited block is not a state we act on")
    }

    /// The rule text really derives the intended spellings, run through a real regex engine
    /// with librime's replace direction (`fuzz` is a regex_replace plus a credibility
    /// penalty; the engine's own proof stays with the native projection at deployment).
    func testRuleTextDerivesBothDirectionsWithoutRematching() {
        // Retroflex: a short onset gains h, an already-long one never gains a second h.
        XCTAssertEqual(apply("fuzz/^z(?!h)/zh/", to: "zong"), "zhong")
        XCTAssertNil(apply("fuzz/^z(?!h)/zh/", to: "zhong"))
        XCTAssertEqual(apply("fuzz/^zh/z/", to: "zhong"), "zong")
        XCTAssertNil(apply("fuzz/^zh/z/", to: "zong"))
        XCTAssertEqual(apply("fuzz/^c(?!h)/ch/", to: "cai"), "chai")
        XCTAssertNil(apply("fuzz/^c(?!h)/ch/", to: "chai"))
        XCTAssertEqual(apply("fuzz/^s(?!h)/sh/", to: "san"), "shan")
        XCTAssertNil(apply("fuzz/^s(?!h)/sh/", to: "shan"))
        // Nasal finals reach a syllable with an onset, not only a bare final.
        XCTAssertEqual(apply("fuzz/an(?!g)/ang/", to: "an"), "ang")
        XCTAssertEqual(apply("fuzz/an(?!g)/ang/", to: "ban"), "bang")
        XCTAssertEqual(apply("fuzz/an(?!g)/ang/", to: "zhuan"), "zhuang")
        // A final that already ends in "ang" is left alone: "nang" must not become "nangg".
        XCTAssertNil(apply("fuzz/an(?!g)/ang/", to: "nang"))
        XCTAssertNil(apply("fuzz/an(?!g)/ang/", to: "shang"))
        XCTAssertEqual(apply("fuzz/ang/an/", to: "bang"), "ban")
        XCTAssertEqual(apply("fuzz/ang/an/", to: "nang"), "nan")
        XCTAssertEqual(apply("fuzz/ang/an/", to: "an"), nil)
        XCTAssertEqual(apply("fuzz/en(?!g)/eng/", to: "ben"), "beng")
        XCTAssertNil(apply("fuzz/en(?!g)/eng/", to: "sheng"))
        XCTAssertEqual(apply("fuzz/in(?!g)/ing/", to: "lin"), "ling")
        XCTAssertNil(apply("fuzz/in(?!g)/ing/", to: "ling"))
        XCTAssertEqual(apply("fuzz/eng/en/", to: "cheng"), "chen")
        // Initials.
        XCTAssertEqual(apply("fuzz/^n/l/", to: "ni"), "li")
        XCTAssertEqual(apply("fuzz/^l/n/", to: "la"), "na")
        XCTAssertEqual(apply("fuzz/^f/h/", to: "fang"), "hang")
        XCTAssertNil(apply("fuzz/^h/f/", to: "fang"))
        // No rule of ours ever erases a spelling: they only add one.
        XCTAssertTrue(FuzzyPinyin.allPairs.flatMap(\.rules).allSatisfy { !$0.contains("erase/") })
    }

    // MARK: - Recipe generation

    func testRecipeInsertsBeforeTheSchemasOwnAlgebraWithoutRestatingIt() throws {
        let alpha = target("alpha")
        let beta = target("beta", namespace: "main")
        // A real source carries rules we must not have to reproduce: back-references and
        // inherited settings cannot survive a whole-list rewrite.
        let originals = ["alpha": ["xform/^ng$/n/", "derive/^([zcs])h/$1/"], "beta": []]
        let recipe = try FuzzyPinyin.make(enabledPairIDs: ["an-ang", "z-zh"], targets: [beta, alpha])
        XCTAssertEqual(recipe.declaredName, FuzzyPinyin.recipeName)
        XCTAssertTrue(recipe.installPatterns.isEmpty)
        XCTAssertTrue(recipe.downloads.isEmpty)
        XCTAssertEqual(recipe.patchTargets.sorted(), ["alpha.custom.yaml", "beta.custom.yaml"])

        let userCustom = Data("patch:\n  menu/page_size: 7\n".utf8)
        let existing: [String: Data] = [
            "alpha.schema.yaml": source(id: "alpha", algebra: originals["alpha"]),
            "beta.schema.yaml": source(id: "beta", algebra: []),
            "alpha.custom.yaml": userCustom,
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/pkg",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [:], existingFiles: existing,
            userCustomBaseline: ["alpha.custom.yaml": userCustom])
        let alphaText = try XCTUnwrap(plan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(alphaText.contains("menu/page_size: 7"), "user custom content is preserved")
        XCTAssertTrue(alphaText.contains("# Rx: \(FuzzyPinyin.rx(packageReference: "user/pkg")) {"))
        // List insertion is what keeps the schema's own rules out of our block.
        XCTAssertEqual(try appended(alphaText), FuzzyPinyin.rules(pairIDs: ["z-zh", "an-ang"])!)
        XCTAssertFalse(alphaText.contains("xform/^ng$/n/"), "the schema's own rules are never restated")
        XCTAssertFalse(alphaText.contains("$1"))
        XCTAssertTrue(alphaText.contains("speller/algebra/@before 00"), "rules go in front of the schema's own")
        XCTAssertFalse(alphaText.contains("speller/algebra/+"), "nothing is appended at the end any more")
        XCTAssertEqual(
            try appended(XCTUnwrap(plan.files["beta.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })),
            FuzzyPinyin.rules(pairIDs: ["z-zh", "an-ang"])!)
        XCTAssertEqual(plan.files["alpha.schema.yaml"], existing["alpha.schema.yaml"], "source schema untouched")

        // Re-running replaces the managed block instead of stacking a second one.
        let one = try FuzzyPinyin.make(enabledPairIDs: ["z-zh"], targets: [alpha])
        let replan = try DeclarativeRecipePlan(
            recipe: one, packageReference: "user/pkg",
            selectedRecipe: one.declaredName!, arguments: [], packageFiles: [:], existingFiles: plan.files)
        let again = try XCTUnwrap(replan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(again.components(separatedBy: "# Rx: user/pkg:\(FuzzyPinyin.recipeName):").count - 1, 1)
        XCTAssertEqual(try appended(again), FuzzyPinyin.pair(id: "z-zh")!.rules, "the dropped pair is gone")
        XCTAssertTrue(again.contains("menu/page_size: 7"))
        // Our own managed block is never read as a user setting.
        XCTAssertFalse(
            FuzzyPinyin.userOwnsSetting(
                customYAML: replan.files["alpha.custom.yaml"],
                packageReference: "user/pkg"))
    }

    /// Input methods are configured separately: one method's pairs must never leak into
    /// another's file, and changing one must leave the others byte-for-byte alone.
    func testPerSchemaPairsKeepEachInputMethodsOwnAssignments() throws {
        let alpha = target("alpha")
        let beta = target("beta", namespace: "main")
        let recipe = try FuzzyPinyin.make(
            enabledPairIDsBySchema: ["alpha": ["z-zh"], "beta": ["n-l"]],
            targets: [beta, alpha])
        XCTAssertEqual(recipe.patchTargets.sorted(), ["alpha.custom.yaml", "beta.custom.yaml"])

        let existing: [String: Data] = [
            "alpha.schema.yaml": source(id: "alpha", algebra: []),
            "beta.schema.yaml": source(id: "beta", algebra: []),
            "beta.custom.yaml": Data("patch:\n  menu/page_size: 7\n".utf8),
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/pkg",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [:], existingFiles: existing)
        let alphaText = try XCTUnwrap(plan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        let betaText = try XCTUnwrap(plan.files["beta.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(try appended(alphaText), FuzzyPinyin.pair(id: "z-zh")!.rules)
        XCTAssertEqual(try appended(betaText), FuzzyPinyin.pair(id: "n-l")!.rules)
        XCTAssertNotEqual(
            try appended(alphaText), try appended(betaText),
            "each input method carries its own pairs")
        XCTAssertTrue(betaText.contains("menu/page_size: 7"), "the other method's own content is kept")

        // The user changes alpha only; beta's current assignment is passed through untouched.
        let updated = try FuzzyPinyin.make(
            enabledPairIDsBySchema: ["alpha": ["z-zh", "an-ang"], "beta": ["n-l"]], targets: [alpha, beta])
        let replan = try DeclarativeRecipePlan(
            recipe: updated, packageReference: "user/pkg",
            selectedRecipe: updated.declaredName!, arguments: [], packageFiles: [:], existingFiles: plan.files)
        XCTAssertEqual(
            replan.files["beta.custom.yaml"], plan.files["beta.custom.yaml"],
            "an untouched input method is not rewritten")
        let alphaAgain = try XCTUnwrap(replan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(
            try appended(alphaAgain),
            FuzzyPinyin.pair(id: "z-zh")!.rules + FuzzyPinyin.pair(id: "an-ang")!.rules)
        XCTAssertFalse(alphaAgain.contains("n-l"), "alpha never gains beta's pair")

        // Switching one method off appends nothing for it, and only for it.
        let offAlpha = try FuzzyPinyin.make(
            enabledPairIDsBySchema: ["alpha": [], "beta": ["n-l"]],
            targets: [alpha, beta])
        let offPlan = try DeclarativeRecipePlan(
            recipe: offAlpha, packageReference: "user/pkg",
            selectedRecipe: offAlpha.declaredName!, arguments: [], packageFiles: [:], existingFiles: replan.files)
        let offAlphaText = try XCTUnwrap(
            offPlan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(try appended(offAlphaText), [])
        XCTAssertEqual(
            FuzzyPinyin.managedAlgebra(
                customYAML: offPlan.files["alpha.custom.yaml"],
                packageReference: "user/pkg"), [])
        XCTAssertEqual(
            try appended(XCTUnwrap(offPlan.files["beta.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })),
            FuzzyPinyin.pair(id: "n-l")!.rules, "beta is untouched by alpha being switched off")

        // The common form is the degenerate case: every method gets the same list.
        let common = try FuzzyPinyin.make(enabledPairIDs: ["n-l"], targets: [alpha, beta])
        let commonPlan = try DeclarativeRecipePlan(
            recipe: common, packageReference: "user/pkg",
            selectedRecipe: common.declaredName!, arguments: [], packageFiles: [:], existingFiles: [:])
        for path in ["alpha.custom.yaml", "beta.custom.yaml"] {
            XCTAssertEqual(
                try appended(XCTUnwrap(commonPlan.files[path].flatMap { String(data: $0, encoding: .utf8) })),
                FuzzyPinyin.pair(id: "n-l")!.rules)
        }
    }

    func testPerSchemaPairsRefuseAnIncompleteAssignment() throws {
        let alpha = target("alpha")
        let beta = target("beta")
        // A schema missing from the map would silently be written as "no pairs", i.e. off.
        XCTAssertThrowsError(
            try FuzzyPinyin.make(
                enabledPairIDsBySchema: ["alpha": ["z-zh"]],
                targets: [alpha, beta]))
        XCTAssertThrowsError(
            try FuzzyPinyin.make(
                enabledPairIDsBySchema: [
                    "alpha": ["z-zh"],
                    "beta": ["n-l"],
                    "gamma": ["n-l"],
                ],
                targets: [alpha, beta]))
        XCTAssertThrowsError(try FuzzyPinyin.make(enabledPairIDsBySchema: [:], targets: []))
        XCTAssertThrowsError(
            try FuzzyPinyin.make(
                enabledPairIDsBySchema: ["alpha": ["bogus"]],
                targets: [alpha]))
    }

    func testRecipeRefusesInputsItCannotApply() throws {
        XCTAssertThrowsError(try FuzzyPinyin.make(enabledPairIDs: ["z-zh"], targets: []))
        XCTAssertThrowsError(try FuzzyPinyin.make(enabledPairIDs: ["zh-z"], targets: [target("alpha")]))
        XCTAssertThrowsError(
            try FuzzyPinyin.make(
                enabledPairIDs: ["z-zh"],
                targets: [.init(schemaID: "../bad", namespace: "translator")]))
        let companion = CompactSchemaAdapter.identifier(sourceID: "alpha", fold: .phone9)
        XCTAssertThrowsError(
            try FuzzyPinyin.make(
                enabledPairIDs: ["z-zh"],
                targets: [.init(schemaID: companion, namespace: "translator")]),
            "a compact companion is never patched")
    }

    // MARK: - Turning pairs off restores the schema exactly

    func testDisableAppendsNothingAndLeavesTheSchemasRulesAlone() throws {
        let originals = ["alpha": ["derive/^([zcs])h/$1/"], "beta": ["erase/^xx$/"]]
        let on = try FuzzyPinyin.make(
            enabledPairIDs: Set(FuzzyPinyin.allPairs.map(\.id)),
            targets: [target("alpha"), target("beta")])
        let off = try FuzzyPinyin.make(enabledPairIDs: [], targets: [target("alpha"), target("beta")])
        for target in ["alpha.custom.yaml", "beta.custom.yaml"] {
            let text = String(decoding: on.source, as: UTF8.self)
            XCTAssertTrue(text.contains(target))
        }

        // Deploy "everything on" first, so the file we switch off really carries our block.
        let onPlan = try DeclarativeRecipePlan(
            recipe: on, packageReference: "user/pkg",
            selectedRecipe: on.declaredName!, arguments: [], packageFiles: [:],
            existingFiles: [
                "alpha.schema.yaml": source(id: "alpha", algebra: originals["alpha"]),
                "beta.custom.yaml": Data("patch:\n  menu/page_size: 7\n".utf8),
            ])
        XCTAssertTrue(
            try XCTUnwrap(onPlan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
                .contains("fuzz/"), "the schema really carries our derivations before we switch them off")

        let plan = try DeclarativeRecipePlan(
            recipe: off, packageReference: "user/pkg",
            selectedRecipe: off.declaredName!, arguments: [], packageFiles: [:], existingFiles: onPlan.files)
        let alpha = try XCTUnwrap(plan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(try appended(alpha), [], "nothing is appended once every pair is off")
        XCTAssertFalse(alpha.contains("fuzz/"), "no leftover derivation of ours")
        XCTAssertFalse(alpha.contains("derive/^([zcs])h/$1/"), "and the schema's own rule is not restated")
        XCTAssertEqual(FuzzyPinyin.managedAlgebra(customYAML: Data(alpha.utf8), packageReference: "user/pkg"), [])
        // The compiled schema the engine then reads is the schema's own algebra, unchanged.
        let beta = try XCTUnwrap(plan.files["beta.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(beta.contains("menu/page_size: 7"))
        XCTAssertEqual(try appended(beta), [])
    }

    // MARK: - Compiled algebra

    func testCompiledAlgebraReadsTheSchemasList() {
        let own = ["derive/^([zcs])h/$1/", "xlit/ü/v/"]
        XCTAssertEqual(
            FuzzyPinyin.compiledAlgebra(
                compiled: compiled(id: "alpha", algebra: own),
                schemaID: "alpha"), own)
        XCTAssertEqual(FuzzyPinyin.compiledAlgebra(compiled: compiled(id: "alpha"), schemaID: "alpha"), [])
        // Unreadable, mismatched or non-list algebra read as nil.
        XCTAssertNil(FuzzyPinyin.compiledAlgebra(compiled: Data("::: not yaml".utf8), schemaID: "alpha"))
        XCTAssertNil(FuzzyPinyin.compiledAlgebra(compiled: compiled(id: "alpha", algebra: own), schemaID: "beta"))
        let notAList = Data(
            ("schema:\n  schema_id: alpha\nspeller:\n  alphabet: zyxwvutsrqponmlkjihgfedcba\n"
                + "  algebra: 5\n").utf8)
        XCTAssertNil(FuzzyPinyin.compiledAlgebra(compiled: notAList, schemaID: "alpha"))
    }

    // MARK: - User ownership and invocation isolation

    func testUserOwnedAlgebraIsNeverTouched() throws {
        let own = Data("patch:\n  speller/algebra: [\"xform/^a$/b/\"]\n".utf8)
        XCTAssertTrue(FuzzyPinyin.userOwnsSetting(customYAML: own, packageReference: "p"))
        XCTAssertFalse(
            FuzzyPinyin.userOwnsSetting(
                customYAML: Data("# algebra note\npatch: {}\n".utf8),
                packageReference: "p"))
        XCTAssertFalse(FuzzyPinyin.userOwnsSetting(customYAML: nil, packageReference: "p"))
        // Only OUR marker is skipped. Another invocation's block owns its rules exactly as
        // the user does, and patching the same key under it would overwrite those rules.
        let foreign = Data(
            ("__patch:\n# Rx: other/pkg:\(FuzzyPinyin.recipeName): {\n"
                + "  - patch/+:\n      speller/algebra/+: [\"fuzz/^z(?!h)/zh/\"]\n# }\n").utf8)
        XCTAssertTrue(FuzzyPinyin.userOwnsSetting(customYAML: foreign, packageReference: "p"))
        XCTAssertTrue(FuzzyPinyin.userOwnsSetting(customYAML: foreign, packageReference: "other/pkg2"))
        XCTAssertFalse(
            FuzzyPinyin.userOwnsSetting(customYAML: foreign, packageReference: "other/pkg"),
            "the invocation that wrote that block is not blocked by its own rules")
        // The bare word is not a setting: neither a value nor prose counts.
        XCTAssertFalse(
            FuzzyPinyin.userOwnsSetting(
                customYAML: Data("patch:\n  schema/name: algebra\n".utf8), packageReference: "p"))
        XCTAssertFalse(
            FuzzyPinyin.userOwnsSetting(
                customYAML: Data("patch:\n  menu/page_size: 7\n".utf8), packageReference: "p"))
        XCTAssertTrue(
            FuzzyPinyin.userOwnsSetting(
                customYAML: Data("patch:\n  speller: {algebra: [\"xform/^a$/b/\"]}\n".utf8),
                packageReference: "p"), "flow style still names the key")

        let recipe = try FuzzyPinyin.make(enabledPairIDs: ["z-zh"], targets: [target("alpha")])
        let existing: [String: Data] = [
            "alpha.schema.yaml": source(id: "alpha", algebra: []),
            "alpha.custom.yaml": own,
        ]
        let plan = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/pkg",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [:], existingFiles: existing,
            userCustomBaseline: ["alpha.custom.yaml": own])
        let merged = try XCTUnwrap(plan.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(merged.contains("xform/^a$/b/"), "the user's own algebra survives")
        XCTAssertTrue(
            FuzzyPinyin.userOwnsSetting(
                customYAML: plan.files["alpha.custom.yaml"],
                packageReference: "user/pkg"),
            "and the schema stays user-managed")
    }

    func testRecipeIdentityIsPerPackageReference() throws {
        let recipe = try FuzzyPinyin.make(enabledPairIDs: ["z-zh"], targets: [target("alpha")])
        XCTAssertEqual(FuzzyPinyin.rx(packageReference: "user/pkg"), "user/pkg:\(FuzzyPinyin.recipeName):")
        XCTAssertNotEqual(
            FuzzyPinyin.rx(packageReference: "other/pkg"),
            FuzzyPinyin.rx(packageReference: "user/pkg"))

        let mine = try DeclarativeRecipePlan(
            recipe: recipe, packageReference: "user/pkg",
            selectedRecipe: recipe.declaredName!, arguments: [], packageFiles: [:],
            existingFiles: ["alpha.schema.yaml": source(id: "alpha", algebra: [])])
        let alpha = try XCTUnwrap(mine.files["alpha.custom.yaml"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertEqual(
            FuzzyPinyin.managedAlgebra(customYAML: Data(alpha.utf8), packageReference: "user/pkg"),
            FuzzyPinyin.pair(id: "z-zh")!.rules)
        XCTAssertNil(
            FuzzyPinyin.managedAlgebra(customYAML: Data(alpha.utf8), packageReference: "other/pkg"),
            "another invocation identity does not read our block as its own")
        XCTAssertNil(FuzzyPinyin.managedAlgebra(customYAML: nil, packageReference: "user/pkg"))
        XCTAssertEqual(
            FuzzyPinyin.pairIDs(
                rules: FuzzyPinyin.managedAlgebra(
                    customYAML: Data(alpha.utf8), packageReference: "user/pkg")!), ["z-zh"])
    }

    // MARK: - Save planning

    /// Our managed block for `reference`, appending `rules`, as the recipe writes it.
    private func managedBlock(_ rules: [String], reference: String = "user/pkg") -> Data {
        let body =
            rules.isEmpty
            ? "  - patch/+: {}\n"
            : "  - patch/+:\n"
                + rules.enumerated().map {
                    "      \"\(FuzzyPinyin.insertKey($0.offset))\": \"\($0.element)\"\n"
                }.joined()
        return Data(("__patch:\n# Rx: \(FuzzyPinyin.rx(packageReference: reference)) {\n" + body + "# }\n").utf8)
    }

    private func buildDirectory(enabled: [String], schemas: [String: Data]) throws -> URL {
        let build = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzzy-plan-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: build) }
        let list = enabled.map { "  - schema: \($0)" }.joined(separator: "\n")
        try Data("schema_list:\n\(list)\n".utf8).write(to: build.appendingPathComponent("default.yaml"))
        for (id, data) in schemas { try data.write(to: build.appendingPathComponent(id + ".schema.yaml")) }
        return build
    }

    func testPlanTellsRefusalApartFromNothingToChange() throws {
        let zzh = FuzzyPinyin.Pair.zZh.rules
        let build = try buildDirectory(
            enabled: ["alpha", "shape"],
            schemas: [
                "alpha": compiled(id: "alpha", algebra: ["xform/^a$/b/"] + zzh),
                "shape": compiled(id: "shape", translators: ["table_translator"]),
                "idle": compiled(id: "idle"),
            ])
        func plan(_ id: String, _ pairs: Set<String>, _ custom: [String: Data] = [:]) -> FuzzyPinyin.SavePlan {
            FuzzyPinyin.plan(
                schemaID: id, enabledPairIDs: pairs, build: build, customFiles: custom,
                packageReference: "user/pkg")
        }
        func isRefused(_ value: FuzzyPinyin.SavePlan) -> Bool {
            if case .refused(let reason) = value { return !reason.isEmpty }
            return false
        }
        let ours = ["alpha.custom.yaml": managedBlock(zzh)]
        // Asking for what is already applied is "nothing to change", never a refusal.
        XCTAssertEqual(plan("alpha", ["z-zh"], ours), .noChange)
        // Every reason the save cannot be applied is a refusal with a reason to show.
        XCTAssertTrue(isRefused(plan("idle", ["z-zh"])), "not enabled")
        XCTAssertTrue(isRefused(plan("shape", ["z-zh"])), "not eligible")
        XCTAssertTrue(
            isRefused(
                plan(
                    "alpha", ["z-zh"],
                    ["alpha.custom.yaml": Data("patch:\n  speller/algebra: [\"xform/^a$/b/\"]\n".utf8)])),
            "user-managed")
        // A real change is planned.
        guard case .planned(let planned) = plan("alpha", ["z-zh", "n-l"], ours) else {
            return XCTFail("a real change must be planned")
        }
        XCTAssertEqual(planned.changed, target("alpha"))
        XCTAssertEqual(planned.pairIDsBySchema, ["alpha": ["z-zh", "n-l"]])
        XCTAssertEqual(planned.targets, [target("alpha")])
    }

    func testPlanKeepsOtherInputMethodsSavedPairs() throws {
        let build = try buildDirectory(
            enabled: ["alpha", "beta", "gamma"],
            schemas: [
                "alpha": compiled(id: "alpha"),
                "beta": compiled(id: "beta", algebra: FuzzyPinyin.Pair.cCh.rules),
                "gamma": compiled(id: "gamma"),
            ])
        let result = FuzzyPinyin.plan(
            schemaID: "alpha", enabledPairIDs: ["f-h"], build: build,
            customFiles: ["beta.custom.yaml": managedBlock(FuzzyPinyin.Pair.cCh.rules)],
            packageReference: "user/pkg")
        guard case .planned(let planned) = result else { return XCTFail("expected a plan") }
        XCTAssertEqual(
            planned.pairIDsBySchema, ["alpha": ["f-h"], "beta": ["c-ch"]],
            "beta keeps its pairs; gamma has no block and is not written")
        XCTAssertEqual(Set(planned.targets), [target("alpha"), target("beta")])
    }

    func testAlgebraKeyIsRecognizedQuotedAndAsAListEntry() {
        for line in [
            "\"speller/algebra\": []", "'speller/algebra/+': []", "- \"speller/algebra/+\": []",
            "- speller/algebra: []", "  -  speller/algebra/+: []", "\"algebra\": []",
            "speller: {\"algebra\": []}",
        ] {
            XCTAssertTrue(FuzzyPinyin.touchesAlgebraKey(line), line)
        }
        for line in [
            "\"speller/alphabet\": abc", "- \"schema/name\": algebra", "\"algebra_note\": x",
            "- patch/+:", "\"speller/algebra",
        ] {
            XCTAssertFalse(FuzzyPinyin.touchesAlgebraKey(line), line)
        }
        XCTAssertTrue(
            FuzzyPinyin.userOwnsSetting(
                customYAML: Data("__patch:\n  - \"speller/algebra/+\": [\"xform/^a$/b/\"]\n".utf8),
                packageReference: "p"))
    }

    // MARK: - Helpers

    /// The derivations our managed block inserts, in list order, read back from the merged custom file.
    private func appended(_ customText: String) throws -> [String] {
        let root = try XCTUnwrap(Yams.load(yaml: customText) as? [String: Any])
        let patches = try XCTUnwrap(root["__patch"] as? [[String: Any]])
        return patches.compactMap { $0["patch/+"] as? [String: Any] }.flatMap { map in
            map.keys.filter { $0.hasPrefix("speller/algebra/@before ") }.sorted().compactMap { map[$0] as? String }
        }
    }

    /// One native `fuzz/<pattern>/<replacement>/` rule, applied the way librime does it:
    /// a regex replace that leaves the spelling unchanged when nothing matches.
    private func apply(_ rule: String, to input: String) -> String? {
        let body = rule.dropFirst("fuzz/".count)
        guard let separator = body.firstIndex(of: "/"), body.hasSuffix("/") else { return nil }
        let pattern = String(body[body.startIndex..<separator])
        let replacement = String(body[body.index(after: separator)...].dropLast())
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = regex.firstMatch(in: input, range: range), match.range.length > 0 else { return nil }
        let replaced = regex.stringByReplacingMatches(
            in: input, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        return replaced == input ? nil : replaced
    }
}
