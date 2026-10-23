import Foundation

// MARK: - Candidate and output snapshots (consumer-side value types shared by RimeBridge/DemoEngine)

/// A candidate (a librime menu candidate in the real engine).
public struct Candidate: Identifiable, Equatable, Sendable, Hashable {
    /// Index within the page (0-based, unique only within the current page).
    public let index: Int
    /// Candidate text, e.g. 「你好」.
    public let text: String
    /// Comment, e.g. code length or a reading hint; may be empty.
    public let comment: String
    /// The engine's own in-page select key (librime `RimeMenu.select_keys`, i.e. the
    /// index-th character of the schema's `menu/alternative_select_keys`). nil = the
    /// schema declares none; never fall back to a fabricated `1`..`9`.
    public let selectKey: String?
    /// The engine's own in-page label (librime `RimeContext.select_labels`, i.e. the
    /// index-th entry of the schema's `menu/alternative_select_labels`). nil = the schema
    /// declares none. `comment` is a different source and must never stand in for a label.
    public let selectLabel: String?

    public init(
        index: Int, text: String, comment: String = "",
        selectKey: String? = nil, selectLabel: String? = nil
    ) {
        self.index = index
        self.text = text
        self.comment = comment
        self.selectKey = selectKey
        self.selectLabel = selectLabel
    }

    public var id: Int { index }
}

/// Full engine state handed to the front end after a key press or selection.
public struct EngineSnapshot: Equatable, Sendable {
    public var schemaID: String = ""
    public var commitTextPreview: String = ""
    /// Observed engine mode flags (librime `RimeStatus`): direct latin input,
    /// full-width forms, ASCII punctuation. Pure observations — the consumer
    /// never derives a UI mode switch or writes an option from them. Default
    /// false keeps existing snapshots and demo engines source-compatible.
    public var isAsciiMode: Bool = false
    public var isFullShape: Bool = false
    public var isAsciiPunct: Bool = false
    public var preeditSelection: NSRange = NSRange(location: 0, length: 0)
    /// Text committed by this operation (the real engine returns it from key handling or a commit event).
    public var committed: String
    /// Candidate texts (while composing, current page).
    public var candidates: [Candidate]
    /// Preedit text (the composition text shown to the user).
    public var preedit: String
    /// The raw code string as typed (e.g. 26-key nihao / 14-key bu gc / 9-key 64426).
    public var rawInput: String
    /// Whether a composition is active (there is uncommitted content).
    public var isComposing: Bool
    /// In-page index of the highlighted candidate; -1 means none.
    public var highlightedIndex: Int
    /// Current candidate page (0-based; 0 when there is no paging).
    public var pageIndex: Int
    /// Candidates per page (0 when there is no paging).
    public var pageSize: Int
    /// Whether this is the last page.
    public var isLastPage: Bool
    /// UTF-8 byte range in `preedit` of the unconfirmed highlighted segment reported by the
    /// engine (librime composition `sel_start`/`sel_end`). Only this segment may be redrawn
    /// as the candidate reading; text outside it (confirmed text, punctuation, tail code) is kept as is.
    public var preeditSelStart: Int = 0
    public var preeditSelEnd: Int = 0
    /// UTF-8 byte offset of the composition cursor in `preedit` (librime composition `cursor_pos`).
    public var preeditCaretByte: Int = 0
    /// The highlighted candidate's real spelling: the engine decodes the candidate's own
    /// syllable codes back to canonical pinyin with the schema dictionary
    /// (`Dictionary::Decode`), independent of candidate comments/filters; empty if unavailable.
    /// Display metadata only: `rawInput`/`preedit` stay the engine's original code and
    /// control flow and commits are unchanged.
    public var highlightedSpelling: String = ""
    /// Display value of the highlighted segment resolved from the schema's declared
    /// `keyboard_adapter` capability (display metadata only). Non-empty only when
    /// `displayMode != .native` and resolution succeeded: `canonical` is canonical pinyin,
    /// `source_code` is the source scheme's unique normal code (e.g. Xiaohe `zc'uh'hc`).
    /// Empty when no authoritative value exists; consumers then fall back exactly to the
    /// engine preedit. It never writes `rawInput`/`preedit`/`sel`.
    public var highlightedDisplay: String = ""
    /// Resolution mode of the highlighted-segment display value; `.native` = keep the engine preedit.
    public var displayMode: CompositionDisplayMode = .native
    /// Whether the current schema declares a `keyboard_adapter` capability block (whether or
    /// not authorization succeeded). When true the engine has already ruled on the
    /// capability, and `MarkedComposition` must never fall back to the legacy
    /// `highlightedSpelling` protocol (so a failed capability cannot leak full pinyin).
    public var hasDisplayCapability: Bool = false
    /// Whether the current schema's declared display capability is 9-key numeric `canonical`.
    /// The engine preedit is then the internal numeric transport code sent to the engine
    /// (e.g. `555`) and, whether or not the highlighted segment resolves to a trusted
    /// display, must not be written into marked text as the user's composition string:
    ///   * a resolved display value replaces only the highlighted code segment;
    ///   * unconverted digit codes after the highlighted segment are dropped (the prefix is
    ///     confirmed candidate text and is kept);
    ///   * when unresolvable, keep the confirmed prefix and suppress the digit segment;
    ///     never fall back to the whole digit string.
    /// Either source may set it; if either is true it takes effect:
    ///   * `RimeBackend.snapshot` sets it from the *declared* `canonical` mode
    ///     (`declaredDisplayMode`), so snapshots not yet authorized or without compact-layout
    ///     demand also do not echo digit codes;
    ///   * `CompositionDisplayPolicy.applied` ORs it in when `canonical` is *authorized*.
    /// `source_code` (14-key letter source code) and native keep the original semantics
    /// (may fall back to the engine preedit).
    public var hidesNumericTransportCode: Bool = false
    /// Post-commit prediction: candidates the engine offers when there is no input code
    /// (librime-predict's placeholder segment, or an equivalent in the scheme).
    /// `isComposing == false` then (nothing to confirm or display; the host sets no marked
    /// text), candidates can still be tapped, and any other key first dismisses the
    /// prediction and is then handled with idle semantics (see `InputSession`).
    public var isPrediction: Bool = false

