import Foundation
import OSLog
import RimeKit

extension RimeEngine {
    #if DEBUG
        private static let readingLogger = Logger(subsystem: "app.songyan.ime", category: "RimeReading")
    #endif

    /// Trusted spelling of the currently highlighted candidate, or "" when the
    /// engine cannot prove it. Explicit one-shot request (used by diagnostics);
    /// production reads it atomically via `state()`/action results. Gated by
    /// `spellingDemand` exactly like the snapshot path: with no demand this
    /// performs zero decodes even on a capability-bearing schema. Never reads
    /// the mutable comment and performs no layout heuristic of its own.
    public func highlightedSpelling() -> String {
        queue.sync {
            highlightedSpellingOnQueue()
        }
    }

    /// Must run on `queue`. Returns "" when there is no session, no demand, or
    /// the candidate cannot be proven.
    private func highlightedSpellingOnQueue() -> String {
        guard session != 0 else { return "" }
        guard spellingDemand?() ?? false else { return "" }
        guard let spelling = rb_copy_highlighted_spelling(session) else { return "" }
        defer { free(spelling) }
        return String(cString: spelling)
    }

    /// A marked-text fallback needs both a highlighted preedit range proof and
    /// one complete reading path for that same absolute candidate. Browsing alone
    /// does not prove where a candidate belongs in the displayed preedit. The
    /// physical-layout gate is captured by the caller before background dispatch.
    public func verifiedHighlightedReading(
        absoluteIndex: Int, expectedText: String,
        physicalLayoutEligible: Bool
    ) -> String? {
        queue.sync {
            guard engine != nil, session != 0, physicalLayoutEligible,
                (0...Int(Int32.max)).contains(absoluteIndex), !expectedText.isEmpty,
                let api = rime_get_api(),
                let highlightedJSON = rb_copy_highlighted_syllables_json(session)
            else { return nil }
            defer { free(highlightedJSON) }
            struct Highlight: Decodable {
                let separator: String
                let syllables: [String]
            }
            guard
                let highlight = try? JSONDecoder().decode(
                    Highlight.self, from: Data(String(cString: highlightedJSON).utf8)),
                !highlight.syllables.isEmpty,
                highlight.syllables.allSatisfy({ !$0.isEmpty })
            else { return nil }

            var iterator = RimeCandidateListIterator()
            guard api.pointee.candidate_list_from_index(session, &iterator, Int32(absoluteIndex)) != 0 else {
                return nil
            }
            defer { api.pointee.candidate_list_end(&iterator) }
            guard api.pointee.candidate_list_next(&iterator) != 0,
                string(fromC: iterator.candidate.text) == expectedText,
                let readingsJSON = rb_copy_candidate_syllables_json(session, Int32(absoluteIndex))
            else { return nil }
            defer { free(readingsJSON) }
            struct Readings: Decodable {
                let paths: [[String]]
                let complete: Bool
            }
            guard
                let readings = try? JSONDecoder().decode(
                    Readings.self, from: Data(String(cString: readingsJSON).utf8)),
                readings.complete, readings.paths.count == 1,
                readings.paths[0] == highlight.syllables
            else { return nil }
            return highlight.syllables.joined(separator: highlight.separator)
        }
    }

    #if DEBUG
        /// Debug-only companion of `verifiedHighlightedReading`: after it returned nil, name the
        /// first gate that refuses. Logs gate names and counts only, never composition,
        /// reading or candidate text. Read-only; never influences the production result.
        public func debugExplainReadingRefusal(absoluteIndex: Int, expectedText: String) {
            queue.sync {
                func log(_ gate: String, highlighted: Int = -1, paths: Int = -1, complete: Bool = false) {
                    Self.readingLogger.debug(
                        "readingRefused gate=\(gate, privacy: .public) idx=\(absoluteIndex, privacy: .public) highlighted=\(highlighted, privacy: .public) paths=\(paths, privacy: .public) complete=\(complete, privacy: .public)"
                    )
                }
                guard engine != nil, session != 0, let api = rime_get_api() else { return log("noSession") }
                guard let highlightedJSON = rb_copy_highlighted_syllables_json(session) else {
                    return log("highlightedDecode")
                }
                defer { free(highlightedJSON) }
                var iterator = RimeCandidateListIterator()
                guard api.pointee.candidate_list_from_index(session, &iterator, Int32(absoluteIndex)) != 0 else {
                    return log("candidateIterator")
                }
                defer { api.pointee.candidate_list_end(&iterator) }
                guard api.pointee.candidate_list_next(&iterator) != 0,
                    string(fromC: iterator.candidate.text) == expectedText
                else { return log("candidateTextMismatch") }
                guard let readingsJSON = rb_copy_candidate_syllables_json(session, Int32(absoluteIndex)) else {
                    return log("candidateReadings")
                }
                defer { free(readingsJSON) }
                struct Highlight: Decodable { let syllables: [String] }
                struct Readings: Decodable {
                    let paths: [[String]]
                    let complete: Bool
                }
                let highlight = try? JSONDecoder().decode(
                    Highlight.self, from: Data(String(cString: highlightedJSON).utf8))
                let readings = try? JSONDecoder().decode(
                    Readings.self, from: Data(String(cString: readingsJSON).utf8))
                log(
                    "readingsShape", highlighted: highlight?.syllables.count ?? -1,
                    paths: readings?.paths.count ?? -1, complete: readings?.complete ?? false)
            }
        }
    #endif

