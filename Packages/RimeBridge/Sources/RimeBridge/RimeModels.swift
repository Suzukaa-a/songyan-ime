import Foundation

public struct RimeGrammarDiagnostics: Codable, Sendable {
    public struct Load: Codable, Sendable {
        public let path: String
        public let success: Bool
        public let entries: Int
        public let error: String
    }
    public struct Sample: Codable, Sendable {
        public let path: String
        public let context: String
        public let word: String
        public let score: Double?
        public let rear: Bool
    }
    public let recording: Bool
    public let queryCount: UInt64
    public let lookupCount: UInt64
    public let matchCount: UInt64
    public let loads: [Load]
    public let samples: [Sample]
}

/// Errors thrown by `RimeEngine`.
public enum RimeEngineError: Error, Equatable, LocalizedError {
    /// The engine was not started (call `start()` first).
    case notStarted
    /// The engine failed to initialize or deploy.
    case initializationFailed(String)
    /// The engine was stopped already (shutdown raced with a call).
    case stopped
    /// No usable Rime session exists.
    case noSession
    /// A native action may have completed, but its state/commit was not observed.
    /// Only a verified cancellation or a fresh session may resume input.
    case snapshotUnavailable
    /// Schema selection failed.
    case schemaSelectionFailed(String)
    /// Native sync (`sync_user_data`) could not be performed or its
    /// deployment reported failure.
    case syncFailed(String)
    /// A key/candidate/option operation returned a failure from librime.
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            return "RimeEngine is not started; call start() first."
        case .initializationFailed(let detail):
            return "RimeEngine initialization failed: \(detail)"
        case .stopped:
            return "RimeEngine has been stopped."
        case .noSession:
            return "RimeEngine has no live session."
        case .snapshotUnavailable:
            return "引擎状态读取失败，输入已暂停；请放弃当前组合并重试。"
        case .schemaSelectionFailed(let schemaID):
            return "Could not select schema '\(schemaID)'."
        case .syncFailed(let detail):
            return "Rime sync failed: \(detail)"
        case .operationFailed(let detail):
            return "Rime operation failed: \(detail)"
        }
    }
}

/// librime deployment state mirrored from the C bridge (`rb_deploy_state`).
enum RimeDeployState: Int32 {
    case none = 0
    case start = 1
    case success = 2
    case failure = 3
}

/// One candidate shown by the engine.
public struct RimeCandidate: Hashable, Sendable {
    /// Candidate text (UTF-8, e.g. "你好").
    public let text: String
    /// Optional annotation, e.g. the pronunciation or code (UTF-8).
    public let comment: String?
    /// Canonical tokens decoded from this candidate's own proven dictionary code.
    /// nil is unsupported provenance, not an empty pronunciation.
    public let readingPaths: [[String]]?
    public let readingsComplete: Bool
    /// The engine's own select key for this candidate's page slot
    /// (`RimeMenu.select_keys`, i.e. the schema's `menu/alternative_select_keys`).
    /// nil means the active schema declared none — the bridge never fabricates
    /// the default `1`..`9` keys. This is the key the engine's selector accepts,
    /// not a front-end keycap guess.
    public let selectKey: String?
    /// The engine's own label for this candidate's page slot
    /// (`RimeContext.select_labels`, i.e. the schema's
    /// `menu/alternative_select_labels`). nil means the active schema declared
    /// none. A candidate `comment` is a different field and must never be used
    /// as a label.
    public let selectLabel: String?
    public var syllables: [String]? { readingPaths?.first }

    public init(
        text: String, comment: String?, syllables: [String]? = nil,
        readingPaths: [[String]]? = nil, readingsComplete: Bool = true,
        selectKey: String? = nil, selectLabel: String? = nil
    ) {
        self.text = text
        self.comment = comment
        self.readingPaths = readingPaths ?? syllables.map { [$0] }
        self.readingsComplete = readingsComplete && self.readingPaths != nil
        self.selectKey = selectKey
        self.selectLabel = selectLabel
    }
}

