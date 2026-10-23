import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import OSLog
import UIKit

extension KeyboardController {
    /// Display gate for merged 14/9 layouts (UI hint only; engine-side display is driven by schema capability).
    public var usesReducedLayout: Bool { layout.requiresSpellingDisplay }
    /// Replaces the unconfirmed raw-code segment only when the current schema declares a non-native
    /// display capability and the policy resolves a highlighted-segment display value. The criterion is
    /// `snapshot.displayMode`/`highlightedDisplay` (from the actual schema's `keyboard_adapter`
    /// capability), not the physical layout; it affects display only, and `rawInput`/`preedit`/control
    /// flow are unchanged.
    public var usesSpellingPreedit: Bool {
        snapshot.displayMode != .native && !snapshot.highlightedDisplay.isEmpty
    }
    public var keyboardCompositionFallback: MarkedComposition? {
        guard snapshot.isComposing, case .keyboard = compositionPresentation else { return nil }
        return withPendingEcho(markedComposition)
    }

    func publishMarked(_ base: MarkedComposition?) {
        publishedMarkedBase = base
        echoedPendingCodes = session.pendingCodes.count
        onMarkedComposition?(withPendingEcho(base))
    }

    /// Code keys still decoding (`InputSession.pendingCodes`) show after the decoded
    /// composition, one letter per key on a keypad, so a slow decode never looks like a
    /// swallowed press. A newly typed key waits `pendingEchoDelay` for its own decode
    /// first: most land sooner, and echoing every key at once made the field (and an
    /// in-keyboard composition) update twice per key, the echo letter sometimes not the
    /// one the engine then chose. A taken-back key updates at once.
    func publishPendingEcho() {
        pendingEchoWork?.cancel()
        pendingEchoWork = nil
        guard !retired, snapshot.isComposing else { return }
        let pending = session.pendingCodes.count
        if pending > echoedPendingCodes {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingEchoWork = nil
                self.showPendingEcho()
            }
            pendingEchoWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingEchoDelay, execute: work)
        } else if pending < echoedPendingCodes {
            showPendingEcho()
        }
    }

    private func showPendingEcho() {
        guard !retired, snapshot.isComposing else { return }
        if compositionPresentation.isKeyboardFallback { objectWillChange.send() }
        publishMarked(holdsMarkedCompositionForReading ? publishedMarkedBase : markedComposition)
    }

    static let pendingEchoDelay: TimeInterval = 0.03

    /// The engine inserts typed keys at its caret, so the echo goes there too. On a
    /// keypad it joins a spelled syllable with `'` and runs straight on from a
    /// confirmed Chinese prefix (`你ga`), like `MarkedComposition.keypadText`.
    private func withPendingEcho(_ base: MarkedComposition?) -> MarkedComposition? {
        let pending = session.pendingCodes
        guard !pending.isEmpty else { return base }
        let text = (base?.text ?? "") as NSString
        let caret = min(max(0, base?.selection.location ?? text.length), text.length)
        let head = text.substring(to: caret), tail = text.substring(from: caret)
        let exactLetters = exactTokenLetters
        var echo = String(pending.joined().map { exactLetters[$0] ?? $0 })
        if snapshot.hidesNumericTransportCode {
            echo = SentenceSpelling.spell(segments: pending, text: "", entries: [], keyForLetter: readingKeyMap) ?? echo
            if let last = head.last, last.isASCII, last.isLetter || last.isNumber {
                echo = SentenceSpelling.separator + echo
            }
        }
        let caretAfter = (head as NSString).length + (echo as NSString).length
        return MarkedComposition(text: head + echo + tail, selection: NSRange(location: caretAfter, length: 0))
    }
    /// The one composition string for the host field and the in-keyboard fallback.
    public var markedComposition: MarkedComposition {
        // A keypad spells the sentence while the highlighted reading is still being
        // read, instead of holding the field (that read waits behind deferred keys).
        let reading =
            highlightedReading.isEmpty && (highlightedReadCompleted || snapshot.hidesNumericTransportCode)
            ? sentenceSpelling ?? "" : highlightedReading
        let keypad = snapshot.hidesNumericTransportCode
        let marked = MarkedComposition(
            snapshot: snapshot, chinesePreview: usesChineseMarkedPreview,
            spellingPreedit: usesSpellingPreedit,
            readingFallback: keypad ? Self.keypadJoined(reading) : reading,
            keypadTail: keypad ? keypadTailSpelling ?? "" : "",
            exactLetters: isEnglishMode || snapshot.isAsciiMode ? [:] : exactTokenLetters)
        // An unverifiable (e.g. polyphonic) highlight falls back to the engine preedit,
        // which already spells the completed candidate (`na` for one key). Trim a
        // pure-pinyin preedit with the caret at its end the same way.
        // A reading filter decides what space commits (its first match), so the field
        // shows that candidate's reading, not the engine's unchanged highlight.
        // Only a plain pinyin mark with the caret at its end is replaced, and only when
        // that match covers every typed key; a Chinese preview, a schema display value,
        // a caret inside the mark or a partial candidate keep the engine's text.
        if session.compactSpellingLayout, !isEnglishMode, readingFilter.isFiltering,
            !usesChineseMarkedPreview, !usesSpellingPreedit,
            readingFilter.revision == session.compositionRevision,
            marked.selection.location == marked.text.utf16.count,
            snapshot.preedit.allSatisfy(\.isASCII),
            let path = readingFilter.matches.first?.readingPaths?.first(where: readingFilter.startsWithPrefix),
            let typed = ReadingInputCoverage(
                input: snapshot.rawInput, keyForLetter: readingKeyMap, exactKeys: exactTokenLetters)?
                .typedSpelling(path)
        {
            return MarkedComposition(text: typed.joined(separator: keypad ? SentenceSpelling.separator : " "))
        }
        guard highlightedReading.isEmpty, session.compactSpellingLayout, !isEnglishMode,
            marked.selection.location == marked.text.utf16.count,
            marked.text.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == " " || $0 == "'") })
        else { return marked }
        let typed = typedReading(marked.text, rawInput: snapshot.rawInput, keypad: snapshot.hidesNumericTransportCode)
        return typed == marked.text ? marked : MarkedComposition(text: typed)
    }

    func refreshHighlightedReading(for s: EngineSnapshot) {
        let revision = session.compositionRevision
        // Any schema whose capability produced no display value (none declared, or a
        // declared source_code map that cannot express a highlighted token) falls
        // back to the engine-proven reading, never to the merged key-letter preedit.
        guard s.isComposing, !isEnglishMode, session.compactSpellingLayout,
            s.highlightedDisplay.isEmpty,
            s.candidates.indices.contains(s.highlightedIndex), s.pageIndex >= 0
        else {
            highlightedReadSource = nil
            highlightedReadInFlight = nil
            highlightedReadCompleted = false
            if !highlightedReading.isEmpty { highlightedReading = "" }
            return
        }
        if highlightedReadSource?.revision != revision || highlightedReadSource?.snapshot != s {
            highlightedReadSource = (revision, s)
            highlightedReadInFlight = nil
            highlightedReadCompleted = false
            if !highlightedReading.isEmpty { highlightedReading = "" }
        }
        guard !highlightedReadCompleted, highlightedReadInFlight == nil else { return }
        let absolute = s.pageSize > 0 ? s.pageIndex * s.pageSize + s.highlightedIndex : s.highlightedIndex
        let text = s.candidates[s.highlightedIndex].text
        let physicalLayoutEligible = session.compactSpellingLayout
        // EngineBackend is not Sendable; its calls are serialized on EngineOpQueue.
        nonisolated(unsafe) let engine = session.engine
        let readID = UUID()
        highlightedReadInFlight = readID
        Task { @MainActor in
            // One turn only: the field holds its previous text until this read lands,
            // so it must not wait; a newer key in the same turn supersedes this read.
            await Task.yield()
            guard highlightedReadInFlight == readID else { return }
            guard session.engine === engine, session.compositionRevision == revision,
                session.compactSpellingLayout == physicalLayoutEligible,
                !isEnglishMode, snapshot == s
            else {
                highlightedReadInFlight = nil
                releaseHeldMarkedComposition()
                return
            }
            let resolved = try? await EngineOpQueue.async {
                try engine.verifiedHighlightedReading(
                    absoluteIndex: absolute, expectedText: text,
                    physicalLayoutEligible: physicalLayoutEligible)
            }
            // No `coalescedCompletionTurn()` here: the host field is held until this
            // read lands, so the barrier was pure per-key latency (the field lagged a
            // key behind and caught up in jumps during fast typing). The other
            // queries are debounced 50ms and rarely complete in the same window.
            guard highlightedReadInFlight == readID else { return }
            guard session.engine === engine, session.compactSpellingLayout == physicalLayoutEligible,
                !isEnglishMode, session.compositionRevision == revision, snapshot == s
            else {
                highlightedReadInFlight = nil
                releaseHeldMarkedComposition()
                return
            }
            highlightedReadInFlight = nil
            highlightedReadCompleted = true
            let reading = resolved ?? ""
            let safeReading = s.hidesNumericTransportCode && reading.contains(where: { $0.isNumber }) ? "" : reading
            let shownReading = typedReading(safeReading, rawInput: s.rawInput, keypad: s.hidesNumericTransportCode)
            guard highlightedReading != shownReading else {
                // The held text (see `refresh`) is released even when unchanged.
                publishMarked(markedComposition)
                return
            }
            highlightedReading = shownReading
            publishMarked(markedComposition)
        }
    }
    /// A sentence the engine joined from several words (一金贵呀) has no provable
    /// reading, and a 9-key field hides the numeric code, so the field went blank.
    /// Spell it from the engine's own syllable segments of the highlighted code
    /// (`94 546 484 92`) with the proven readings already loaded (`SentenceSpelling`).
    var sentenceSpelling: String? {
        let s = snapshot
        guard s.hidesNumericTransportCode, session.compactSpellingLayout, !readingKeyMap.isEmpty,
            readingFilter.revision == session.compositionRevision,
            s.candidates.indices.contains(s.highlightedIndex)
        else { return nil }
        let bytes = Array(s.preedit.utf8)
        guard 0 <= s.preeditSelStart, s.preeditSelStart < s.preeditSelEnd, s.preeditSelEnd <= bytes.count,
            let span = String(bytes: bytes[s.preeditSelStart..<s.preeditSelEnd], encoding: .utf8)
        else { return nil }
        let segments = span.split(whereSeparator: { $0 == " " || $0 == ReadingInputCoverage.separator }).map(
            String.init)
        return SentenceSpelling.spell(
            segments: segments, text: s.candidates[s.highlightedIndex].text,
            entries: readingFilter.entries, keyForLetter: readingKeyMap,
            knownReadings: knownCharacterReadings)
    }

    private static let knownCharacterReadingsLimit = 4096

    func rememberCharacterReadings(_ page: [ReadingCandidate]) {
        for entry in page where entry.readingsComplete {
            for path in entry.readingPaths ?? [] where path.count == entry.text.count {
                for (character, syllable) in zip(entry.text, path) {
                    var readings = knownCharacterReadings[character] ?? []
                    guard !readings.contains(syllable) else { continue }
                    if knownCharacterReadings.count >= Self.knownCharacterReadingsLimit,
                        readings.isEmpty
                    {
                        knownCharacterReadings.removeAll(keepingCapacity: true)
                    }
                    readings.append(syllable)
                    knownCharacterReadings[character] = readings
                }
            }
        }
    }

    /// Show only what was typed: one key is `n`, not the top candidate's `na`, and
    /// `bu g` rather than 不过's full `bu guo`. Syllables are always space-separated,
    /// whether they came from a verified reading or the engine's `'`-joined preedit.
    /// Unprovable key maps keep the reading. A numeric keypad joins syllables with
    /// `'` like mainstream 9-key pinyin (`ni'h`).
    private func typedReading(_ reading: String, rawInput: String, keypad: Bool) -> String {
        guard !reading.isEmpty,
            let coverage = ReadingInputCoverage(
                input: rawInput, keyForLetter: readingKeyMap, exactKeys: exactTokenLetters)
        else {
            return keypad ? Self.keypadJoined(reading) : reading
        }
        let syllables = reading.split(whereSeparator: { $0 == " " || $0 == "'" }).map(String.init)
        guard let typed = coverage.typedSpelling(syllables) else {
            return keypad ? Self.keypadJoined(reading) : reading
        }
        return typed.joined(separator: keypad ? SentenceSpelling.separator : " ")
    }

    private static func keypadJoined(_ reading: String) -> String {
        reading.replacingOccurrences(of: " ", with: SentenceSpelling.separator)
    }

    /// The keys typed after the highlighted span (a candidate covering only the head
    /// of the code, or the rest after a partial pick), spelled like a sentence tail.
    private var keypadTailSpelling: String? {
        let s = snapshot
        guard s.hidesNumericTransportCode, !readingKeyMap.isEmpty else { return nil }
        let bytes = Array(s.preedit.utf8)
        guard 0 <= s.preeditSelEnd, s.preeditSelEnd < bytes.count,
            let tail = String(bytes: bytes[s.preeditSelEnd...], encoding: .utf8)
        else { return nil }
        let segments = tail.split(whereSeparator: { $0 == " " || $0 == ReadingInputCoverage.separator }).map(
            String.init)
        guard !segments.isEmpty else { return nil }
        return SentenceSpelling.spell(
            segments: segments, text: "", entries: readingFilter.entries,
            keyForLetter: readingKeyMap, knownReadings: knownCharacterReadings)
    }

    /// A verified reading for the live snapshot is still being read. The field keeps
    /// its previous text meanwhile instead of flashing the raw engine preedit
    /// (merged-key letters or `'`-joined codes) for one frame on every key.
    var holdsMarkedCompositionForReading: Bool {
        highlightedReadInFlight != nil && highlightedReading.isEmpty
            && !(snapshot.hidesNumericTransportCode && sentenceSpelling != nil)
    }

    /// An abandoned read (layout/mode changed under it) must not leave the field on
    /// held text; a newer read that took over keeps holding instead.
    private func releaseHeldMarkedComposition() {
        guard highlightedReadInFlight == nil else { return }
        publishMarked(snapshot.isComposing ? markedComposition : nil)
    }

    public func reportCompositionPresentation(_ value: CompositionPresentation) {
        guard compositionPresentation != value else { return }
        if value.isKeyboardFallback != compositionPresentation.isKeyboardFallback {
            objectWillChange.send()
        }
        compositionPresentation = value
    }
}
