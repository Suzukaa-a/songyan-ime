import XCTest

@testable import KeyboardCore

private final class NumericPreeditEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("numeric-preedit-test")
    private var input = ""

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { input = "" }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        input += keyValue
        return currentSnapshot()
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { currentSnapshot() }
    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }
    func currentSnapshot() -> EngineSnapshot {
        var snapshot = EngineSnapshot(
            preedit: input == "555" ? "55 5" : input,
            rawInput: input, isComposing: !input.isEmpty)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = snapshot.preedit.utf8.count
        snapshot.preeditCaretByte = snapshot.preedit.utf8.count
        return snapshot
    }
    func shutdown() {}
    var statusSummary: String { "numeric-preedit" }
}

/// Runtime display policy: only a capability explicitly declared at generation time re-expresses; if any token
/// cannot be proven the whole run falls back to native, never partially rewritten, never defaulting to identity, never picking the first spelling.
@MainActor
final class CompositionDisplayPolicyTests: XCTestCase {

    private func capability(
        mode: String = "source_code",
        sourceSchema: String = "songyan_flypy",
        separator: String = "'",
        adapterSchema: String = "keyboard_3d7821f984693864ae91_14",
        syllables: [String: String] = ["zao": "zc", "shang": "uh", "hao": "hc"]
    )
        -> SchemaDisplayCapability
    {
        let wire: [String: Any] = [
            "version": 1,
            "display_mode": mode,
            "source_schema": sourceSchema,
            "translator_namespace": "translator",
            "separator": separator,
            "mapping_policy": "unique_normal",
            "adapter_schema": adapterSchema,
            "syllables": syllables,
        ]
        guard let capability = SchemaDisplayCapability(wire: wire) else {
            preconditionFailure("capability fixture must decode: \(wire)")
        }
        return capability
    }

    // MARK: - Acceptance: physical zcuggc, trusted "早上好" highlight shows the source code

    func testSourceCodeReproducesFlypySourceCodingForAcceptance() {
        // Engine behavior: physical 14-key input zcuggc -> preedit "zc ug gc", highlighted "早上好",
        // rb_copy_highlighted_spelling canonical="zao shang hao".
        // The capability projects the canonical syllables zao/shang/hao to flypy source codes zc/uh/hc and joins them with the explicit display
        // separator `'` -> acceptance string zc'uh'hc. Never the merged representative code, never canonical full pinyin.
        let outcome = CompositionDisplayPolicy.resolve(
            canonicalSyllables: ["zao", "shang", "hao"],
            capability: capability())
        XCTAssertEqual(outcome, .display("zc'uh'hc"))
        XCTAssertNotEqual(outcome, .display("zcug gc"))
        XCTAssertNotEqual(outcome, .display("zao shang hao"))
    }