/// Read-only per-page-slot select metadata for the cross-page candidate
/// browsing path (`rb_copy_context_metadata_json`): the engine's own
/// `menu/alternative_select_keys` / `menu/alternative_select_labels` for the
/// ACTIVE schema. Unlike the full snapshot this performs no commit-consuming
/// read, so a read-only page reader can attach the right slot label on any page.
///
/// Slot arrays are already split per Unicode scalar by the bridge — the Swift
/// side never indexes UTF-8 bytes. An undeclared list is `nil`; the bridge never
/// synthesizes default `1`..`9` keys/labels, and a label is never derived from a
/// candidate comment.
public struct RimePageSelectMetadata: Hashable, Sendable {
    /// The engine's page size (`menu/page_size`) the metadata was read for.
    public let pageSize: Int
    /// One entry per page slot, or nil when the active schema declares none.
    public let selectKeys: [String]?
    /// One entry per page slot, or nil when the active schema declares none.
    public let selectLabels: [String]?

    public init(pageSize: Int, selectKeys: [String]?, selectLabels: [String]?) {
        self.pageSize = pageSize
        self.selectKeys = selectKeys
        self.selectLabels = selectLabels
    }

    /// Strict decode of the bridge JSON. `select_labels`, when present, must have
    /// exactly `page_size` entries (matching librime's emission rule); a mismatch
    /// rejects the whole object so a partial/mis-aligned label set is never used.
    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let pageSize = (root["page_size"] as? NSNumber)?.intValue,
            pageSize >= 0
        else { return nil }
        let keys = root["select_keys"] as? [String]
        let labels = root["select_labels"] as? [String]
        if let labels, labels.count != pageSize { return nil }
        self.pageSize = pageSize
        self.selectKeys = keys
        self.selectLabels = labels
    }

    /// Select key for a page-local slot, or nil when undeclared/out of range.
    public func selectKey(pageLocalIndex: Int) -> String? {
        guard let selectKeys, pageLocalIndex >= 0, pageLocalIndex < selectKeys.count
        else { return nil }
        return selectKeys[pageLocalIndex]
    }

    /// Label for a page-local slot, or nil when undeclared/out of range.
    public func selectLabel(pageLocalIndex: Int) -> String? {
        guard let selectLabels, pageLocalIndex >= 0, pageLocalIndex < selectLabels.count
        else { return nil }
        return selectLabels[pageLocalIndex]
    }
}

/// How the highlighted segment should be displayed, from the active schema's
/// declared `keyboard_adapter` capability. `.native` = keep the engine preedit.
public enum RimeDisplayMode: String, Hashable, Sendable {
    case native
    case canonical
    case sourceCode = "source_code"
    case sourceRendered = "source_rendered"
}

/// The declared display capability block (mirrors the `keyboard_adapter` wire
/// format; the adapter maps it to `KeyboardCore.SchemaDisplayCapability`). This
/// package never decides trust — it only reports what the schema declared.
public struct RimeDisplayCapability: Hashable, Sendable {
    public let version: Int
    public let mode: RimeDisplayMode
    public let sourceSchema: String
    public let translatorNamespace: String
    public let separator: String
    public let mappingPolicy: String
    public let adapterSchema: String
    public let syllables: [String: String]

    /// The `keyboard_adapter` wire dictionary, shared with
    /// `KeyboardCore.SchemaDisplayCapability` (the adapter maps it across the
    /// package boundary; this package never decides trust).
    public var wireDictionary: [String: Any] {
        [
            "version": version,
            "display_mode": mode.rawValue,
            "source_schema": sourceSchema,
            "translator_namespace": translatorNamespace,
            "separator": separator,
            "mapping_policy": mappingPolicy,
            "adapter_schema": adapterSchema,
            "syllables": syllables,
        ]
    }
}

/// Config facts of the source schema named by the capability.
public struct RimeDisplaySourceFacts: Hashable, Sendable {
    public let sourceSchema: String
    public let translatorNamespace: String
    public let dictionary: String
    public let alphabet: String
    /// The source's explicit semantic declaration (`keyboard_adapter_source`).
    public let declaration: String
    public let algebra: [String]
}

