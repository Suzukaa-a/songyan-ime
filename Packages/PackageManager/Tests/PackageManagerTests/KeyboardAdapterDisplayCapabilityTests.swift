import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

/// Generation-time capability: forward projection of the source algebra -> a unique normal spelling mapping. A missing/ambiguous/non-letter
/// entry is only rejected and recorded, and at runtime an uncovered token makes the whole span fall back; never invert, never default to identity, never pick the first.
/// The source digest is produced by the real native bridge and adopted as is; the nil generation path explicitly strips an inherited capability block.
final class KeyboardAdapterDisplayCapabilityTests: XCTestCase {

    func syllable(_ token: String, _ spellings: [(String, Bool, Bool)]) -> CompactSchemaAdapter.ProjectedSyllable {
        CompactSchemaAdapter.ProjectedSyllable(
            token: token,
            spellings: spellings.map {
                .init(text: $0.0, isNormal: $0.1, isCorrection: $0.2)
            })
    }

    func projection(
        schema: String = "songyan_flypy",
        dictionary: String = "songyan_basic",
        alphabet: String = "zyxwvutsrqponmlkjihgfedcba",
        algebra: [String] = ["xform/(.)ao$/$1C/"],
        separator: String = "'",
        declaration: String = "",
        syllables: [CompactSchemaAdapter.ProjectedSyllable]
    ) -> CompactSchemaAdapter.SourceProjection {
        .init(
            sourceSchema: schema, translatorNamespace: "translator", dictionary: dictionary,
            alphabet: alphabet, algebra: algebra, separator: separator,
            declaration: declaration,
            syllables: syllables)
    }

    // MARK: - Acceptance: Xiaohe zao/shang/hao -> zc/uh/hc

