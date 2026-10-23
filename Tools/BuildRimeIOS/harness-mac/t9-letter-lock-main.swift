import CryptoKit
// ---------------------------------------------------------------------------
// t9-letter-lock-main.swift — REAL-engine evidence for the schema-agnostic
// letter-class PREFIX lock (9-key long-press ABC → A/B/C).
//
// What is proven here, end to end, on the real macOS librime and through the
// REAL installer generation path (`CompactAdapterDeployment.prepare`):
//
//   The fixture source `t9_digits` is the built-in full pinyin with the eight
//   telephone derives added, i.e. a digit-coded 9-key scheme (the harness script
//   writes it next to a copy of the built-in package).
//
//   PROFILE A (opted-in source): `t9_digits` plus ONE added line
//   (`keyboard_rewrite_prefix: letter_class_v1`). The generator must
//     * add the bounded letter-class abbreviation layer to the GENERATED 9-key
//       companion (never to the source) because the source's own prism has no
//       single-letter keys,
//     * declare `keyboard_rewrite` version 4 / `prefix_token_rewrite_v4` with a
//       bounded `prefix_keys` sample derived from the source's real token
//       inventory,
//     * pass the native candidate-free deploy verification, and
//     * make the live report for the digit `2` offer the actual letter classes
//       a/b/c (and `d`/… never), each one live-proven to NARROW the code.
//   Every offered option is then locked, restored, continued and refused through
//   the engine: no hanzi is committed, the composition stays valid, restore is
//   lossless, and stale/invalid/unknown requests change nothing.
//
//   PROFILE C (un-opted): the same source WITHOUT the opt-in. Generation
//   succeeds, but it must produce the bounded alias lock — no prefix layer, no
//   prefix keys — so an upstream scheme is never auto-upgraded.
//
// Everything is machine-parsable (`INFO`/`PASS`/`FAIL`/`RESULT` lines). The
// harness only fails on contract violations, never because an upstream scheme
// turned out to be unsupported.
//
// Usage:
//   t9-letter-lock-main --opted <sharedA> --adapted <sharedC>
//                       --user <userDir>
// ---------------------------------------------------------------------------
import Foundation
import KeyboardCore
import PackageManager

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(2)
}
var failureCount = 0
func check(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS: \(name)")
    } else {
        failureCount += 1
        print("FAIL: \(name)")
    }
}
func note(_ message: String) { print("INFO \(message)") }

/// One machine-parsable record (sorted keys keep repeated runs byte-stable).
func emit(_ tag: String, _ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else { return }
    print("\(tag) \(text)")
}

/// Minimal scan of `speller/algebra` (the harness must not pull in a YAML lib).
func algebraRules(ofYAML text: String) -> [String] {
    var inAlgebra = false
    var out: [String] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("algebra:") {
            inAlgebra = true
            continue
        }
        guard inAlgebra else { continue }
        if trimmed.hasPrefix("- ") {
            out.append(
                trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
            continue
        }
        if !trimmed.isEmpty && !trimmed.hasPrefix("#") { break }
    }
    return out
}