/// The schema actually running now (the generated/builtin companion).
public struct RimeDisplayProducer: Hashable, Sendable {
    public let schemaID: String
    public let translatorNamespace: String
    public let dictionary: String
    public let prism: String
    /// The primary Table and Prism of the producer are both open.
    public let producerLoaded: Bool
}

/// The active schema's runtime display context: declared capability (if any), the
/// source schema facts and the actual producer. Swift authorizes only when the
/// block, the source and the producer agree — one decision, consumed by the
/// adapter.
public struct RimeDisplayContext: Hashable, Sendable {
    public let capability: RimeDisplayCapability?
    public let capabilityPresent: Bool
    public let source: RimeDisplaySourceFacts?
    public let producer: RimeDisplayProducer?

    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else { return nil }
        self.capability = (root["capability"] as? [String: Any]).flatMap(Self.decodeCapability)
        self.capabilityPresent = (root["capability_present"] as? Bool) ?? (self.capability != nil)
        self.source = (root["source"] as? [String: Any]).flatMap(Self.decodeSource)
        self.producer = (root["producer"] as? [String: Any]).flatMap(Self.decodeProducer)
    }

    /// Strict decode of the declared capability. Unknown version / mode / missing
    /// required fields yield nil so the caller treats it as no capability (native,
    /// zero decode). `canonical`/`source_code` additionally require an
    /// adapter schema; `source_code` also a mapping policy and non-empty map.
    public static func decodeCapability(_ wire: [String: Any]) -> RimeDisplayCapability? {
        guard let version = (wire["version"] as? NSNumber)?.intValue,
            let rawMode = wire["display_mode"] as? String,
            let mode = RimeDisplayMode(rawValue: rawMode),
            let sourceSchema = wire["source_schema"] as? String, !sourceSchema.isEmpty,
            let namespace = wire["translator_namespace"] as? String, !namespace.isEmpty,
            let separator = wire["separator"] as? String, !separator.isEmpty
        else { return nil }
        let policy = wire["mapping_policy"] as? String ?? ""
        let adapter = wire["adapter_schema"] as? String ?? ""
        let syllables = wire["syllables"] as? [String: String] ?? [:]
        if mode == .canonical || mode == .sourceCode || mode == .sourceRendered {
            guard !adapter.isEmpty else { return nil }
        }
        if mode == .sourceCode || mode == .sourceRendered {
            guard policy == "unique_normal", !syllables.isEmpty else { return nil }
        }
        return RimeDisplayCapability(
            version: version, mode: mode, sourceSchema: sourceSchema,
            translatorNamespace: namespace,
            separator: separator, mappingPolicy: policy, adapterSchema: adapter,
            syllables: syllables)
    }

    private static func decodeSource(_ wire: [String: Any]) -> RimeDisplaySourceFacts? {
        guard let sourceSchema = wire["source_schema"] as? String,
            let namespace = wire["translator_namespace"] as? String,
            let dictionary = wire["dictionary"] as? String
        else { return nil }
        return RimeDisplaySourceFacts(
            sourceSchema: sourceSchema, translatorNamespace: namespace,
            dictionary: dictionary, alphabet: wire["alphabet"] as? String ?? "",
            declaration: wire["declaration"] as? String ?? "",
            algebra: wire["algebra"] as? [String] ?? [])
    }

    private static func decodeProducer(_ wire: [String: Any]) -> RimeDisplayProducer? {
        guard let schemaID = wire["schema_id"] as? String,
            let namespace = wire["translator_namespace"] as? String
        else { return nil }
        return RimeDisplayProducer(
            schemaID: schemaID, translatorNamespace: namespace,
            dictionary: wire["dictionary"] as? String ?? "",
            prism: wire["prism"] as? String ?? "",
            producerLoaded: (wire["producer_loaded"] as? Bool) ?? false)
    }

    /// The single authorization decision: whether the declared capability may
    /// gate a candidate decode and a re-expression. `nil` = no authorized mode
    /// (keep the native preedit). Both `canonical` and `source_code` require the
    /// same conditions: a live source, the producer's schema/namespace/dictionary
    /// matching the block and source, and an opened producer table and prism.
    /// Unknown version/mode, `source_rendered`, a malformed block, or a
    /// cross-wired producer is refused before any decode.
    public func authorizedMode() -> RimeDisplayMode? {
        guard let capability else { return nil }
        guard capability.version == 1 else { return nil }
        switch capability.mode {
        case .native:
            return nil
        case .sourceRendered:
            // Declared but not implemented: never authorized.
            return nil
        case .canonical, .sourceCode:
            guard let producer, let source,
                producer.producerLoaded,
                !producer.prism.isEmpty,
                capability.adapterSchema == producer.schemaID,
                capability.translatorNamespace == source.translatorNamespace,
                capability.translatorNamespace == producer.translatorNamespace,
                producer.translatorNamespace == source.translatorNamespace,
                producer.dictionary == source.dictionary
            else { return nil }
            // canonical additionally requires the source's explicit semantic
            // declaration, checked HERE at runtime so a canonical block whose
            // source is not declared canonical-pinyin is refused. source_code keeps
            // its own projection-based boundary and does not need this.
            if capability.mode == .canonical,
                source.declaration != "canonical_pinyin"
            {
                return nil
            }
            return capability.mode
        }
    }
}