    /// Enumerates, **read-only**, the spellings reachable by the last `composition.back()`
    /// `abc` segment, for the 9/14-key composition disambiguation entry (schema
    /// independent: the live prism's proven interpretations of that segment). It must not
    /// be used to rewrite input or lock a spelling.
    ///
    /// Returns `nil` when the engine **cannot give a trustworthy answer** (no
    /// session/schema, not composing, empty composition, tail segment is not `abc`,
    /// script translator not unique, dictionary/prism unavailable, allocation failure).
    /// A non-nil result with `spellings.count < 2` means "unambiguous" and is never mixed
    /// up with `nil`.
    ///
    /// Read-only: it does not change input/caret/candidates/page/highlight, read candidate
    /// comments, enumerate front-end key caps, or touch `rb_spelling_decode_count`. The
    /// caller decides when to ask (never proactively for 26-key). `maxItems` defaults to
    /// 32 with a hard cap of 64; when truncated, `complete == false`.
    ///
    /// `maxItems` is normalized on the Swift side per the C contract (`<= 0` means the
    /// default 32, `> 64` clamps to 64) before converting to `Int32`, so extremes like
    /// `Int.max` / `Int.min` cannot trap on integer conversion or rely on C-side clamping.
    public func ambiguitySpellings(maxItems: Int = RimeAmbiguitySpellings.defaultLimit) -> RimeAmbiguitySpellings? {
        queue.sync {
            guard engine != nil, session != 0 else { return nil }
            let normalized: Int
            if maxItems <= 0 {
                normalized = RimeAmbiguitySpellings.defaultLimit
            } else if maxItems > RimeAmbiguitySpellings.hardLimit {
                normalized = RimeAmbiguitySpellings.hardLimit
            } else {
                normalized = maxItems
            }
            guard let json = rb_copy_ambiguity_spellings_json(session, Int32(normalized)) else {
                return nil
            }
            defer { free(json) }
            return RimeAmbiguitySpellings(json: Data(String(cString: json).utf8))
        }
    }

    /// Capability-gated ambiguity rewrite. This is a narrow CAS, not a general
    /// `set_input`: it only replaces the current `composition.back()` `abc`
    /// segment's raw byte span, and only when the ACTIVE schema declares a
    /// recognized `keyboard_rewrite` capability (`bounded_token_alias_rewrite_v2`,
    /// `direct_token_rewrite_v3` or `prefix_token_rewrite_v4`). It is schema-agnostic: the chosen token may
    /// be any syllable the schema's prism proves. The engine re-proves `token`
    /// against a fresh prism enumeration before writing and re-validates
    /// afterwards; on any post-write failure the original input is restored. It
    /// never selects a candidate, never reads a comment and never commits text.
    ///
    /// `expectedInput` must be the whole raw input the caller observed for
    /// `segmentStart`/`segmentEnd`; a mismatch yields `.stale`.
    public func applyAmbiguitySpelling(
        expectedInput: String,
        segmentStart: Int,
        segmentEnd: Int,
        spelling: String
    ) -> RimeAmbiguityApplyResult {
        queue.sync {
            guard engine != nil, session != 0 else { return .failed }
            // Validate the raw range in `Int` BEFORE any Int32 conversion, so
            // Int.max/Int.min cannot trap and out-of-bounds offsets are refused.
            guard segmentStart >= 0, segmentEnd > segmentStart,
                segmentEnd <= expectedInput.utf8.count,
                segmentStart <= Int(Int32.max), segmentEnd <= Int(Int32.max),
                !spelling.isEmpty
            else { return .invalid }
            let result = expectedInput.withCString { inputPtr in
                spelling.withCString { spellingPtr in
                    rb_apply_ambiguity_spelling(
                        session, inputPtr, Int32(segmentStart), Int32(segmentEnd), spellingPtr)
                }
            }
            return RimeAmbiguityApplyResult(rawValue: result) ?? .failed
        }
    }

