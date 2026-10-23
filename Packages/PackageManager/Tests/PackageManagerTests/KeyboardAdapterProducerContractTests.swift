import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

extension KeyboardAdapterDisplayCapabilityTests {
    // MARK: - Primary-producer contract (eligibility == dispatch == generator == native)

    /// A minimal source with an explicit `engine/translators` list. `translator`
    /// section entries (`translatorDefaults`) are appended so a default producer can
    /// carry a dictionary.
    func sourceWithTranslators(
        _ schemaID: String, _ translators: [String],
        translatorDefaults: Bool = true
    ) -> Data {
        let list = translators.map { "\"_\($0)\"".replacingOccurrences(of: "_", with: "\"") }.joined(separator: ", ")
        let translatorSection = translatorDefaults ? "\ntranslator: {dictionary: d}" : ""
        return Data(
            """
            schema: {schema_id: \(schemaID), name: \(schemaID)}
            engine: {translators: [\(list)]}
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            \(translatorSection)
            """.utf8)
    }

    func testPrimaryProducerMirrorsNativeSingleProducer() throws {
        // Unique default wins over any number of named auxiliaries.
        let withAux = CompactSchemaAdapter.primaryProducer(
            translators: [
                "punct_translator", "script_translator",
                "table_translator@custom_phrase", "lua_translator@*date_translator",
            ])
        XCTAssertEqual(withAux?.klass, .script)
        XCTAssertEqual(withAux?.namespace, "translator")
        XCTAssertEqual(withAux?.isDefaultNamespace, true)
        let tableDefault = CompactSchemaAdapter.primaryProducer(
            translators: [
                "punct_translator", "table_translator",
                "table_translator@custom_phrase", "reverse_lookup_translator",
            ])
        XCTAssertEqual(tableDefault?.klass, .table)
        XCTAssertEqual(tableDefault?.isDefaultNamespace, true)
        // Two default producers -> mixed provenance -> nil.
        XCTAssertNil(
            CompactSchemaAdapter.primaryProducer(
                translators: ["script_translator", "table_translator"]))
        XCTAssertNil(
            CompactSchemaAdapter.primaryProducer(
                translators: ["script_translator", "script_translator@alt", "table_translator"]))
        // Named-only: exactly one is a read-only fallback with its own namespace.
        let namedOnly = CompactSchemaAdapter.primaryProducer(
            translators: ["table_translator@custom_phrase"])
        XCTAssertEqual(namedOnly?.namespace, "custom_phrase")
        XCTAssertEqual(namedOnly?.isDefaultNamespace, false)
        XCTAssertNil(
            CompactSchemaAdapter.primaryProducer(
                translators: ["table_translator@a", "table_translator@b"]))
        XCTAssertNil(CompactSchemaAdapter.primaryProducer(translators: ["punct_translator"]))
    }