/// Read-only ambiguity-spelling report for the current composition's last
/// (`composition.back()`) `abc` segment (`rb_copy_ambiguity_spellings_json`).
///
/// This is REPORT ONLY: it is not authorization to rewrite input, lock a
/// spelling or select a candidate. `spellings.count < 2` is the definite
/// "no ambiguity / not a reduced spelling unit" answer. The engine API returns
/// `nil` (not an empty object) when the bridge cannot prove an answer, so an
/// unavailable result is never mistaken for "not ambiguous".
public struct RimeAmbiguitySpellings: Hashable, Sendable {
    /// Raw-input byte range (start inclusive, end exclusive) of the enumerated
    /// `composition.back()` segment. Raw-input coordinates, never preedit ones.
    public struct Segment: Hashable, Sendable {
        public let start: Int
        public let end: Int

        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// The WHOLE raw input this report was computed for. Compare it with the
    /// live input to reject stale clicks; never mix it with preedit offsets.
    public let revisionInput: String
    /// Raw span of the segment the spellings belong to.
    public let segment: Segment
    /// Deduplicated, lexicographically sorted source spellings reachable
    /// from the segment's raw code. An empty/singleton list means "not
    /// ambiguous"; it is never an error.
    public let spellings: [String]
    /// `false` when the bridge capped the list (default 32, hard limit 64), so
    /// `spellings` is a prefix and must not be presented as the full choice set.
    public let complete: Bool
    /// The active schema's lock mode. `.none` means input rewrite is not
    /// authorized (the options are display-only).
    public enum LockMode: String, Hashable, Sendable {
        case none
        /// `bounded_token_alias_rewrite_v2`: opaque ALIAS rewrite (script sources).
        /// The rewrite target is re-proven against the live prism to resolve to
        /// exactly the chosen token.
        case tokenAlias = "bounded_token_alias"
        /// `direct_token_rewrite_v3`: DIRECT-code rewrite (table sources). The
        /// chosen token IS the rewrite target and must itself be a unique live
        /// prism key; no per-code alias is generated.
        case directToken = "direct_token"
        /// `prefix_token_rewrite_v4`: DIRECT-key rewrite to a bounded, live-proven
        /// narrowing of the current segment (numeric/compact script sources that
        /// explicitly opted into the letter-class layer). Every option is a live
        /// prism key whose interpretation set is a non-empty SUBSET of the
        /// segment's, so applying it can only narrow the reading. Options carry a
        /// semantic label (`optionSemantics`): `exact` = the key names exactly one
        /// token; `initial` = an abbreviation (first-letter) class; `mixed` = both.
        case prefixToken = "prefix_token"
    }
    public let lockMode: LockMode
    /// The subset of `spellings` the engine will actually accept in
    /// `applyAmbiguitySpelling`. It is computed from a fresh prism enumeration of
    /// each rewrite target and may be smaller than `spellings`; a consumer must
    /// not offer a non-lockable option as a lock. Never conflated with `spellings`.
    /// In the prefix mode it may also name entries of `prefixOptions`.
    public let lockable: [String]
    /// The bounded narrowing keys of the prefix mode (`.prefixToken`), sorted.
    /// Each one is a live prism key whose interpretation set is a non-empty subset
    /// of the segment's; these are the front end's letter-class choices, so they
    /// are never capped away by the `spellings` limit. Always empty for the other
    /// lock modes. A consumer must only offer those it finds in `lockable`.
    public let prefixOptions: [String]
    /// Per-option semantic label for `lockable` entries: `exact` / `initial` /
    /// `mixed`. Empty for the other lock modes. It is DATA for the UI, never an
    /// authorization: `lockable` alone decides what may be applied.
    public let optionSemantics: [String: String]