    /// Symmetric unlock for `applyAmbiguitySpelling`: puts the reduced numeric
    /// code back. Equally CAS-gated — it refuses to touch input unless the live
    /// tail `abc` span is exactly `expectedSpelling`, `reducedCode` is in the
    /// schema's own alphabet, and both re-enumerate against the current prism.
    /// It is not permitted to set an arbitrary string.
    public func restoreAmbiguitySpelling(
        expectedInput: String,
        segmentStart: Int,
        segmentEnd: Int,
        expectedSpelling: String,
        reducedCode: String
    ) -> RimeAmbiguityApplyResult {
        queue.sync {
            guard engine != nil, session != 0 else { return .failed }
            guard segmentStart >= 0, segmentEnd > segmentStart,
                segmentEnd <= expectedInput.utf8.count,
                segmentStart <= Int(Int32.max), segmentEnd <= Int(Int32.max),
                !expectedSpelling.isEmpty, !reducedCode.isEmpty
            else { return .invalid }
            let result = expectedInput.withCString { inputPtr in
                expectedSpelling.withCString { spellingPtr in
                    reducedCode.withCString { reducedPtr in
                        rb_restore_ambiguity_spelling(
                            session, inputPtr, Int32(segmentStart), Int32(segmentEnd),
                            spellingPtr, reducedPtr)
                    }
                }
            }
            return RimeAmbiguityApplyResult(rawValue: result) ?? .failed
        }
    }

    /// Read-only, candidate-free verification of the ACTIVE schema's rewrite
    /// capability, for the installer deploy check. Verifies the full
    /// source/producer binding and that every baked alias enumerates (through the
    /// live prism) to exactly its token. Never feeds a key, never reads a
    /// candidate/comment/literal, and does not require any dictionary word to
    /// exist. Returns `.unavailable` when there is no live session.
    public func rewriteVerification() -> RimeRewriteVerification {
        queue.sync { rewriteVerificationOnQueue() }
    }

    private func rewriteVerificationOnQueue() -> RimeRewriteVerification {
        guard engine != nil, session != 0 else { return .unavailable }
        guard let json = rb_copy_rewrite_verification_json(session) else { return .unavailable }
        defer { free(json) }
        return RimeRewriteVerification(json: Data(String(cString: json).utf8)) ?? .unavailable
    }

    /// The active schema's declared display capability plus the config facts of
    /// the source schema it names, read in one serialized step and cached per
    /// active schema. The adapter uses this to resolve the highlighted segment's
    /// display value; the engine itself uses the mode to decide whether to decode
    /// at all. nil = no live session (not "no capability").
    public func displayContext() -> RimeDisplayContext? {
        queue.sync { displayContextOnQueue() }
    }

    /// `schemaID`: the session's current schema when the caller already read it (a
    /// snapshot carries it), saving another engine call per key.
    func displayContextOnQueue(schemaID: String? = nil) -> RimeDisplayContext? {
        guard engine != nil, session != 0 else { return nil }
        let schema = schemaID ?? readCurrentSchemaIDOnQueue()
        if displayContextComputed, displayContextSchema == schema {
            return cachedDisplayContext
        }
        displayContextSchema = schema
        displayContextComputed = true
        guard let json = rb_copy_display_context_json(session) else {
            cachedDisplayContext = nil
            return nil
        }
        defer { rb_copy_display_context_free(json) }
        cachedDisplayContext = RimeDisplayContext(json: Data(String(cString: json).utf8))
        return cachedDisplayContext
    }

    func invalidateDisplayContextOnQueue() {
        displayContextSchema = ""
        displayContextComputed = false
        cachedDisplayContext = nil
    }

    /// Must run on `queue`. Call after anything that can rewrite the build.
    func invalidateSchemaFactsOnQueue() {
        schemaFacts.removeAll()
    }

    static func parseSyllables(_ data: Data) -> (separator: String, syllables: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let syllables = root["syllables"] as? [String]
        else { return nil }
        return (root["separator"] as? String ?? " ", syllables)
    }

    /// Forward algebra projection of the ACTIVE (source) schema, for the Host App
    /// generator: primary Table syllabary + this schema's *unmerged*
    /// `speller/algebra`, with every final spelling tagged normal/correction.
    /// Returns nil when the projection cannot be proven (no session, not exactly
    /// one script translator, dictionary/table unavailable, algebra load/apply
    /// failure). Never used by the keyboard runtime.
    public func sourceProjectionMap() -> Data? {
        queue.sync {
            guard engine != nil, session != 0 else { return nil }
            guard let json = rb_syllable_display_map_json(session) else { return nil }
            defer { rb_syllable_display_map_free(json) }
            return Data(String(cString: json).utf8)
        }
    }
}
