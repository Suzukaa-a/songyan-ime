// ---------------------------------------------------------------------------
// ambiguity-main.swift — production-path verification of the ambiguity-spelling
// bridge (`rb_copy_ambiguity_spellings_json` and the lock/apply calls) against
// the pinned macOS librime engine:
//
//   RimeEngine (real librime) -> RimeAmbiguitySpellings (typed model)
//
// It asserts that enumeration is read-only (input/preedit/highlight/candidates
// unchanged), that a 26-key layout never asks on the production gate, that
// `nil` is reserved for "cannot answer" while an empty/singleton list is a
// definite "not ambiguous", that the cap/truncation contract holds, and that
// locking a spelling is reversible and refused for undeclared adapters.
// Fixtures:
//
//   built-in 9-key `72`  -> <2 spellings (no valid combination)
//   built-in 9-key `986` -> ["yun","zuo"]
//   built-in 14-key flypy `ug` -> ["chang","cheng","shang","sheng"]
//   ice t9 `72`  -> ["pa","sa"]
//
// Usage: ambiguity-main --shared <dir> --user <dir> [--prebuilt <dir>]
// ---------------------------------------------------------------------------
import Foundation
import RimeKit

/// Generated companions bundled with the built-in package (BuiltinTemplateSchemas.adapters).
let builtinT9 = "keyboard_47246213a538cb99d374_9"
let builtinFlypy14 = "keyboard_3d7821f984693864ae91_14"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { fail(name) }
}