    /// The bridge's default item cap and hard limit; a decoded report can never
    /// exceed the hard limit, and neither value is inferred from `complete`.
    public static let defaultLimit = 32
    public static let hardLimit = 64

    /// A wire token is any non-empty string the active schema's prism can name
    /// (pinyin, double-pinyin, ASCII shape codes, Bopomofo, dialect, ...). The
    /// bridge — not this decoder — is the authority on which tokens exist; this
    /// is only a structural sanity gate so a malformed payload is rejected:
    /// non-empty, bounded, and free of control characters.
    private static func isWireToken(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 64 else { return false }
        return token.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
    }

    /// Strict decode of the bridge JSON. Returns nil on a malformed object or a
    /// violated invariant, so the caller keeps the native state:
    ///   * `lock_mode` must be present and one of the recognized values; an
    ///     unknown or missing mode is REFUSED (never degraded to `.none`);
    ///   * ranges must be non-negative, ordered and inside `revision_input`;
    ///   * at most `hardLimit` spellings, each a structurally valid wire token;
    ///   * the lists must already be deduplicated and lexicographically sorted;
    ///   * `prefixOptions` must be deduped/sorted single printable ASCII keys;
    ///   * mode coherence:
    ///       - `.prefixToken`: `prefixOptions ⊆ lockable` and
    ///         `lockable ⊆ spellings ∪ prefixOptions`; `optionSemantics` maps
    ///         EXACTLY the `lockable` entries, each to a recognized label;
    ///       - every other mode: `prefixOptions`/`optionSemantics` must be empty
    ///         and `lockable ⊆ spellings`;
    ///   * a singleton list is accepted (it is a definite "not ambiguous").
    /// `prefix_options`/`option_semantics` may be ABSENT (an older wire), but when
    /// PRESENT they must have the declared type: a present-but-wrong-typed field
    /// is malformed and refused, never silently treated as empty.
    /// `complete` is decoded verbatim; when it is false the original total is
    /// deliberately NOT guessed from the count.
    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let revisionInput = root["revision_input"] as? String,
            let segment = root["segment"] as? [String: Any],
            let spellings = root["spellings"] as? [String],
            let lockable = root["lockable"] as? [String],
            let complete = root["complete"] as? Bool,
            let rawMode = root["lock_mode"] as? String,
            let lockMode = LockMode(rawValue: rawMode),
            let start = (segment["start"] as? NSNumber)?.intValue,
            let end = (segment["end"] as? NSNumber)?.intValue,
            start >= 0, end >= start,
            end <= revisionInput.utf8.count,
            spellings.count <= Self.hardLimit,
            lockable.count <= Self.hardLimit,
            spellings.allSatisfy(Self.isWireToken),
            lockable.allSatisfy(Self.isWireToken),
            spellings == spellings.sorted(),
            Set(spellings).count == spellings.count,
            lockable == lockable.sorted(),
            Set(lockable).count == lockable.count,
            let prefixOptions = Self.strictOptional(
                root, "prefix_options", as: [String].self, default: []),
            let semantics = Self.strictOptional(
                root, "option_semantics", as: [String: String].self, default: [:]),
            prefixOptions.count <= Self.hardLimit,
            prefixOptions.allSatisfy(Self.isPrefixKey),
            prefixOptions == prefixOptions.sorted(),
            Set(prefixOptions).count == prefixOptions.count
        else { return nil }

