import Foundation
import RimeKit

extension RimeEngine {
    // MARK: - Session snapshots (must run on `queue`)

    /// Whether librime still has the session is left to the action's own read
    /// (`actionSnapshotOnQueue`): every action is a no-op on a missing session.
    func requireReadableSessionOnQueue() throws {
        guard engine != nil else { throw RimeEngineError.notStarted }
        guard session != 0 else { throw RimeEngineError.noSession }
        guard !snapshotRecoveryRequired else { throw RimeEngineError.snapshotUnavailable }
    }

    func actionSnapshotOnQueue() throws -> RimeState {
        guard let state = snapshotOnQueue(missingSessionIsError: true) else {
            throw snapshotRecoveryRequired ? RimeEngineError.snapshotUnavailable : RimeEngineError.noSession
        }
        return state
    }

    func snapshotOnQueue(recovering: Bool = false, missingSessionIsError: Bool = false) -> RimeState? {
        // A failed action owns any pending commit until explicit cancellation.
        // Neither state() nor another action may accidentally consume/deliver it.
        guard recovering || !snapshotRecoveryRequired else { return nil }
        #if SONGYAN_TEST_FAILPOINTS
            if testFailNextSnapshotOnQueue {
                testFailNextSnapshotOnQueue = false
                snapshotRecoveryRequired = true
                return nil  // same boundary as rb_snapshot_get returning NULL
            }
        #endif
        guard let engine = engine, session != 0 else { return nil }
        guard let snap = rb_snapshot_get(engine, session) else {
            // A session librime no longer has holds no pending commit to protect.
            if missingSessionIsError, let api = rime_get_api(), !hasLiveStatusOnQueue(api: api) { return nil }
            snapshotRecoveryRequired = true
            return nil
        }
        defer { rb_snapshot_free(snap) }

        // Engine-owned page select metadata, copied verbatim. An absent
        // declaration stays nil (never synthesized as 1..9); a comment is never
        // promoted to a label.
        let selectKeys: [Character] = string(fromC: snap.pointee.select_keys).map(Array.init) ?? []
        var selectLabels: [String] = []
        let labelCount = Int(snap.pointee.num_select_labels)
        if labelCount > 0, let labels = snap.pointee.select_labels {
            selectLabels.reserveCapacity(labelCount)
            for i in 0..<labelCount {
                selectLabels.append(string(fromC: labels[i]) ?? "")
            }
        }
        var candidates: [RimeCandidate] = []
        let n = Int(snap.pointee.num_candidates)
        if n > 0, let list = snap.pointee.candidates {
            candidates.reserveCapacity(n)
            for i in 0..<n {
                let item = list[i]
                candidates.append(
                    RimeCandidate(
                        text: string(fromC: item.text) ?? "",
                        comment: item.comment.flatMap { string(fromC: $0) },
                        selectKey: i < selectKeys.count ? String(selectKeys[i]) : nil,
                        selectLabel: i < selectLabels.count ? selectLabels[i] : nil
                    ))
            }
        }
        // Computed in the same serialized step as the candidate list above, so a
        // consumer never sees a candidate page and a spelling from different
        // states. The authorization decision is made HERE, before any decode:
        // strict version/mode parsing plus the source/producer
        // agreement must all pass. An unknown version, an
        // unsupported `source_rendered`, a cross-wired producer or no capability
        // at all therefore performs ZERO candidate decodes and stays native —
        // the Backend never has to (and must not) re-decide this.
        var spelling = ""
        var syllables: [String] = []
        var displayMode: RimeDisplayMode = .native
        var hasDisplayCapability = false
        var declaredDisplayMode: RimeDisplayMode = .native
        var displayCapability: RimeDisplayCapability?
        let composing = snap.pointee.is_composing != 0
        let schemaID = string(fromC: snap.pointee.schema_id) ?? ""
        // Failure-closed demand gate, evaluated in the same serialized step as
        // the candidate list. When the front end has not requested spelling for
        // its actual layout (`false` or unset `nil`), the declared capability is
        // never consulted for decoding and ZERO candidate spelling decodes run —
        // even when the schema carries an authorized `keyboard_adapter` block.
        // When it is requested, the existing authorization contract
        // (version/mode/source/producer agreement) still applies.
        let demand = spellingDemand?() ?? false
        if composing {
            let context = displayContextOnQueue(schemaID: schemaID)
            // Raw block presence (independent of parse success): a malformed block
            // still suppresses the legacy spelling protocol, while never
            // authorizing a decode.
            hasDisplayCapability = context?.capabilityPresent ?? false
            // The DECLARED (strictly-decoded) mode is reported independently of the
            // demand gate and of authorization, so the consumer can tell that a
            // declared 9-key `canonical` schema's preedit is a numeric transport
            // code even before a compact-layout demand is established.
            declaredDisplayMode = context?.capability?.mode ?? .native
            if demand, let authorized = context?.authorizedMode() {
                displayMode = authorized
                displayCapability = context?.capability
                if let decoded = rb_copy_highlighted_syllables_json(session) {
                    defer { free(decoded) }
                    if let parsed = Self.parseSyllables(Data(String(cString: decoded).utf8)) {
                        syllables = parsed.syllables
                        spelling = parsed.syllables.joined(separator: parsed.separator)
                    }
                }
            }
        }
        let state = RimeState(
            schemaID: schemaID,
            schemaName: string(fromC: snap.pointee.schema_name) ?? "",
            isComposing: composing,
            isAsciiMode: snap.pointee.is_ascii_mode != 0,
            isFullShape: snap.pointee.is_full_shape != 0,
            isAsciiPunct: snap.pointee.is_ascii_punct != 0,
            input: string(fromC: snap.pointee.input) ?? "",
            preedit: string(fromC: snap.pointee.preedit) ?? "",
            preeditCursor: Int(snap.pointee.preedit_cursor),
            preeditSelStart: Int(snap.pointee.preedit_sel_start),
            preeditSelEnd: Int(snap.pointee.preedit_sel_end),
            highlightedSpelling: spelling,
            highlightedSyllables: syllables,
            displayMode: displayMode,
            hasDisplayCapability: hasDisplayCapability,
            declaredDisplayMode: declaredDisplayMode,
            displayCapability: displayCapability,
            pageIndex: Int(snap.pointee.page_no),
            pageSize: Int(snap.pointee.page_size),
            isLastPage: snap.pointee.is_last_page != 0,
            highlightedIndex: Int(snap.pointee.highlighted_index),
            candidates: candidates,
            commitText: string(fromC: snap.pointee.commit_text) ?? "",
            commitTextPreview: string(fromC: snap.pointee.commit_text_preview) ?? ""
        )
        // Cached observation carries no one-shot commit; state() may return it on
        // failure, but only the triggering successful action can deliver the text.
        if !recovering { lastTrustedState = state.withoutCommit() }
        return state
    }

    func readCurrentSchemaIDOnQueue() -> String {
        guard let engine = engine, session != 0 else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        if rb_get_current_schema(engine, session, &buf, 256) != 0 {
            return string(fromC: buf) ?? ""
        }
        return ""
    }

    func string(fromC cString: UnsafePointer<CChar>?) -> String? {
        guard let cString = cString else { return nil }
        return String(cString: cString)
    }

    func string(fromC cString: UnsafeMutablePointer<CChar>?) -> String? {
        guard let cString = cString else { return nil }
        return String(cString: cString)
    }
}