    func testSourceCodeUsesConfiguredSeparatorNotEnginesMergedDelimiter() {
        let spaced = capability(separator: " ")
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: ["zao", "shang", "hao"],
                capability: spaced),
            .display("zc uh hc"))
    }

    // MARK: - Missing entry / ambiguity: whole-run fallback, no mixed spelling, no default identity

    func testMissingSyllableFallsBackEntireSegment() {
        // chang is not in the map (rejected or missing in the source) -> whole-run fallback, never shows zc'chang'hc.
        let outcome = CompositionDisplayPolicy.resolve(
            canonicalSyllables: ["zao", "chang", "hao"],
            capability: capability())
        XCTAssertEqual(outcome, .native(.missingSyllable("chang")))
    }

    func testAmbiguousTokenIsNotDefaultedToIdentity() {
        // ju is excluded by the derive ju/jv ambiguity; at runtime it must fall back rather than display ju itself.
        let outcome = CompositionDisplayPolicy.resolve(
            canonicalSyllables: ["ju"],
            capability: capability())
        XCTAssertEqual(outcome, .native(.missingSyllable("ju")))
    }

    // MARK: - Default path: no capability / native / source_rendered unverified

    func testNoCapabilityKeepsEnginePreedit() {
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: ["ni", "hao"],
                capability: nil),
            .native(.noCapability))
    }

    func testExplicitNativeModeKeepsEnginePreedit() {
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: ["ni", "hao"],
                capability: capability(mode: "native")),
            .native(.modeNative))
    }

    func testSourceRenderedIsUnsupportedUntilSeparatelyVerified() {
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: ["ni", "hao"],
                capability: capability(mode: "source_rendered")),
            .native(.unsupportedMode(.sourceRendered)))
    }

    // MARK: - MarkedComposition uses the capability-driven display value

    func testMarkedCompositionUsesDeclaredDisplayValueOverLegacyCanonical() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "早上好")],
            preedit: "zc ug gc", rawInput: "zcuggc", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 8
        snapshot.preeditCaretByte = 8
        snapshot.preeditSelection = NSRange(location: 8, length: 0)
        snapshot.displayMode = .sourceCode
        snapshot.highlightedDisplay = "zc'uh'hc"
        snapshot.highlightedSpelling = "zao shang hao"  // legacy canonical must lose
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "zc'uh'hc")
        XCTAssertEqual(snapshot.rawInput, "zcuggc", "display must not rewrite the engine's raw code")
    }

    func testMarkedCompositionFallsBackWhenDeclaredDisplayIsEmpty() {
        // When the capability declares non-native but the policy falls back (missing entry / stale), never use the legacy canonical.
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "早上好")],
            preedit: "zc ug gc", rawInput: "zcuggc", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 8
        snapshot.preeditCaretByte = 8
        snapshot.displayMode = .native
        snapshot.highlightedDisplay = ""
        snapshot.highlightedSpelling = "zao shang hao"
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: false).text, "zc ug gc")
    }

    /// Counterexample: a snapshot whose capability block exists but authorization failed (native / missing entry / stale), even if the caller wrongly passes
    /// `spellingPreedit: true`, must never override the native preedit with the legacy canonical.
    func testCapabilitySnapshotNeverFallsBackToLegacySpelling() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "去")],
            preedit: "qd", rawInput: "qd", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 2
        snapshot.preeditSelection = NSRange(location: 2, length: 0)
        snapshot.hasDisplayCapability = true  // engine evaluated a capability
        snapshot.displayMode = .native  // and refused it (stale/missing)
        snapshot.highlightedDisplay = ""
        snapshot.highlightedSpelling = "qu"  // canonical leak from the engine decode
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "qd")
    }

    /// The legacy protocol entry (demo / capability-less snapshot) can still use the legacy spelling, so existing paths are not harmed.
    func testLegacyProtocolStillWorksWithoutCapabilitySnapshot() {
        var snapshot = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "你")],
            preedit: "bu", rawInput: "bu", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 2
        snapshot.hasDisplayCapability = false
        snapshot.highlightedSpelling = "ni"
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "ni")
    }

    func testEmptyTokensKeepEnginePreedit() {
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: [],
                capability: capability()),
            .native(.emptyTokens))
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: [""],
                capability: capability()),
            .native(.emptyTokens))
    }

    // MARK: - 9-key canonical: keep the existing canonical pinyin semantics, no source format

    func testCanonicalJoinsDecodedSyllablesWithDeclaredSeparator() {
        // Existing 9-key native Code Decode (9-key companion delimiter "'") -> ni'hao.
        // The authorization binding of canonical lives in RimeEngine/RimeModels (producer/source);
        // here only token joining after authorization is verified.
        XCTAssertEqual(
            CompositionDisplayPolicy.resolve(
                canonicalSyllables: ["ni", "hao"],
                capability: capability(
                    mode: "canonical",
                    separator: "'",
                    syllables: ["ni": "ni"])),
            .display("ni'hao"))
    }

    // MARK: - 9-key digit codes: after canonical is authorized, never write the internal digit transport code into marked
    //
    // Device counterexample: bundled 9-key pressing JKL three times -> engine input/preedit is "555";
    // the canonical capability is authorized (displayMode=canonical) but there is currently no decodable candidate
    // (rb_copy_highlighted_syllables_json returns empty) -> the old implementation fell back the whole preedit,
    // and the host marked text showed the internal digit code "555". The existing 6445->ni'hao evidence only covers the single-segment display of a
    // **complete candidate**, not `emptyTokens` / unconverted trailing codes.

    private func canonicalCapability(
        separator: String = "'",
        adapterSchema: String = "keyboard_47246213a538cb99d374_9"
    ) -> SchemaDisplayCapability {
        let wire: [String: Any] = [
            "version": 1, "display_mode": "canonical", "source_schema": "keyboard_47246213a538cb99d374_9",
            "translator_namespace": "translator",
            "separator": separator, "adapter_schema": adapterSchema,
        ]
        guard let capability = SchemaDisplayCapability(wire: wire) else {
            preconditionFailure("canonical fixture must decode")
        }
        return capability
    }

    private func composed(
        _ preedit: String, sel: Range<Int>, caret: Int,
        syllables: [String],
        capability: SchemaDisplayCapability?,
        hasCapability: Bool = true
    ) -> EngineSnapshot {
        var base = EngineSnapshot(candidates: [], preedit: preedit, rawInput: preedit, isComposing: true)
        base.preeditSelStart = sel.lowerBound
        base.preeditSelEnd = sel.upperBound
        base.preeditCaretByte = caret
        return CompositionDisplayPolicy.applied(
            to: base, canonicalSyllables: syllables,
            capability: capability,
            hasCapability: hasCapability
        ).snapshot
    }

    func testCanonicalIncompleteNumericCodeShowsThePressedKeys() {
        // JKL JKL JKL → input "555"; no candidate decodes. An empty mark made the
        // presses look swallowed, so the field shows the keys that were pressed.
        let snapshot = composed("555", sel: 0..<3, caret: 3, syllables: [], capability: canonicalCapability())
        XCTAssertTrue(snapshot.hidesNumericTransportCode)
        XCTAssertEqual(snapshot.displayMode, .native)
        XCTAssertEqual(snapshot.highlightedDisplay, "")
        let marked = MarkedComposition(snapshot: snapshot, spellingPreedit: true)
        XCTAssertEqual(marked.text, "555")
        XCTAssertEqual(marked.selection, NSRange(location: 3, length: 0))
    }

    func testProvenKeypadShowsSpacedNumericPreeditAsOneRunOfKeys() {
        // Installed imported-source counterexample: raw transport remains `555`,
        // while the engine formats its native preedit as `55 5`. The engine's code
        // spacing is not shown; the keys read as one run.
        XCTAssertTrue(CompositionDisplayPolicy.isNumericTransport(rawInput: "555"))
        XCTAssertFalse(CompositionDisplayPolicy.isNumericTransport(rawInput: "ni55"))
        var snapshot = EngineSnapshot(preedit: "55 5", rawInput: "555", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 4
        snapshot.preeditCaretByte = 4
        snapshot.hidesNumericTransportCode = true
        XCTAssertEqual(MarkedComposition(snapshot: snapshot).text, "555")
    }

    func testInputSessionAppliesPhysicalKeypadGuardButFullLayoutKeepsNativePreedit() {
        let keypad = InputSession(engine: NumericPreeditEngine(), layout: .phone9)
        keypad.numericTransportLayout = true
        keypad.tap(.code("5"))
        keypad.tap(.code("5"))
        keypad.tap(.code("5"))
        XCTAssertEqual(keypad.snapshot.preedit, "55 5")
        XCTAssertTrue(keypad.snapshot.hidesNumericTransportCode)
        XCTAssertEqual(MarkedComposition(snapshot: keypad.snapshot).text, "555")

        let full = InputSession(engine: NumericPreeditEngine(), layout: .qwerty26)
        full.tap(.code("5"))
        full.tap(.code("5"))
        full.tap(.code("5"))
        XCTAssertFalse(full.snapshot.hidesNumericTransportCode)
        XCTAssertEqual(MarkedComposition(snapshot: full.snapshot).text, "55 5")
    }

    func testCanonicalPartialNumericCodeKeepsUnconvertedTailAsKeys() {
        // 64'45: only the first syllable decodes (ni); the tail "45" was typed too and
        // dropping it made those presses look swallowed.
        let snapshot = composed("6445", sel: 0..<2, caret: 4, syllables: ["ni"], capability: canonicalCapability())
        let marked = MarkedComposition(snapshot: snapshot, spellingPreedit: true)
        XCTAssertEqual(marked.text, "ni'45")
        XCTAssertEqual(marked.selection, NSRange(location: 5, length: 0))
    }

    /// 14-key `bu gao` with "你好" as the first choice used to leave the representative code in the field. When the capability gives no
    /// display value, the highlighted candidate's **unique** engine reading supplied by the caller replaces the highlighted run; the trailing code is kept as is.
    func testReadingFallbackReplacesOnlyTheHighlightedSpanWhenCapabilityIsSilent() {
        var snapshot = EngineSnapshot(preedit: "bu gao", rawInput: "bugao", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 6
        snapshot.preeditCaretByte = 6
        XCTAssertEqual(
            MarkedComposition(snapshot: snapshot).text, "bu gao", "no fallback value: keep the engine preedit")
        let marked = MarkedComposition(snapshot: snapshot, readingFallback: "ni'hao")
        XCTAssertEqual(marked.text, "ni'hao")
        XCTAssertEqual(marked.selection, NSRange(location: 6, length: 0))
        var partial = snapshot
        partial.preedit = "你 gao"
        partial.preeditSelStart = 4
        partial.preeditSelEnd = 7
        partial.preeditCaretByte = 7
        XCTAssertEqual(
            MarkedComposition(snapshot: partial, readingFallback: "hao").text, "你 hao",
            "the confirmed prefix is kept, only the highlighted run is replaced")
    }

    /// 9-key: when the capability gives no display value, the pressed keys are shown (hiding them makes the field look like it swallowed keys); with a unique engine
    /// reading the highlighted run shows the reading, and the unconverted keys after it are shown as typed.
    func testNumericTransportShowsTrustedReadingThenThePressedKeys() {
        var snapshot = EngineSnapshot(preedit: "64 426", rawInput: "64426", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 6
        snapshot.hidesNumericTransportCode = true
        XCTAssertEqual(MarkedComposition(snapshot: snapshot).text, "64426")
        let marked = MarkedComposition(snapshot: snapshot, readingFallback: "ni")
        XCTAssertEqual(marked.text, "ni'426")
    }

    func testCapabilityDisplayStillWinsOverTheReadingFallback() {
        let snapshot = composed("6445", sel: 0..<2, caret: 4, syllables: ["ni"], capability: canonicalCapability())
        XCTAssertEqual(
            MarkedComposition(snapshot: snapshot, spellingPreedit: true, readingFallback: "yi").text, "ni'45",
            "the display value given by the schema capability takes priority")
    }

    /// When the capability block is declared but gives no display value: an unproven legacy spelling is still rejected, the engine-proven
    /// highlighted reading (consistent range + unique complete path) replaces the highlighted run as usual, and digit codes are still not exposed.
    func testUnusableDeclaredCapabilityStillUsesProvenReading() {
        var snapshot = EngineSnapshot(preedit: "6445", rawInput: "6445", isComposing: true)
        snapshot.preeditSelStart = 0
        snapshot.preeditSelEnd = 2
        snapshot.preeditCaretByte = 4
        snapshot.hasDisplayCapability = true
        snapshot.hidesNumericTransportCode = true
        snapshot.highlightedSpelling = "yi"
        XCTAssertEqual(
            MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "6445",
            "an unproven legacy spelling must not bypass fail-closed: show only the pressed keys")
        XCTAssertEqual(
            MarkedComposition(snapshot: snapshot, spellingPreedit: true, readingFallback: "ni").text, "ni'45")
    }

    /// Device counterexample (rime-ice x 14-key): the source algebra's error-correction derive gives `hao` two normal spellings,
    /// the `unique_normal` mapping rejects it, and source_code falls back to native as a whole. The field must now show
    /// the proven reading `bu hao` of the highlighted "不好", not the merged key code `bu gao`.
    func testSourceCodeMissingSyllableFallsBackToProvenReadingNotKeyLetters() {
        let cap = capability(syllables: ["bu": "bu"])
        var base = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "不好")],
            preedit: "bu gao", rawInput: "bugao", isComposing: true)
        base.preeditSelStart = 0
        base.preeditSelEnd = 6
        base.preeditCaretByte = 6
        let applied = CompositionDisplayPolicy.applied(
            to: base, canonicalSyllables: ["bu", "hao"],
            capability: cap, hasCapability: true)
        XCTAssertEqual(applied.outcome, .native(.missingSyllable("hao")))
        XCTAssertEqual(
            MarkedComposition(snapshot: applied.snapshot, spellingPreedit: true).text, "bu gao",
            "with no proven reading keep the engine preedit, do not fabricate")
        let marked = MarkedComposition(snapshot: applied.snapshot, spellingPreedit: true, readingFallback: "bu hao")
        XCTAssertEqual(marked.text, "bu hao")
        XCTAssertEqual(marked.selection, NSRange(location: 6, length: 0))
    }

    func testCanonicalConfirmedPrefixSurvivesUnresolvedNumericTail() {
        // After selecting 你, preedit is "你45": the confirmed prefix stays, and the
        // still unresolved keys show as pressed.
        let snapshot = composed("你45", sel: 3..<5, caret: 5, syllables: [], capability: canonicalCapability())
        let marked = MarkedComposition(snapshot: snapshot, spellingPreedit: true)
        XCTAssertEqual(marked.text, "你45")
        XCTAssertEqual(marked.selection, NSRange(location: 3, length: 0))
    }

    func testCanonicalWholeCompositionStillDisplaysNormally() {
        // 64426 → ni'hao (existing behaviour preserved for a complete composition).
        let snapshot = composed(
            "64'426", sel: 0..<6, caret: 6, syllables: ["ni", "hao"],
            capability: canonicalCapability())
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "ni'hao")
    }

    func testDeclaredCanonicalWithoutAuthorizedCapabilityShowsKeysWithoutSpacing() {
        // RimeBackend marks a snapshot whose schema DECLARED canonical, even before
        // authorization/demand resolves (capability nil here): the pressed keys show.
        var base = EngineSnapshot(preedit: "555", rawInput: "555", isComposing: true)
        base.preeditSelStart = 0
        base.preeditSelEnd = 3
        base.preeditCaretByte = 3
        base.hidesNumericTransportCode = true
        let applied = CompositionDisplayPolicy.applied(
            to: base, canonicalSyllables: [],
            capability: nil,
            hasCapability: true
        ).snapshot
        XCTAssertTrue(applied.hidesNumericTransportCode)
        XCTAssertEqual(MarkedComposition(snapshot: applied, spellingPreedit: true).text, "555")
    }

    func testSourceCodeNativeFallbackStillKeepsRawPreedit() {
        // 14-key source_code keeps the native fallback: only an
        // authorized `canonical` (9-key numeric) capability suppresses the raw code.
        let snapshot = composed(
            "zc ig", sel: 0..<5, caret: 5, syllables: ["zao", "chang"],
            capability: capability())
        XCTAssertFalse(snapshot.hidesNumericTransportCode)
        XCTAssertEqual(snapshot.displayMode, .native)
        XCTAssertEqual(MarkedComposition(snapshot: snapshot, spellingPreedit: true).text, "zc ig")
    }

    // MARK: - Strict decoding

    func testDecodeRejectsUnsupportedVersionAndPolicy() {
        let base: [String: Any] = [
            "version": 1, "display_mode": "source_code", "source_schema": "s",
            "translator_namespace": "translator",
            "separator": "'", "mapping_policy": "unique_normal", "adapter_schema": "kbd",
            "syllables": ["a": "b"],
        ]
        XCTAssertNotNil(SchemaDisplayCapability(wire: base))

        var unknownVersion = base
        unknownVersion["version"] = 2
        XCTAssertNil(SchemaDisplayCapability(wire: unknownVersion))

        var badPolicy = base
        badPolicy["mapping_policy"] = "inverse"
        XCTAssertNil(SchemaDisplayCapability(wire: badPolicy))

        var unknownMode = base
        unknownMode["display_mode"] = "magic"
        XCTAssertNil(SchemaDisplayCapability(wire: unknownMode))

        var emptySeparator = base
        emptySeparator["separator"] = ""
        XCTAssertNil(SchemaDisplayCapability(wire: emptySeparator))

        var emptyValue = base
        emptyValue["syllables"] = ["a": ""]
        XCTAssertNil(SchemaDisplayCapability(wire: emptyValue))

        var emptyMap = base
        emptyMap["syllables"] = [String: String]()
        XCTAssertNil(SchemaDisplayCapability(wire: emptyMap))

        // source_code must bind adapter_schema (prevents copying to another companion scheme).
        var noAdapter = base
        noAdapter["adapter_schema"] = ""
        XCTAssertNil(SchemaDisplayCapability(wire: noAdapter))

        // canonical must also carry adapter_schema.
        let canonicalBase: [String: Any] = [
            "version": 1, "display_mode": "canonical", "source_schema": "keyboard_47246213a538cb99d374_9",
            "translator_namespace": "translator",
            "separator": "'", "adapter_schema": "keyboard_47246213a538cb99d374_9",
        ]
        XCTAssertNotNil(SchemaDisplayCapability(wire: canonicalBase))
        var canonicalNoAdapter = canonicalBase
        canonicalNoAdapter["adapter_schema"] = ""
        XCTAssertNil(SchemaDisplayCapability(wire: canonicalNoAdapter))
    }

    func testDecodeRejectsUnsupportedVersionFromJSON() {
        let json = Data(
            #"{"version":9,"display_mode":"source_code","source_schema":"s","translator_namespace":"t","separator":"'","mapping_policy":"unique_normal","adapter_schema":"kbd","syllables":{"a":"b"}}"#
                .utf8)
        XCTAssertNil(SchemaDisplayCapability.decode(json: json))
    }

    func testCodableRoundTripKeepsWireContract() throws {
        let original = capability()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SchemaDisplayCapability.self, from: data)
        XCTAssertEqual(decoded, original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["display_mode"] as? String, "source_code")
        XCTAssertEqual(json["mapping_policy"] as? String, "unique_normal")
        XCTAssertEqual(json["source_schema"] as? String, "songyan_flypy")
        XCTAssertEqual(json["adapter_schema"] as? String, "keyboard_3d7821f984693864ae91_14")
    }
}