        let lockableSet = Set(lockable)
        switch lockMode {
        case .prefixToken:
            // The narrowing keys are a separate, complete list; the engine
            // guarantees every one of them is lockable and that each lockable
            // option is labelled.
            guard Set(prefixOptions).isSubset(of: lockableSet),
                lockableSet.isSubset(of: Set(spellings).union(prefixOptions)),
                Set(semantics.keys) == lockableSet,
                semantics.values.allSatisfy(Self.validOptionSemantics.contains)
            else { return nil }
        default:
            // No other mode may smuggle a prefix list/label or lock a token it
            // did not report as a plain spelling.
            guard prefixOptions.isEmpty, semantics.isEmpty,
                lockableSet.isSubset(of: Set(spellings))
            else { return nil }
        }

        self.lockMode = lockMode
        self.lockable = lockable
        self.prefixOptions = prefixOptions
        self.optionSemantics = semantics
        self.revisionInput = revisionInput
        self.segment = Segment(start: start, end: end)
        self.spellings = spellings
        self.complete = complete
    }

    /// Decodes a payload field that may be ABSENT (older wire) but must have the
    /// declared type when present. Absent yields `defaultValue`; a
    /// present-but-wrong-typed field yields nil, so the caller refuses the payload
    /// instead of silently treating it as empty.
    private static func strictOptional<T>(
        _ root: [String: Any], _ key: String,
        as type: T.Type, default defaultValue: T
    ) -> T? {
        guard let raw = root[key] else { return defaultValue }
        return raw as? T
    }

    /// The labelled kinds an option may carry (the wire vocabulary of
    /// `option_semantics`). Unknown labels are refused rather than displayed.
    public static let validOptionSemantics: Set<String> = ["exact", "initial", "mixed"]

    /// A prefix key is a single printable ASCII character: bounded by one byte and
    /// free of control characters. The engine still re-proves liveness; this is
    /// only the structural sanity gate that keeps the wire bounded.
    private static func isPrefixKey(_ key: String) -> Bool {
        guard key.utf8.count == 1, let scalar = key.unicodeScalars.first else { return false }
        return scalar.value >= 0x20 && scalar.value < 0x7F
    }
}

/// Result of the read-only, candidate-free rewrite verification
/// (`rb_copy_rewrite_verification_json`), used by the installer deploy check.
public enum RimeRewriteVerification: Equatable, Sendable {
    /// The bridge could not answer (no live session).
    case unavailable
    /// The active schema declares no rewrite capability at all.
    case absent
    /// Declared, fully bound, and every baked alias enumerates to exactly its token.
    case verified
    /// Declared but not usable: unbound/stale/cross-wired, or some alias does not
    /// enumerate to exactly its token. Carries the failed tokens (diagnostics).
    case failed(checked: Int, failures: [String])

    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let present = (root["present"] as? Bool) ?? (root["present"] as? NSNumber)?.boolValue,
            let verified = (root["verified"] as? Bool) ?? (root["verified"] as? NSNumber)?.boolValue,
            let checked = (root["checked"] as? NSNumber)?.intValue
        else { return nil }
        if !present {
            self = .absent
            return
        }
        if verified {
            self = .verified
            return
        }
        self = .failed(checked: checked, failures: root["failures"] as? [String] ?? [])
    }
}