    func testFlypyAcceptanceMapIsSourceCodingNotIdentityOrMerged() throws {
        let source = projection(syllables: [
            syllable("zao", [("zc", true, false)]),
            syllable("shang", [("uh", true, false)]),
            syllable("hao", [("hc", true, false)]),
        ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source, displaySeparator: "'")
        XCTAssertEqual(build.capability.mode, "source_code")
        XCTAssertEqual(build.capability.mappingPolicy, "unique_normal")
        XCTAssertEqual(
            build.capability.separator, "'",
            "the acceptance apostrophe comes from the explicit display separator setting")
        XCTAssertEqual(build.capability.syllables, ["zao": "zc", "shang": "uh", "hao": "hc"])
        XCTAssertTrue(build.rejections.isEmpty)
        XCTAssertNotEqual(build.capability.syllables["shang"], "ug")
        XCTAssertNotEqual(build.capability.syllables["zao"], "zao")
    }

    func testDisplaySeparatorOverrideYieldsApostropheAcceptance() throws {
        let spaced = projection(
            separator: " ",
            syllables: [
                syllable("zao", [("zc", true, false)]),
                syllable("shang", [("uh", true, false)]),
                syllable("hao", [("hc", true, false)]),
            ])
        XCTAssertEqual(try CompactSchemaAdapter.makeDisplayCapability(from: spaced).capability.separator, " ")
        XCTAssertEqual(
            try CompactSchemaAdapter.makeDisplayCapability(from: spaced, displaySeparator: "'")
                .capability.separator, "'")
    }

    func testEmptyDisplaySeparatorRejected() {
        XCTAssertThrowsError(
            try CompactSchemaAdapter.makeDisplayCapability(
                from: projection(separator: "", syllables: [syllable("zao", [("zc", true, false)])]))
        ) {
            XCTAssertEqual($0 as? CompactSchemaAdapter.DisplayCapabilityError, .emptySeparator)
        }
    }

    func testFullPinyinIdentityIsRecordedExplicitlyNotImplied() throws {
        let source = projection(
            schema: "songyan_quanpin", algebra: [], separator: " ",
            syllables: [
                syllable("zao", [("zao", true, false)]),
                syllable("shang", [("shang", true, false)]),
                syllable("hao", [("hao", true, false)]),
            ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source)
        XCTAssertEqual(build.capability.syllables, ["zao": "zao", "shang": "shang", "hao": "hao"])
        XCTAssertEqual(Array(build.capability.syllables.keys).sorted(), ["hao", "shang", "zao"])
    }

    // MARK: - Ambiguity / missing / erase: reject the entry, don't pick the first, don't fill in identity

    func testAmbiguousNormalJuJvIsRejectedAndNotFirstPicked() throws {
        let source = projection(syllables: [
            syllable("ju", [("ju", true, false), ("jv", true, false)]),
            syllable("zao", [("zc", true, false)]),
        ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source)
        XCTAssertNil(build.capability.syllables["ju"], "an ambiguous token must be rejected, never pick the first")
        XCTAssertEqual(build.capability.rejectedTokens["ju"], "ambiguous_normal")
        XCTAssertEqual(
            build.capability.syllables["zao"], "zc",
            "remaining unique tokens can still be declared (partial domain is safe)")
        XCTAssertEqual(build.rejections.first?.detail, "ju,jv")
        XCTAssertThrowsError(try CompactSchemaAdapter.makeDisplayCapability(from: source, requireFullDomain: true)) {
            XCTAssertEqual($0 as? CompactSchemaAdapter.DisplayCapabilityError, .incompleteDomain(["ju"]))
        }
    }

    func testErasedAndMissingTokensAreRejected() throws {
        let source = projection(syllables: [
            syllable("zao", [("zc", true, false)]),
            syllable("xx", []),
        ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source)
        XCTAssertNil(build.capability.syllables["xx"])
        XCTAssertEqual(build.capability.rejectedTokens["xx"], "missing_normal")
    }

    func testFuzzyAbbrevAndCorrectionAreNotUsedAsNormal() throws {
        let source = projection(syllables: [
            syllable(
                "zao",
                [
                    ("zc", true, false), ("zc", false, false),
                    ("z", false, false), ("zc", true, true),
                ]),
            syllable("shang", [("sh", false, false)]),
        ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source)
        XCTAssertEqual(build.capability.syllables["zao"], "zc")
        XCTAssertNil(build.capability.syllables["shang"])
        XCTAssertEqual(build.capability.rejectedTokens["shang"], "missing_normal")
    }

    func testNonAlphabeticSpellingRejectedForSourceRendered() throws {
        let source = projection(syllables: [
            syllable("ni", [("ㄋㄧ", true, false)]),
            syllable("hao", [("hc", true, false)]),
        ])
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: source)
        XCTAssertNil(build.capability.syllables["ni"])
        XCTAssertEqual(build.capability.rejectedTokens["ni"], "non_alphabetic")
        XCTAssertEqual(build.capability.syllables["hao"], "hc")
    }

    func testEmptyDomainDuplicateAndAllRejected() {
        XCTAssertThrowsError(try CompactSchemaAdapter.makeDisplayCapability(from: projection(syllables: []))) {
            XCTAssertEqual($0 as? CompactSchemaAdapter.DisplayCapabilityError, .emptyTokenDomain)
        }
        let duplicated = projection(syllables: [
            syllable("zao", [("zc", true, false)]),
            syllable("zao", [("zc2", true, false)]),
        ])
        XCTAssertThrowsError(try CompactSchemaAdapter.makeDisplayCapability(from: duplicated)) {
            XCTAssertEqual($0 as? CompactSchemaAdapter.DisplayCapabilityError, .duplicateToken("zao"))
        }
        let allRejected = projection(syllables: [
            syllable("ju", [("ju", true, false), ("jv", true, false)]),
            syllable("xx", []),
        ])
        XCTAssertThrowsError(try CompactSchemaAdapter.makeDisplayCapability(from: allRejected)) {
            XCTAssertEqual($0 as? CompactSchemaAdapter.DisplayCapabilityError, .emptyResolvedDomain)
        }
    }

    // MARK: - Canonical authorization rests on the canonical pinyin token domain, not a single "你好" oracle

    func testCanonicalPinyinDomainValidation() {
        XCTAssertTrue(
            CompactSchemaAdapter.isCanonicalPinyinDomain(
                ["ni", "hao", "zhong", "guo", "er", "yu", "lve", "nv", "ju", "que", "xue"]))
        XCTAssertTrue(
            CompactSchemaAdapter.isCanonicalPinyinDomain(
                ["yi", "wu", "yue", "yuan", "yun", "a", "o", "e", "ang", "eng"]))
        // A non-pinyin token (counterexample: xx + xform/^xx$/nihao/) must be rejected.
        XCTAssertFalse(CompactSchemaAdapter.isCanonicalPinyinDomain(["xx"]))
        XCTAssertFalse(
            CompactSchemaAdapter.isCanonicalPinyinDomain(["ni", "xx"]), "a non-pinyin token rejects the whole set")
        XCTAssertFalse(CompactSchemaAdapter.isCanonicalPinyinDomain(["wq", "abcd"]), "shape-code tokens rejected")
        XCTAssertFalse(CompactSchemaAdapter.isCanonicalPinyinDomain([]))
        XCTAssertFalse(CompactSchemaAdapter.isCanonicalPinyinDomain(["Nihao"]), "non-lowercase-ASCII rejected")
    }

    // MARK: - Native digest adoption + the nil generation path clears an inherited capability block

    func testWireDictionaryCarriesRuntimeKeysIncludingAdapterSchema() throws {
        let build = try CompactSchemaAdapter.makeDisplayCapability(
            from: projection(
                syllables: [
                    syllable("zao", [("zc", true, false)]),
                    syllable("ju", [("ju", true, false), ("jv", true, false)]),
                ]))
        let wire = build.capability.settingAdapterSchema("keyboard_abc_14").wireDictionary()
        XCTAssertEqual(
            Set(wire.keys),
            [
                "version", "display_mode", "source_schema",
                "translator_namespace", "separator", "mapping_policy", "adapter_schema",
                "syllables", "rejected_tokens",
            ])
        XCTAssertEqual(wire["display_mode"] as? String, "source_code")
        XCTAssertEqual(wire["adapter_schema"] as? String, "keyboard_abc_14")
        XCTAssertEqual(wire["syllables"] as? [String: String], ["zao": "zc"])
        XCTAssertEqual(wire["rejected_tokens"] as? [String: String], ["ju": "ambiguous_normal"])
    }

    func testDecodeNativeProjectionJSON() throws {
        let json = Data(
            #"""
            {"source_schema":"songyan_flypy","translator_namespace":"translator","dictionary":"songyan_basic",
             "alphabet":"zyxwvutsrqponmlkjihgfedcba","algebra":["xform/(.)ao$/$1C/"],"separator":" ",
             "dictionary_checksum":1799550295,"fingerprint":"deadbeef",
             "syllables":{"zao":[{"text":"zc","normal":true,"correction":false}],
                          "ju":[{"text":"ju","normal":true,"correction":false},{"text":"jv","normal":true,"correction":false}]}}
            """#.utf8)
        let decoded = try XCTUnwrap(CompactSchemaAdapter.SourceProjection.decode(json: json))
        XCTAssertEqual(decoded.sourceSchema, "songyan_flypy")

        let build = try CompactSchemaAdapter.makeDisplayCapability(from: decoded)
        XCTAssertEqual(build.capability.syllables, ["zao": "zc"])
        XCTAssertEqual(build.capability.rejectedTokens, ["ju": "ambiguous_normal"])
    }

    func testNilGenerationStripsInheritedCapabilityBlock() throws {
        // The source itself carries a valid capability block; when projection fails (nil) the generated result must NOT contain it,
        // rather than inheriting it as canonical/source_code.
        let compiled = Data(
            """
            schema:
              schema_id: flypy_test
              name: Flypy Test
            engine:
              translators:
                - script_translator
            speller:
              alphabet: zyxwvutsrqponmlkjihgfedcba
              algebra: []
            translator:
              dictionary: songyan_basic
            keyboard_adapter:
              version: 1
              display_mode: canonical
              source_schema: flypy_test
              translator_namespace: translator
              separator: "'"
              adapter_schema: flypy_test
            """.utf8)

        let without = try CompactSchemaAdapter.generate(
            compiled: compiled, sourceID: "flypy_test",
            fold: .merged14, displayCapability: nil)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: without, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_adapter"], "the nil path must explicitly remove the inherited capability block")

        let build = try CompactSchemaAdapter.makeDisplayCapability(
            from: projection(
                schema: "flypy_test", syllables: [syllable("zao", [("zc", true, false)])]))
        let with = try CompactSchemaAdapter.generate(
            compiled: compiled, sourceID: "flypy_test",
            fold: .merged14, displayCapability: build.capability)
        let withRoot = try XCTUnwrap(Yams.load(yaml: String(decoding: with, as: UTF8.self)) as? [String: Any])
        let block = try XCTUnwrap(withRoot["keyboard_adapter"] as? [String: Any])
        XCTAssertEqual(block["display_mode"] as? String, "source_code")
        XCTAssertEqual(block["source_schema"] as? String, "flypy_test")
        XCTAssertEqual(
            block["adapter_schema"] as? String,
            CompactSchemaAdapter.identifier(sourceID: "flypy_test", fold: .merged14))
        XCTAssertEqual(block["syllables"] as? [String: String], ["zao": "zc"])
    }

    func testCanonicalWireBindsTarget() throws {
        let canonical = CompactSchemaAdapter.canonicalDisplayCapability(
            sourceSchema: "keyboard_47246213a538cb99d374_9", separator: "'")
        XCTAssertEqual(canonical.mode, "canonical")
        XCTAssertEqual(canonical.adapterSchema, "", "generate is responsible for binding the target")
    }

    func testCanonicalPinyinSourceDeclaration() throws {
        let declared = Data(
            """
            schema: { schema_id: t, name: T }
            engine: { translators: [script_translator] }
            keyboard_adapter_source: canonical_pinyin
            """.utf8)
        let undeclared = Data(
            """
            schema: { schema_id: t, name: T }
            engine: { translators: [script_translator] }
            """.utf8)
        XCTAssertTrue(CompactSchemaAdapter.declaresCanonicalPinyinSource(compiled: declared))
        XCTAssertFalse(
            CompactSchemaAdapter.declaresCanonicalPinyinSource(compiled: undeclared),
            "without an explicit declaration, canonical must not be granted from the token shape")

        // Declaration carried by the projection (from the compiled config, native artifact first).
        let declaredProjection = projection(
            declaration: "canonical_pinyin",
            syllables: [syllable("ni", [("ni", true, false)])])
        let undeclaredProjection = projection(
            declaration: "",
            syllables: [syllable("ni", [("ni", true, false)])])
        XCTAssertTrue(CompactSchemaAdapter.declaresCanonicalPinyinSource(projection: declaredProjection))
        XCTAssertFalse(CompactSchemaAdapter.declaresCanonicalPinyinSource(projection: undeclaredProjection))
    }

    func testInjectingCapabilityStripsInheritedBlock() throws {
        // Injection must strip a block inherited from the source clone
        // regardless of whether a replacement is supplied.
        let schema = Data(
            """
            schema: { schema_id: keyboard_3d7821f984693864ae91_14, name: F }
            keyboard_adapter:
              version: 1
              display_mode: source_code
              source_schema: songyan_flypy
              translator_namespace: translator
              separator: "'"
              mapping_policy: unique_normal
              adapter_schema: keyboard_3d7821f984693864ae91_14
              syllables: { zao: zc }
            """.utf8)
        let stripped = try CompactSchemaAdapter.injectingCapability(
            into: schema, adapterSchema: "keyboard_3d7821f984693864ae91_14", displayCapability: nil)
        let strippedRoot = try XCTUnwrap(Yams.load(yaml: String(decoding: stripped, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(strippedRoot["keyboard_adapter"], "an inherited block must be removed")
    }

    func testTableTranslatorSourceGeneratesNoAdapterSoItStaysNative() throws {
        let wubi = Data(
            """
            schema:
              schema_id: wubi_test
              name: Wubi Test
            engine:
              translators:
                - table_translator
            speller:
              alphabet: zyxwvutsrqponmlkjihgfedcba
            translator:
              dictionary: wubi_test
            """.utf8)
        XCTAssertThrowsError(
            try CompactSchemaAdapter.generate(
                compiled: wubi, sourceID: "wubi_test",
                fold: .merged14, displayCapability: nil))
    }

    // MARK: - 9-key / 14-key independent rewrite capability (schema-agnostic)

    private var canonicalT9Source: Data {
        Data(
            """
            schema:
              schema_id: t9_test
              name: T9 Test
            engine:
              translators:
                - script_translator
            speller:
              alphabet: zyxwvutsrqponmlkjihgfedcba
              algebra:
                - derive/[abc]/2/
                - derive/[def]/3/
                - derive/[hgi]/4/
                - derive/[jkl]/5/
                - derive/[omn]/6/
                - derive/[pqrs]/7/
                - derive/[tuv]/8/
                - derive/[wxyz]/9/
            translator:
              dictionary: songyan_basic
            keyboard_adapter_source: canonical_pinyin
            """.utf8)
    }

    private var identityProjection: CompactSchemaAdapter.SourceProjection {
        .init(
            sourceSchema: "t9_test", translatorNamespace: "translator", dictionary: "songyan_basic",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [],
            separator: "'", declaration: "canonical_pinyin",
            syllables: [
                syllable("ni", [("ni", true, false)]),
                syllable("shang", [("shang", true, false)]),
            ])
    }

    private var destructiveProjection: CompactSchemaAdapter.SourceProjection {
        .init(
            sourceSchema: "t9_test", translatorNamespace: "translator", dictionary: "songyan_basic",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: ["xform/^sh/U/"],
            separator: "'", declaration: "canonical_pinyin",
            syllables: [
                syllable("shang", [("uh", true, false)]),
                syllable("ni", [("ni", true, false)]),
            ])
    }

    func displayCapability() -> CompactSchemaAdapter.DisplayCapability {
        CompactSchemaAdapter.DisplayCapability(
            version: 1, mode: "source_code", sourceSchema: "t9_test",
            translatorNamespace: "translator",
            separator: "'", mappingPolicy: "unique_normal", syllables: [:])
    }

    private func rewriteBlock(_ root: [String: Any]) -> [String: Any]? {
        root["keyboard_rewrite"] as? [String: Any]
    }

    func testInjectingCapabilityWritesIndependentRewriteBlock() throws {
        let schema = Data(
            """
            schema: { schema_id: keyboard_3d7821f984693864ae91_14, name: F }
            keyboard_adapter:
              version: 1
              display_mode: source_code
              source_schema: songyan_flypy
              translator_namespace: translator
              separator: "'"
              mapping_policy: unique_normal
              adapter_schema: keyboard_3d7821f984693864ae91_14
              syllables: { zao: zc }
            keyboard_rewrite:
              version: 2
              lock: bounded_token_alias_rewrite_v2
              adapter_schema: stale_adapter
            """.utf8)
        // Both nil -> both blocks stripped.
        let stripped = try CompactSchemaAdapter.injectingCapability(
            into: schema, adapterSchema: "keyboard_3d7821f984693864ae91_14", displayCapability: nil,
            rewriteCapability: nil)
        let strippedRoot = try XCTUnwrap(Yams.load(yaml: String(decoding: stripped, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(strippedRoot["keyboard_adapter"], "the old display block must be removed")
        XCTAssertNil(strippedRoot["keyboard_rewrite"], "the old rewrite block must be removed")

        // Native display + rewrite: only the rewrite block is present, and it is
        // rebound to this adapter.
        let rewrite = CompactSchemaAdapter.RewriteCapability(
            version: CompactSchemaAdapter.rewriteWireVersion,
            lock: CompactSchemaAdapter.tokenAliasLockValue,
            sourceSchema: "songyan_flypy",
            translatorNamespace: "translator", adapterSchema: "keyboard_3d7821f984693864ae91_14",
            lockMap: ["shang": "9084"])
        let nativePlusRewrite = try CompactSchemaAdapter.injectingCapability(
            into: schema, adapterSchema: "keyboard_3d7821f984693864ae91_14", displayCapability: nil,
            rewriteCapability: rewrite)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: nativePlusRewrite, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_adapter"], "native display writes no display block")
        let block = try XCTUnwrap(rewriteBlock(root))
        XCTAssertEqual(block["version"] as? Int, CompactSchemaAdapter.rewriteWireVersion)
        XCTAssertEqual(block["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
        XCTAssertEqual(block["adapter_schema"] as? String, "keyboard_3d7821f984693864ae91_14")
        XCTAssertEqual(block["source_schema"] as? String, "songyan_flypy")
        XCTAssertEqual(block["translator_namespace"] as? String, "translator")
        XCTAssertEqual(block["lock_map"] as? [String: String], ["shang": "9084"])
    }

    func testGenerateCarriesIndependentRewriteForBothLayouts() throws {
        for nine in [true, false] {
            let data = try CompactSchemaAdapter.generate(
                compiled: canonicalT9Source, sourceID: "t9_test", fold: nine ? .phone9 : .merged14,
                displayCapability: nil, sourceProjection: identityProjection)
            let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
            XCTAssertNil(root["keyboard_adapter"], "no display requested -> no display block (nineKey=\(nine))")
            let block = try XCTUnwrap(rewriteBlock(root), "rewrite must be carried even with native display")
            XCTAssertEqual(block["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
            XCTAssertEqual(block["source_schema"] as? String, "t9_test")
            XCTAssertEqual(block["translator_namespace"] as? String, "translator")
            let map = try XCTUnwrap(block["lock_map"] as? [String: String])
            XCTAssertEqual(Set(map.keys), ["ni", "shang"])
            XCTAssertEqual(block["version"] as? Int, CompactSchemaAdapter.rewriteWireVersion)
        }
    }

    func testRewriteLockIsTokenAliasForBothFolds() throws {
        for nine in [true, false] {
            let data = try CompactSchemaAdapter.generate(
                compiled: canonicalT9Source, sourceID: "t9_test", fold: nine ? .phone9 : .merged14,
                displayCapability: displayCapability(), sourceProjection: identityProjection)
            let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
            let lock = rewriteBlock(root)?["lock"] as? String
            XCTAssertEqual(lock, CompactSchemaAdapter.tokenAliasLockValue, "nineKey=\(nine)")
        }
    }

    /// The rewrite layer never requires canonical identity to survive: a destructive
    /// source still gets the rewrite block because the alias layer is prepended
    /// BEFORE the source algebra and re-proven against the live prism at runtime.
    func testDestructiveSourceStillGetsRewriteLock() throws {
        let data = try CompactSchemaAdapter.generate(
            compiled: canonicalT9Source, sourceID: "t9_test", fold: .phone9,
            displayCapability: nil, sourceProjection: destructiveProjection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertEqual(rewriteBlock(root)?["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
    }

    func testNoProjectionGetsNoRewriteBlock() throws {
        let data = try CompactSchemaAdapter.generate(
            compiled: canonicalT9Source, sourceID: "t9_test", fold: .phone9,
            displayCapability: nil, sourceProjection: nil)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_rewrite"], "no projection -> no rewrite authorization")
        XCTAssertNil(root["keyboard_adapter"])
    }

    // MARK: - Exact domain / exact mapping binding

    func companion(
        _ source: CompactSchemaAdapter.SourceProjection,
        nine: Bool = false
    ) throws -> Data {
        try CompactSchemaAdapter.generate(
            compiled: canonicalT9Source, sourceID: "t9_test", fold: nine ? .phone9 : .merged14,
            displayCapability: nil, sourceProjection: source)
    }

    func testTokenAliasLockAuthorizedRequiresExactDomainAndMap() throws {
        let source = identityProjection  // tokens: ni, shang
        for nine in [false, true] {
            let data = try companion(source, nine: nine)
            XCTAssertTrue(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: source, companion: data), "nine=\(nine)")
            // A live domain that gained a token must fail closed (stale companion).
            let superset = CompactSchemaAdapter.SourceProjection(
                sourceSchema: "t9_test", translatorNamespace: "translator", dictionary: "songyan_basic",
                alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                declaration: "canonical_pinyin",
                syllables: [
                    syllable("ni", [("ni", true, false)]),
                    syllable("shang", [("shang", true, false)]),
                    syllable("hao", [("hao", true, false)]),
                ])
            XCTAssertFalse(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: superset, companion: data),
                "live superset must fail closed (nine=\(nine))")
            // A live domain that lost a token must fail closed.
            let subset = CompactSchemaAdapter.SourceProjection(
                sourceSchema: "t9_test", translatorNamespace: "translator", dictionary: "songyan_basic",
                alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                declaration: "canonical_pinyin",
                syllables: [syllable("ni", [("ni", true, false)])])
            XCTAssertFalse(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: subset, companion: data),
                "live subset must fail closed (nine=\(nine))")
        }
    }

    func testTokenAliasLockAuthorizedRejectsWrongAliasAndWrongDomain() throws {
        let source = identityProjection
        let expected = try XCTUnwrap(CompactSchemaAdapter.tokenAliasAssignmentMap(source))
        let entry = try XCTUnwrap(expected.first { $0.key == "shang" })
        for nine in [false, true] {
            let good = try companion(source, nine: nine)
            // Corrupt ONE alias in the baked layer -> refused.
            var yaml = String(decoding: good, as: UTF8.self)
            yaml = yaml.replacingOccurrences(
                of: "derive/^\(entry.key)$/\(entry.value)/", with: "derive/^\(entry.key)$/9zzz/")
            XCTAssertFalse(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: source, companion: Data(yaml.utf8)),
                "a wrong alias must fail closed (nine=\(nine))")
            // A companion baked from a DIFFERENT source domain -> refused.
            let other = CompactSchemaAdapter.SourceProjection(
                sourceSchema: "t9_test", translatorNamespace: "translator", dictionary: "songyan_basic",
                alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                declaration: "canonical_pinyin",
                syllables: [
                    syllable("hao", [("hao", true, false)]),
                    syllable("zao", [("zao", true, false)]),
                ])
            let otherData = try companion(other, nine: nine)
            XCTAssertFalse(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: source, companion: otherData), "nine=\(nine)")
        }
    }

    func testGeneratorVersionAndWireConstants() throws {
        XCTAssertGreaterThanOrEqual(CompactSchemaAdapter.displayGeneratorVersion, 7)
        XCTAssertEqual(CompactSchemaAdapter.tokenAliasLimit, 4096)
        XCTAssertEqual(CompactSchemaAdapter.tokenAliasSentinel, "90")
        XCTAssertEqual(CompactSchemaAdapter.rewriteWireVersionDirect, 3)
        XCTAssertEqual(CompactSchemaAdapter.directTokenLockValue, "direct_token_rewrite_v3")
        XCTAssertEqual(CompactSchemaAdapter.rewriteWireVersionPrefix, 4)
        XCTAssertEqual(CompactSchemaAdapter.prefixTokenLockValue, "prefix_token_rewrite_v4")
        XCTAssertEqual(CompactSchemaAdapter.letterClassPrefixLayerValue, "letter_class_v1")
        XCTAssertEqual(CompactSchemaAdapter.letterClassPrefixRule, "abbrev/^([a-z]).+$/$1/")
        XCTAssertEqual(CompactSchemaAdapter.letterClassPrefixKeyLimit, 26)
        XCTAssertEqual(CompactFold.merged14.target, "qqeettuuooaaddggjjlzzccbbm")
        XCTAssertEqual(CompactFold.merged18.target, "qwwrryuiipassffhjjlzxxvbbm")
        XCTAssertEqual(CompactFold.phone9.target, "22233344455566677778889999")
    }

    // MARK: - Letter-class prefix layer (v4)

    /// A numeric (2–9) source that explicitly opts in.
    private var optedNumericProjection: CompactSchemaAdapter.SourceProjection {
        .init(
            sourceSchema: "keyboard_47246213a538cb99d374_9", translatorNamespace: "translator",
            dictionary: "songyan_basic",
            alphabet: "23456789abcdefghijklmnopqrstuvwxyz", algebra: [],
            separator: "'", prefixDeclaration: "letter_class_v1",
            syllables: [
                syllable("a", [("a", true, false), ("2", true, false)]),
                syllable("ba", [("ba", true, false), ("22", true, false)]),
                syllable("ca", [("ca", true, false), ("22", true, false)]),
                syllable("de", [("de", true, false), ("33", true, false)]),
            ])
    }

    private func numericNineKeySource(_ id: String) -> Data {
        Data(
            """
            schema: {schema_id: \(id), name: \(id)}
            engine:
              translators:
                - script_translator
            speller:
              alphabet: "23456789abcdefghijklmnopqrstuvwxyz"
              algebra:
                - 'derive/[abc]/2/'
                - 'derive/[def]/3/'
            translator: {dictionary: d, prism: \(id), user_dict: d}
            """.utf8)
    }

    func testPrefixKeysComeFromTheRealTokenInventoryOnly() throws {
        let keys = try XCTUnwrap(CompactSchemaAdapter.letterClassPrefixKeys(optedNumericProjection))
        XCTAssertEqual(keys, ["a", "b", "c", "d"])
        // No token -> no layer (fail closed, never a synthesized alphabet).
        let empty = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t9", translatorNamespace: "translator", dictionary: "d",
            alphabet: "23456789", algebra: [], separator: "'",
            prefixDeclaration: "letter_class_v1", syllables: [])
        XCTAssertNil(CompactSchemaAdapter.letterClassPrefixKeys(empty))
        // A non-opted source is never a v4 candidate.
        XCTAssertFalse(
            CompactSchemaAdapter.declaresLetterClassPrefixSource(
                CompactSchemaAdapter.SourceProjection(
                    sourceSchema: "t9", translatorNamespace: "translator", dictionary: "d",
                    alphabet: "23456789", algebra: [], separator: "'",
                    syllables: [syllable("a", [("2", true, false)])])))
    }

    func testOptedNumericSourceGeneratesV4PrefixCompanion() throws {
        let data = try CompactSchemaAdapter.generate(
            compiled: numericNineKeySource("keyboard_47246213a538cb99d374_9"),
            sourceID: "keyboard_47246213a538cb99d374_9", fold: .phone9,
            displayCapability: nil, sourceProjection: optedNumericProjection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        let block = try XCTUnwrap(rewriteBlock(root))
        XCTAssertEqual(block["version"] as? Int, 4)
        XCTAssertEqual(block["lock"] as? String, "prefix_token_rewrite_v4")
        XCTAssertEqual(block["prefix_layer"] as? String, "letter_class_v1")
        XCTAssertEqual(block["prefix_keys"] as? [String], ["a", "b", "c", "d"])
        XCTAssertNil(block["lock_map"], "v4 carries no per-token alias map")
        XCTAssertNil(block["direct_tokens"])
        // The abbreviation layer is added to the GENERATED grammar, before the
        // fold derives, so a single letter becomes a live key of its class.
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertEqual(algebra.first, "abbrev/^([a-z]).+$/$1/")
        let alphabet = try XCTUnwrap(speller["alphabet"] as? String)
        XCTAssertTrue(alphabet.contains("a") && alphabet.contains("2"))
    }

    func testUnOptedSourceKeepsTheAliasLock() throws {
        let unOpted = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "keyboard_47246213a538cb99d374_9", translatorNamespace: "translator",
            dictionary: "songyan_basic",
            alphabet: "23456789abcdefghijklmnopqrstuvwxyz", algebra: [],
            separator: "'",
            syllables: [
                syllable("a", [("a", true, false), ("2", true, false)]),
                syllable("ba", [("ba", true, false), ("22", true, false)]),
            ])
        let data = try CompactSchemaAdapter.generate(
            compiled: numericNineKeySource("keyboard_47246213a538cb99d374_9"),
            sourceID: "keyboard_47246213a538cb99d374_9", fold: .phone9,
            displayCapability: nil, sourceProjection: unOpted)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        let block = try XCTUnwrap(rewriteBlock(root))
        XCTAssertEqual(
            block["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue,
            "no opt-in -> the schema-agnostic alias lock is unchanged")
        XCTAssertNil(block["prefix_keys"])
        let algebra = try XCTUnwrap((root["speller"] as? [String: Any])?["algebra"] as? [String])
        XCTAssertFalse(
            algebra.contains(CompactSchemaAdapter.letterClassPrefixRule),
            "no opt-in -> no letter-class grammar is injected")
    }

    /// The opt-in is part of the source contract: a source that revokes
    /// it can never keep a v4 companion verified.
    func testPrefixDeclarationIsFoldedIntoTheSourceContract() throws {
        XCTAssertEqual(optedNumericProjection.prefixDeclaration, "letter_class_v1")
        let opted = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t9", translatorNamespace: "translator", dictionary: "d",
            alphabet: "23456789", algebra: [], separator: "'",
            prefixDeclaration: "letter_class_v1", syllables: [])
        let revoked = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t9", translatorNamespace: "translator", dictionary: "d",
            alphabet: "23456789", algebra: [], separator: "'",
            prefixDeclaration: "", syllables: [])
        XCTAssertTrue(CompactSchemaAdapter.declaresLetterClassPrefixSource(opted))
        XCTAssertFalse(CompactSchemaAdapter.declaresLetterClassPrefixSource(revoked))
    }

    func testPrefixLockAuthorizedRequiresTheBakedLayer() throws {
        let keys = try XCTUnwrap(CompactSchemaAdapter.letterClassPrefixKeys(optedNumericProjection))
        let data = try CompactSchemaAdapter.generate(
            compiled: numericNineKeySource("keyboard_47246213a538cb99d374_9"),
            sourceID: "keyboard_47246213a538cb99d374_9", fold: .phone9,
            displayCapability: nil, sourceProjection: optedNumericProjection)
        XCTAssertTrue(
            CompactSchemaAdapter.prefixLockAuthorized(
                sourceProjection: optedNumericProjection, companion: data, keys: keys,
                layerAlreadyPresent: false))
        // A companion whose declared rule was altered must fail closed.
        var yaml = String(decoding: data, as: UTF8.self)
        yaml = yaml.replacingOccurrences(
            of: CompactSchemaAdapter.letterClassPrefixRule,
            with: "abbrev/^([a-z]).+$/$2/")
        XCTAssertFalse(
            CompactSchemaAdapter.prefixLockAuthorized(
                sourceProjection: optedNumericProjection, companion: Data(yaml.utf8),
                keys: keys, layerAlreadyPresent: false),
            "the declared layer must really be baked into the companion")
        // A key the companion cannot type is refused.
        XCTAssertFalse(
            CompactSchemaAdapter.prefixLockAuthorized(
                sourceProjection: optedNumericProjection, companion: data, keys: ["a", "Z"],
                layerAlreadyPresent: false))
        // A source that did not opt in can never authorize the lock.
        XCTAssertFalse(
            CompactSchemaAdapter.prefixLockAuthorized(
                sourceProjection: CompactSchemaAdapter.SourceProjection(
                    sourceSchema: "keyboard_47246213a538cb99d374_9", translatorNamespace: "translator",
                    dictionary: "songyan_basic",
                    alphabet: "23456789", algebra: [], separator: "'",
                    syllables: [syllable("a", [("a", true, false)])]),
                companion: data, keys: keys, layerAlreadyPresent: false))
    }

    func testRewriteCapabilityWireShapeForPrefixMode() throws {
        let capability = CompactSchemaAdapter.RewriteCapability(
            version: CompactSchemaAdapter.rewriteWireVersionPrefix,
            lock: CompactSchemaAdapter.prefixTokenLockValue,
            sourceSchema: "keyboard_47246213a538cb99d374_9",
            translatorNamespace: "translator", adapterSchema: "adapter9",
            lockMap: [:], prefixKeys: ["a", "b"], prefixLayer: "letter_class_v1")
        let wire = capability.wireDictionary()
        XCTAssertEqual(wire["version"] as? Int, 4)
        XCTAssertEqual(wire["lock"] as? String, "prefix_token_rewrite_v4")
        XCTAssertEqual(wire["prefix_keys"] as? [String], ["a", "b"])
        XCTAssertEqual(wire["prefix_layer"] as? String, "letter_class_v1")
        XCTAssertNil(wire["lock_map"])
        XCTAssertNil(wire["direct_tokens"])
        XCTAssertEqual(capability.settingAdapterSchema("other").adapterSchema, "other")
    }

    // MARK: - Shared physical-alphabet contract (adaptability == generate)

    func tableSource(_ schemaID: String, alphabet: String) -> Data {
        Data(
            """
            schema: {schema_id: \(schemaID), name: \(schemaID)}
            engine: {translators: [table_translator]}
            speller: {alphabet: "\(alphabet)"}
            translator: {dictionary: d}
            """.utf8)
    }
}