func sha256(ofFile path: String) -> String {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return "<missing>" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@main
struct T9LetterLockMain {
    static func main() {
        var opted = "", adapted = "", userRoot = ""
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--opted": opted = args.next() ?? ""
            case "--adapted": adapted = args.next() ?? ""
            case "--user": userRoot = args.next() ?? ""
            default: fail("unknown argument \(a)")
            }
        }
        guard !opted.isEmpty, !adapted.isEmpty, !userRoot.isEmpty else {
            fail("--opted/--adapted/--user required")
        }
        let fm = FileManager.default
        let userRootURL = URL(fileURLWithPath: userRoot, isDirectory: true)
        try? fm.createDirectory(at: userRootURL, withIntermediateDirectories: true)

        // ---- shared helpers -------------------------------------------------
        func type(_ engine: RimeEngine, _ text: String) {
            for ch in text { if let key = RimeKey(character: ch) { _ = try! engine.processKey(key) } }
        }
        /// Type `text` from a clean composition and read the live report.
        func probe(_ engine: RimeEngine, _ text: String) -> RimeAmbiguitySpellings? {
            engine.clearComposition()
            type(engine, text)
            return engine.ambiguitySpellings()
        }
        func candidates(_ engine: RimeEngine) -> [String] { engine.state().candidates.map(\.text) }

        func withEngine(
            shared: String, user: String, app: String,
            _ body: (RimeEngine) -> Void
        ) {
            let url = URL(fileURLWithPath: user, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            let engine = RimeEngine(
                configuration: .init(
                    sharedDirectory: URL(fileURLWithPath: shared, isDirectory: true),
                    userDirectory: url, appName: app))
            do { try engine.start() } catch { fail("start: \(error)") }
            body(engine)
            engine.shutdown()
        }

        /// Run the production generation path over `shared` and return the
        /// generated adapter registry plus the queryable engine.
        func prepare(shared: String, user: String, sources: [String]) -> RimeEngine {
            let sharedURL = URL(fileURLWithPath: shared, isDirectory: true)
            let userURL = URL(fileURLWithPath: user, isDirectory: true)
            let engine = RimeEngine(
                configuration: .init(
                    sharedDirectory: sharedURL, userDirectory: userURL,
                    appName: "rime.songyan.letterlock"))
            do { try engine.start() } catch { fail("start: \(error)") }
            let available = Set(engine.schemas().map(\.id))
            let enabled = sources.filter { available.contains($0) }
            guard enabled.count == sources.count else {
                fail("sources missing: \(sources) vs \(available.sorted())")
            }
            do {
                let requested = enabled.flatMap { source in
                    [KeyboardLayoutKind.merged14, .phone9].map { PublishedKeyboard(schemaID: source, layout: $0) }
                }
                try CompactAdapterDeployment.prepare(
                    engine: engine, resourceURL: sharedURL, userDataURL: userURL,
                    requested: requested)
                note("prepare \(sharedURL.lastPathComponent)")
            } catch { fail("prepare: \(error)") }
            return engine
        }

        let adapters = { (user: String) -> [KeyboardResourceSet.EncodingAdapter] in
            KeyboardResourceSet.readEncodingAdapters(
                build: URL(fileURLWithPath: user, isDirectory: true).appendingPathComponent("build"))
        }

        // =====================================================================
        // PROFILE A — the opted-in digit-coded source
        // =====================================================================
        let sourceYAML = URL(fileURLWithPath: opted, isDirectory: true)
            .appendingPathComponent("t9_digits.schema.yaml").path
        let sourceDigestBefore = sha256(ofFile: sourceYAML)
        let engineA = prepare(
            shared: opted, user: userRootURL.appendingPathComponent("a").path,
            sources: ["t9_digits"])
        let adaptersA = adapters(userRootURL.appendingPathComponent("a").path)
        guard
            let t9AdapterA = adaptersA.first(where: {
                $0.sourceSchemaID == "t9_digits" && $0.layout == .phone9 && $0.schemaID != $0.sourceSchemaID
            })
        else {
            fail("opted profile: no generated 9-key companion for t9_digits")
        }
        let companionA = userRootURL.appendingPathComponent("a")
            .appendingPathComponent(t9AdapterA.schemaID + ".schema.yaml").path
        guard let yamlA = try? String(contentsOfFile: companionA, encoding: .utf8) else {
            fail("opted profile: generated companion missing at \(companionA)")
        }
        let rulesA = algebraRules(ofYAML: yamlA)
        note("A companion=\(t9AdapterA.schemaID) algebraRules=\(rulesA.count)")
        emit(
            "COMPANION_A",
            [
                "schemaID": t9AdapterA.schemaID,
                "hasPrefixLayerRule": rulesA.contains(CompactSchemaAdapter.letterClassPrefixRule),
                "hasV4Lock": yamlA.contains(CompactSchemaAdapter.prefixTokenLockValue),
                "hasAliasLock": yamlA.contains(CompactSchemaAdapter.tokenAliasLockValue),
                "bytes": yamlA.utf8.count,
            ])
        check(
            rulesA.contains(CompactSchemaAdapter.letterClassPrefixRule),
            "A: generated companion carries the bounded letter-class abbreviation layer")
        check(
            yamlA.contains(CompactSchemaAdapter.prefixTokenLockValue),
            "A: generated companion declares prefix_token_rewrite_v4")
        check(
            !yamlA.contains("lock_map:"),
            "A: v4 companion carries no per-token alias map")

        // The source itself must not have been rewritten by generation.
        check(
            sha256(ofFile: sourceYAML) == sourceDigestBefore,
            "A: source schema byte-identical after generation (read-only source)")
        check(
            !fm.fileExists(
                atPath: URL(fileURLWithPath: opted, isDirectory: true)
                    .appendingPathComponent(t9AdapterA.schemaID + ".schema.yaml").path),
            "A: no generated companion written into the source resource directory")

        // Parse the declared capability's `prefix_keys` with a minimal line scan
        // (the harness deliberately links no YAML library of its own).
        func prefixKeys(in yaml: String) -> [String] {
            var inKeys = false
            var out: [String] = []
            for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("prefix_keys:") {
                    inKeys = true
                    continue
                }
                guard inKeys else { continue }
                if trimmed.hasPrefix("- ") {
                    out.append(
                        trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
                    continue
                }
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") { break }
            }
            return out
        }
        let keysA = prefixKeys(in: yamlA)
        emit("PREFIX_KEYS_A", ["keys": keysA, "count": keysA.count])
        check(
            !keysA.isEmpty && keysA.count <= CompactSchemaAdapter.letterClassPrefixKeyLimit,
            "A: prefix_keys sample is non-empty and bounded (got \(keysA.count))")
        check(
            keysA == keysA.sorted() && Set(keysA).count == keysA.count,
            "A: prefix_keys sample is sorted and duplicate-free")
        check(
            keysA.contains("a") && keysA.contains("b") && keysA.contains("c"),
            "A: prefix_keys derived from the real token inventory contains a/b/c")
        check(
            !keysA.contains("A") && !keysA.contains("1"),
            "A: prefix_keys is lowercase-ASCII-letter only")

        // Native, candidate-free deploy verification of the generated companion.
        guard engineA.selectSchema(t9AdapterA.schemaID) else { fail("A: select companion") }
        check(
            engineA.rewriteVerification() == .verified,
            "A: native post-deploy rewrite verification verified (mode=prefix)")
        engineA.clearComposition()

        // ---- live report: digit `2` must offer the real letter classes -------
        let label = "A/\(t9AdapterA.schemaID)"
        let report2 = probe(engineA, "2")
        guard let report2 else { fail("\(label): no live report for 2") }
        emit(
            "REPORT2",
            [
                "mode": report2.lockMode.rawValue,
                "spellings": report2.spellings,
                "lockable": report2.lockable,
                "prefixOptions": report2.prefixOptions,
                "optionSemantics": report2.optionSemantics,
                "complete": report2.complete,
            ])
        check(report2.lockMode == .prefixToken, "\(label): lock mode is prefix_token")
        check(
            Set(report2.prefixOptions) == Set(["a", "b", "c"]),
            "\(label): live prefix options are exactly a/b/c (got \(report2.prefixOptions))")
        check(
            report2.lockable.contains("a") && report2.lockable.contains("b")
                && report2.lockable.contains("c"),
            "\(label): a/b/c are all lockable")
        check(
            !report2.lockable.contains("d") && !report2.prefixOptions.contains("d"),
            "\(label): a letter outside the digit class is never offered")
        check(
            report2.optionSemantics["b"] == "initial" && report2.optionSemantics["c"] == "initial",
            "\(label): abbreviation options are labelled 'initial'")
        check(
            report2.spellings.contains("a"),
            "\(label): the plain spelling `a` is still reported")

        // The other digit classes must behave identically without any hardcoded
        // letter table in the bridge.
        for (digit, letters) in [
            ("3", ["d", "e", "f"]), ("7", ["p", "q", "r", "s"]),
            ("9", ["w", "x", "y", "z"]),
        ] {
            guard let r = probe(engineA, digit) else { fail("\(label): no report for \(digit)") }
            check(
                Set(r.prefixOptions) == Set(letters),
                "\(label): digit \(digit) offers \(letters) (got \(r.prefixOptions))")
            check(r.lockMode == .prefixToken, "\(label): digit \(digit) uses the prefix lock")
        }

        // ---- lock / continue / backspace / restore / refusals ---------------
        // Baseline candidates of the reduced code, for the lossless comparison.
        engineA.clearComposition()
        type(engineA, "2")
        let baseline2 = candidates(engineA)
        let baselineReport2 = engineA.ambiguitySpellings()

        for option in report2.lockable {
            let optionLabel = "\(label) lock 2/\(option)"
            // Every option starts from a clean, freshly typed reduced code.
            engineA.clearComposition()
            type(engineA, "2")
            let apply = engineA.applyAmbiguitySpelling(
                expectedInput: "2", segmentStart: 0, segmentEnd: 1, spelling: option)
            check(apply == .applied, "\(optionLabel): applied (got \(apply))")
            let locked = engineA.state()
            check(locked.isComposing, "\(optionLabel): stays composing")
            check(locked.input == option, "\(optionLabel): input is the live key (got '\(locked.input)')")
            check(locked.commitText.isEmpty, "\(optionLabel): commits no hanzi")
            let lockedCandidates = candidates(engineA)
            check(!lockedCandidates.isEmpty, "\(optionLabel): locked code has real candidates")
            emit(
                "LOCK",
                [
                    "option": option, "input": locked.input,
                    "candidateCount": lockedCandidates.count,
                    "candidatesFirst": Array(lockedCandidates.prefix(6)),
                ])

            // Stale re-apply of the same segment must be refused untouched.
            let stale = engineA.applyAmbiguitySpelling(
                expectedInput: "2", segmentStart: 0, segmentEnd: 1, spelling: option)
            check(stale == .stale, "\(optionLabel): stale re-apply refused (got \(stale))")
            check(engineA.state().input == option, "\(optionLabel): stale re-apply left the input")

            // First Backspace (the controller restores before deleting).
            let firstBackspace = engineA.restoreAmbiguitySpelling(
                expectedInput: option, segmentStart: 0, segmentEnd: option.utf8.count,
                expectedSpelling: option, reducedCode: "2")
            check(
                firstBackspace == .applied,
                "\(optionLabel): first-backspace restore -> applied (got \(firstBackspace))")
            let restored = engineA.state()
            check(restored.input == "2", "\(optionLabel): restore recovers '2' (got '\(restored.input)')")
            check(
                candidates(engineA) == baseline2,
                "\(optionLabel): restore recovers the exact reduced candidate order")
            check(restored.commitText.isEmpty, "\(optionLabel): restore commits no hanzi")
            emit(
                "RESTORE",
                [
                    "option": option, "reducedCode": "2",
                    "restoredInput": restored.input,
                    "candidateCount": candidates(engineA).count,
                ])

            // Continued digits after restore re-interpret the reduced code.
            type(engineA, "2")
            let continued = engineA.state()
            check(continued.input == "22", "\(optionLabel): continued digit appends (got '\(continued.input)')")
            check(
                !candidates(engineA).isEmpty,
                "\(optionLabel): continued digit still yields candidates")
            engineA.clearComposition()
            type(engineA, "2")
            check(
                engineA.ambiguitySpellings()?.lockable == baselineReport2?.lockable,
                "\(optionLabel): reduced code re-offers the same options")

            // ---- refusals on the locked span --------------------------------
            _ = engineA.applyAmbiguitySpelling(
                expectedInput: "2", segmentStart: 0,
                segmentEnd: 1, spelling: option)
            let lockedInput = engineA.state().input
            let unknown = engineA.applyAmbiguitySpelling(
                expectedInput: lockedInput, segmentStart: 0,
                segmentEnd: lockedInput.utf8.count, spelling: "not-a-token")
            check(
                unknown == .invalid || unknown == .stale,
                "\(optionLabel): unknown token refused (got \(unknown))")
            let offAlphabet = engineA.restoreAmbiguitySpelling(
                expectedInput: lockedInput, segmentStart: 0,
                segmentEnd: lockedInput.utf8.count, expectedSpelling: option,
                reducedCode: "!")
            check(
                offAlphabet == .invalid || offAlphabet == .failed,
                "\(optionLabel): off-alphabet reduced code refused (got \(offAlphabet))")
            let wrongSpelling = engineA.restoreAmbiguitySpelling(
                expectedInput: lockedInput, segmentStart: 0,
                segmentEnd: lockedInput.utf8.count, expectedSpelling: "z",
                reducedCode: "2")
            check(
                wrongSpelling != .applied,
                "\(optionLabel): wrong expected key refused (got \(wrongSpelling))")
            check(
                engineA.state().input == lockedInput,
                "\(optionLabel): refused probes left the locked input")
            emit(
                "REFUSE",
                [
                    "option": option, "unknownToken": "\(unknown)",
                    "offAlphabet": "\(offAlphabet)",
                    "wrongExpectedKey": "\(wrongSpelling)",
                ])

            // While locked, a further digit keeps the composition alive without
            // committing anything (the documented controller flow restores before
            // continuing; this only proves the locked state is stable).
            type(engineA, "4")
            let extended = engineA.state()
            check(
                extended.isComposing && extended.commitText.isEmpty,
                "\(optionLabel): locked state stays composing after a digit")
            emit(
                "LOCKED_CONTINUE",
                [
                    "option": option, "input": extended.input,
                    "candidateCount": candidates(engineA).count,
                    "candidatesFirst": Array(candidates(engineA).prefix(4)),
                ])
            engineA.clearComposition()
        }

        // A letter outside the digit class must be refused for the segment, and
        // an arbitrary exact token that the segment does not narrow to as well.
        for bad in ["d", "ba", "z"] {
            engineA.clearComposition()
            type(engineA, "2")
            let outcome = engineA.applyAmbiguitySpelling(
                expectedInput: "2", segmentStart: 0, segmentEnd: 1, spelling: bad)
            check(
                outcome == .invalid || outcome == .stale,
                "\(label): non-option '\(bad)' refused (got \(outcome))")
            check(
                engineA.state().input == "2",
                "\(label): refused non-option '\(bad)' left the input")
        }

        // ---- multi-key code: the EXACT token path of the same v4 companion ---
        // No single-character narrowing exists for `22`, so the option is the
        // segment's own exact token `ba`, which must itself be a unique live key.
        let report22 = probe(engineA, "22")
        if let report22 {
            emit(
                "REPORT22",
                [
                    "mode": report22.lockMode.rawValue,
                    "spellings": report22.spellings,
                    "lockable": report22.lockable,
                    "prefixOptions": report22.prefixOptions,
                    "optionSemantics": report22.optionSemantics,
                ])
            check(report22.lockMode == .prefixToken, "\(label): 22 uses the prefix lock")
            check(
                report22.prefixOptions.isEmpty,
                "\(label): a multi-key segment has no single-character narrowing")
            check(
                report22.lockable == ["ba"],
                "\(label): 22 lockable is the exact live token (got \(report22.lockable))")
            engineA.clearComposition()
            type(engineA, "22")
            let baseline22 = candidates(engineA)
            let apply22 = engineA.applyAmbiguitySpelling(
                expectedInput: "22", segmentStart: 0, segmentEnd: 2, spelling: "ba")
            check(apply22 == .applied, "\(label): 22 lock ba applied (got \(apply22))")
            check(
                engineA.state().input == "ba",
                "\(label): 22 lock writes the token (got '\(engineA.state().input)')")
            check(engineA.state().commitText.isEmpty, "\(label): 22 lock commits no hanzi")
            let restore22 = engineA.restoreAmbiguitySpelling(
                expectedInput: "ba", segmentStart: 0, segmentEnd: 2,
                expectedSpelling: "ba", reducedCode: "22")
            check(restore22 == .applied, "\(label): 22 restore applied (got \(restore22))")
            check(
                candidates(engineA) == baseline22,
                "\(label): 22 restore recovers the exact reduced candidates")
            let badToken = engineA.applyAmbiguitySpelling(
                expectedInput: "22", segmentStart: 0, segmentEnd: 2, spelling: "ca")
            check(
                badToken == .invalid || badToken == .stale,
                "\(label): 22 wrong token refused (got \(badToken))")
            engineA.clearComposition()
        } else {
            fail("\(label): no live report for 22")
        }

        // ---- no capability on the adapted SOURCE (report-only until generated) --
        if engineA.selectSchema("t9_digits") {
            let sourceVerification = engineA.rewriteVerification()
            emit("SOURCE_A", ["verification": "\(sourceVerification)"])
            check(
                sourceVerification == .absent,
                "\(label): the opted-in source itself declares no rewrite capability")
            engineA.clearComposition()
            type(engineA, "2")
            let sourceReport = engineA.ambiguitySpellings()
            check(
                sourceReport == nil || sourceReport?.lockMode == RimeAmbiguitySpellings.LockMode.none,
                "\(label): the source exposes no lock mode")
            check(
                sourceReport?.prefixOptions.isEmpty ?? true,
                "\(label): the source exposes no prefix options")
            if let source = sourceReport {
                check(source.lockable.isEmpty, "\(label): the source exposes no lockable option")
            }
        } else {
            fail("\(label): could not select the source schema")
        }
        engineA.shutdown()

        // =====================================================================
        // PROFILE C — the adapted-but-un-opted source: alias lock, never v4
        // =====================================================================
        let adaptedSourceYAML = URL(fileURLWithPath: adapted, isDirectory: true)
            .appendingPathComponent("t9_digits.schema.yaml").path
        let adaptedDigestBefore = sha256(ofFile: adaptedSourceYAML)
        let engineC = prepare(
            shared: adapted, user: userRootURL.appendingPathComponent("c").path,
            sources: ["t9_digits"])
        let adaptersC = adapters(userRootURL.appendingPathComponent("c").path)
        guard
            let t9AdapterC = adaptersC.first(where: {
                $0.sourceSchemaID == "t9_digits" && $0.layout == .phone9 && $0.schemaID != $0.sourceSchemaID
            })
        else {
            fail("adapted profile: no generated 9-key companion for t9_digits")
        }
        let companionC = userRootURL.appendingPathComponent("c")
            .appendingPathComponent(t9AdapterC.schemaID + ".schema.yaml").path
        guard let yamlC = try? String(contentsOfFile: companionC, encoding: .utf8) else {
            fail("adapted profile: generated companion missing")
        }
        emit(
            "COMPANION_C",
            [
                "schemaID": t9AdapterC.schemaID,
                "hasV4Lock": yamlC.contains(CompactSchemaAdapter.prefixTokenLockValue),
                "hasAliasLock": yamlC.contains(CompactSchemaAdapter.tokenAliasLockValue),
                "hasPrefixKeys": yamlC.contains("prefix_keys:"),
                "hasPrefixLayerRule": algebraRules(ofYAML: yamlC)
                    .contains(CompactSchemaAdapter.letterClassPrefixRule),
            ])
        check(
            !yamlC.contains(CompactSchemaAdapter.prefixTokenLockValue),
            "C: an adaptable but un-opted source is NOT auto-upgraded to the prefix lock")
        check(
            !yamlC.contains("prefix_keys:"),
            "C: no prefix_keys are declared without the opt-in")
        check(
            !algebraRules(ofYAML: yamlC).contains(CompactSchemaAdapter.letterClassPrefixRule),
            "C: no letter-class grammar layer without the opt-in")
        check(
            yamlC.contains(CompactSchemaAdapter.tokenAliasLockValue),
            "C: the schema-agnostic alias lock is unchanged for un-opted script sources")
        check(
            sha256(ofFile: adaptedSourceYAML) == adaptedDigestBefore,
            "C: source schema byte-identical after generation (read-only source)")

        guard engineC.selectSchema(t9AdapterC.schemaID) else { fail("C: select companion") }
        check(
            engineC.rewriteVerification() == .verified,
            "C: alias companion verification unchanged")
        engineC.clearComposition()
        let reportC = probe(engineC, "2")
        guard let reportC else { fail("C: no live report for 2") }
        emit(
            "REPORT2_C",
            [
                "mode": reportC.lockMode.rawValue,
                "spellings": reportC.spellings,
                "lockable": reportC.lockable,
                "prefixOptions": reportC.prefixOptions,
            ])
        check(reportC.lockMode != .prefixToken, "C: un-opted companion keeps its lock mode")
        check(reportC.prefixOptions.isEmpty, "C: no prefix options without the opt-in")
        check(
            reportC.lockable == ["a"],
            "C: lockable for 2 is the exact single-letter token only (got \(reportC.lockable))")
        engineC.shutdown()

        // =====================================================================
        emit(
            "RESULT",
            [
                "failures": failureCount,
                "optedCompanion": t9AdapterA.schemaID,
                "adaptedCompanion": t9AdapterC.schemaID,
            ])
        print("ALL DONE (failures=\(failureCount))")
        if failureCount > 0 { exit(1) }
    }
}