@main
struct AmbiguityMain {
    static func main() {
        var shared = "", user = "", prebuilt = ""
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--shared": shared = args.next() ?? ""
            case "--user": user = args.next() ?? ""
            case "--prebuilt": prebuilt = args.next() ?? ""
            default: fail("unknown argument \(a)")
            }
        }
        guard !shared.isEmpty, !user.isEmpty else { fail("--shared/--user required") }

        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: URL(fileURLWithPath: shared, isDirectory: true),
                userDirectory: URL(fileURLWithPath: user, isDirectory: true),
                appName: "rime.songyan.ambiguity",
                prebuiltDirectory: prebuilt.isEmpty ? nil : URL(fileURLWithPath: prebuilt, isDirectory: true)))
        do { try engine.start() } catch { fail("start: \(error)") }

        // Model the production physical-layout gate explicitly. Reduced-layout
        // profiles request trusted spelling; the 26-key section turns this off
        // and proves state reads perform zero candidate decodes.
        var compactSpellingLayout = true
        engine.spellingDemand = { compactSpellingLayout }

        let schemaIDs = engine.schemas().map(\.id)
        print("schemas=\(schemaIDs)")
        // Each fixture tree is one profile; the built-in tree must carry every built-in fixture.
        if schemaIDs.contains("songyan_flypy") {
            for id in [builtinT9, builtinFlypy14] where !schemaIDs.contains(id) {
                fail("built-in fixture schema \(id) is missing")
            }
        } else if !schemaIDs.contains("t9") && !schemaIDs.contains("cross_wired") {
            fail("no known fixture profile in \(shared)")
        }

        // The production front-end gate that decides whether the picker may ever
        // ask. No alphabet/keycap heuristic: it is purely the real reduced layout.
        func isReducedSchema(_ id: String) -> Bool {
            id.hasSuffix("_14") || id.hasSuffix("_18") || id.hasSuffix("_9") || id == "t9"
        }

        func type(_ text: String) {
            for ch in text { if let key = RimeKey(character: ch) { _ = try! engine.processKey(key) } }
        }

        // The observable state the read-only call must never touch. `commitText`
        // is excluded on purpose: `state()` itself consumes librime's pending
        // commit, which is orthogonal to the enumeration under test.
        func fingerprint(_ state: RimeState) -> String {
            let candidates = state.candidates.map { "\($0.text)|\($0.comment ?? "")" }
                .joined(separator: ";")
            return "\(state.schemaID)|\(state.isComposing)|\(state.input)|\(state.preedit)"
                + "|\(state.preeditSelStart)|\(state.preeditSelEnd)|\(state.pageIndex)"
                + "|\(state.highlightedIndex)|\(candidates)"
        }

        func decodeCount() -> UInt64 { rb_spelling_decode_count() }

        // ---- built-in 9-key: 72 has no valid combination, 986 is {yun,zuo} --
        if schemaIDs.contains(builtinT9) {
            _ = engine.selectSchema(builtinT9)
            engine.clearComposition()
            let decodeBefore = decodeCount()

            type("72")
            let state72 = engine.state()
            check(state72.input == "72", "t9 72 raw input")
            let fingerprint72 = fingerprint(state72)
            guard let report72 = engine.ambiguitySpellings() else {
                fail("t9 72: bridge refused to answer a real composing abc segment")
            }
            check(report72.revisionInput == "72", "t9 72 revision_input")
            check(
                report72.segment.start == 0 && report72.segment.end == 2,
                "t9 72 segment [0,2)")
            check(
                report72.spellings.count < 2,
                "t9 72 is not an ambiguity (got \(report72.spellings))")
            check(report72.complete, "t9 72 complete")
            check(fingerprint(engine.state()) == fingerprint72, "t9 72 read-only")
            check(
                decodeCount() == decodeBefore,
                "t9 72 does not touch the candidate-decode counter")
            engine.clearComposition()

            type("986")
            let state986 = engine.state()
            check(state986.input == "986", "t9 986 raw input")
            let fingerprint986 = fingerprint(state986)
            guard let report986 = engine.ambiguitySpellings() else {
                fail("t9 986: bridge refused to answer")
            }
            check(
                report986.spellings == ["yun", "zuo"],
                "t9 986 == [yun,zuo] (got \(report986.spellings))")
            check(report986.revisionInput == "986", "t9 986 revision_input")
            check(
                report986.segment.start == 0 && report986.segment.end == 3,
                "t9 986 segment [0,3)")
            check(report986.complete, "t9 986 complete")
            check(fingerprint(engine.state()) == fingerprint986, "t9 986 read-only")

            // Cap contract: default 32, explicit 1 truncates with complete=false,
            // <=0 falls back to the default, >64 is clamped to the hard limit.
            guard let capped = engine.ambiguitySpellings(maxItems: 1) else {
                fail("t9 986 capped request refused")
            }
            check(capped.spellings == ["yun"], "cap=1 keeps first sorted spelling")
            check(capped.complete == false, "cap=1 reports complete=false")
            guard let defaulted = engine.ambiguitySpellings(maxItems: 0) else {
                fail("t9 986 max_items<=0 refused")
            }
            check(
                defaulted.spellings == ["yun", "zuo"] && defaulted.complete,
                "max_items<=0 falls back to default 32")
            guard let clamped = engine.ambiguitySpellings(maxItems: 1000) else {
                fail("t9 986 max_items>64 refused")
            }
            check(
                clamped.spellings == ["yun", "zuo"] && clamped.complete,
                "max_items>64 is clamped to the hard limit")
            // Swift-side normalization must not trap on integer extremes.
            guard let huge = engine.ambiguitySpellings(maxItems: Int.max) else {
                fail("t9 986 max_items=Int.max refused")
            }
            check(
                huge.spellings == ["yun", "zuo"] && huge.complete,
                "max_items=Int.max normalizes without trapping")
            guard let tiny = engine.ambiguitySpellings(maxItems: Int.min) else {
                fail("t9 986 max_items=Int.min refused")
            }
            check(
                tiny.spellings == ["yun", "zuo"] && tiny.complete,
                "max_items=Int.min falls back to the default 32 without trapping")
            check(fingerprint(engine.state()) == fingerprint986, "t9 986 cap probes read-only")
            engine.clearComposition()

            // Stale revision: a report taken before the next key must not match
            // the live input afterwards (the Swift picker rejects it).
            type("98")
            guard let staleProbe = engine.ambiguitySpellings() else {
                fail("t9 98 probe refused")
            }
            type("6")
            let liveInput = engine.state().input
            check(liveInput == "986", "t9 stale probe live input 986")
            check(
                staleProbe.revisionInput != liveInput,
                "stale revision '\(staleProbe.revisionInput)' != live '\(liveInput)'")
            engine.clearComposition()

            // Partial selection: only the tail segment [2,5) is enumerated.
            type("64426")
            _ = engine.selectCandidateAbsolute(1)  // 你 (segment closes to [0,2))
            let tailState = engine.state()
            check(tailState.isComposing, "t9 64426+你 still composing")
            guard let tail = engine.ambiguitySpellings() else {
                fail("t9 tail segment refused")
            }
            check(
                tail.segment.start == 2 && tail.segment.end == 5,
                "t9 tail segment [2,5) (got [\(tail.segment.start),\(tail.segment.end)))")
            check(tail.revisionInput == "64426", "t9 tail revision_input is whole input")
            check(tail.spellings == ["hao"], "t9 tail 426 == [hao] (got \(tail.spellings))")
            check(tail.spellings.count < 2, "t9 tail is not an ambiguity")
            engine.clearComposition()

            check(
                engine.ambiguitySpellings() == nil,
                "t9 no composition -> nil (cannot answer, not 'no ambiguity')")

            // ---- 9-key CAS apply / restore (capability-gated) --------------
            _ = engine.selectSchema(builtinT9)
            engine.clearComposition()
            // Canonical display must be authorized for the static block.
            if let context = engine.displayContext() {
                check(
                    context.capability?.mode == .canonical,
                    "t9 static block is canonical")
                check(
                    context.authorizedMode() == .canonical,
                    "t9 display context authorizes canonical")
            } else {
                fail("t9 display context unavailable")
            }
            type("986")
            let beforeLock = engine.state()
            check(
                beforeLock.candidates.map(\.text) == ["云", "作", "雨", "鱼"],
                "t9 986 digit candidate order baseline")
            let applyResult = engine.applyAmbiguitySpelling(
                expectedInput: "986", segmentStart: 0, segmentEnd: 3, spelling: "yun")
            check(applyResult == .applied, "t9 986 apply yun -> applied (got \(applyResult))")
            let locked = engine.state()
            // The schema-agnostic capability rewrites to the opaque alias declared
            // by lock_map (never to the raw spelling itself).
            let yunAlias = locked.input
            check(
                yunAlias.hasPrefix("9") && yunAlias != "yun",
                "t9 lock rewrites to an opaque alias (got '\(yunAlias)')")
            check(locked.isComposing, "t9 lock stays composing")
            check(
                locked.highlightedSpelling == "yun",
                "t9 lock resolves to yun (got '\(locked.highlightedSpelling)')")
            check(
                locked.candidates.map(\.text) == ["云"],
                "t9 lock yun narrows candidates (got \(locked.candidates.map(\.text)))")
            check(locked.commitText.isEmpty, "t9 lock commits no hanzi")

            // stale: reusing the pre-lock input must not write.
            let staleApply = engine.applyAmbiguitySpelling(
                expectedInput: "986", segmentStart: 0, segmentEnd: 3, spelling: "zuo")
            check(staleApply == .stale, "t9 applying with stale input -> stale (got \(staleApply))")
            check(engine.state().input == yunAlias, "t9 stale apply leaves input unchanged")
            // invalid: spelling not proven by the prism.
            let badSpelling = engine.applyAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: 0, segmentEnd: yunAlias.utf8.count,
                spelling: "nope")
            check(badSpelling == .invalid, "t9 illegal spelling -> invalid (got \(badSpelling))")
            check(engine.state().input == yunAlias, "t9 invalid apply leaves input unchanged")
            // stale: wrong raw range.
            let badRange = engine.applyAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: 0, segmentEnd: 2, spelling: "yun")
            check(badRange == .stale, "t9 wrong range -> stale (got \(badRange))")
            check(engine.state().input == yunAlias, "t9 wrong-range apply leaves input unchanged")
            // Int extremes / out-of-bounds must be refused BEFORE Int32(),
            // without trapping, and without touching input.
            let hugeRange = engine.applyAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: 0, segmentEnd: Int.max, spelling: "yun")
            check(hugeRange == .invalid, "t9 end=Int.max -> invalid (got \(hugeRange))")
            let negRange = engine.applyAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: Int.min, segmentEnd: 3, spelling: "yun")
            check(negRange == .invalid, "t9 start=Int.min -> invalid (got \(negRange))")
            let hugeStart = engine.restoreAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: Int(Int32.max) + 1, segmentEnd: Int(Int32.max) + 2,
                expectedSpelling: "yun", reducedCode: "986")
            check(hugeStart == .invalid, "t9 restore Int32-overflow -> invalid (got \(hugeStart))")
            check(engine.state().input == yunAlias, "t9 extreme-range probes leave input unchanged")

            // restore back to the reduced code the user actually typed.
            let restoreResult = engine.restoreAmbiguitySpelling(
                expectedInput: yunAlias, segmentStart: 0, segmentEnd: yunAlias.utf8.count,
                expectedSpelling: "yun", reducedCode: "986")
            check(restoreResult == .applied, "t9 restore -> applied (got \(restoreResult))")
            let restored = engine.state()
            check(restored.input == "986", "t9 restore input back to '986' (got '\(restored.input)')")
            check(
                restored.candidates.map(\.text) == ["云", "作", "雨", "鱼"],
                "t9 restore recovers the original digit candidate order")
            check(restored.commitText.isEmpty, "t9 restore commits no hanzi")
            let staleRestore = engine.restoreAmbiguitySpelling(
                expectedInput: "986", segmentStart: 0, segmentEnd: 3,
                expectedSpelling: "yun", reducedCode: "986")
            check(staleRestore == .stale, "t9 restore on unlocked span -> stale (got \(staleRestore))")
            engine.clearComposition()
        } else {
            print("SKIP: no t9 schema")
        }

        // ---- built-in 14-key flypy: ug -> 4 canonical spellings -------------
        if schemaIDs.contains(builtinFlypy14) {
            _ = engine.selectSchema(builtinFlypy14)
            engine.clearComposition()
            if let context = engine.displayContext() {
                check(
                    context.capability?.mode == .sourceCode,
                    "flypy14 static block is source_code")
                check(
                    context.authorizedMode() == .sourceCode,
                    "flypy14 display context authorizes source_code")
            } else {
                fail("flypy14 display context unavailable")
            }
            type("ug")
            let state = engine.state()
            check(state.input == "ug", "flypy14 ug raw input")
            let before = fingerprint(state)
            guard let report = engine.ambiguitySpellings() else {
                fail("flypy14 ug: bridge refused to answer")
            }
            check(
                report.spellings == ["chang", "cheng", "shang", "sheng"],
                "flypy14 ug == [chang,cheng,shang,sheng] (got \(report.spellings))")
            check(report.revisionInput == "ug", "flypy14 ug revision_input")
            check(
                report.segment.start == 0 && report.segment.end == 2,
                "flypy14 ug segment [0,2)")
            check(report.complete, "flypy14 ug complete")
            check(fingerprint(engine.state()) == before, "flypy14 ug read-only")
            check(
                report.lockMode == .tokenAlias,
                "flypy14 declares bounded_token_alias lock (got \(report.lockMode))")
            check(
                report.lockable == ["chang", "cheng", "shang", "sheng"],
                "flypy14 ug ALL four options lockable (got \(report.lockable))")
            engine.clearComposition()

            // ---- 14-key alias CAS apply / restore, EVERY option -------------
            func lockAndRestore(
                merged: String, segmentEnd: Int, canonical: String,
                label: String
            ) {
                _ = engine.selectSchema(builtinFlypy14)
                engine.clearComposition()
                type(merged)
                let baselineCandidates = engine.state().candidates.map(\.text)
                check(!baselineCandidates.isEmpty, "\(label): merged baseline non-empty")
                let apply = engine.applyAmbiguitySpelling(
                    expectedInput: merged, segmentStart: 0, segmentEnd: segmentEnd,
                    spelling: canonical)
                check(apply == .applied, "\(label): apply \(canonical) -> applied (got \(apply))")
                let locked = engine.state()
                let alias = locked.input
                check(
                    alias != merged && alias.hasPrefix("9"),
                    "\(label): rewrites to an internal alias (got '\(alias)')")
                check(locked.isComposing, "\(label): still composing")
                check(locked.commitText.isEmpty, "\(label): no hanzi committed")
                check(
                    locked.highlightedSpelling == canonical,
                    "\(label): locked segment resolves only to \(canonical) (got '\(locked.highlightedSpelling)')")
                if let lockedReport = engine.ambiguitySpellings() {
                    check(
                        lockedReport.spellings == [canonical],
                        "\(label): alias enumerates to exactly [\(canonical)] (got \(lockedReport.spellings))")
                } else {
                    fail("\(label): alias report unavailable")
                }
                // stale must not corrupt the locked span.
                let stale = engine.applyAmbiguitySpelling(
                    expectedInput: merged, segmentStart: 0, segmentEnd: segmentEnd,
                    spelling: canonical)
                check(stale == .stale, "\(label): stale apply -> stale (got \(stale))")
                check(engine.state().input == alias, "\(label): stale apply input unchanged")
                let restore = engine.restoreAmbiguitySpelling(
                    expectedInput: alias, segmentStart: 0, segmentEnd: alias.utf8.count,
                    expectedSpelling: canonical, reducedCode: merged)
                check(restore == .applied, "\(label): restore -> applied (got \(restore))")
                let restored = engine.state()
                check(restored.input == merged, "\(label): restore input back to '\(merged)'")
                check(
                    restored.candidates.map(\.text) == baselineCandidates,
                    "\(label): restore recovers exact merged candidate order")
                check(restored.commitText.isEmpty, "\(label): restore commits no hanzi")
                engine.clearComposition()
            }
            for canonical in ["chang", "cheng", "shang", "sheng"] {
                lockAndRestore(merged: "ug", segmentEnd: 2, canonical: canonical, label: "ug/\(canonical)")
            }
            // Second ambiguous group so the full-coverage proof is not a one-off.
            _ = engine.selectSchema(builtinFlypy14)
            engine.clearComposition()
            type("gc")
            guard let gcReport = engine.ambiguitySpellings() else {
                fail("flypy14 gc: bridge refused to answer")
            }
            check(
                gcReport.spellings == ["gui", "hao", "hui"],
                "flypy14 gc == [gui,hao,hui] (got \(gcReport.spellings))")
            check(
                gcReport.lockable == ["gui", "hao", "hui"],
                "flypy14 gc all options lockable (got \(gcReport.lockable))")
            engine.clearComposition()
            for canonical in ["gui", "hao", "hui"] {
                lockAndRestore(merged: "gc", segmentEnd: 2, canonical: canonical, label: "gc/\(canonical)")
            }

            // BN+UI merged-key trajectory (the physical 14-key layout sends the
            // cluster-head letters: BN -> "b", UI -> "u", i.e. raw "bu"). The same
            // trajectory must expose BOTH BU and NI as live-prism-proven, lockable
            // alternatives — not just the engine's current first interpretation.
            _ = engine.selectSchema(builtinFlypy14)
            engine.clearComposition()
            type("bu")
            let buState = engine.state()
            check(buState.input == "bu", "flypy14 bu raw input")
            check(
                buState.candidates.contains { $0.text == "你" },
                "flypy14 bu candidates include 你")
            guard let buReport = engine.ambiguitySpellings() else {
                fail("flypy14 bu: bridge refused to answer")
            }
            check(
                buReport.spellings.contains("bu") && buReport.spellings.contains("ni"),
                "flypy14 bu spellings include bu+ni (got \(buReport.spellings))")
            check(
                buReport.lockable.contains("bu") && buReport.lockable.contains("ni"),
                "flypy14 bu lockable include bu+ni (got \(buReport.lockable))")
            check(
                buReport.lockMode == .tokenAlias,
                "flypy14 bu lock mode bounded_token_alias (got \(buReport.lockMode))")
            check(
                buReport.revisionInput == "bu" && buReport.segment.start == 0
                    && buReport.segment.end == 2, "flypy14 bu segment [0,2)")
            engine.clearComposition()
            // Every live-prism-proven option is independently lockable+reversible.
            lockAndRestore(merged: "bu", segmentEnd: 2, canonical: "ni", label: "bu/ni")
            lockAndRestore(merged: "bu", segmentEnd: 2, canonical: "bu", label: "bu/bu")
        } else {
            print("SKIP: no flypy14 schema")
        }

        // ---- rime-ice t9: 72 -> {pa,sa}; non-abc segment -> nil ------------
        if schemaIDs.contains("t9") {
            _ = engine.selectSchema("t9")
            engine.clearComposition()
            type("72")
            let state = engine.state()
            check(state.input == "72", "t9 72 raw input")
            let before = fingerprint(state)
            guard let report = engine.ambiguitySpellings() else {
                fail("t9 72: bridge refused to answer")
            }
            check(
                report.spellings == ["pa", "sa"],
                "rime-ice t9 72 == [pa,sa] (got \(report.spellings))")
            check(report.revisionInput == "72", "t9 72 revision_input")
            check(report.segment.start == 0 && report.segment.end == 2, "t9 72 segment [0,2)")
            check(report.complete, "t9 72 complete")
            check(fingerprint(engine.state()) == before, "t9 72 read-only")
            // Upstream rime-ice t9 has no declared lock capability: apply must be
            // refused as unsupported and leave input bytes untouched.
            let iceApply = engine.applyAmbiguitySpelling(
                expectedInput: "72", segmentStart: 0, segmentEnd: 2, spelling: "pa")
            check(
                iceApply == .unsupported,
                "upstream ice t9 apply -> unsupported (got \(iceApply))")
            check(engine.state().input == "72", "ice unsupported apply leaves input unchanged")
            engine.clearComposition()

            // A non-`abc` composing segment (calculator matcher) must yield nil,
            // never a fabricated empty-spelling "not ambiguous".
            type("=1+1")
            let calc = engine.state()
            check(calc.isComposing && calc.input == "=1+1", "t9 calculator segment composing")
            check(engine.ambiguitySpellings() == nil, "t9 non-abc segment -> nil")
            engine.clearComposition()
        } else {
            print("SKIP: no rime-ice t9 schema")
        }

        // ---- Fail-closed adapter check (native bridge verification) ----
        // A declaration naming another adapter schema is refused: lockMode "none",
        // empty lockable, and a rejected apply.
        func expectLockRefused(schema: String, merged: String, label: String) {
            _ = engine.selectSchema(schema)
            engine.clearComposition()
            type(merged)
            guard let report = engine.ambiguitySpellings() else {
                fail("\(label): bridge refused to answer")
            }
            check(
                report.lockMode == .none,
                "\(label): mismatched adapter -> lockMode none (got \(report.lockMode))")
            check(
                report.lockable.isEmpty,
                "\(label): mismatched adapter -> no lockable option (got \(report.lockable))")
            let apply = engine.applyAmbiguitySpelling(
                expectedInput: merged, segmentStart: 0, segmentEnd: merged.utf8.count,
                spelling: report.spellings.first ?? "x")
            check(
                apply == .unsupported,
                "\(label): mismatched adapter -> apply unsupported (got \(apply))")
            check(engine.state().input == merged, "\(label): refused apply leaves input unchanged")
            engine.clearComposition()
        }
        for schema in ["cross_wired", "direct_unbound"] where schemaIDs.contains(schema) {
            expectLockRefused(schema: schema, merged: "ab", label: "\(schema) ab")
        }

        // ---- 26-key isolation ----------------------------------------------
        for full in ["songyan_flypy"] where schemaIDs.contains(full) {
            compactSpellingLayout = false
            check(
                !isReducedSchema(full),
                "26-key \(full) is excluded by the production reduced-layout gate")
            _ = engine.selectSchema(full)
            engine.clearComposition()
            let decodeBefore = decodeCount()
            type("ni")
            let state = engine.state()
            check(state.isComposing, "songyan_flypy ni composing")
            let before = fingerprint(state)
            // Safety proof only: the front end must not ask on 26-key, but if a
            // bug ever did, the call must still be read-only and must not report
            // an ambiguity for a single canonical spelling.
            guard let report = engine.ambiguitySpellings() else {
                fail("26-key read-only safety probe refused a live abc segment")
            }
            check(
                report.spellings.count < 2,
                "26-key never reports an ambiguity (got \(report.spellings))")
            check(fingerprint(engine.state()) == before, "26-key enumeration read-only")
            check(decodeCount() == decodeBefore, "26-key enumeration performs 0 candidate decodes")
            // A 26-key schema has no lock capability: apply must be unsupported and
            // must not rewrite the input.
            let apply26 = engine.applyAmbiguitySpelling(
                expectedInput: "ni", segmentStart: 0, segmentEnd: 2, spelling: "ni")
            check(apply26 == .unsupported, "26-key apply -> unsupported (got \(apply26))")
            check(engine.state().input == "ni", "26-key unsupported apply leaves input unchanged")
            engine.clearComposition()
        }

        // ---- 14-key: a wrong input is still refused (no blind set_input) ----
        for reduced in [builtinFlypy14] where schemaIDs.contains(reduced) {
            compactSpellingLayout = true
            _ = engine.selectSchema(reduced)
            engine.clearComposition()
            type("ug")
            check(engine.state().input == "ug", "flypy14 ug composing")
            // Wrong expected input must be stale, not applied; the CAS guard is
            // independent of which options are lockable.
            let stale14 = engine.applyAmbiguitySpelling(
                expectedInput: "zz", segmentStart: 0, segmentEnd: 2, spelling: "shang")
            check(stale14 == .stale, "14-key wrong expected input -> stale (got \(stale14))")
            check(engine.state().input == "ug", "14-key refused apply leaves input unchanged")
            engine.clearComposition()
        }

        // ---- report cap/subset invariant + Swift decode of truncation ----
        check(
            rb_ambiguity_json_selftest() == 0,
            "C emission keeps lockable ⊆ spellings under over-cap input")
        func decode(_ json: String) -> RimeAmbiguitySpellings? {
            RimeAmbiguitySpellings(json: Data(json.utf8))
        }
        // A legal truncated report (cap hit) must decode, with lockable ⊆ spellings.
        let truncated = """
            {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"bounded_token_alias",
             "spellings":["aaa","bbb"],"lockable":["aaa"],"complete":false}
            """
        if let report = decode(truncated) {
            check(
                report.lockable == ["aaa"] && report.spellings == ["aaa", "bbb"],
                "truncated report decodes; lockable ⊆ spellings")
            check(!report.complete, "truncated report is complete=false")
        } else {
            fail("legal truncated report must decode")
        }
        // lockable not a subset of spellings is malformed -> nil.
        let badSubset = """
            {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"none",
             "spellings":["aaa"],"lockable":["zzz"],"complete":true}
            """
        check(decode(badSubset) == nil, "lockable ⊄ spellings must be rejected")
        // Unsorted payloads are rejected.
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"none",
                 "spellings":["bbb","aaa"],"lockable":[],"complete":true}
                """) == nil, "unsorted spellings rejected")
        // A control character is structurally invalid -> nil.
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"none",
                 "spellings":["a\\u0007b"],"lockable":[],"complete":true}
                """) == nil, "control character in token rejected")
        // Schema-agnostic tokens (shape codes with punctuation, Unicode/Bopomofo)
        // are structurally valid: the bridge, not the decoder, is the authority.
        if let shape = decode(
            """
            {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"bounded_token_alias",
             "spellings":["a.b","abc"],"lockable":["a.b"],"complete":true}
            """)
        {
            check(
                shape.spellings == ["a.b", "abc"] && shape.lockable == ["a.b"],
                "schema-agnostic ASCII token decodes")
            check(shape.lockMode == .tokenAlias, "bounded_token_alias lock mode decodes")
        } else {
            fail("shape-code token payload must decode")
        }
        if let unicode = decode(
            """
            {"revision_input":"bi","segment":{"start":0,"end":2},"lock_mode":"bounded_token_alias",
             "spellings":["\u{3105}\u{3127}"],"lockable":["\u{3105}\u{3127}"],"complete":true}
            """)
        {
            check(unicode.spellings == ["\u{3105}\u{3127}"], "Unicode token decodes")
        } else {
            fail("Unicode token payload must decode")
        }

        // ---- v4 letter-class PREFIX wire shape --------------------------------
        // The narrowing keys are a separate, complete list; `lockable` may name
        // them even when they are not plain spellings of the segment, and the
        // per-option semantics are labelled.
        if let prefix = decode(
            """
            {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
             "spellings":["a"],"prefix_options":["a","b","c"],
             "lockable":["a","b","c"],"option_semantics":{"a":"mixed","b":"initial","c":"initial"},
             "complete":true}
            """)
        {
            check(prefix.lockMode == .prefixToken, "prefix_token lock mode decodes")
            check(prefix.prefixOptions == ["a", "b", "c"], "prefix options decode")
            check(prefix.optionSemantics["b"] == "initial", "option semantics decode")
            check(prefix.lockable == ["a", "b", "c"], "prefix lockable decodes")
        } else {
            fail("v4 prefix payload must decode")
        }
        // lockable outside spellings ∪ prefix_options is malformed -> nil.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a","b"],"lockable":["a","c"],"complete":true}
                """) == nil, "lockable ⊄ spellings ∪ prefix_options rejected")
        // A multi-character / control prefix key is malformed -> nil.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["ab"],"lockable":["a"],"complete":true}
                """) == nil, "multi-character prefix key rejected")
        // An unknown semantic label is refused rather than displayed.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a","b"],"lockable":["a","b"],
                 "option_semantics":{"b":"guessed"},"complete":true}
                """) == nil, "unknown option semantics label rejected")
        // A semantic label for a non-lockable option is malformed -> nil.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a","b"],"lockable":["a"],
                 "option_semantics":{"b":"initial"},"complete":true}
                """) == nil, "semantics for a non-lockable option rejected")

        // ---- v4 strict-decoder negatives (fail closed) -------------------------
        // A prefix key that is not lockable breaks prefixOptions ⊆ lockable.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a","b"],"lockable":["a"],
                 "option_semantics":{"a":"mixed"},"complete":true}
                """) == nil, "prefix option that is not lockable rejected")
        // A lockable option without a semantic label is malformed in prefix mode
        // (the engine always labels every offered option).
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a","b"],"lockable":["a","b"],
                 "option_semantics":{"a":"mixed"},"complete":true}
                """) == nil, "missing semantic for a lockable option rejected")
        // present-but-wrong-typed fields are malformed, never treated as empty.
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":"a","lockable":["a"],
                 "option_semantics":{"a":"mixed"},"complete":true}
                """) == nil, "wrong-typed prefix_options rejected")
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a"],"lockable":["a"],
                 "option_semantics":{"a":1},"complete":true}
                """) == nil, "wrong-typed option_semantics value rejected")
        check(
            decode(
                """
                {"revision_input":"2","segment":{"start":0,"end":1},"lock_mode":"prefix_token",
                 "spellings":["a"],"prefix_options":["a"],"lockable":["a"],
                 "option_semantics":["a","mixed"],"complete":true}
                """) == nil, "wrong-typed option_semantics rejected")
        // An unknown or missing lock_mode is refused, never degraded to `.none`.
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"mystery",
                 "spellings":["aaa"],"lockable":[],"complete":true}
                """) == nil, "unknown lock_mode rejected")
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},
                 "spellings":["aaa"],"lockable":[],"complete":true}
                """) == nil, "missing lock_mode rejected")
        // A non-prefix mode may not smuggle a prefix list or labels, and its
        // lockable must stay inside the reported spellings.
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"bounded_token_alias",
                 "spellings":["aaa"],"prefix_options":["a"],"lockable":["aaa"],"complete":true}
                """) == nil, "non-prefix mode carrying prefix_options rejected")
        check(
            decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"bounded_token_alias",
                 "spellings":["aaa"],"lockable":["aaa"],
                 "option_semantics":{"aaa":"exact"},"complete":true}
                """) == nil, "non-prefix mode carrying option_semantics rejected")
        // Legacy wire (no new fields) still decodes for every non-prefix mode.
        for mode in ["bounded_token_alias", "direct_token", "none"] {
            if let legacy = decode(
                """
                {"revision_input":"abc","segment":{"start":0,"end":3},"lock_mode":"\(mode)",
                 "spellings":["aaa"],"lockable":["aaa"],"complete":true}
                """)
            {
                check(
                    legacy.prefixOptions.isEmpty && legacy.optionSemantics.isEmpty,
                    "legacy \(mode) wire decodes with empty new fields")
                check(legacy.lockMode.rawValue == mode, "legacy \(mode) mode preserved")
            } else {
                fail("legacy \(mode) wire must still decode")
            }
        }

        engine.shutdown()
        print("ALL PASS")
    }
}