    public init(
        committed: String = "",
        candidates: [Candidate] = [],
        preedit: String = "",
        rawInput: String = "",
        isComposing: Bool = false,
        highlightedIndex: Int = -1,
        pageIndex: Int = 0,
        pageSize: Int = 0,
        isLastPage: Bool = true
    ) {
        self.committed = committed
        self.candidates = candidates
        self.preedit = preedit
        self.rawInput = rawInput
        self.isComposing = isComposing
        self.highlightedIndex = highlightedIndex
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.isLastPage = isLastPage
    }

    /// Has paging and can go back (not the first page).
    public var canPageBackward: Bool { pageSize > 0 && pageIndex > 0 }
    /// Has paging and can go forward (not the last page).
    public var canPageForward: Bool { pageSize > 0 && !isLastPage }
}

/// Candidate reading display: replaces only the engine-reported unconfirmed highlighted
/// segment with the highlighted candidate's real spelling.
///
/// Both inputs come from the engine and are not guessed in the front end:
///   * range = librime composition `sel_start`/`sel_end` (UTF-8 byte interval of `preedit`);
///   * spelling = canonical pinyin the bridge decodes from the candidate's own syllable
///     codes with the schema dictionary (independent of candidate comments or Lua/filter rewrites).
/// Outside the range (confirmed text, punctuation, tail code) and the cursor position are
/// kept as the engine reported them; if any field is missing or the range is invalid this
/// returns nil and the caller falls back exactly to the engine preedit.
/// The exception is `droppingTail`: numeric `canonical` composition requires removing the
/// unconverted tail code as well.
public enum SpellingDisplay {
    /// Replaces `[selStart, selEnd)` (UTF-8 bytes) of `preedit` in place with `spelling`
    /// and remaps `caretByte` into the result (returned as a UTF-16 offset).
    /// Returns nil when it cannot rewrite safely (out of bounds / not on a UTF-8 boundary);
    /// the caller must fall back.
    /// - Parameter droppingTail: when true, drops `[selEnd, end)`. Used for authorized 9-key
    ///   `canonical` capability: in librime `Composition::GetPreedit` the text after the
    ///   highlighted segment is always `input_.substr(end)` (the not-yet-converted raw digit
    ///   code), which must be removed from the user-visible composition together with the
    ///   highlighted code segment; the prefix (confirmed candidate text) is kept. A cursor
    ///   inside the dropped range clamps to the end of the new string. Default false = only
    ///   replace `[selStart, selEnd)`.
    public static func rewrite(
        preedit: String, selStart: Int, selEnd: Int,
        caretByte: Int, spelling: String,
        droppingTail: Bool = false
    ) -> (text: String, caret: Int)? {
        let bytes = preedit.utf8
        guard selStart >= 0, selEnd >= selStart, selEnd <= bytes.count,
            caretByte >= 0, caretByte <= bytes.count
        else { return nil }
        guard let start = bytes.index(bytes.startIndex, offsetBy: selStart, limitedBy: bytes.endIndex),
            let end = bytes.index(bytes.startIndex, offsetBy: selEnd, limitedBy: bytes.endIndex),
            let caret = bytes.index(bytes.startIndex, offsetBy: caretByte, limitedBy: bytes.endIndex),
            start.samePosition(in: preedit) != nil,
            end.samePosition(in: preedit) != nil,
            caret.samePosition(in: preedit) != nil
        else { return nil }

        let prefix = String(decoding: bytes[bytes.startIndex..<start], as: UTF8.self)
        let suffix = droppingTail ? "" : String(decoding: bytes[end..<bytes.endIndex], as: UTF8.self)
        let replacementBytes = spelling.utf8.count
        let coveredBytes = selEnd - selStart
        let newCaretByte: Int
        if caretByte <= selStart {
            newCaretByte = caretByte  // caret before/at the replaced span: unchanged
        } else if droppingTail {
            newCaretByte = prefix.utf8.count + replacementBytes  // caret in/after the dropped tail: clamp to end
        } else if caretByte >= selEnd {
            newCaretByte = caretByte + (replacementBytes - coveredBytes)  // shift by the delta
        } else {
            newCaretByte = selStart + replacementBytes  // caret inside the replaced span: move to its end
        }
        let text = prefix + spelling + suffix
        let textBytes = text.utf8
        let clamped = min(max(0, newCaretByte), textBytes.count)
        guard let caretIndex = textBytes.index(textBytes.startIndex, offsetBy: clamped, limitedBy: textBytes.endIndex),
            let stringIndex = caretIndex.samePosition(in: text)
        else { return nil }
        return (text, stringIndex.utf16Offset(in: text))
    }
}