/// Result of a capability-gated ambiguity rewrite (`rb_ambig_result`).
/// The engine maps the C enum verbatim and never folds failure into success.
public enum RimeAmbiguityApplyResult: Int32, Hashable, Sendable {
    /// Applied and re-validated; no candidate selected, nothing committed.
    case applied = 0
    /// Expected input / back `abc` segment / range no longer match. Nothing written.
    case stale = 1
    /// Active schema lacks a recognized `keyboard_rewrite` capability
    /// (e.g. an ordinary 26-key or non-adapted schema). Nothing written.
    case unsupported = 2
    /// Bad arguments or the requested spelling/target is not proven by a fresh
    /// prism enumeration. Nothing written.
    case invalid = 3
    /// The write was attempted but post-validation failed; the original input
    /// was re-written and re-read byte-equal. No hanzi committed.
    case failed = 4
    /// Post-validation failed AND the rollback could not be re-read as the
    /// original input. The caller must treat the input as unknown/changed.
    case failedRollbackUnverified = 5
}

/// A full, copied snapshot of the session state after an action.
///
/// All strings are copies — the snapshot remains valid across further key
/// presses and does not need to be consumed inside a librime callback.
public struct RimeState: Hashable, Sendable {
    public let commitTextPreview: String
    /// Active schema id, e.g. "luna_pinyin".
    public let schemaID: String
    /// Human-readable schema name.
    public let schemaName: String
    /// Whether a composition (preedit/candidates) is active.
    public let isComposing: Bool
    /// `ascii_mode` option value (direct latin input), from `RimeStatus.is_ascii_mode`.
    public let isAsciiMode: Bool
    /// `full_shape` option value (full-width punctuation/forms), from
    /// `RimeStatus.is_full_shape`. Observed only; this package never derives or
    /// toggles UI mode from it.
    public let isFullShape: Bool
    /// `ascii_punct` option value (ASCII punctuation), from
    /// `RimeStatus.is_ascii_punct`. Observed only; never used to write an option.
    public let isAsciiPunct: Bool
    /// Raw key sequence librime has collected, "" when idle.
    public let input: String
    /// Text shown in the composing area, "" when not composing.
    public let preedit: String
    /// Caret position within `preedit` as reported by librime.
    public let preeditCursor: Int
    /// UTF-8 byte range of the highlighted (unconfirmed) segment inside
    /// `preedit`, straight from librime's composition sel_start/sel_end. Only
    /// this span may be re-rendered; everything outside is already-converted
    /// text, punctuation or trailing raw code.
    public let preeditSelStart: Int
    public let preeditSelEnd: Int
    /// Genuine spelling of the highlighted candidate, decoded by librime from the
    /// candidate's own syllable code through its own script dictionary. Populated
    /// only when the active schema declares a non-native display capability and the
    /// state is composing; "" otherwise. It is produced in the same serialized step
    /// as `candidates`, so the two always describe one state.
    public let highlightedSpelling: String
    /// Canonical decoded syllable tokens of the highlighted candidate (same trust
    /// gates as `highlightedSpelling`), so the adapter can project each token
    /// through the schema's declared capability. Empty when not requested/decoded.
    public let highlightedSyllables: [String]
    /// The effective (authorized) display mode at this snapshot's point in time.
    /// `.native` whenever the declared capability did not pass authorization, so a
    /// consumer can never decode or re-express on an unauthorized capability.
    public let displayMode: RimeDisplayMode
    /// Whether the active schema declared any `keyboard_adapter` block at all
    /// (authorized or not). Used by the adapter so a capability snapshot never
    /// falls back to the legacy spelling protocol.
    public let hasDisplayCapability: Bool
    /// The strictly-decoded DECLARED display mode of the active schema's
    /// `keyboard_adapter` block, independent of authorization/demand. `.native`
    /// when there is no decodable block. A declared `canonical` is what tells the
    /// consumer that the engine preedit is an internal numeric transport code
    /// (e.g. 9-key `555`), so it must never be echoed as user-facing composition
    /// even before authorization or a compact-layout demand is established.
    public let declaredDisplayMode: RimeDisplayMode
    /// The strictly-decoded authorized capability (nil when none/unauthorized).
    public let displayCapability: RimeDisplayCapability?
    /// 0-based page index of the current candidate page.
    public let pageIndex: Int
    /// Candidates per page.
    public let pageSize: Int
    /// Whether the current page is the last one.
    public let isLastPage: Bool
    /// 0-based index of the highlighted candidate on the current page.
    public let highlightedIndex: Int
    /// Candidates on the current page.
    public let candidates: [RimeCandidate]
    /// Text committed by the triggering action ("" when nothing committed).
    /// Reading it consumes librime's pending commit, so a snapshot is a
    /// one-shot description of the state *after* the action.
    public private(set) var commitText: String

