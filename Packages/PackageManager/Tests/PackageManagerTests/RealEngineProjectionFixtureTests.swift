import KeyboardCore
import XCTest
import Yams

@testable import PackageManager

/// Real-librime evidence: the JSON fixtures below were produced by a probe run against pinned macOS librime 1.17.0
/// (the fixture dictionary adds 早/早上/早上好 to cover the acceptance words). They show that the Xiaohe re-expression
/// mapping comes from the real source-algebra projection and not from an algebra stand-in made in this repo.
final class RealEngineProjectionFixtureTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> CompactSchemaAdapter.SourceProjection {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: name, withExtension: "json",
                subdirectory: "Fixtures"),
            "missing real-engine fixture \(name)")
        return try XCTUnwrap(CompactSchemaAdapter.SourceProjection.decode(json: Data(contentsOf: url)))
    }

    private func syllable(_ token: String, _ spellings: [(String, Bool, Bool)])
        -> CompactSchemaAdapter.ProjectedSyllable
    {
        CompactSchemaAdapter.ProjectedSyllable(
            token: token,
            spellings: spellings.map {
                .init(text: $0.0, isNormal: $0.1, isCorrection: $0.2)
            })
    }

    /// A near-real projection: token domain + one identity normal spelling each.
    private func projection(tokens: [String], declared: Bool = false)
        -> CompactSchemaAdapter.SourceProjection
    {
        .init(
            sourceSchema: "t", translatorNamespace: "translator", dictionary: "d",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: [], separator: "'",
            declaration: declared ? "canonical_pinyin" : "",
            syllables: tokens.map { syllable($0, [($0, true, false)]) })
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoFlypySource: Data {
        get throws {
            try Data(
                contentsOf: repoRoot()
                    .appendingPathComponent("Resources/BuiltinPackages/Basic/songyan_flypy.schema.yaml"))
        }
    }

    private func fourteenLock(_ root: [String: Any]) -> String? {
        (root["keyboard_rewrite"] as? [String: Any])?["lock"] as? String
    }

    // MARK: - Existing display-capability fixtures (unchanged semantics)

    func testRealFlypy26ProjectionYieldsAcceptanceSourceCoding() throws {
        let projection = try loadFixture("songyan_flypy.projection")
        XCTAssertEqual(projection.sourceSchema, "songyan_flypy")
        XCTAssertEqual(projection.translatorNamespace, "translator")
        XCTAssertEqual(projection.dictionary, "songyan_basic")
        XCTAssertEqual(
            projection.declaration, "canonical_pinyin",
            "the explicit source declaration is returned with the native artifact")
        XCTAssertFalse(projection.algebra.isEmpty, "the real source algebra must be projected")

        let build = try CompactSchemaAdapter.makeDisplayCapability(from: projection, displaySeparator: "'")
        XCTAssertEqual(build.capability.mode, "source_code")
        XCTAssertEqual(build.capability.separator, "'")
        XCTAssertEqual(build.capability.syllables["zao"], "zc")
        XCTAssertEqual(build.capability.syllables["shang"], "uh")
        XCTAssertEqual(build.capability.syllables["hao"], "hc")
        XCTAssertNil(build.capability.syllables["qu"])
        XCTAssertEqual(build.capability.rejectedTokens["qu"], "ambiguous_normal")
        XCTAssertThrowsError(try CompactSchemaAdapter.makeDisplayCapability(from: projection, requireFullDomain: true))
    }

    func testRealQuanpinProjectionIsExplicitIdentity() throws {
        let projection = try loadFixture("songyan_quanpin.projection")
        XCTAssertTrue(projection.algebra.isEmpty, "the full-pinyin source algebra is empty (a valid identity)")
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: projection)
        XCTAssertTrue(
            build.rejections.isEmpty, "an empty algebra's valid identity must be declarable over the whole domain")
        XCTAssertEqual(build.capability.syllables["zao"], "zao")
        XCTAssertEqual(build.capability.syllables["shang"], "shang")
        XCTAssertEqual(build.capability.syllables["hao"], "hao")
    }

    func testRealSecondDoublePinyinMspyUsesItsOwnAlgebra() throws {
        let projection = try loadFixture("double_pinyin_mspy_test.projection")
        XCTAssertEqual(projection.sourceSchema, "double_pinyin_mspy_test")
        let build = try CompactSchemaAdapter.makeDisplayCapability(from: projection)
        XCTAssertEqual(build.capability.syllables["zao"], "zk")
        XCTAssertEqual(build.capability.syllables["hao"], "hk")
        XCTAssertNil(build.capability.syllables["qu"])
    }

    func testFlypy14MergedAlgebraMustNotBeUsedAsSource() throws {
        let evidence = try String(
            contentsOf: XCTUnwrap(
                Bundle.module.url(
                    forResource: "README", withExtension: "md", subdirectory: "Fixtures")))
        XCTAssertTrue(evidence.contains("14-key companion `zcuggc`: `preedit=\"zc ug gc\""))
        XCTAssertTrue(evidence.contains("canonical=\"zao shang hao\""))
    }

    func testBuiltinFlypy14CapabilityMatchesRealSourceProjection() throws {
        let projection = try loadFixture("songyan_flypy.projection")
        let generated = try CompactSchemaAdapter.makeDisplayCapability(
            from: projection, displaySeparator: "'"
        ).capability
        let yaml = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Resources/BuiltinPackages/Basic/keyboard_3d7821f984693864ae91_14.schema.yaml"),
            encoding: .utf8)
        let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        let block = try XCTUnwrap(
            root["keyboard_adapter"] as? [String: Any], "the built-in 14-key schema must declare display capability")
        let embedded = try XCTUnwrap(
            SchemaDisplayCapability(wire: block), "the built-in capability block must strictly decode")

        XCTAssertEqual(embedded.mode, .sourceCode)
        XCTAssertEqual(
            embedded.syllables, generated.syllables, "the built-in map must match the source projection entry by entry")
        XCTAssertEqual(embedded.adapterSchema, "keyboard_3d7821f984693864ae91_14")
        XCTAssertEqual(embedded.separator, "'")
        XCTAssertEqual(embedded.syllables["zao"], "zc")
        XCTAssertEqual(embedded.syllables["shang"], "uh")
        XCTAssertEqual(embedded.syllables["hao"], "hc")
    }

    func testBuiltinFlypy14CarriesGenericAliasLockMatchingProjection() throws {
        let projection = try loadFixture("songyan_flypy.projection")
        let yaml = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Resources/BuiltinPackages/Basic/keyboard_3d7821f984693864ae91_14.schema.yaml"),
            encoding: .utf8)
        let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        XCTAssertEqual(fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue)
        let block = try XCTUnwrap(root["keyboard_rewrite"] as? [String: Any])
        XCTAssertEqual(
            block["lock_map"] as? [String: String],
            CompactSchemaAdapter.lockMap(projection),
            "the built-in lock_map must match deterministic regeneration from the source projection")
        XCTAssertTrue(
            CompactSchemaAdapter.tokenAliasLockAuthorized(
                sourceProjection: projection, companion: Data(yaml.utf8)))
    }

    func testBuiltinT9DeclaresCanonicalDisplayAndGenericAliasLock() throws {
        let yaml = try String(
            contentsOf: repoRoot()
                .appendingPathComponent("Resources/BuiltinPackages/Basic/keyboard_47246213a538cb99d374_9.schema.yaml"),
            encoding: .utf8)
        let root = try XCTUnwrap(Yams.load(yaml: yaml) as? [String: Any])
        let block = try XCTUnwrap(root["keyboard_adapter"] as? [String: Any])
        let capability = try XCTUnwrap(SchemaDisplayCapability(wire: block))
        XCTAssertEqual(capability.mode, .canonical)
        XCTAssertEqual(capability.sourceSchema, "songyan_quanpin")
        XCTAssertEqual(capability.adapterSchema, "keyboard_47246213a538cb99d374_9")
        XCTAssertEqual(capability.separator, " ")
        XCTAssertTrue(capability.syllables.isEmpty)
        // The rewrite capability is the schema-agnostic alias layer, not the
        // legacy canonical rewrite.
        XCTAssertEqual(fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue)
        XCTAssertNotNil((root["keyboard_rewrite"] as? [String: Any])?["lock_map"])
    }

    // MARK: - Schema-agnostic bounded token alias domain

    /// The domain is the whole primary token inventory, bounded and deterministic,
    /// regardless of token shape: pinyin, ASCII shape codes, extras and Unicode.
    func testTokenAliasDomainIsSchemaAgnostic() throws {
        let pinyin = projection(tokens: ["ni", "shang", "bu"])
        XCTAssertEqual(CompactSchemaAdapter.tokenAliasDomain(pinyin), ["bu", "ni", "shang"])
        let shape = projection(tokens: ["abc", "abd", "english", "ABC123"])
        XCTAssertEqual(
            CompactSchemaAdapter.tokenAliasDomain(shape),
            ["ABC123", "abc", "abd", "english"],
            "ASCII shape tokens are aliased, not shape-filtered")
        let bopomofo = projection(tokens: ["\u{3105}\u{3127}", "\u{3106}\u{3127}"])
        XCTAssertEqual(
            CompactSchemaAdapter.tokenAliasDomain(bopomofo),
            ["\u{3105}\u{3127}", "\u{3106}\u{3127}"],
            "Unicode (Bopomofo) tokens are aliased")
        let extras = projection(tokens: ["ni", "shang", "A", "Z"])
        let assignments = CompactSchemaAdapter.tokenAliasAssignments(extras)
        XCTAssertEqual(Set(assignments.map(\.token)), ["ni", "shang", "A", "Z"])
        XCTAssertEqual(Set(assignments.map(\.alias)).count, assignments.count)
    }

    /// Tokens that cannot be represented exactly fail the WHOLE domain closed.
    func testTokenAliasDomainFailsClosedOnUnrepresentableTokens() throws {
        for bad in ["ni x", "a/b", "a\tb", "a\nb", "a\u{7}b"] {
            XCTAssertNil(
                CompactSchemaAdapter.tokenAliasDomain(projection(tokens: ["ni", bad])),
                "token \(bad.debugDescription) must fail the domain closed")
            XCTAssertTrue(CompactSchemaAdapter.tokenAliasAssignments(projection(tokens: ["ni", bad])).isEmpty)
        }
        XCTAssertNil(CompactSchemaAdapter.tokenAliasDomain(projection(tokens: [])))
        XCTAssertNil(
            CompactSchemaAdapter.tokenAliasDomain(
                projection(tokens: Array(repeating: "ni", count: 2))), "duplicate token")
        XCTAssertNil(
            CompactSchemaAdapter.tokenAliasDomain(
                projection(tokens: Array(repeating: "ni", count: CompactSchemaAdapter.tokenAliasLimit + 1))),
            "over the versioned hard limit")
    }

    /// Regex metacharacters are ESCAPED (exactly expressible), never injected raw.
    func testAliasPatternEscapesRegexMetacharacters() throws {
        XCTAssertEqual(CompactSchemaAdapter.aliasPattern(for: "a.b"), "^a\\.b$")
        XCTAssertEqual(CompactSchemaAdapter.aliasPattern(for: "a$"), "^a\\$$")
        XCTAssertEqual(CompactSchemaAdapter.aliasPattern(for: "a[b](c)*"), "^a\\[b\\]\\(c\\)\\*$")
        XCTAssertEqual(CompactSchemaAdapter.aliasPattern(for: "\\"), "^\\\\$")
        for token in ["a.b", "a$", "x^y", "a|b", "a+b?", "a\\b", "\u{3105}\u{3127}"] {
            let pattern = try XCTUnwrap(CompactSchemaAdapter.aliasPattern(for: token))
            XCTAssertEqual(
                CompactSchemaAdapter.aliasToken(fromPattern: String(pattern.dropFirst().dropLast())),
                token, "round-trip")
        }
        // A metacharacter token still gets a working, escaped derive.
        let proj = projection(tokens: ["a.b", "abd"])
        let derives = CompactSchemaAdapter.tokenAliasDerives(proj)
        XCTAssertEqual(derives.count, 2)
        XCTAssertTrue(
            derives.contains { $0.hasPrefix("derive/^a\\.b$/") },
            "metacharacter escaped: \(derives)")
        XCTAssertFalse(
            derives.contains { $0.contains("derive/^a.b$/") },
            "unescaped metacharacter never spliced")
    }

    func testAliasFixedWidthPrefixFreeAndDeterministic() throws {
        let projection = try loadFixture("songyan_flypy.projection")
        let assignments = CompactSchemaAdapter.tokenAliasAssignments(projection)
        XCTAssertFalse(assignments.isEmpty)
        let width = CompactSchemaAdapter.tokenAliasWidth(for: projection.syllables.count)
        for (_, alias) in assignments {
            XCTAssertEqual(
                alias.count,
                CompactSchemaAdapter.tokenAliasSentinel.count + width,
                "fixed-width alias")
            XCTAssertTrue(alias.hasPrefix(CompactSchemaAdapter.tokenAliasSentinel))
            XCTAssertTrue(
                alias.dropFirst(CompactSchemaAdapter.tokenAliasSentinel.count)
                    .allSatisfy(\.isNumber))
        }
        let set = Set(assignments.map(\.alias))
        XCTAssertEqual(set.count, assignments.count)
        for a in set { for b in set where a != b { XCTAssertFalse(b.hasPrefix(a)) } }
        XCTAssertEqual(
            CompactSchemaAdapter.tokenAliasAssignments(projection).map(\.alias),
            assignments.map(\.alias), "alias assignment is deterministic")
    }

    /// The alias carries the `0` from its sentinel, which no compact physical
    /// layout can type (14-key sends letters, 9-key sends 2–9), so an alias is
    /// never reachable by physical input.
    func testTokenAliasIsNeverTypeableFromACompactLayout() throws {
        let physical14 = Set("qetuoadgjlzcbm")
        let physical9 = Set("23456789")
        for count in [1, 9, 10, 120, 999, 1000, 2166, 4096] {
            let tokens = (0..<count).map { "t\($0)" }
            let assigns = CompactSchemaAdapter.tokenAliasAssignments(projection(tokens: tokens))
            XCTAssertEqual(assigns.count, count)
            for (_, alias) in assigns {
                XCTAssertTrue(
                    alias.contains("0"),
                    "alias \(alias) must contain a non-physical 0 (count=\(count))")
                XCTAssertFalse(alias.allSatisfy { physical14.contains($0) })
                XCTAssertFalse(alias.allSatisfy { physical9.contains($0) })
            }
            // Fixed width per domain -> prefix-free.
            let lengths = Set(assigns.map { $0.alias.count })
            XCTAssertEqual(lengths.count, 1, "equal length (count=\(count))")
        }
    }

    /// Near-limit is accepted; over-limit and an unrepresentable token fail the
    /// domain closed (no partial alias layer, no capability).
    func testTokenAliasDomainNearAndOverLimitFailClosed() throws {
        let limit = CompactSchemaAdapter.tokenAliasLimit
        XCTAssertEqual(limit, 4096)
        let near = projection(tokens: (0..<limit).map { "t\($0)" })
        let nearAssigns = CompactSchemaAdapter.tokenAliasAssignments(near)
        XCTAssertEqual(nearAssigns.count, limit, "near-limit domain is accepted")
        XCTAssertEqual(Set(nearAssigns.map(\.alias)).count, limit)
        let over = projection(tokens: (0..<(limit + 1)).map { "t\($0)" })
        XCTAssertNil(CompactSchemaAdapter.tokenAliasDomain(over), "over-limit fails closed")
        XCTAssertTrue(CompactSchemaAdapter.tokenAliasAssignments(over).isEmpty, "no partial map")
        XCTAssertFalse(
            CompactSchemaAdapter.tokenAliasLockAuthorized(
                sourceProjection: over, companion: Data("speller: {algebra: []}\n".utf8)))
        // The generated companion for an over-limit domain must carry NO rewrite block.
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: t, name: t}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: t}
                """.utf8),
            sourceID: "t", fold: .merged14, displayCapability: displayCapability(),
            sourceProjection: over)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_rewrite"], "over-limit must not write a rewrite capability")
        XCTAssertNil(
            CompactSchemaAdapter.tokenAliasDomain(projection(tokens: ["ni", "a/b"])),
            "unrepresentable token fails closed")
    }

    func testExistingAliasMapRoundTripsABakedCompanion() throws {
        let proj = projection(tokens: ["ni", "shang", "hao", "a.b"])
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: t, name: t}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: t}
                """.utf8),
            sourceID: "t", fold: .merged14, displayCapability: displayCapability(),
            sourceProjection: proj)
        XCTAssertEqual(
            CompactSchemaAdapter.existingAliasMap(from: data),
            CompactSchemaAdapter.lockMap(proj))
        XCTAssertNil(CompactSchemaAdapter.existingAliasMap(from: Data("speller: {algebra: []}\n".utf8)))
        XCTAssertNil(
            CompactSchemaAdapter.existingAliasMap(
                from: Data(
                    """
                    speller:
                      algebra:
                        - derive/^ni$/9/
                    """.utf8)), "malformed alias width is rejected wholesale")
    }

    private func displayCapability() -> CompactSchemaAdapter.DisplayCapability {
        CompactSchemaAdapter.DisplayCapability(
            version: 1, mode: "source_code", sourceSchema: "t",
            translatorNamespace: "translator",
            separator: "'", mappingPolicy: "unique_normal", syllables: [:])
    }

    /// The authorization is anchored on the companion's baked alias layer and the
    /// live domain; it never inspects token shape or a `canonical_pinyin` declaration.
    func testTokenAliasLockAuthorizedIsSchemaAgnosticAndBindsBakedMap() throws {
        for tokens in [["ni", "shang"], ["abc", "abd"], ["\u{3105}\u{3127}", "\u{3106}\u{3127}"]] {
            let proj = projection(tokens: tokens)
            let companion = try CompactSchemaAdapter.generate(
                compiled: Data(
                    """
                    schema: {schema_id: t, name: t}
                    engine: {translators: [script_translator]}
                    speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                    translator: {dictionary: t}
                    """.utf8),
                sourceID: "t", fold: .merged14, displayCapability: displayCapability(),
                sourceProjection: proj)
            XCTAssertEqual(
                fourteenLock(
                    try XCTUnwrap(
                        Yams.load(yaml: String(decoding: companion, as: UTF8.self)) as? [String: Any])),
                CompactSchemaAdapter.tokenAliasLockValue,
                "tokens \(tokens) authorize without a pinyin gate")
            XCTAssertTrue(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: proj, companion: companion))
            // A disjoint live domain must refuse it.
            XCTAssertFalse(
                CompactSchemaAdapter.tokenAliasLockAuthorized(
                    sourceProjection: projection(tokens: ["zzz", "yyy"]), companion: companion))
        }
    }

    /// A destructive source algebra (canonical identity does not survive) still
    /// gets the lock: the alias is prepended BEFORE the algebra and re-proven
    /// against the live prism at runtime.
    func testDestructiveSourceStillGetsGenericAliasLock() throws {
        let destructive = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "t", translatorNamespace: "translator", dictionary: "t",
            alphabet: "abcdefghijklmnopqrstuvwxyz", algebra: ["xform/^sh/U/"],
            separator: "'", declaration: "",
            syllables: [
                syllable("shang", [("uh", true, false)]),
                syllable("ni", [("ni", true, false)]),
            ])
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: t, name: t}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: t}
                """.utf8),
            sourceID: "t", fold: .phone9, displayCapability: displayCapability(),
            sourceProjection: destructive)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertEqual(
            fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue,
            "identity-survive is not required by the generic alias layer")
        XCTAssertTrue((root["keyboard_rewrite"] as? [String: Any])?["lock_map"] != nil)
    }

    func testNoProjectionOrNoDisplayCapabilityEmitsNoLock() throws {
        let source = Data(
            """
            schema: {schema_id: t, name: t}
            engine: {translators: [script_translator]}
            speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
            translator: {dictionary: t}
            """.utf8)
        // No projection -> no rewrite authorization.
        let legacy = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "t", fold: .merged14,
            displayCapability: displayCapability(), sourceProjection: nil)
        let legacyRoot = try XCTUnwrap(
            Yams.load(yaml: String(decoding: legacy, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(legacyRoot["keyboard_rewrite"])
        XCTAssertNil(fourteenLock(legacyRoot))
        // Projection but no display capability -> rewrite only (no display block).
        let noDisplay = try CompactSchemaAdapter.generate(
            compiled: source, sourceID: "t", fold: .merged14,
            displayCapability: nil, sourceProjection: projection(tokens: ["ni", "hao"]))
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: noDisplay, as: UTF8.self)) as? [String: Any])
        XCTAssertNil(root["keyboard_adapter"], "native display -> no display block")
        XCTAssertNotNil(root["keyboard_rewrite"], "rewrite is independent of display")
    }

    // MARK: - Real rime-ice projection (shuangpin BU/NI + uppercase extras)

    func testRealDoublePinyinFlypyProjectionGetsBoundedSchemaAgnosticAliasLock() throws {
        let projection = try loadFixture("double_pinyin_flypy.projection")
        XCTAssertEqual(projection.sourceSchema, "double_pinyin_flypy")
        XCTAssertEqual(projection.declaration, "", "upstream rime-ice does not declare canonical")
        XCTAssertGreaterThan(projection.syllables.count, 400)
        XCTAssertTrue(projection.syllables.contains { $0.token == "A" }, "uppercase extras present")
        let domain = try XCTUnwrap(CompactSchemaAdapter.tokenAliasDomain(projection))
        XCTAssertGreaterThan(domain.count, 400)
        for token in ["bu", "bi", "ni", "nu", "A"] {
            XCTAssertTrue(domain.contains(token), "\(token) is in the schema-agnostic domain")
        }
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: double_pinyin_flypy, name: double_pinyin_flypy}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: rime_ice}
                """.utf8),
            sourceID: "double_pinyin_flypy", fold: .merged14,
            displayCapability: displayCapability(), sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertEqual(fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue)
        let lockMap = try XCTUnwrap((root["keyboard_rewrite"] as? [String: Any])?["lock_map"] as? [String: String])
        for token in ["bu", "bi", "ni", "nu"] {
            XCTAssertNotNil(lockMap[token], "\(token) must have a bounded alias")
        }
        XCTAssertTrue(
            CompactSchemaAdapter.tokenAliasLockAuthorized(
                sourceProjection: projection, companion: data))
    }

    /// A near-real ASCII shape-code projection (Wubi/Cangjie-like): `ab` is the
    /// merged trajectory for `abc`/`abd`; both must be aliased and lockable.
    func testShapeCodeAsciiProjectionGetsSchemaAgnosticAliasLock() throws {
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "shape_codes", translatorNamespace: "translator",
            dictionary: "shape_codes", alphabet: "abcdefghijklmnopqrstuvwxyz",
            algebra: ["derive/^abc$/ab/", "derive/^abd$/ab/"], separator: "'",
            declaration: "",
            syllables: [
                syllable("abc", [("abc", true, false)]),
                syllable("abd", [("abd", true, false)]),
            ])
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: shape_codes, name: shape_codes}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: shape_codes}
                """.utf8),
            sourceID: "shape_codes", fold: .merged14, displayCapability: displayCapability(),
            sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertEqual(fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue)
        let lockMap = try XCTUnwrap((root["keyboard_rewrite"] as? [String: Any])?["lock_map"] as? [String: String])
        XCTAssertEqual(Set(lockMap.keys), ["abc", "abd"])
        XCTAssertTrue(
            CompactSchemaAdapter.tokenAliasLockAuthorized(
                sourceProjection: projection, companion: data))
    }

    /// A near-real Bopomofo (Unicode token) projection: the tokens are Bopomofo
    /// and must be aliased exactly like pinyin tokens.
    func testBopomofoUnicodeProjectionGetsSchemaAgnosticAliasLock() throws {
        let tokens = ["\u{3105}\u{3127}", "\u{3106}\u{3127}"]  // ㄅㄧ / ㄆㄧ
        let projection = CompactSchemaAdapter.SourceProjection(
            sourceSchema: "bopomofo", translatorNamespace: "translator",
            dictionary: "bopomofo", alphabet: "abcdefghijklmnopqrstuvwxyz",
            algebra: ["xform/^\u{3105}\u{3127}$/bi/", "xform/^\u{3106}\u{3127}$/bi/"],
            separator: "'", declaration: "",
            syllables: tokens.map { syllable($0, [($0, true, false)]) })
        let data = try CompactSchemaAdapter.generate(
            compiled: Data(
                """
                schema: {schema_id: bopomofo, name: bopomofo}
                engine: {translators: [script_translator]}
                speller: {alphabet: "abcdefghijklmnopqrstuvwxyz"}
                translator: {dictionary: bopomofo}
                """.utf8),
            sourceID: "bopomofo", fold: .merged14, displayCapability: displayCapability(),
            sourceProjection: projection)
        let root = try XCTUnwrap(Yams.load(yaml: String(decoding: data, as: UTF8.self)) as? [String: Any])
        XCTAssertEqual(fourteenLock(root), CompactSchemaAdapter.tokenAliasLockValue)
        let lockMap = try XCTUnwrap((root["keyboard_rewrite"] as? [String: Any])?["lock_map"] as? [String: String])
        XCTAssertEqual(Set(lockMap.keys), Set(tokens))
        XCTAssertTrue(
            CompactSchemaAdapter.tokenAliasLockAuthorized(
                sourceProjection: projection, companion: data))
    }

    // MARK: - Canonical DISPLAY domain (9-key) stays pinyin-declared

    func testCanonicalPinyinDomainAllowingEvidencedExtras() throws {
        XCTAssertTrue(
            CompactSchemaAdapter.isCanonicalPinyinDomainAllowingBenignExtras(
                ["ni", "shang", "A", "Z"]))
        XCTAssertFalse(
            CompactSchemaAdapter.isCanonicalPinyinDomainAllowingBenignExtras(["A", "Z"]),
            "no canonical token -> false")
        XCTAssertFalse(
            CompactSchemaAdapter.isCanonicalPinyinDomainAllowingBenignExtras(["ni", "english"]),
            "multi-character non-pinyin extra -> false (canonical display only)")
    }

    func testRealFlypy26TokensAreCanonicalPinyinDomain() throws {
        let projection = try loadFixture("songyan_flypy.projection")
        XCTAssertTrue(CompactSchemaAdapter.isCanonicalPinyinDomain(projection.syllables.map(\.token)))
    }
}