    func testDefaultTableWithAuxiliariesIsAdaptableAndPreserved() throws {
        // Real schemas commonly carry `table_translator@custom_phrase` plus a
        // reverse-lookup translator; those must NOT make the primary look mixed.
        let source = Data(
            """
            schema: {schema_id: tbl_aux, name: tbl_aux}
            engine:
              translators: [punct_translator, reverse_lookup_translator, table_translator, table_translator@custom_phrase, lua_translator@*calc]
              segmentors: [abc_segmentor, matcher, fallback_segmentor]
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            translator: {dictionary: d}
            custom_phrase: {dictionary: "", user_dict: custom_phrase, db_class: stabledb}
            reverse_lookup: {dictionary: pinyin_simp, prefix: z}
            """.utf8)
        XCTAssertEqual(
            try CompactSchemaAdapter.adaptability(compiled: source, sourceID: "tbl_aux"),
            .adaptable)
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "tbl_aux", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "table_translator",
            syllables: [
                syllable("kw", [("kw", true, false)]),
                syllable("kk", [("kk", true, false)]),
            ])
        let data = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "tbl_aux", fold: .merged14,
            displayCapability: nil, sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        // The FULL translator list (order + auxiliaries) is preserved verbatim.
        let engine = try XCTUnwrap(root["engine"] as? [String: Any])
        XCTAssertEqual(
            engine["translators"] as? [String],
            [
                "punct_translator", "reverse_lookup_translator", "table_translator",
                "table_translator@custom_phrase", "lua_translator@*calc",
            ])
        XCTAssertEqual(
            engine["segmentors"] as? [String],
            ["abc_segmentor", "matcher", "fallback_segmentor"])
        XCTAssertNotNil(root["custom_phrase"], "auxiliary config section preserved")
        XCTAssertNotNil(root["reverse_lookup"], "reverse_lookup section preserved")
        // The primary `translator` section was rewritten to the new prism.
        let translator = try XCTUnwrap(root["translator"] as? [String: Any])
        XCTAssertEqual(
            translator["prism"] as? String,
            "keyboard_"
                + String(
                    CompactSchemaAdapter.identifier(sourceID: "tbl_aux", fold: .merged14).dropFirst("keyboard_".count)))
        // DIRECT capability present, no lock_map.
        let block = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any])
        XCTAssertEqual(block["lock"] as? String, CompactSchemaAdapter.directTokenLockValue)
        XCTAssertNil(block["lock_map"])
    }

    func testDefaultScriptWithNamedTableAuxiliaryGoesScriptNotMixed() throws {
        let source = Data(
            """
            schema: {schema_id: scr_aux, name: scr_aux}
            engine:
              translators: [punct_translator, script_translator, table_translator@custom_phrase]
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            translator: {dictionary: d}
            custom_phrase: {dictionary: "", user_dict: custom_phrase, db_class: stabledb}
            """.utf8)
        XCTAssertEqual(
            try CompactSchemaAdapter.adaptability(compiled: source, sourceID: "scr_aux"),
            .adaptable)
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "scr_aux", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "script_translator",
            syllables: [syllable("ni", [("ni", true, false)])])
        let data = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "scr_aux", fold: .merged14,
            displayCapability: nil, sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        let engine = try XCTUnwrap(root["engine"] as? [String: Any])
        XCTAssertEqual(
            engine["translators"] as? [String],
            ["punct_translator", "script_translator", "table_translator@custom_phrase"],
            "script path reached; auxiliary preserved")
        // Script path emits the ALIAS lock (v2), not the direct lock.
        let block = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any])
        XCTAssertEqual(block["lock"] as? String, CompactSchemaAdapter.tokenAliasLockValue)
        XCTAssertNotNil(block["lock_map"])
    }

    func testRimeStyleCaseAliasedAlphabetIsAdaptableAndGenerates() throws {
        let alphabet = "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA`"
        let source = Data(
            """
            schema: {schema_id: case_alias, name: Case Alias}
            engine:
              translators: [punct_translator, script_translator, table_translator@custom_phrase]
            speller: {alphabet: "\(alphabet)"}
            translator: {dictionary: d}
            custom_phrase: {dictionary: "", user_dict: custom_phrase, db_class: stabledb}
            """.utf8)
        XCTAssertEqual(
            try CompactSchemaAdapter.adaptability(
                compiled: source, sourceID: "case_alias"), .adaptable)
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "case_alias", translatorNamespace: "translator", dictionary: "d",
            alphabet: alphabet, algebra: [], separator: "'",
            producerClass: "script_translator",
            syllables: [syllable("ni", [("ni", true, false)])])
        XCTAssertNoThrow(
            try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "case_alias", fold: .merged14,
                displayCapability: nil, sourceProjection: projection))
        XCTAssertNoThrow(
            try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "case_alias", fold: .phone9,
                displayCapability: nil, sourceProjection: projection))
    }

    func testTwoDefaultProducersFailClosedBeforeGeneration() throws {
        let source = Data(
            """
            schema: {schema_id: mixed, name: mixed}
            engine: {translators: [script_translator, table_translator]}
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            translator: {dictionary: d}
            """.utf8)
        switch try CompactSchemaAdapter.adaptability(compiled: source, sourceID: "mixed") {
        case .unsupported: break
        case .adaptable: XCTFail("two default producers must not be adaptable")
        }
        // And the generator refuses too (never "adaptable then throw").
        XCTAssertThrowsError(
            try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "mixed", fold: .merged14,
                displayCapability: nil,
                sourceProjection: CompactSchemaAdapter.SourceProjection(
                    sourceSchema: "mixed", translatorNamespace: "translator", dictionary: "d",
                    alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                    producerClass: "script_translator",
                    syllables: [syllable("ni", [("ni", true, false)])])))
    }

    func testNamedOnlyProducerIsExplicitlyUnsupportedNotAdaptable() throws {
        let source = Data(
            """
            schema: {schema_id: named_only, name: named_only}
            engine: {translators: [punct_translator, table_translator@custom_phrase]}
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            custom_phrase: {dictionary: "", user_dict: custom_phrase, db_class: stabledb}
            """.utf8)
        switch try CompactSchemaAdapter.adaptability(compiled: source, sourceID: "named_only") {
        case .unsupported(let reason):
            XCTAssertTrue(reason.contains("default-namespace"), "got: \(reason)")
        case .adaptable:
            XCTFail("a named-only producer must be explicitly unsupported for auto-generation")
        }
        // The generator must also refuse (no "adaptable then throw").
        XCTAssertThrowsError(
            try CompactSchemaAdapter.generate(
                compiled: source, sourceID: "named_only", fold: .merged14,
                displayCapability: nil,
                sourceProjection: CompactSchemaAdapter.SourceProjection(
                    sourceSchema: "named_only", translatorNamespace: "custom_phrase", dictionary: "d",
                    alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                    producerClass: "table_translator",
                    syllables: [syllable("kw", [("kw", true, false)])])))
    }

    func testPhysicalFoldIsTheSingleSharedContract() throws {
        // Full a-z: 12 exact-token rules first, then 12 real fold rules; compact keys,
        // letters and exact tokens typeable.
        let full = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: "zyxwvutsrqponmlkjihgfedcba", fold: .merged14))
        XCTAssertEqual(full.rules.count, 24)
        XCTAssertEqual(full.exactTokenRules, Array(full.rules.prefix(12)))
        XCTAssertTrue(full.exactTokenRules.contains("derive/d/>/"))
        XCTAssertEqual(full.exactTokenPreedit, "xlit/<~|>#@^+!%*_/abcdegjoqtuz/")
        XCTAssertTrue(full.typeableAlphabet.contains(">"))
        XCTAssertTrue(full.rules.contains("derive/w/q/"))
        XCTAssertTrue(full.rules.contains("derive/s/a/"))
        XCTAssertFalse(full.rules.contains("derive/q/q/"), "a fixpoint rule is never emitted")
        XCTAssertTrue(full.typeableAlphabet.contains("q"))
        // Missing `z` (real shape code alphabets need not carry every letter): still
        // adaptable, and NO `z`-rule is invented.
        let noZ = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: "abcdefghijklmnopqrstuvwxy", fold: .merged14))
        XCTAssertFalse(
            noZ.rules.contains { $0.hasPrefix("derive/z/") },
            "must not invent a key the source does not have")
        // Sparse custom letter set.
        let sparse = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: "abc", fold: .merged14))
        XCTAssertEqual(Set(sparse.rules), [], "no partner letter, no exact token")
        XCTAssertTrue(sparse.typeableAlphabet.contains("b"))
        // Invalid / empty fail closed.
        XCTAssertNil(CompactSchemaAdapter.physicalFold(sourceAlphabet: "", fold: .merged14))
        XCTAssertNil(CompactSchemaAdapter.physicalFold(sourceAlphabet: "abc\u{4e2d}", fold: .merged14))
        XCTAssertNil(CompactSchemaAdapter.physicalFold(sourceAlphabet: "ab c", fold: .merged14))

        // Real Rime schemas commonly append uppercase aliases to the same physical
        // lowercase alphabet. They remain adaptable; an uppercase-only key does not.
        let rimeAlphabet = "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA`"
        let caseAliases = try XCTUnwrap(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: rimeAlphabet, fold: .merged14))
        XCTAssertEqual(caseAliases.rules.count, 50)
        XCTAssertTrue(caseAliases.rules.contains("derive/W/q/"))
        XCTAssertTrue(
            caseAliases.rules.contains("derive/Q/q/"),
            "uppercase fixpoints still need a compact-key derive")
        XCTAssertTrue(
            caseAliases.typeableAlphabet.contains("W"),
            "exact direct-token rewrite must be accepted by the companion")
        XCTAssertTrue(caseAliases.typeableAlphabet.contains("`"))
        XCTAssertNil(CompactSchemaAdapter.physicalFold(sourceAlphabet: "abcZ", fold: .merged14))
        XCTAssertNil(CompactSchemaAdapter.physicalFold(sourceAlphabet: "ABC", fold: .merged14))
    }

    /// `adaptability` and `generate` must agree: a source missing letters must be
    /// judged adaptable AND generate without throwing.
    func testAdaptabilityAndGenerateAgreeOnSparseAlphabets() throws {
        for alphabet in [
            "abcdefghijklmnopqrstuvwxy", "abc", "zyxwvutsrqponmlkjihgfedcba",
            "zyxwvutsrqponmlkjihgfedcbaZYXWVUTSRQPONMLKJIHGFEDCBA`",
        ] {
            let source = tableSource("sparse_test", alphabet: alphabet)
            XCTAssertEqual(
                try CompactSchemaAdapter.adaptability(compiled: source, sourceID: "sparse_test"),
                .adaptable, "alphabet=\(alphabet)")
            let projection = CompactSchemaAdapter.SourceProjection(
                sourceSchema: "sparse_test", translatorNamespace: "translator",
                dictionary: "d", alphabet: alphabet, algebra: [], separator: "'",
                producerClass: "table_translator",
                syllables: [syllable("abc", [("abc", true, false)])])
            XCTAssertNoThrow(
                try CompactSchemaAdapter.generate(
                    compiled: source, sourceID: "sparse_test", fold: .merged14,
                    displayCapability: nil, sourceProjection: projection), "alphabet=\(alphabet)")
        }
        // Non-foldable physical alphabet fails BOTH consistently.
        let bad = tableSource("bad_test", alphabet: "abc\u{4e2d}")
        XCTAssertEqual(
            try CompactSchemaAdapter.adaptability(compiled: bad, sourceID: "bad_test"),
            .unsupported("speller alphabet is not a foldable latin/numeric input alphabet"))
        // A numeric (2–9) physical key space is typeable on the 9-key layout only: it
        // is adaptable (a 9-key companion exists) while the 14-key fold is not
        // constructible, so `prepare` skips ONLY that layout instead of writing the
        // whole source off as unsupported (a digit-coded 9-key scheme).
        let numeric = tableSource("numeric_test", alphabet: "23456789abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(
            try CompactSchemaAdapter.adaptability(compiled: numeric, sourceID: "numeric_test"),
            .adaptable)
        XCTAssertNil(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: "23456789abcdefghijklmnopqrstuvwxyz", fold: .merged14),
            "the 14-key layout cannot type a source's numeric keys")
        XCTAssertNotNil(
            CompactSchemaAdapter.physicalFold(
                sourceAlphabet: "23456789abcdefghijklmnopqrstuvwxyz", fold: .phone9))
    }

    func testTableUppercaseTokenGetsAReachableCompactDeriveAndMatchingSample() throws {
        let alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let source = Data(
            """
            schema: {schema_id: uppercase_table, name: uppercase_table}
            engine: {translators: [table_translator]}
            speller: {alphabet: "\(alphabet)"}
            translator: {dictionary: d}
            recognizer: {import_preset: default}
            """.utf8)
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "uppercase_table", translatorNamespace: "translator",
            dictionary: "d", alphabet: alphabet, algebra: [], separator: "'",
            producerClass: "table_translator",
            syllables: [syllable("W", [("W", true, false)])])

        XCTAssertEqual(
            CompactSchemaAdapter.directTokenSample(
                projection, fold: .merged14), ["W"])
        let generated = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "uppercase_table", fold: .merged14,
            displayCapability: nil, sourceProjection: projection)
        let root = try XCTUnwrap(
            Yams.load(
                yaml: String(decoding: generated, as: UTF8.self)) as? [String: Any])
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertTrue(
            algebra.contains("derive/W/q/"),
            "accepted uppercase table codes must be reachable from compact keys")
        XCTAssertTrue((speller["alphabet"] as? String)?.contains("q") == true)
        XCTAssertTrue(
            (speller["alphabet"] as? String)?.contains("W") == true,
            "librime must accept the exact direct token during lock apply")
    }

    // MARK: - Numeric detection scans the COMPLETE projection, order-independent

    func testIsNumericCodeSourceScansWholeProjection() throws {
        func syl(_ t: String, _ s: String) -> CompactSchemaAdapter.ProjectedSyllable {
            .init(token: t, spellings: [.init(text: s, isNormal: true, isCorrection: false)])
        }
        func proj(_ s: [CompactSchemaAdapter.ProjectedSyllable]) -> CompactSchemaAdapter.SourceProjection {
            .init(
                sourceSchema: "n", translatorNamespace: "translator", dictionary: "d",
                alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
                producerClass: "script_translator", syllables: s)
        }
        XCTAssertTrue(CompactSchemaAdapter.isNumericCodeSource(proj([syl("ni", "64"), syl("hao", "426")])))
        // A numeric spelling appearing only at token index 32 (past any prefix) and
        // only as the 9th spelling is still detected. Every token is numeric, but the
        // LAST one only reveals its numeric spelling at slot 9.
        let many: [CompactSchemaAdapter.ProjectedSyllable] =
            (0..<32).map {
                syl("t\($0)", "4\($0 % 8 + 2)")
            } + [
                .init(
                    token: "late",
                    spellings: (0..<8).map {
                        .init(text: "p\($0)", isNormal: true, isCorrection: false)
                    } + [.init(text: "426", isNormal: true, isCorrection: false)])
            ]
        XCTAssertTrue(
            CompactSchemaAdapter.isNumericCodeSource(proj(many)),
            "a numeric spelling past the 32nd token / 9th slot is detected")
        // Reordering must not change the answer.
        XCTAssertTrue(CompactSchemaAdapter.isNumericCodeSource(proj(Array(many.reversed()))))
        // One non-numeric token makes the whole source non-numeric.
        XCTAssertFalse(CompactSchemaAdapter.isNumericCodeSource(proj([syl("ni", "64"), syl("x", "abc")])))
        XCTAssertFalse(CompactSchemaAdapter.isNumericCodeSource(proj([])))
    }

    // MARK: - Direct (table) mode: bounded sample + fold soundness

    func testDirectTokenSampleIsBoundedAndUniquelyIdentifiable() throws {
        // `s` folds to `a`, so the code `s` collides with the code `a`; only a code
        // unique within its fold class is sampled.
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "table_translator",
            syllables: [
                syllable("a", [("a", true, false)]),
                syllable("s", [("s", true, false)]),
                syllable("kw", [("kw", true, false)]),
            ])
        let sample = try XCTUnwrap(CompactSchemaAdapter.directTokenSample(projection, fold: .merged14))
        XCTAssertTrue(sample.contains("kw"), "a class-unique code is sampled")
        // `a` is a partial fold of `s` (both yield the key `a`), so key `a` is
        // ambiguous and must NOT be sampled; key `s` is unique and IS sampled.
        XCTAssertFalse(sample.contains("a"), "a code colliding with its fold partner is not sampled")
        XCTAssertTrue(sample.contains("s"), "the unique side of a collision is sampled")
        XCTAssertLessThanOrEqual(sample.count, 16)
        // An empty domain has no uniquely-identifiable code -> fail closed.
        let empty = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "table_translator", syllables: [])
        XCTAssertNil(CompactSchemaAdapter.directTokenSample(empty, fold: .merged14))
    }

    func testGenerateTableCompanionEmitsDirectLockWithoutLockMap() throws {
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "tbl", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            producerClass: "table_translator",
            syllables: [
                syllable("kw", [("kw", true, false)]),
                syllable("kk", [("kk", true, false)]),
            ])
        let data = try CompactSchemaAdapter.generate(
            compiled: tableSource("tbl", alphabet: "abcdefghijklmnopqrstuvwxyz"),
            sourceID: "tbl", fold: .merged14, displayCapability: nil,
            sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_adapter"], "table companions keep native display")
        let block = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any])
        XCTAssertEqual(block["version"] as? Int, CompactSchemaAdapter.rewriteWireVersionDirect)
        XCTAssertEqual(block["lock"] as? String, CompactSchemaAdapter.directTokenLockValue)
        XCTAssertNil(block["lock_map"], "direct mode carries no per-code map")
        XCTAssertNotNil(block["direct_tokens"])
        let speller = try XCTUnwrap(root["speller"] as? [String: Any])
        let algebra = try XCTUnwrap(speller["algebra"] as? [String])
        XCTAssertTrue(algebra.contains("derive/w/q/"), "per-letter fold rule present")
    }
}