/// The value handed to the host as marked text. It is derived from engine evidence
/// only. For a `canonical` (9-key numeric) schema (`hidesNumericTransportCode`) it
/// is the confirmed prefix plus the resolved canonical display of the highlighted
/// span, then the keys typed after that span (spelled by the caller when it can,
/// `keypadTail`), syllables joined with `'`. Nothing typed is ever left out: an
/// empty or shortened mark made presses look swallowed.
public struct MarkedComposition: Equatable, Sendable {
    public let text: String
    public let selection: NSRange
    /// - Parameter spellingPreedit: legacy entry point (demo/legacy-protocol snapshots). It
    ///   applies only if the snapshot has *never* declared a `keyboard_adapter` capability;
    ///   once `snapshot.hasDisplayCapability` is true (the engine has ruled on the
    ///   capability, even native/missing/stale) it never falls back to `highlightedSpelling`,
    ///   so a failed capability cannot leak canonical full pinyin.
    /// - Parameter readingFallback: read-only reading of the highlighted candidate, proven
    ///   by the engine (matching highlight range + a unique complete reading path). The
    ///   capability authorizes only the "canonical syllable -> source code" mapping and does
    ///   not affect whether the reading itself is genuine, so it is also used when the
    ///   capability yields no display value (missing entry / ambiguous mapping /
    ///   unauthorized), instead of falling back to a merged key code unrelated to the
    ///   highlighted candidate. When empty the original fallback applies (engine preedit, or
    ///   suppressed digit code for 9-key).
    /// - Parameter exactLetters: exact-pick token → its letter. The engine preedit shows
    ///   the raw token when nothing translates it (a lone exact pick), so the fallback
    ///   spells it back as the letter, like the pending echo.
    public init(
        snapshot: EngineSnapshot, chinesePreview: Bool = false, spellingPreedit: Bool = false,
        readingFallback: String = "", keypadTail: String = "", exactLetters: [Character: Character] = [:]
    ) {
        let display = snapshot.displayMode != .native ? snapshot.highlightedDisplay : ""
        let legacy =
            display.isEmpty && spellingPreedit && !snapshot.hasDisplayCapability
            ? snapshot.highlightedSpelling : ""
        let fallback = readingFallback
        let replacement = !display.isEmpty ? display : (!legacy.isEmpty ? legacy : fallback)
        // Validated 9-key `canonical` capability: the raw engine preedit is the numeric
        // key code (e.g. "64 426 666"). Show the confirmed prefix (already-converted
        // candidate text), the resolved display of the highlighted span or, when the
        // engine cannot spell it, the span's keys, then the keys typed after the span
        // as one run. Spaces the engine put between code segments are not shown.
        if snapshot.hidesNumericTransportCode {
            let keypad = Self.keypadText(snapshot: snapshot, spelling: replacement, tail: keypadTail)
            self.text = keypad.text
            self.selection = NSRange(location: keypad.caret, length: 0)
            return
        }
        if !replacement.isEmpty,
            let rewritten = SpellingDisplay.rewrite(
                preedit: snapshot.preedit,
                selStart: snapshot.preeditSelStart,
                selEnd: snapshot.preeditSelEnd,
                caretByte: snapshot.preeditCaretByte,
                spelling: replacement)
        {
            self.text = rewritten.text
            self.selection = NSRange(location: rewritten.caret, length: 0)
            return
        }
        let usePreview = chinesePreview && !snapshot.commitTextPreview.isEmpty
        // Tokens and letters are both one ASCII scalar, so the selection still holds.
        text =
            usePreview
            ? snapshot.commitTextPreview : String(snapshot.preedit.map { exactLetters[$0] ?? $0 })
        selection = usePreview ? NSRange(location: text.utf16.count, length: 0) : snapshot.preeditSelection
    }