    func withoutCommit() -> Self {
        var copy = self
        copy.commitText = ""
        return copy
    }

    public init(
        schemaID: String,
        schemaName: String,
        isComposing: Bool,
        isAsciiMode: Bool,
        isFullShape: Bool = false,
        isAsciiPunct: Bool = false,
        input: String,
        preedit: String,
        preeditCursor: Int,
        preeditSelStart: Int = 0,
        preeditSelEnd: Int = 0,
        highlightedSpelling: String = "",
        highlightedSyllables: [String] = [],
        displayMode: RimeDisplayMode = .native,
        hasDisplayCapability: Bool = false,
        declaredDisplayMode: RimeDisplayMode = .native,
        displayCapability: RimeDisplayCapability? = nil,
        pageIndex: Int,
        pageSize: Int,
        isLastPage: Bool,
        highlightedIndex: Int,
        candidates: [RimeCandidate],
        commitText: String,
        commitTextPreview: String = ""
    ) {
        self.schemaID = schemaID
        self.schemaName = schemaName
        self.isComposing = isComposing
        self.isAsciiMode = isAsciiMode
        self.isFullShape = isFullShape
        self.isAsciiPunct = isAsciiPunct
        self.input = input
        self.preedit = preedit
        self.preeditCursor = preeditCursor
        self.preeditSelStart = preeditSelStart
        self.preeditSelEnd = preeditSelEnd
        self.highlightedSpelling = highlightedSpelling
        self.highlightedSyllables = highlightedSyllables
        self.displayMode = displayMode
        self.hasDisplayCapability = hasDisplayCapability
        self.declaredDisplayMode = declaredDisplayMode
        self.displayCapability = displayCapability
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.isLastPage = isLastPage
        self.highlightedIndex = highlightedIndex
        self.candidates = candidates
        self.commitText = commitText
        self.commitTextPreview = commitTextPreview
    }
}

/// Empty snapshot used before the first successful `start()`.
extension RimeState {
    public static let empty = RimeState(
        schemaID: "", schemaName: "", isComposing: false, isAsciiMode: false,
        input: "", preedit: "", preeditCursor: 0,
        pageIndex: 0, pageSize: 0, isLastPage: true,
        highlightedIndex: 0, candidates: [], commitText: ""
    )
}

/// Result of feeding one key: whether librime consumed it and the state after.
public struct RimeActionResult: Hashable, Sendable {
    /// `true`: librime handled the key (update the UI from `state`).
    /// `false`: the keyboard should handle the key itself (for a printable
    /// ASCII key while not composing this usually means: insert the text).
    public let consumed: Bool
    /// Session state after processing the key.
    public let state: RimeState

    public init(consumed: Bool, state: RimeState) {
        self.consumed = consumed
        self.state = state
    }

    /// Text committed by this key press, or nil.
    public var commitText: String? {
        state.commitText.isEmpty ? nil : state.commitText
    }
}

/// One key of a batch: only what decides how the next key is handled. The
/// state itself is read once after the batch (`RimeEngine.actionState()`).
public struct RimeKeyFeed: Hashable, Sendable {
    /// Same meaning as `RimeActionResult.consumed`.
    public let consumed: Bool
    /// `RimeState.isComposing` after the key.
    public let isComposing: Bool
    /// `RimeState.input` is non-empty after the key.
    public let hasInput: Bool
    /// Text this key committed; "" when none.
    public let commitText: String

    public init(consumed: Bool, isComposing: Bool, hasInput: Bool, commitText: String) {
        self.consumed = consumed
        self.isComposing = isComposing
        self.hasInput = hasInput
        self.commitText = commitText
    }
}
