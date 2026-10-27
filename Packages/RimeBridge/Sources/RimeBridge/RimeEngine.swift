import Foundation
import RimeKit
import os

/// One memoized `schemaValue` answer. `value == nil` is the real answer for an
/// absent key (or an unopenable schema) and must stay distinguishable from
/// "not cached", which is why it is wrapped instead of stored as `String?`.
struct RimeCachedSchemaString {
    let value: String?
}

/// One memoized `schemaStringList` answer. `value == nil` is absent/non-list;
/// `value == []` is a real empty list — the public contract keeps them apart.
struct RimeCachedSchemaList {
    let value: [String]?
}

/// Memo of schema config reads for an immutable prebuilt build. Only touched on
/// the engine queue; cleared on cleanup and whenever the build may be rewritten.
/// Only successful reads are stored, so a transient failure is re-read.
struct RimeSchemaConfigFacts {
    var components: [String: [String]] = [:]
    var strings: [String: [String: RimeCachedSchemaString]] = [:]
    var lists: [String: [String: RimeCachedSchemaList]] = [:]
    mutating func removeAll() {
        components.removeAll()
        strings.removeAll()
        lists.removeAll()
    }
}

/// Thin, thread-safe Swift wrapper over librime 1.17.0 (vendored as the
/// `RimeKit` XCFramework + the `rb_*` C bridge).
///
/// # Concurrency model
/// Every engine instance shares one process-wide dispatch queue, and librime
/// API access never leaves that queue (except the deployment notification,
/// which the C bridge reduces to an atomic state int). Only one instance may
/// be started in a process at a time. All public
/// methods are synchronous and safe to call from any thread, **but never
/// re-entrantly** (do not call a method from inside another method of this
/// object — e.g. from a callback that itself runs on the same caller).
///
/// # C memory / session lifecycle rules enforced here
/// * librime strings are copied out by the C bridge into snapshots that are
///   freed after conversion to Swift value types;
/// * `RimeSyncUserData()` destroys every librime session, so after `sync()` a
///   fresh session is created and the previously active schema re-selected;
/// * `shutdown()`/`deinit` finalize the engine on the serial queue.
// @unchecked: every mutable field is confined to `processQueue` (each entry point is a
// `queue.sync`); the remaining shared state sits behind locks.
public final class RimeEngine: @unchecked Sendable {

    public struct Configuration {
        /// Directory holding the Rime data (default.yaml, *.schema.yaml,
        /// *.dict.yaml, ...). Read-only for the engine.
        public var sharedDirectory: URL
        /// Per-device writable directory (build/, *.userdb/, sync/...).
        /// Created automatically if it does not exist.
        public var userDirectory: URL
        /// librime `app_name` — must start with "rime." so old log files are
        /// cleaned automatically.
        public var appName: String
        /// librime `distribution_version`, recorded in installation.yaml.
        /// Defaults to the running bundle's marketing version.
        public var distributionVersion: String?
        /// Immutable deployed build directory. Non-nil skips ALL maintenance;
        /// schema/version errors fail start instead of compiling dictionaries.
        public var prebuiltDirectory: URL?
        /// Development diagnostics only: records bounded actual decoder context/word samples.
        /// Default off; load outcomes contain paths/metadata only and remain available.
        public var grammarDiagnosticsEnabled: Bool

        public init(
            sharedDirectory: URL,
            userDirectory: URL,
            appName: String = "rime.songyan",
            distributionVersion: String? =
                Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            prebuiltDirectory: URL? = nil,
            grammarDiagnosticsEnabled: Bool = false
        ) {
            self.sharedDirectory = sharedDirectory
            self.userDirectory = userDirectory
            self.appName = appName
            self.distributionVersion = distributionVersion
            self.prebuiltDirectory = prebuiltDirectory
            self.grammarDiagnosticsEnabled = grammarDiagnosticsEnabled
        }
    }