    /// The 9-key (`hidesNumericTransportCode`) mark: the confirmed prefix, `spelling`
    /// for the highlighted span or, when it is empty, the span's keys, then `tail`
    /// (the spelled keys after the span) or those keys themselves, joined with `'`.
    /// The engine's spacing between code segments is not shown. Shared with the
    /// installer's display verification.
    public static func keypadText(
        snapshot: EngineSnapshot, spelling: String,
        tail spelledTail: String = ""
    ) -> (text: String, caret: Int) {
        let bytes = Array(snapshot.preedit.utf8)
        let selStart = snapshot.preeditSelStart, selEnd = snapshot.preeditSelEnd
        func keys(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self).filter { !$0.isWhitespace }
        }
        guard selStart >= 0, selStart <= selEnd, selEnd <= bytes.count,
            let rewritten = SpellingDisplay.rewrite(
                preedit: snapshot.preedit, selStart: selStart, selEnd: selEnd,
                caretByte: snapshot.preeditCaretByte,
                spelling: spelling.isEmpty ? keys(selStart..<selEnd) : spelling,
                droppingTail: true)
        else {
            // No usable highlight: the typed keys themselves.
            let text = snapshot.preedit.filter { !$0.isWhitespace }
            return (text, text.utf16.count)
        }
        let rawTail = keys(selEnd..<bytes.count)
        let tail = rawTail.isEmpty || spelledTail.isEmpty ? rawTail : spelledTail
        // A confirmed Chinese prefix runs straight into the spelling (`你gang`), and
        // unspelled keys after unspelled keys stay one run (`64426`).
        let last = rewritten.text.last
        let joins = last.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false
        let letters = last?.isLetter == true || tail.first?.isLetter == true
        let separator = !tail.isEmpty && joins && letters ? "'" : ""
        let text = rewritten.text + separator + tail
        return (text, snapshot.preeditCaretByte >= selEnd ? text.utf16.count : rewritten.caret)
    }

    /// A display-only replacement of an ASCII preedit, caret at the end.
    public init(text: String) {
        self.text = text
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    /// A display-only mark with an explicit caret (clamped into the text).
    public init(text: String, selection: NSRange) {
        self.text = text
        let length = text.utf16.count
        let location = min(max(0, selection.location), length)
        self.selection = NSRange(location: location, length: min(max(0, selection.length), length - location))
    }

    /// UITextDocumentProxy has no marked range and may return only a short context
    /// window or the current line. Keep long/multiline compositions in the keyboard
    /// before sending an unverifiable mark; this never limits engine input or commits.
    public var isWithinProxyInlineBudget: Bool {
        text.utf16.count <= ProxyDocumentContext.windowUTF16
            && !text.unicodeScalars.contains(where: CharacterSet.newlines.contains)
    }

    /// Conservative visibility check for document proxies. Does not prove native marked-range semantics.
    public func isEchoed(before: String?, after: String?, selectedText: String?) -> Bool {
        let value = text as NSString
        guard selection.location >= 0, selection.length >= 0,
            selection.location <= value.length, selection.length <= value.length - selection.location,
            !text.isEmpty
        else { return false }
        let prefix = value.substring(to: selection.location)
        let suffix = value.substring(from: selection.location + selection.length)
        let selected = value.substring(with: selection)
        return (prefix.isEmpty || before?.hasSuffix(prefix) == true)
            && (suffix.isEmpty || after?.hasPrefix(suffix) == true)
            && (selected.isEmpty || selectedText == selected)
    }
}

/// Presentation evidence, not a promise inferred from an enabled preference.
public enum InlineCompositionEvidence: String, Equatable, Sendable {
    case nativeMarkedRange
    /// Public UITextDocumentProxy exposes context, but no markedTextRange or acceptance result.
    /// This confirms visible text echo only; native marking semantics still require host QA.
    case documentContextEcho
}

public enum CompositionPresentation: Equatable, Sendable {
    case idle
    /// A native request was sent, but the proxy has no acceptance result. Lack of
    /// context echo is not rejection; never duplicate possibly visible text as fallback.
    case awaitingHost
    case keyboard(reason: String)
    case inline(evidence: InlineCompositionEvidence)

    public var isInline: Bool {
        if case .inline = self { return true }
        return false
    }

    public var isKeyboardFallback: Bool {
        if case .keyboard = self { return true }
        return false
    }
}

public struct KeyboardSchemaDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public var alphabet: String
    public init(id: String, name: String, alphabet: String = "") {
        self.id = id
        self.name = name
        self.alphabet = alphabet
    }

    /// Resource manifests sometimes carry an ID as their label. Preserve real
    /// source-provided names; only known ID fallbacks get a friendly presentation name.
    public var displayName: String {
        guard name.isEmpty || name == id else { return name }
        return [
            "rime_ice": "雾凇拼音", "double_pinyin_flypy": "小鹤双拼",
            "double_pinyin": "自然码双拼", "double_pinyin_abc": "智能 ABC 双拼",
            "double_pinyin_mspy": "微软双拼", "double_pinyin_sogou": "搜狗双拼",
            "double_pinyin_ziguang": "紫光双拼", "double_pinyin_pyjj": "拼音加加双拼",
            "double_pinyin_jiajia": "拼音加加双拼",
            "luna_pinyin": "朙月拼音", "luna_pinyin_simp": "朙月拼音·简化字",
        ][id]
            ?? BuiltinTemplateSchemas.names[id] ?? (name.isEmpty ? id : name)
    }

    /// Human-readable name for the *user interface*: returned only when the structured
    /// resource descriptor provides a real name (non-empty and not equal to its own ID);
    /// otherwise nil.
    ///
    /// Unlike `displayName`, this never falls back to a bare schema/source ID and does no
    /// ID/brand special-casing. On nil callers fall back to generic copy (e.g. 「当前输入方式」)
    /// or omit it, so internal IDs are not exposed to users.
    public var humanReadableName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != id else { return nil }
        return trimmed
    }

    /// Single-character supplementary codes in the schema alphabet that the currently
    /// rendered keys do not send (one set difference). `renderedCodes` must be the set of
    /// single-character `.code` values the current UI actually emits (DIY definitions use
    /// their rows/auxiliary area, other paths the built-in table). Do not subtract the
    /// built-in key table first and then DIY: if the built-in 26 keys include a but the DIY
    /// definition lacks it, two subtractions would drop a forever.
    /// Multi-character codes/merged codes follow the existing mapping (LayoutAction
    /// validates a code as a single printable ASCII; a merged cluster sends its leading
    /// representative character); this function rewrites or guesses nothing; whitespace is
    /// not counted as a supplementary code.
    public static func additionalCodeValues(alphabet: String, renderedCodes: Set<String>) -> [String] {
        let rendered = Set(renderedCodes.flatMap { $0 })
        return Set(alphabet).subtracting(rendered)
            .filter { !$0.isWhitespace }
            .sorted().map(String.init)
    }
}

public struct KeyboardSelectionChange: Equatable, Sendable {
    public let token: UUID
    public let date: Date
    public let schemaID: String
    public let layout: KeyboardLayoutKind
    public init(schemaID: String, layout: KeyboardLayoutKind) {
        token = UUID()
        date = Date()
        self.schemaID = schemaID
        self.layout = layout
    }
}

/// Engine implementation kind. The UI must distinguish the real engine from the demo engine and never call demo candidates real.
public enum EngineBackendKind: Equatable, Sendable {
    /// Real Rime engine (RimeBridge; does not exist until it is wired in).
    case rime
    /// Local demo/offline simulation (clearly labeled, for UI flow demonstration only).
    case demoSimulator(String)