    let configuration: Configuration
    private static let processQueue = DispatchQueue(
        label: "app.songyan.rimebridge.engine",
        qos: .userInteractive
    )
    var queue: DispatchQueue { Self.processQueue }
    // Written only on processQueue; the lock just makes the static storage Sendable.
    // Identity avoids retention and stays reserved until deinit's queued cleanup
    // finishes (weak references clear earlier).
    static let processOwnerID = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)

    // Internal (not private) only so the RimeEngine+*.swift extensions can reach it;
    // like all engine state, touch it only on `queue`.
    var engine: OpaquePointer?
    var session: UInt = 0
    // Written only on `queue`; the lock lets the main thread read it per key without
    // waiting behind a slow engine op. Main's own ops are synchronous, so it never
    // observes a value older than its last completed op.
    private let storedSnapshotRecoveryRequired = OSAllocatedUnfairLock(initialState: false)
    var snapshotRecoveryRequired: Bool {
        get { storedSnapshotRecoveryRequired.withLock { $0 } }
        set { storedSnapshotRecoveryRequired.withLock { $0 = newValue } }
    }
    var lastTrustedState: RimeState = .empty

    public var requiresSnapshotRecovery: Bool { snapshotRecoveryRequired }
    /// Read-only word-completion session (the ABC page queries the active scheme). Same
    /// engine instance, never commits, destroyed with the input session.
    var wordSession: UInt = 0
    private var wordSchemaID = ""
    var activeSchemaID: String = ""
    var explicitlySetOptions: Set<String> = []
    struct SuspendedSession {
        let schemaID: String
        let options: [(String, Int32)]
    }
    var suspendedSession: SuspendedSession?
    #if SONGYAN_TEST_FAILPOINTS
        /// Test-only (macOS real-engine harness compiles with `-DSONGYAN_TEST_FAILPOINTS`).
        /// Forces the next state read to fail before native pending commit is consumed.
        /// This symbol
        /// does not exist in app targets (the flag is never passed to Xcode builds).
        var testFailNextSnapshotOnQueue = false
    #endif
    /// Active-schema display context (capability + source facts). Read on the
    /// serialized queue and invalidated whenever the session/schema can change,
    /// so a re-deploy in the same instance cannot leave a stale mapping.
    var displayContextSchema: String = ""
    var displayContextComputed = false
    var cachedDisplayContext: RimeDisplayContext?

    /// Used on `queue` only, and only when `prebuiltDirectory` is set.
    var schemaFacts = RimeSchemaConfigFacts()
    var memoizesSchemaFacts: Bool { configuration.prebuiltDirectory != nil }

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Lifecycle

    /// librime version, or "-" before `start()`.
    public var engineVersion: String {
        queue.sync {
            guard let engine = engine else { return "-" }
            return string(fromC: rb_engine_version(engine)) ?? "-"
        }
    }

    public var isRunning: Bool {
        queue.sync {
            guard let engine = engine else { return false }
            return rb_engine_ready(engine) != 0 && session != 0
        }
    }

    /// Initializes librime, deploys the shared data into `userDirectory` and
    /// opens the first usable session. Synchronous and potentially slow on
    /// first run (dictionary compilation) — call it off the keyboard's
    /// performance-critical path.
    public func start() throws {
        try queue.sync {
            if engine != nil { return }  // already started
            guard Self.processOwnerID.withLock({ $0 }) == nil else {
                throw RimeEngineError.initializationFailed(
                    "another RimeEngine is active in this process; shut it down first")
            }
            rb_grammar_diagnostics_reset(configuration.grammarDiagnosticsEnabled ? 1 : 0)
            let fm = FileManager.default
            let sharedExists = fm.fileExists(atPath: configuration.sharedDirectory.path)
            guard sharedExists else {
                throw RimeEngineError.initializationFailed(
                    "shared data directory missing: \(configuration.sharedDirectory.path)")
            }
            if let prebuilt = configuration.prebuiltDirectory {
                try validatePrebuiltDirectory(prebuilt)
            }
            try fm.createDirectory(
                at: configuration.userDirectory,
                withIntermediateDirectories: true
            )

            let cEngine = configuration.sharedDirectory.path.withCString { sharedPtr in
                configuration.userDirectory.path.withCString { userPtr in
                    configuration.appName.withCString { appPtr in
                        withOptionalCString(configuration.distributionVersion) { versionPtr in
                            if let prebuilt = configuration.prebuiltDirectory {
                                return prebuilt.path.withCString {
                                    rb_engine_create_prebuilt(sharedPtr, userPtr, appPtr, versionPtr, $0)
                                }
                            }
                            return rb_engine_create(sharedPtr, userPtr, appPtr, versionPtr)
                        }
                    }
                }
            }
            guard let cEngine = cEngine else {
                throw RimeEngineError.initializationFailed(
                    "rb_engine_create returned NULL")
            }
            engine = cEngine
            guard rb_engine_ready(cEngine) != 0 else {
                var detail = "engine not ready"
                if let errorPtr = rb_engine_last_error(cEngine) {
                    detail = String(cString: errorPtr)
                }
                cleanupEngineOnQueue()
                throw RimeEngineError.initializationFailed(detail)
            }
            let sid = rb_session_create(cEngine)
            guard sid != 0 else {
                cleanupEngineOnQueue()
                throw RimeEngineError.initializationFailed("cannot create session")
            }
            session = sid
            let owner = ObjectIdentifier(self)
            Self.processOwnerID.withLock { $0 = owner }
            activeSchemaID = readCurrentSchemaIDOnQueue()
            if configuration.prebuiltDirectory != nil && (activeSchemaID.isEmpty || activeSchemaID == ".default") {
                cleanupEngineOnQueue()
                throw RimeEngineError.initializationFailed(
                    "prebuilt default schema is unavailable; republish from the host App")
            }
        }
    }

    /// Releases the engine and all librime state. Idempotent; safe to call
    /// when not started. Call start() to reopen this instance afterwards.
    public func shutdown() {
        queue.sync {
            cleanupEngineOnQueue()
        }
    }

    /// A hidden keyboard must not retain the userdb file lock across iOS suspension.
    /// Keep librime initialized so the same engine and route can be reused on return.
    @discardableResult
    public func suspendSession() -> Bool {
        queue.sync {
            guard let engine, session != 0 else { return false }
            let schemaID = readCurrentSchemaIDOnQueue()
            let names = explicitlySetOptions.union([
                "ascii_mode", "full_shape", "simplification", "ascii_punct",
            ])
            let options = names.sorted().map { name in
                (name, name.withCString { rb_get_option(engine, session, $0) })
            }
            rb_session_destroy(engine, session)
            session = 0
            destroyWordSessionOnQueue()
            suspendedSession = SuspendedSession(schemaID: schemaID, options: options)
            invalidateDisplayContextOnQueue()
            return true
        }
    }

    /// Restore only the session, not the deployed engine. A failed restore stays
    /// suspended so a later appearance can retry without claiming input succeeded.
    @discardableResult
    public func resumeSession() throws -> Bool {
        try queue.sync {
            guard let saved = suspendedSession else { return false }
            guard let engine else { throw RimeEngineError.notStarted }
            // Another path (redeploy/sync) rebuilt the session while suspended: don't stack a second one (it would leak and hold the userdb).
            guard session == 0 else {
                suspendedSession = nil
                return false
            }
            let restoredSession = rb_session_create(engine)
            guard restoredSession != 0 else {
                throw RimeEngineError.operationFailed("cannot recreate suspended session")
            }
            session = restoredSession
            let restored =
                saved.schemaID.isEmpty
                || saved.schemaID.withCString {
                    rb_select_schema(engine, restoredSession, $0) != 0
                }
            guard restored else {
                rb_session_destroy(engine, restoredSession)
                session = 0
                throw RimeEngineError.operationFailed("cannot restore suspended schema")
            }
            for (name, value) in saved.options {
                name.withCString { _ = rb_set_option(engine, restoredSession, $0, value) }
            }
            activeSchemaID = readCurrentSchemaIDOnQueue()
            invalidateDisplayContextOnQueue()
            guard let state = snapshotOnQueue(recovering: true), !state.isComposing,
                state.commitText.isEmpty
            else {
                rb_session_destroy(engine, restoredSession)
                session = 0
                throw RimeEngineError.snapshotUnavailable
            }
            snapshotRecoveryRequired = false
            lastTrustedState = state.withoutCommit()
            suspendedSession = nil
            return true
        }
    }

    deinit {
        // No other strong reference can exist at this point; still serialize
        // the finalize on our own queue for safety.
        queue.sync {
            cleanupEngineOnQueue()
        }
    }

    func destroyWordSessionOnQueue() {
        if let engine, wordSession != 0 { rb_session_destroy(engine, wordSession) }
        wordSession = 0
        wordSchemaID = ""
    }

    /// A second session holds its own schema, translators and dictionary pages; a
    /// keyboard extension's memory limit is tight, so it lives only while ABC is used.
    public func releaseWordCompletions() {
        queue.sync { destroyWordSessionOnQueue() }
    }

    /// librime-predict's switch (`predictor` checks it on every context update).
    static let predictionOption = "prediction"

    /// Completions of `prefix` from a read-only session on `schemaID` (candidate
    /// texts in engine order, at most `limit`). nil = the schema cannot be selected
    /// or the engine is not running; the caller then offers no suggestions.
    public func wordCompletions(prefix: String, schemaID: String, limit: Int) -> [String]? {
        queue.sync {
            guard let engine, session != 0, !schemaID.isEmpty, limit > 0,
                let api = rime_get_api()
            else { return nil }
            if wordSession == 0 || wordSchemaID != schemaID {
                destroyWordSessionOnQueue()
                let created = rb_session_create(engine)
                guard created != 0 else { return nil }
                guard schemaID.withCString({ rb_select_schema(engine, created, $0) != 0 }),
                    readSchemaID(session: created, api: api) == schemaID
                else {
                    rb_session_destroy(engine, created)
                    return nil
                }
                // A read-only lookup session never predicts: librime-predict's engine state is
                // shared per database across sessions, so a second predicting session would
                // disturb the keyboard's own predictions (and crashed the simplifier behind
                // them on device). The option is the one `predictor` consults; absent → no-op.
                Self.predictionOption.withCString { _ = rb_set_option(engine, created, $0, 0) }
                api.pointee.clear_composition(created)
                wordSession = created
                wordSchemaID = schemaID
            }
            defer { api.pointee.clear_composition(wordSession) }
            guard !prefix.isEmpty else { return [] }
            guard prefix.withCString({ api.pointee.set_input(wordSession, $0) }) != 0 else { return nil }
            var iterator = RimeCandidateListIterator()
            guard api.pointee.candidate_list_begin(wordSession, &iterator) != 0 else { return [] }
            defer { api.pointee.candidate_list_end(&iterator) }
            var words: [String] = []
            while words.count < limit, api.pointee.candidate_list_next(&iterator) != 0 {
                if let text = string(fromC: iterator.candidate.text), !text.isEmpty { words.append(text) }
            }
            return words
        }
    }

    /// Schemas a word-completion session may use for `sourceSchemaID`, read from its
    /// own config: each `table_translator@ns` it mounts (as `ns` and as `ns/dictionary`),
    /// then the source itself. No recipe or dictionary name is assumed; ids that
    /// are not selectable schemas simply fail in `wordCompletions`.
    public func wordCompletionSchemas(sourceSchemaID: String) -> [String] {
        queue.sync {
            guard !sourceSchemaID.isEmpty else { return [] }
            var chain: [String] = []
            let prefix = "table_translator@"
            for translator in schemaStringListOnQueue(sourceSchemaID, key: "engine/translators") ?? []
            where translator.hasPrefix(prefix) {
                let namespace = String(translator.dropFirst(prefix.count))
                let dictionaryKey = "\(namespace)/dictionary"
                let dictionary = schemaStringsOnQueue(sourceSchemaID, keys: [dictionaryKey])?[dictionaryKey]
                for id in [namespace, dictionary].compactMap({ $0 })
                where !id.isEmpty && id != sourceSchemaID && !chain.contains(id) {
                    chain.append(id)
                }
            }
            chain.append(sourceSchemaID)
            return chain
        }
    }

    private func readSchemaID(session: UInt, api: UnsafeMutablePointer<RimeApi>) -> String {
        var status = RimeStatus()
        status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_status(session, &status) != 0 else { return "" }
        defer { _ = api.pointee.free_status(&status) }
        return status.schema_id.flatMap { string(fromC: $0) } ?? ""
    }

    func cleanupEngineOnQueue() {
        destroyWordSessionOnQueue()
        if let engine = engine {
            if session != 0 {
                rb_session_destroy(engine, session)
                session = 0
            }
            rb_engine_destroy(engine)
            self.engine = nil
        }
        session = 0
        suspendedSession = nil
        snapshotRecoveryRequired = false
        lastTrustedState = .empty
        activeSchemaID = ""
        explicitlySetOptions.removeAll()
        displayContextSchema = ""
        displayContextComputed = false
        cachedDisplayContext = nil
        schemaFacts.removeAll()
        let owner = ObjectIdentifier(self)
        Self.processOwnerID.withLock { if $0 == owner { $0 = nil } }
    }

    // MARK: - State

    /// Current schema id, or nil when idle/unknown.
    public var currentSchemaID: String? {
        queue.sync {
            let schema = readCurrentSchemaIDOnQueue()
            return schema.isEmpty ? nil : schema
        }
    }

    /// Current full state snapshot. Consumes any pending commit exactly once;
    /// action methods already consume theirs in the returned state. If reading
    /// fails, returns the last trusted observation without a commit and sets
    /// `requiresSnapshotRecovery`; it does not claim the observation is current.
    public func state() -> RimeState {
        queue.sync {
            snapshotOnQueue() ?? lastTrustedState
        }
    }

    /// Reads a candidate page of the current segment by absolute index, **read-only**, for
    /// cross-page browsing: it never changes the engine's current page, highlight or
    /// selected candidate (unlike `pageForward/Backward` -> `change_page` -> `Context::Highlight`).
    /// It uses librime's candidate list iterator (`candidate_list_from_index` +
    /// `candidate_list_next`), which only reads the current segment's menu (generating
    /// candidates via the translator if needed) and never writes `selected_index`.
    ///
    /// Error / end semantics (matching librime 1.17 `RimeCandidateListFromIndex`):
    ///   * engine not started / no session / no `RimeApi` -> `throw` (genuinely unavailable, retryable);
    ///   * invalid `fromIndex`/`count` -> `throw` (caller bug, never treated as an empty page);
    ///   * `candidate_list_from_index` returns false **only when the session is invalid or
    ///     the Context has no menu** (it is not an out-of-range check; `index` is just the
    ///     iteration start). The read-only `get_status` tells them apart: live session =>
    ///     no candidate list (not composing / empty) => return `[]`; dead session => `throw`;
    ///   * running past the end is `candidate_list_next` returning false, yielding an
    ///     empty or short page (a short page is a real EOF), not a failure.
    /// - Parameters:
    ///   - fromIndex: global absolute index (0-based, accumulated across pages).
    ///   - count: maximum number of candidates to read (usually the current pageSize).
    public func readCandidatePage(fromIndex: Int, count: Int, includeReadings: Bool = false) throws -> [RimeCandidate] {
        try queue.sync {
            // Protect both the C index conversion and the page reservation from malformed requests.
            guard fromIndex >= 0, fromIndex < Int(Int32.max),
                count > 0, count <= 1024, count <= Int(Int32.max) - fromIndex
            else {
                throw RimeEngineError.operationFailed(
                    "非法候选读取请求 fromIndex=\(fromIndex) count=\(count)")
            }
            guard engine != nil else { throw RimeEngineError.notStarted }
            guard session != 0, let api = rime_get_api() else {
                throw RimeEngineError.noSession
            }
            var iterator = RimeCandidateListIterator()
            guard api.pointee.candidate_list_from_index(session, &iterator, Int32(fromIndex)) != 0 else {
                // Only two causes remain: invalid session, or no menu in the Context.
                // get_status only reads session/schema/context; it never touches menu/commit/highlight.
                guard hasLiveStatusOnQueue(api: api) else { throw RimeEngineError.noSession }
                return []
            }
            defer { api.pointee.candidate_list_end(&iterator) }
            // Per-page-slot select metadata, read once from the LIVE schema. This
            // dedicated helper consumes no pending commit (unlike rb_snapshot_get)
            // and is page-independent, so every read-only page keeps the schema's
            // own slot labels. Undeclared stays nil; nothing is fabricated.
            let selectMetadata = contextSelectMetadataOnQueue()
            struct ReadingWire: Decodable {
                let paths: [[String]]
                let complete: Bool
            }
            let readingDecoder = includeReadings ? JSONDecoder() : nil
            var page: [RimeCandidate] = []
            page.reserveCapacity(count)
            while page.count < count {
                guard api.pointee.candidate_list_next(&iterator) != 0 else { break }
                let absoluteIndex = fromIndex + page.count
                var reading: ReadingWire?
                if let readingDecoder, let json = rb_copy_candidate_syllables_json(session, Int32(absoluteIndex)) {
                    defer { free(json) }
                    // Decoding copies every string out before the deferred free.
                    let bytes = Data(bytesNoCopy: json, count: strlen(json), deallocator: .none)
                    reading = try? readingDecoder.decode(ReadingWire.self, from: bytes)
                }
                var selectKey: String?
                var selectLabel: String?
                if let metadata = selectMetadata, metadata.pageSize > 0 {
                    let slot = absoluteIndex % metadata.pageSize
                    selectKey = metadata.selectKey(pageLocalIndex: slot)
                    selectLabel = metadata.selectLabel(pageLocalIndex: slot)
                }
                page.append(
                    RimeCandidate(
                        text: string(fromC: iterator.candidate.text) ?? "",
                        comment: iterator.candidate.comment.flatMap { string(fromC: $0) },
                        readingPaths: reading?.paths, readingsComplete: reading?.complete ?? false,
                        selectKey: selectKey, selectLabel: selectLabel))
            }
            return page
        }
    }

    /// Must run on `queue`. Read-only schema slot metadata for cross-page
    /// browsing. nil when the bridge cannot answer (no session/schema); an
    /// undeclared list decodes to nil slots, never a synthesized default.
    private func contextSelectMetadataOnQueue() -> RimePageSelectMetadata? {
        guard session != 0 else { return nil }
        guard let json = rb_copy_context_metadata_json(session) else { return nil }
        defer { free(json) }
        return RimePageSelectMetadata(json: Data(String(cString: json).utf8))
    }

    /// `RimeGetStatus` returns false only when session/context/schema is missing; it is
    /// read-only (builds no candidate page, consumes no commit, leaves highlight/page alone).
    /// Used only to tell "invalid session" from "no menu".
    func hasLiveStatusOnQueue(api: UnsafeMutablePointer<RimeApi>) -> Bool {
        guard session != 0 else { return false }
        var status = RimeStatus()
        status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_status(session, &status) != 0 else { return false }
        _ = api.pointee.free_status(&status)
        return true
    }

    private let storedSpellingDemand = OSAllocatedUnfairLock<(@Sendable () -> Bool)?>(initialState: nil)

    /// Composition display request, and the **fail-closed gate before decoding**. The
    /// front end (the active 14/9-key layout) installs this closure; only when it returns
    /// true while composing do `state()`, every action's `RimeState.highlightedSpelling`
    /// and `highlightedSpelling()` ask the engine for spelling (which triggers candidate
    /// decoding). When it returns false or is not installed (nil), there is zero candidate
    /// spelling decoding **even if the current schema carries an authorized
    /// `keyboard_adapter` capability block**: the block is never used to decode or to
    /// bypass this gate. When true, the existing `authorizedMode()` contract (version /
    /// mode / source / producer agreement) must still pass.
    /// The closure is evaluated on the engine's serial queue, so it sees the same snapshot
    /// as the candidate list; the failure fallback path also uses the current layout.
    /// Default nil = never request.
    public var spellingDemand: (@Sendable () -> Bool)? {
        get { storedSpellingDemand.withLock { $0 } }
        set { storedSpellingDemand.withLock { $0 = newValue } }
    }

    // MARK: - Schema

    @discardableResult
    public func selectSchema(_ schemaID: String) -> Bool {
        queue.sync {
            guard let engine = engine, session != 0, !snapshotRecoveryRequired else { return false }
            let ok = schemaID.withCString { idPtr in
                rb_select_schema(engine, session, idPtr) != 0
            }
            if ok {
                activeSchemaID = readCurrentSchemaIDOnQueue()
                invalidateDisplayContextOnQueue()
            }
            return ok
        }
    }

    // MARK: - Key input

    /// Feeds one key. Returns whether librime consumed the key plus the state
    /// after the key (see `RimeActionResult`).
    @discardableResult
    public func processKey(_ key: RimeKey) throws -> RimeActionResult {
        try queue.sync {
            try requireReadableSessionOnQueue()
            guard let engine else { throw RimeEngineError.notStarted }
            let consumed =
                rb_process_key(
                    engine, session, key.keycode, key.modifiers.rawValue
                ) != 0
            let state = try actionSnapshotOnQueue()
            return RimeActionResult(consumed: consumed, state: state)
        }
    }

    /// Feeds one key of a batch with the same effect on the session as
    /// `processKey`, but reads no state; call `actionState()` after the last key.
    public func feedKey(_ key: RimeKey) throws -> RimeKeyFeed {
        try queue.sync {
            try requireReadableSessionOnQueue()
            guard let engine else { throw RimeEngineError.notStarted }
            var result = rb_key_result()
            guard rb_process_key_brief(engine, session, key.keycode, key.modifiers.rawValue, &result) != 0 else {
                throw RimeEngineError.noSession
            }
            defer { rb_key_result_free(engine, &result) }
            return RimeKeyFeed(
                consumed: result.consumed != 0, isComposing: result.is_composing != 0,
                hasInput: result.has_input != 0, commitText: string(fromC: result.commit_text) ?? "")
        }
    }

    /// The state after keys fed with `feedKey`, with the same failure contract
    /// as an action's own read.
    public func actionState() throws -> RimeState {
        try queue.sync {
            try requireReadableSessionOnQueue()
            return try actionSnapshotOnQueue()
        }
    }

    /// Feeds a whole key sequence (letters/`{Return}`/`{BackSpace}` braces),
    /// same grammar as librime's `simulate_key_sequence`. Mostly for tests.
    @discardableResult
    public func processKeySequence(_ sequence: String) throws -> RimeActionResult {
        try queue.sync {
            try requireReadableSessionOnQueue()
            guard let engine else { throw RimeEngineError.notStarted }
            let consumed = sequence.withCString { seqPtr in
                rb_simulate_key_sequence(engine, session, seqPtr) != 0
            }
            let state = try actionSnapshotOnQueue()
            return RimeActionResult(consumed: consumed, state: state)
        }
    }

    /// Programmatic confirmation of the current composition. Unlike Return,
    /// this commits the composed candidate rather than a schema's raw-code action.
    @discardableResult
    public func commitComposition() throws -> RimeActionResult {
        try queue.sync {
            try requireReadableSessionOnQueue()
            guard let engine else { throw RimeEngineError.notStarted }
            let ok = rb_commit_composition(engine, session) != 0
            let state = try actionSnapshotOnQueue()
            return RimeActionResult(consumed: ok, state: state)
        }
    }

    // MARK: - Candidates & paging

    /// Selects the candidate at `index` (0-based) on the current page.
    @discardableResult
    public func selectCandidate(_ index: Int) -> RimeState? {
        queue.sync { () -> RimeState? in
            guard let engine = engine, session != 0, !snapshotRecoveryRequired else { return nil }
            guard index >= 0 else { return nil }
            guard rb_select_candidate_on_current_page(engine, session, index) != 0 else {
                return nil
            }
            return snapshotOnQueue()
        }
    }

    /// Selects a candidate by absolute index across pages (0-based).
    @discardableResult
    public func selectCandidateAbsolute(_ index: Int) -> RimeState? {
        queue.sync { () -> RimeState? in
            guard let engine = engine, session != 0, !snapshotRecoveryRequired, index >= 0 else { return nil }
            guard rb_select_candidate(engine, session, index) != 0 else {
                return nil
            }
            return snapshotOnQueue()
        }
    }

    @discardableResult
    public func pageForward() -> RimeState? {
        flipPage(backward: false)
    }

    @discardableResult
    public func pageBackward() -> RimeState? {
        flipPage(backward: true)
    }

    private func flipPage(backward: Bool) -> RimeState? {
        queue.sync { () -> RimeState? in
            guard let engine = engine, session != 0, !snapshotRecoveryRequired else { return nil }
            rb_change_page(engine, session, backward ? 1 : 0)
            return snapshotOnQueue()
        }
    }

    // MARK: - Editing

    /// Clears the current composition without committing.
    ///
    /// Best-effort void variant kept for callers that do not need a confirmed
    /// post-state (deployment/self-test teardown). The input-cancellation path
    /// must use `cancelComposition()` instead: this variant silently ignores a
    /// missing session and a failed state read, so it cannot authorize clearing
    /// host text.
    public func clearComposition() {
        queue.sync {
            guard let engine = engine, session != 0, !snapshotRecoveryRequired else { return }
            rb_clear_composition(engine, session)
        }
    }

    /// Cancels the current composition and returns a **validated** post-state,
    /// or throws. Unlike `clearComposition()` this never substitutes success:
    ///   * engine not started → `notStarted`;
    ///   * session/api unavailable or clear refused → `noSession`;
    ///   * the state read after the clear fails → `operationFailed`.
    ///
    /// Clear and the post-state read happen in the **same serial queue step** as
    /// the owning engine, so no other engine action can interleave between them.
    /// A read failure must never be folded into `.empty` (which would look like a
    /// successful non-composing state and grant the host a false clear license).
    public func cancelComposition() throws -> RimeState {
        try queue.sync {
            guard engine != nil else { throw RimeEngineError.notStarted }
            guard session != 0, let api = rime_get_api(), hasLiveStatusOnQueue(api: api) else {
                throw RimeEngineError.noSession
            }
            guard rb_clear_composition(engine, session) != 0 else {
                throw RimeEngineError.noSession
            }
            // ClearComposition does not clear Session's pending commit. Consume and
            // free it explicitly: cancellation never delivers an earlier failed action.
            var discarded = RimeCommit()
            discarded.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
            if api.pointee.get_commit(session, &discarded) != 0 {
                _ = api.pointee.free_commit(&discarded)
            }
            guard let state = snapshotOnQueue(recovering: true),
                !state.isComposing, state.input.isEmpty, state.commitText.isEmpty
            else {
                snapshotRecoveryRequired = true
                throw RimeEngineError.snapshotUnavailable
            }
            snapshotRecoveryRequired = false
            lastTrustedState = state.withoutCommit()
            return state
        }
    }

    #if SONGYAN_TEST_FAILPOINTS
        /// Test-only (see `testFailNextSnapshotOnQueue`). Arms a single forced
        /// snapshot-read failure, executed by the next `cancelComposition()` on the
        /// owning serial queue. Absent from app targets.
        public func armCancelSnapshotFailureForTesting() { armSnapshotFailureForTesting() }

        public func armSnapshotFailureForTesting() {
            queue.sync { testFailNextSnapshotOnQueue = true }
        }
    #endif

    // MARK: - Options (ascii_mode, full_shape, simplification, ...)

    public func setOption(_ option: String, value: Bool) {
        queue.sync {
            guard let engine = engine, session != 0, !snapshotRecoveryRequired else { return }
            _ = option.withCString { optPtr in
                rb_set_option(engine, session, optPtr, value ? 1 : 0)
            }
            explicitlySetOptions.insert(option)
        }
    }

    public func option(_ option: String) -> Bool {
        queue.sync {
            guard let engine = engine, session != 0 else { return false }
            return option.withCString { optPtr in
                rb_get_option(engine, session, optPtr) != 0
            }
        }
    }

    // MARK: - Private helpers (must run on `queue`)

    private func validatePrebuiltDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
            fm.fileExists(atPath: directory.appendingPathComponent("default.yaml").path)
        else {
            throw RimeEngineError.initializationFailed(
                "prebuilt build/default.yaml missing: \(directory.path); republish from the host App")
        }
        let schemas = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".schema.yaml") }
        guard !schemas.isEmpty else {
            throw RimeEngineError.initializationFailed("prebuilt directory has no compiled schemas: \(directory.path)")
        }
        // Only small YAML headers are read, never dictionary contents/userdb.
        // librime repeats its version marker on each compiled schema.
        for file in schemas {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let header = String(decoding: try handle.read(upToCount: 4096) ?? Data(), as: UTF8.self)
            guard header.contains("__build_info:"),
                header.range(of: #"(?m)^  rime_version: [\"']?1\.17\.0[\"']?\s*$"#, options: .regularExpression) != nil
            else {
                throw RimeEngineError.initializationFailed(
                    "prebuilt schema version mismatch (requires librime 1.17.0): \(file.lastPathComponent)")
            }
        }
    }
}

private func withOptionalCString<Result>(
    _ string: String?, _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let string else { return body(nil) }
    return string.withCString { body($0) }
}