    public var isRealRime: Bool {
        if case .rime = self { return true }
        return false
    }
}

public enum EngineBackendError: Error, Equatable, Sendable {
    case unsupportedSchema(String)
    case notReady
    case setupFailed(String)
    case operationFailed(String)
    case engineNotStarted
}

// MARK: - Composition spelling disambiguation (ambiguity spelling picker)

/// Spellings lockable for the last `abc` segment of the current composition. This is a
/// read-only result proven by the engine: `options` holds only items the engine will
/// actually accept (`lockable`); `allSpellings` keeps the full reachable set for
/// diagnostics only and must never generate tappable buttons. `revisionInput`/`segment`
/// are in raw-input coordinates, not preedit coordinates.
///
/// The semantics are schema-agnostic: `options`/`allSpellings` are all interpretations of
/// the current segment proven by the current schema's live prism/segment graph (pinyin,
/// shuangpin, shape codes, zhuyin, dialects, and custom syllable tables alike); nothing is
/// guessed from pinyin tables, keycaps, candidate comments/literals, or dictionary text.
public struct AmbiguitySpellingsReport: Equatable, Sendable {
    /// The full raw input the tail segment belongs to (used to reject stale taps).
    public let revisionInput: String
    /// UTF-8 byte range [start, end) of the tail segment in raw input.
    public let segment: Range<Int>
    /// Spellings the engine allows to apply (deduplicated, sorted lexicographically; a subset of allSpellings ∪ prefixOptions).
    public let options: [String]
    /// All reachable spellings (for diagnostics; includes non-lockable ones).
    public let allSpellings: [String]
    /// Lock mode; `.none` means it cannot be rewritten.
    public let lockMode: AmbiguityLockMode
    /// Whether the engine truncated (capped) the reachable set. When true it must not be shown as the complete choice set.
    public let isComplete: Bool
    /// Bounded narrowing keys for prefix mode (`.prefixToken`) (deduplicated, sorted; single-character ASCII).
    /// The live prism proves each key's interpretation set is a non-empty subset of the
    /// current segment, so replacing the segment only narrows the reading. Empty in other modes.
    public let prefixOptions: [String]
    /// Per-option semantic label (`exact` / `initial` / `mixed`); UI data only, never
    /// authorizes: only items in `options` can be applied. Empty in other modes.
    public let optionSemantics: [String: String]
    /// Fewer than 2 selectable (lockable) spellings = unambiguous.
    public var isAmbiguous: Bool { options.count >= 2 }
    public var isLockable: Bool { lockMode != .none && !options.isEmpty }

    public init(
        revisionInput: String, segment: Range<Int>, options: [String],
        allSpellings: [String], lockMode: AmbiguityLockMode, isComplete: Bool,
        prefixOptions: [String] = [], optionSemantics: [String: String] = [:]
    ) {
        self.revisionInput = revisionInput
        self.segment = segment
        self.options = options
        self.allSpellings = allSpellings
        self.lockMode = lockMode
        self.isComplete = isComplete
        self.prefixOptions = prefixOptions
        self.optionSemantics = optionSemantics
    }
}

public enum AmbiguityLockMode: String, Equatable, Sendable {
    case none
    /// `bounded_token_alias_rewrite_v2`: opaque alias rewrite (script source); the rewrite
    /// target is re-proven at runtime by the live prism to be exactly that token.
    case tokenAlias = "bounded_token_alias"
    /// `direct_token_rewrite_v3`: direct code rewrite (table source); the chosen token is
    /// the rewrite target and must itself be a unique live prism key; no per-code alias is generated.
    case directToken = "direct_token"
    /// `prefix_token_rewrite_v4`: direct key rewrite (explicit opt-in digit-code script source).
    /// Each option is a live prism key whose interpretation set is re-proven at runtime to be
    /// a non-empty subset of the current segment, so the rewrite only narrows the reading;
    /// see `AmbiguitySpellingsReport.optionSemantics` for option semantics.
    case prefixToken = "prefix_token"
}

/// Composition rewrite result; each failure case is explicit and failure is never folded into success.
public enum AmbiguityApplyOutcome: Equatable, Sendable {
    case applied
    case stale
    case unsupported
    case invalid
    case failed
    case failedRollbackUnverified

    public var isSuccess: Bool { self == .applied }
}
