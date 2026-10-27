import Foundation
import KeyboardCore
import RimeBridge

/// RimeBridge adapter: narrows the standalone `RimeBridge.RimeEngine` to the `KeyboardCore.EngineBackend`
/// protocol this app consumes.
///
/// Design notes:
///  - KeyboardCore does not depend on the bridge module; this file lives in Apps/SharedKeyboard and is
///    compiled only by the app and keyboard extension targets.
///  - Key mapping: a single character (a-z/2-9) → `RimeKey(character:)`; `\u{08}` → backspace,
///    `" "` → space, `"\n"` → return, `"Esc"` → Esc (librime key-code space, see RimeKey).
///  - librime `consumed=false` means the keyboard handles the key itself (space/return/ASCII on an empty
///    composition commits directly); the adapter returns the text to commit in `committed`, and the front
///    end inserts it into the document without committing twice.
///  - Candidates/paging: the engine returns 0-based in-page candidates and the page; `selectCandidate` may
///    commit immediately (returning RimeState.commitText), which the adapter passes through exactly once;
///    callers must not commit again.
///  - State is snapshotted after each action; `currentSnapshot()` only reads the latest snapshot and does
///    not query engine state, so an idle query cannot swallow a pending commit.
// Mutable state is guarded by `lock` / `hostSessionLock`; engine calls are serialized on EngineOpQueue.
public final class RimeBackend: EngineBackend, @unchecked Sendable {

    public let kind: EngineBackendKind = .rime

    public let sharedDirectory: URL
    public let userDirectory: URL
    /// Read-only compiled resource directory (non-nil = prebuilt start: skip deployment; missing resources or
    /// a version mismatch fail the start outright, never falling back to a full deploy). Learning data is still
    /// written to `userDirectory`.
    public let prebuiltDirectory: URL?

    /// One short-held lock for all mutable state except the host session below.
    private let lock = NSLock()
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    /// Held across userdb resume/suspend so a queued resume is ordered against the
    /// synchronous host-loss close; kept apart so UI reads of state never wait on it.
    private let hostSessionLock = NSLock()
    private func hostLocked<T>(_ body: () -> T) -> T {
        hostSessionLock.lock()
        defer { hostSessionLock.unlock() }
        return body()
    }
    /// Set by `shutdown()`: late writers must not repopulate a closed backend.
    private var isShutDown = false
    private func update(_ body: () -> Void) { locked { if !isShutDown { body() } } }

    private var storedEngineVersion = "-"
    private var storedLastErrorText: String?
    /// librime version (valid after a successful start).
    public private(set) var engineVersion: String {
        get { locked { storedEngineVersion } }
        set { update { storedEngineVersion = newValue } }
    }
    /// Most recent error text (for UI/self-check display).
    public private(set) var lastErrorText: String? {
        get { locked { storedLastErrorText } }
        set { update { storedLastErrorText = newValue } }
    }
    private var storedInputUnavailableReason: String?
    public private(set) var inputUnavailableReason: String? {
        get {
            locked { storedInputUnavailableReason }
                ?? (rime?.requiresSnapshotRecovery == true
                    ? RimeEngineError.snapshotUnavailable.localizedDescription : nil)
        }
        set { locked { storedInputUnavailableReason = newValue } }
    }

    private var storedRime: RimeEngine?
    private var rime: RimeEngine? {
        get { locked { storedRime } }
        set { locked { storedRime = newValue } }
    }
    private var hostAppearanceToken: UUID?
    private var hostSessionReady = true
    private var hostSessionSuspended = false
    private var pendingHostRestoreState: RimeState?
    public var hostInputIsReady: Bool { hostLocked { hostSessionReady } }
    private var storedEnabledSchemas: [KeyboardSchemaDescriptor] = []
    private var enabledSchemas: [KeyboardSchemaDescriptor] {
        get { locked { storedEnabledSchemas } }
        set { update { storedEnabledSchemas = newValue } }
    }
    private let allowedSchemaIDs: Set<String>?
    private var storedLastState: RimeState = .empty
    private var storedActiveSchema = ""
    private var storedOptionDescriptors: [EngineOptionDescriptor] = []
    private var optionDescriptorCache: [String: [EngineOptionDescriptor]] = [:]
    private var sourceSchemaIDs: [String: String] = [:]
    /// `speller/alphabet` of each generated adapter. A host-added keyboard's adapter
    /// lives only in build/, never in schema_list, so `availableSchemas` lacks it.
    private var adapterAlphabets: [String: String] = [:]
    private var lastState: RimeState {
        get { locked { storedLastState } }
        set { publishState(newValue) }
    }
    private func publishState(_ state: RimeState) {
        update {
            storedLastState = state
            if !state.schemaID.isEmpty, state.schemaID != storedActiveSchema {
                storedActiveSchema = state.schemaID
                storedOptionDescriptors = optionDescriptorCache[state.schemaID] ?? []
            }
        }
    }
    private var activeSchema: String { locked { storedActiveSchema } }
    private let resourceID: String
    private let optionPreferences: OptionPreferenceCache?
    private var persistenceErrors: [OptionPreferenceKey: Error] = [:]
    public var optionPersistenceError: Error? { locked { persistenceErrors.values.first } }
    /// Delivered on the main actor after each option save finishes.
    public var onOptionPersistenceCompleted: (@MainActor (Error?) -> Void)?
    private let runtimeGrammarReceiptContext: GrammarRuntimeReceiptStore.Context?
    /// False while the shared container is read-only (a keyboard without Full Access):
    /// option choices then stay in memory and no receipt is written.
    private let sharedWritesAllowed: @Sendable () -> Bool
    private var optionDescriptors: [EngineOptionDescriptor] { locked { storedOptionDescriptors } }
    private func sourceSchemaID(_ id: String) -> String {
        locked { sourceSchemaIDs[id] ?? id }
    }
    private func cachedOptionDescriptors(for schemaID: String) -> [EngineOptionDescriptor] {
        locked { optionDescriptorCache[schemaID] ?? [] }
    }

    public init(
        sharedDirectory: URL, userDirectory: URL, prebuiltDirectory: URL? = nil,
        resourceID: String = "", optionStore: OptionStore? = nil,
        allowedSchemaIDs: Set<String>? = nil,
        runtimeGrammarReceiptContext: GrammarRuntimeReceiptStore.Context? = nil,
        sharedWritesAllowed: @escaping @Sendable () -> Bool = { true }
    ) {
        self.allowedSchemaIDs = allowedSchemaIDs
        self.sharedDirectory = sharedDirectory
        self.userDirectory = userDirectory
        self.prebuiltDirectory = prebuiltDirectory
        self.resourceID = resourceID
        self.optionPreferences = optionStore.map { OptionPreferenceCache(store: $0, persists: sharedWritesAllowed) }
        self.runtimeGrammarReceiptContext = runtimeGrammarReceiptContext
        self.sharedWritesAllowed = sharedWritesAllowed
    }

    public func startIfNeeded() throws {
        guard rime == nil else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sharedDirectory.path) else {
            throw EngineBackendError.setupFailed("方案资源目录不存在: \(sharedDirectory.path)")
        }
        // Missing prebuilt resources fail explicitly here (the engine-side check would also catch it; failing early
        // gives a clearer error), never silently degrading to a full deploy.
        if let prebuilt = prebuiltDirectory {
            guard fm.fileExists(atPath: prebuilt.appendingPathComponent("default.yaml").path) else {
                throw EngineBackendError.setupFailed(
                    "缺少已编译的方案资源: \(prebuilt.path)，请打开「松烟」App 重新构建方案")
            }
        }
        do {
            try fm.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        } catch {
            throw EngineBackendError.setupFailed("无法创建用户词库存储目录: \(error)")
        }

        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: sharedDirectory,
                userDirectory: userDirectory,
                appName: "rime.songyan",
                prebuiltDirectory: prebuiltDirectory
            ))
        locked { isShutDown = false }
        do {
            try engine.start()
        } catch {
            lastErrorText = "\(error)"
            throw EngineBackendError.setupFailed("\(error)")
        }
        let directory = prebuiltDirectory ?? userDirectory.appendingPathComponent("build")
        let adapters = KeyboardResourceSet.readEncodingAdapters(build: directory)
        let mapping = Dictionary(
            adapters.map { ($0.schemaID, $0.sourceSchemaID) }, uniquingKeysWith: { first, _ in first })
        let alphabets = Dictionary(
            adapters.map { ($0.schemaID, engine.schemaValue($0.schemaID, key: "speller/alphabet") ?? "") },
            uniquingKeysWith: { first, _ in first })
        let schemas = engine.schemas().filter { (try? engine.validateSchemaPrerequisites(schemaID: $0.id)) != nil }
            .map {
                KeyboardSchemaDescriptor(
                    id: $0.id, name: $0.name,
                    alphabet: engine.schemaValue($0.id, key: "speller/alphabet") ?? "")
            }
        let state: RimeState
        do { state = try Self.verifiedState(from: engine) } catch {
            engine.shutdown()
            throw error
        }
        let descriptorIDs = Set(schemas.map(\.id)).union(adapters.map(\.schemaID)).union([state.schemaID])
        var descriptors: [String: [EngineOptionDescriptor]] = [:]
        if !resourceID.isEmpty {
            // Adapters share their source schema's file; parse each file once.
            var bySource: [String: [EngineOptionDescriptor]] = [:]
            for id in descriptorIDs where !id.isEmpty {
                let source = mapping[id] ?? id
                if let read = bySource[source] {
                    descriptors[id] = read
                    continue
                }
                let read = SchemaOptionCapabilities.read(
                    resourceID: resourceID, schemaID: source,
                    compiledDirectory: directory, sharedDirectory: sharedDirectory)
                bySource[source] = read
                descriptors[id] = read
            }
        }
        optionPreferences?.preload(descriptors.values.flatMap { $0 })
        locked {
            sourceSchemaIDs = mapping
            adapterAlphabets = alphabets
            optionDescriptorCache = descriptors
            storedActiveSchema = ""
            storedOptionDescriptors = []
            storedLastState = .empty
        }
        rime = engine
        // A composition display request may have been installed by `InputSession` before start; install it here too.
        engine.spellingDemand = spellingDemand
        enabledSchemas = schemas
        engineVersion = engine.engineVersion
        lastState = state
        hostLocked {
            hostSessionSuspended = false
            pendingHostRestoreState = nil
            hostSessionReady = true
        }
    }

    /// Claim the host before scheduling a resume, invalidating older controllers.
    public func beginHostAppearance() -> UUID {
        hostLocked {
            let token = UUID()
            hostAppearanceToken = token
            hostSessionReady = !hostSessionSuspended && pendingHostRestoreState == nil
            return token
        }
    }

    private func acceptHostResume(_ token: UUID, state: RimeState?) -> Bool {
        hostLocked {
            guard hostAppearanceToken == token else { return false }
            if state != nil { pendingHostRestoreState = nil }
            hostSessionReady = state != nil || !hostSessionSuspended
            return true
        }
    }

    /// EngineOpQueue orders this against boot/shutdown. The lock also orders it
    /// against the synchronous host-loss close, including a queued stale request.
    @MainActor
    @discardableResult
    public func resumeSessionForHostAppearance(token: UUID) async -> Bool {
        do {
            let descriptors = locked { optionDescriptorCache.values.flatMap { $0 } }
            if let refresh = optionPreferences?.beginRefresh(descriptors) { try await refresh.value }
            let state: RimeState? = try await EngineOpQueue.async { [self] in
                hostSessionLock.lock()
                defer { hostSessionLock.unlock() }
                guard hostAppearanceToken == token else { return nil }
                if let pendingHostRestoreState { return pendingHostRestoreState }
                guard hostSessionSuspended, let rime else { return nil }
                if try rime.resumeSession() {
                    hostSessionSuspended = false
                    let state = try Self.verifiedState(from: rime)
                    pendingHostRestoreState = state
                    return state
                }
                if rime.isRunning { hostSessionSuspended = false }
                return nil
            }
            guard acceptHostResume(token, state: state) else { return false }
            if let state { lastState = state }
            if optionPreferences != nil, let engine = rime, hostInputIsReady {
                // Back on the UI actor: no key/schema action can interleave this
                // cached restore with the snapshot publication. No disk access here.
                restoreCachedOptions(on: engine)
                lastState = try Self.verifiedState(from: engine)
                if state != nil { inputUnavailableReason = nil }
                return true
            }
            if state != nil {
                inputUnavailableReason = nil
                lastErrorText = nil
                return true
            }
            return false
        } catch {
            guard acceptHostResume(token, state: nil) else { return false }
            let reason = "用户词库恢复失败：\(error)"
            inputUnavailableReason = reason
            lastErrorText = reason
            lastState = .empty
            return false
        }
    }

    /// The userdb LOCK must be released before the disappear callback returns.
    /// An unawaited async suspend would leave it held across iOS suspension.
    @discardableResult
    public func suspendSessionForHostDisappearance() -> Bool {
        hostSessionLock.lock()
        defer { hostSessionLock.unlock() }
        hostAppearanceToken = nil
        hostSessionReady = false
        let suspended = rime?.suspendSession() ?? false
        hostSessionSuspended = hostSessionSuspended || suspended
        pendingHostRestoreState = nil
        lastState = .empty
        return suspended
    }

    // MARK: EngineBackend

    public func setup(sharedDirectory: URL, userDirectory: URL) throws {
        try startIfNeeded()
    }

    public func selectSchema(_ schemaID: String) throws {
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        try requireEnabled(schemaID)
        let previousSchema = engine.currentSchemaID
        let previousOptions = optionDescriptors.map { ($0.name, engine.option($0.name)) }
        do {
            // Dependency closure, registry components and grammar prerequisites, then select and confirm the
            // live grammar instance. It can fail before or after the select, so both paths restore the previous schema.
            try engine.validateSchemaForActivation(schemaID: schemaID)
        } catch {
            var detail = error.localizedDescription
            do {
                guard let previousSchema else {
                    throw EngineBackendError.operationFailed("没有可恢复的上一方案")
                }
                // A select Bool alone does not establish a live grammar instance.
                try engine.validateSchemaForActivation(schemaID: previousSchema)
                recordRuntimeGrammarReceipt(engine: engine, schemaID: previousSchema)
                for (name, value) in previousOptions {
                    engine.setOption(name, value: value)
                }
                inputUnavailableReason = nil
            } catch {
                detail +=
                    "；恢复上一输入方案失败：\(error.localizedDescription)；当前输入方案为 \(engine.currentSchemaID ?? "未知")，输入功能已停用，请重试以恢复输入"
                inputUnavailableReason = detail
            }
            lastState = engine.state()
            lastErrorText = detail
            throw EngineBackendError.operationFailed(detail)
        }
        inputUnavailableReason = nil
        update { storedActiveSchema = schemaID }
        recordRuntimeGrammarReceipt(engine: engine, schemaID: schemaID)
        let descriptors = cachedOptionDescriptors(for: schemaID)
        update { storedOptionDescriptors = descriptors }
        // Restoration errors are reported without pretending the schema selection failed.
        // The controller exposes this message while keeping the real active schema.
        restoreCachedOptions(on: engine)
        lastState = try Self.verifiedState(from: engine)
    }

    private func restoreCachedOptions(on engine: RimeEngine) {
        lastErrorText = nil
        do {
            for descriptor in optionDescriptors {
                if let value = try optionPreferences?.value(for: descriptor) {
                    engine.setOption(descriptor.name, value: value)
                }
            }
        } catch { lastErrorText = "选项恢复失败：\(error)" }
    }

    private func recordRuntimeGrammarReceipt(engine: RimeEngine, schemaID: String) {
        guard let context = runtimeGrammarReceiptContext, sharedWritesAllowed() else { return }
        // Activation already rejected a configured-but-unloaded model. Re-read the exact live
        // association to obtain its language; a receipt write is diagnostic and must not make a
        // working keyboard fail if the App Group becomes unavailable after startup.
        let language: String?
        do { language = try engine.loadedGrammarLanguage(schemaID: schemaID) } catch { return }
        let sourceID = sourceSchemaID(schemaID)
        _ = OptionPersistenceIO.enqueue {
            try? GrammarRuntimeReceiptStore.record(
                context: context,
                sourceSchemaID: sourceID, runtimeSchemaID: schemaID,
                loadedLanguage: language)
        }
    }

    private func requireEnabled(_ schemaID: String) throws {
        let sourceID = sourceSchemaID(schemaID)
        guard enabledSchemas.contains(where: { $0.id == sourceID }),
            allowedSchemaIDs?.contains(sourceID) != false
        else {
            throw EngineBackendError.unsupportedSchema("输入方案 \(schemaID) 不在当前已启用的列表中，已保留当前输入。")
        }
    }

    /// Read-only pre-check for menus; selecting does its own check once.
    public func validateSchema(_ schemaID: String) throws {
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        try requireEnabled(schemaID)
        try engine.validateSchemaPrerequisites(schemaID: schemaID)
    }

    public var availableSchemas: [KeyboardSchemaDescriptor] {
        rime == nil ? [] : enabledSchemas
    }

    /// The running schema's `speller/alphabet`, generated adapters included; read at start.
    public func spellerAlphabet(schemaID: String) -> String? {
        guard rime != nil else { return nil }
        return locked { adapterAlphabets[schemaID] } ?? enabledSchemas.first { $0.id == schemaID }?.alphabet
    }

    public func optionStates() throws -> [EngineOptionState] {
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        return optionDescriptors.map { .init(descriptor: $0, value: engine.option($0.name)) }
    }

    public func setOption(_ name: String, value: Bool) throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        guard let descriptor = optionDescriptors.first(where: { $0.name == name }) else {
            throw EngineBackendError.operationFailed("当前输入方案不支持选项 \(name)")
        }
        engine.setOption(name, value: value)
        // librime's option notification refreshes the context without synthetic keys.
        lastState = try Self.verifiedState(from: engine)
        guard let optionPreferences else {
            throw EngineBackendError.operationFailed("选项已生效，但未设置存储目录，无法保存")
        }
        let key = OptionPreferenceKey(descriptor)
        let saving = optionPreferences.beginSave(value, for: descriptor)
        locked { persistenceErrors[key] = nil }
        Task { @MainActor [weak self] in
            guard let outcome = try? await saving.value, outcome.isCurrent, let self,
                !self.locked({ self.isShutDown })
            else { return }
            let error: Error?
            if case .failure(let failure) = outcome.result { error = failure } else { error = nil }
            self.locked { self.persistenceErrors[key] = error }
            self.lastErrorText = error.map { "选项已生效，但保存失败：\($0.localizedDescription)" }
            self.onOptionPersistenceCompleted?(error)
        }
        lastErrorText = nil
        return currentSnapshot()
    }

    public func processKey(_ keyValue: String) throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        guard let key = Self.rimeKey(for: keyValue) else {
            return currentSnapshot()
        }
        // Post-commit prediction is not a composition: every key first closes it, then
        // runs with idle semantics (space inserts a space, digits never pick a word).
        if Self.isPrediction(lastState), keyValue != "Esc" {
            try dismissPredictionOnEngine(engine)
        }
        let result: RimeActionResult
        do { result = try engine.processKey(key) } catch {
            lastErrorText = error.localizedDescription
            throw error
        }
        try requireAvailableInput()
        publishState(result.state)

        var snap = Self.snapshot(from: result.state)
        applyDisplay(&snap, from: result.state)
        if !result.state.commitText.isEmpty {
            return snap  // the commit is already in the commit text, exactly once
        }
        // librime did not consume the key: the keyboard handles it.
        if !result.consumed && !result.state.isComposing {
            if let literal = Self.literalForUnconsumed(keyValue) {
                snap.committed = literal
            }
        }
        return snap
    }

    /// `processKey` per key, but librime is asked only for what the next key depends
    /// on (consumed, composing, empty input, commit text) and the full state is read
    /// once at the end. Commits are consumed key by key so unconsumed-key literals
    /// keep their place among them.
    public func processKeys(_ keys: [String], gate: any EngineKeyGate) -> EngineKeyBatch {
        var batch = EngineKeyBatch()
        var committed = ""
        var committedBeforeLastKey = ""
        var predicting: Bool?
        var fed = false
        for keyValue in keys {
            do {
                let admitted = try gate.admit {
                    committedBeforeLastKey = committed
                    try requireAvailableInput()
                    guard let engine = rime else { throw EngineBackendError.engineNotStarted }
                    guard let key = Self.rimeKey(for: keyValue) else { return }
                    if predicting ?? Self.isPrediction(lastState), keyValue != "Esc" {
                        try closePrediction(on: engine)
                    }
                    let result: RimeKeyFeed
                    do { result = try engine.feedKey(key) } catch {
                        lastErrorText = error.localizedDescription
                        throw error
                    }
                    fed = true
                    try requireAvailableInput()
                    predicting = result.isComposing && !result.hasInput
                    if !result.commitText.isEmpty {
                        committed += result.commitText
                    } else if !result.consumed && !result.isComposing, let literal = Self.literalForUnconsumed(keyValue)
                    {
                        committed += literal
                    }
                }
                guard admitted else { break }
                batch.processed += 1
            } catch {
                batch.error = error
                break
            }
        }
        guard batch.processed > 0 else { return batch }
        gate.settle {
            // After a failure no state was read past the last one published.
            var snap = currentSnapshot()
            if batch.error == nil, fed, let engine = rime {
                do {
                    let state = try engine.actionState()
                    publishState(state)
                    snap = Self.snapshot(from: state)
                    applyDisplay(&snap, from: state)
                } catch {
                    // As when the last key's own read fails: that key and its commit are not delivered.
                    lastErrorText = error.localizedDescription
                    batch.error = error
                    batch.processed -= 1
                    committed = committedBeforeLastKey
                }
            }
            snap.committed = committed + snap.committed
            batch.snapshot = batch.processed > 0 ? snap : nil
        }
        return batch
    }

    public func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        guard let state = engine.selectCandidate(index) else {
            lastErrorText = "选择候选字词失败（索引 \(index) 返回空）"
            throw EngineBackendError.operationFailed("选择候选字词失败（索引 \(index)）")
        }
        lastState = state
        var snap = Self.snapshot(from: state)
        applyDisplay(&snap, from: state)
        return snap  // commitText passed through once
    }

    /// Selects by cross-page absolute index (0-based, global). After the front end shows multi-page candidates
    /// continuously, it commits precisely through this: it goes straight to librime's `select_candidate`, is not
    /// limited to the current page, and never mistakes a concatenated index for an in-page one. No need to turn
    /// the page first.
    public func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        guard let state = engine.selectCandidateAbsolute(index) else {
            lastErrorText = "绝对索引选择候选字词失败（索引 \(index) 返回空）"
            throw EngineBackendError.operationFailed("绝对索引选择候选字词失败（索引 \(index)）")
        }
        lastState = state
        var snap = Self.snapshot(from: state)
        applyDisplay(&snap, from: state)
        return snap
    }

    /// The real engine supports read-only cross-page candidate fetch (the candidate-list iterator works by offset, without changing page/highlight).
    public var supportsReadOnlyBrowsing: Bool { true }

    /// Reads a range of candidates read-only (absolute index offset). The returned `Candidate.index` is the
    /// in-page ordinal (0-based), consistent with `selectCandidateAbsolute(pageIndex*pageSize + index)`.
    /// It does not modify `lastState`, produce a commit, or trigger marked.
    ///
    /// Errors and EOF are kept apart: an unavailable engine or a failed read → `throw` (retryable, never an
    /// empty page); a successful empty/short page = real EOF, a normal end.
    public func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        guard fromIndex >= 0, count > 0 else {
            throw EngineBackendError.operationFailed(
                "候选读取请求参数无效 fromIndex=\(fromIndex) count=\(count)")
        }
        return try engine.readCandidatePage(fromIndex: fromIndex, count: count)
            .enumerated().map {
                Candidate(
                    index: $0.offset, text: $0.element.text,
                    comment: $0.element.comment ?? "",
                    selectKey: $0.element.selectKey, selectLabel: $0.element.selectLabel)
            }
    }

    public func wordCompletionSchemas(sourceSchemaID: String) throws -> [String] {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        return engine.wordCompletionSchemas(sourceSchemaID: sourceSchemaID)
    }

    public func releaseWordCompletions() { rime?.releaseWordCompletions() }

    public func wordCompletions(prefix: String, schemaID: String, limit: Int) throws -> [String]? {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        return engine.wordCompletions(prefix: prefix, schemaID: schemaID, limit: limit)
    }

    public func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        return try engine.readCandidatePage(fromIndex: fromIndex, count: count, includeReadings: true)
            .enumerated().map {
                ReadingCandidate(
                    index: fromIndex + $0.offset, text: $0.element.text,
                    readingPaths: $0.element.readingPaths,
                    readingsComplete: $0.element.readingsComplete,
                    comment: $0.element.comment ?? "",
                    selectKey: $0.element.selectKey,
                    selectLabel: $0.element.selectLabel)
            }
    }

    public func verifiedHighlightedReading(
        absoluteIndex: Int, expectedText: String,
        physicalLayoutEligible: Bool
    ) throws -> String? {
        guard physicalLayoutEligible else { return nil }
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        let reading = engine.verifiedHighlightedReading(
            absoluteIndex: absoluteIndex, expectedText: expectedText,
            physicalLayoutEligible: physicalLayoutEligible)
        #if DEBUG
            if reading == nil {
                engine.debugExplainReadingRefusal(absoluteIndex: absoluteIndex, expectedText: expectedText)
            }
        #endif
        return reading
    }

    public func nextPage() throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        if let state = engine.pageForward() {
            lastState = state
            var snap = Self.snapshot(from: state)
            applyDisplay(&snap, from: state)
            return snap
        }
        try requireAvailableInput()
        return currentSnapshot()
    }

    public func previousPage() throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        if let state = engine.pageBackward() {
            lastState = state
            var snap = Self.snapshot(from: state)
            applyDisplay(&snap, from: state)
            return snap
        }
        try requireAvailableInput()
        return currentSnapshot()
    }

    public func currentSnapshot() -> EngineSnapshot {
        // commitText is a one-shot description: only the action snapshot that produced it (processKey/selectCandidate)
        // passes it up; any later state query must not carry that commit again (it would commit twice).
        let state = lastState
        var snap = Self.snapshot(from: state)
        applyDisplay(&snap, from: state)
        snap.committed = ""
        return snap
    }

    /// Dismisses post-commit prediction: Esc goes to the schema (librime-predict's predictor dismisses on Esc and
    /// does not immediately predict again); only if the schema does not handle it, falls back to an unconditional
    /// clear. Produces no commit.
    public func dismissPrediction() throws -> EngineSnapshot {
        try requireAvailableInput()
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        try dismissPredictionOnEngine(engine)
        var snapshot = currentSnapshot()
        snapshot.committed = ""
        return snapshot
    }

    private func dismissPredictionOnEngine(_ engine: RimeEngine) throws {
        guard Self.isPrediction(lastState) else { return }
        try closePrediction(on: engine)
    }

    private func closePrediction(on engine: RimeEngine) throws {
        var state = try engine.processKey(RimeKey(keycode: RimeKeyCode.keyEscape)).state
        if Self.isPrediction(state) { state = try engine.cancelComposition() }
        lastState = state
        guard !state.isComposing else {
            throw EngineBackendError.operationFailed("未能收起联想候选")
        }
    }

    /// librime reports a composition whose input is empty only for placeholder
    /// segments such as librime-predict's post-commit prediction.
    static func isPrediction(_ state: RimeState) -> Bool {
        state.isComposing && state.input.isEmpty
    }

    /// Cancels the current composition (without committing). Public so self-checks/upper layers can clear at a safe point.
    public func clearComposition() {
        guard let engine = rime else { return }
        engine.clearComposition()
        lastState = engine.state()
    }

    /// `EngineBackend.cancelComposition()`: goes through librime's dedicated `clear_composition`,
    /// （`Session::ClearComposition` → `Context::AbortComposition` → `Context::Clear`），
    /// which clears the composition unconditionally and never commits. Unlike a synthesized `Esc`, it is not
    /// affected by schema editor semantics: librime `Editor::CancelComposition`, when a previous segment exists
    /// (remaining syllables keep composing after a partial commit), only rolls back that segment
    /// (`ClearPreviousSegment` in `context.cc`) and the composition survives.
    ///
    /// Must use the throwing `RimeEngine.cancelComposition()`: it performs the clear and the post-state read in
    /// one serial owner step, and throws whenever the session/api is unavailable or the read fails, never
    /// substituting `.empty` for success. `lastState` is updated only after a successful read; on a throw it
    /// keeps the last trusted state, and the returned snapshot has `committed` emptied so callers keep the
    /// "cancel never commits" guarantee.
    public func cancelComposition() throws -> EngineSnapshot {
        guard hostInputIsReady else { throw EngineBackendError.notReady }
        guard let engine = rime else { throw EngineBackendError.engineNotStarted }
        // Cancellation is the explicit recovery path; the unread-snapshot gate
        // must block ordinary input, not the action that drains its pending commit.
        if !engine.requiresSnapshotRecovery { try requireAvailableInput() }
        let state = try engine.cancelComposition()
        lastState = state
        lastErrorText = nil
        var snapshot = Self.snapshot(from: state)
        applyDisplay(&snapshot, from: state)
        snapshot.committed = ""
        return snapshot
    }

    #if SONGYAN_TEST_FAILPOINTS
        /// Test-only bridge (macOS real-engine harness): force the next post-clear
        /// state read to fail. Never compiled into app targets.
        public func armCancelSnapshotFailureForTesting() {
            rime?.armCancelSnapshotFailureForTesting()
        }
        public func armSnapshotFailureForTesting() {
            rime?.armSnapshotFailureForTesting()
        }
    #endif

    public func shutdown() {
        hostLocked {
            hostAppearanceToken = nil
            hostSessionReady = false
            hostSessionSuspended = false
            pendingHostRestoreState = nil
        }
        let engine: RimeEngine? = locked {
            isShutDown = true
            storedEnabledSchemas = []
            storedLastState = .empty
            storedActiveSchema = ""
            storedOptionDescriptors = []
            optionDescriptorCache = [:]
            sourceSchemaIDs = [:]
            adapterAlphabets = [:]
            persistenceErrors = [:]
            storedEngineVersion = "-"
            storedLastErrorText = nil
            return storedRime
        }
        engine?.shutdown()
        locked {
            storedRime = nil
            storedInputUnavailableReason = nil
        }
    }

    private func requireAvailableInput() throws {
        guard hostInputIsReady else { throw EngineBackendError.notReady }
        if let inputUnavailableReason { throw EngineBackendError.operationFailed(inputUnavailableReason) }
    }

    /// state() can return an old observation after a failed native read. Never
    /// publish that fallback as the successful result of an action or activation.
    private static func verifiedState(from engine: RimeEngine) throws -> RimeState {
        let state = engine.state()
        guard !engine.requiresSnapshotRecovery else { throw RimeEngineError.snapshotUnavailable }
        return state
    }

    public var statusSummary: String {
        "RimeBridge(RimeEngine) librime=\(engineVersion) schema=\(activeSchema.isEmpty ? "?" : activeSchema) user=\(userDirectory.lastPathComponent)"
    }

    // MARK: Internal

    private static func rimeKey(for value: String) -> RimeKey? {
        switch value {
        case "\u{08}": return .backspace
        case "\n": return .return
        case "Esc": return RimeKey(keycode: RimeKeyCode.keyEscape)
        case " ": return .space
        default:
            guard value.count == 1, let ch = value.first else { return nil }
            return RimeKey(character: ch)
        }
    }

    private static func literalForUnconsumed(_ keyValue: String) -> String? {
        switch keyValue {
        case " ": return " "
        case "\n": return "\n"
        case "Esc": return nil
        default:
            // Single ASCII character (e.g. letters/digits typed directly on an empty composition)
            guard keyValue.count == 1 else { return nil }
            return keyValue
        }
    }

    static func snapshot(from state: RimeState) -> EngineSnapshot {
        var candidates: [Candidate] = []
        candidates.reserveCapacity(state.candidates.count)
        for (i, c) in state.candidates.enumerated() {
            candidates.append(
                Candidate(
                    index: i, text: c.text, comment: c.comment ?? "",
                    selectKey: c.selectKey, selectLabel: c.selectLabel))
        }
        let prediction = isPrediction(state)
        let preedit = prediction ? "" : (state.preedit.isEmpty ? state.input : state.preedit)
        var snapshot = EngineSnapshot(
            committed: state.commitText,
            candidates: candidates,
            preedit: preedit,
            rawInput: state.input,
            isComposing: state.isComposing && !prediction,
            highlightedIndex: state.highlightedIndex,
            pageIndex: state.pageIndex,
            pageSize: state.pageSize,
            isLastPage: state.isLastPage
        )
        snapshot.schemaID = state.schemaID
        snapshot.isPrediction = prediction && !candidates.isEmpty
        snapshot.commitTextPreview = state.commitTextPreview
        snapshot.isAsciiMode = state.isAsciiMode
        // A schema that DECLARES the 9-key `canonical` capability encodes its preedit
        // as an internal numeric transport code. Mark it here, independently of the
        // authorization/demand gate, so a not-yet-authorized or not-yet-demanded
        // snapshot can never echo that code as the user's composition
        // (`CompositionDisplayPolicy.applied` ORs in the authorized case).
        snapshot.hidesNumericTransportCode = state.declaredDisplayMode == .canonical
        snapshot.isFullShape = state.isFullShape
        snapshot.isAsciiPunct = state.isAsciiPunct
        snapshot.preeditSelStart = state.preeditSelStart
        snapshot.preeditSelEnd = state.preeditSelEnd
        snapshot.preeditCaretByte = state.preeditCursor
        snapshot.highlightedSpelling = state.highlightedSpelling
        snapshot.displayMode = Self.mapDisplayMode(state.displayMode)
        let byteOffset =
            state.preedit.isEmpty ? preedit.utf8.count : min(max(0, state.preeditCursor), preedit.utf8.count)
        var prefixBytes = Array(preedit.utf8.prefix(byteOffset))
        while !prefixBytes.isEmpty && String(bytes: prefixBytes, encoding: .utf8) == nil { prefixBytes.removeLast() }
        let prefix = String(bytes: prefixBytes, encoding: .utf8) ?? ""
        snapshot.preeditSelection = NSRange(location: min(prefix.utf16.count, preedit.utf16.count), length: 0)
        return snapshot
    }

    /// Resolves the highlighted-segment display through the ACTIVE schema's
    /// capability. RimeEngine already made the single authorization decision
    /// (strict version/mode/source/producer agreement, before any
    /// decode); this applies the production `CompositionDisplayPolicy` (missing /
    /// ambiguous token -> native) and returns the exact outcome. Used by the
    /// runtime and by the installer's display verification, so both share one
    /// path. Never touches `rawInput`/`preedit`/`sel`.
    struct ResolvedDisplay {
        let snapshot: EngineSnapshot
        let outcome: CompositionDisplayOutcome
        let capability: SchemaDisplayCapability?
    }

    static func resolvedDisplay(base: EngineSnapshot, from state: RimeState) -> ResolvedDisplay {
        let capability: SchemaDisplayCapability? = {
            guard state.displayMode != .native,
                let cap = state.displayCapability.flatMap({ SchemaDisplayCapability(wire: $0.wireDictionary) }),
                cap.mode == Self.mapDisplayMode(state.displayMode)
            else { return nil }
            return cap
        }()
        let applied = CompositionDisplayPolicy.applied(
            to: base,
            canonicalSyllables: state.highlightedSyllables,
            capability: capability,
            hasCapability: state.hasDisplayCapability)
        return ResolvedDisplay(
            snapshot: applied.snapshot, outcome: applied.outcome,
            capability: capability)
    }

    private func applyDisplay(_ snapshot: inout EngineSnapshot, from state: RimeState) {
        snapshot = Self.resolvedDisplay(base: snapshot, from: state).snapshot
    }

    private static func mapDisplayMode(_ mode: RimeDisplayMode) -> CompositionDisplayMode {
        switch mode {
        case .native: return .native
        case .canonical: return .canonical
        case .sourceCode: return .sourceCode
        case .sourceRendered: return .sourceRendered
        }
    }

    /// Composition display request: forwarded to the engine and evaluated on the serial queue against the actual
    /// layout, so candidates and spelling are produced together and the failure fallback also uses the actual
    /// layout. `InputSession` installs it for the actual layout; held until start and installed then. Default nil =
    /// a plain 26 layout produces no candidate probing/decoding.
    public var spellingDemand: (@Sendable () -> Bool)? {
        didSet { rime?.spellingDemand = spellingDemand }
    }

    // MARK: Composition spelling disambiguation (RimeBridge report/outcome → KeyboardCore value types)

    public func ambiguitySpellings() throws -> AmbiguitySpellingsReport? {
        guard let rime else { throw EngineBackendError.notReady }
        guard let report = rime.ambiguitySpellings() else { return nil }
        let mode: AmbiguityLockMode = {
            switch report.lockMode {
            case .none: return .none
            case .tokenAlias: return .tokenAlias
            case .directToken: return .directToken
            case .prefixToken: return .prefixToken
            }
        }()
        return AmbiguitySpellingsReport(
            revisionInput: report.revisionInput,
            segment: report.segment.start..<report.segment.end,
            options: report.lockable,
            allSpellings: report.spellings,
            lockMode: mode,
            isComplete: report.complete,
            prefixOptions: report.prefixOptions,
            optionSemantics: report.optionSemantics)
    }

    public func applyAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        option: String
    ) throws -> AmbiguityApplyOutcome {
        try requireAvailableInput()
        guard let rime else { throw EngineBackendError.notReady }
        let result = rime.applyAmbiguitySpelling(
            expectedInput: expectedInput, segmentStart: segment.lowerBound,
            segmentEnd: segment.upperBound, spelling: option)
        // Refresh the cached engine state so a following currentSnapshot() reflects
        // the rewrite (mirrors processKey; never commits).
        lastState = try Self.verifiedState(from: rime)
        return Self.mapOutcome(result)
    }

    public func restoreAmbiguitySpelling(
        expectedInput: String, segment: Range<Int>,
        expectedOption: String,
        reducedCode: String
    ) throws -> AmbiguityApplyOutcome {
        try requireAvailableInput()
        guard let rime else { throw EngineBackendError.notReady }
        let result = rime.restoreAmbiguitySpelling(
            expectedInput: expectedInput, segmentStart: segment.lowerBound,
            segmentEnd: segment.upperBound, expectedSpelling: expectedOption,
            reducedCode: reducedCode)
        lastState = try Self.verifiedState(from: rime)
        return Self.mapOutcome(result)
    }

    static func mapOutcome(_ result: RimeAmbiguityApplyResult) -> AmbiguityApplyOutcome {
        switch result {
        case .applied: return .applied
        case .stale: return .stale
        case .unsupported: return .unsupported
        case .invalid: return .invalid
        case .failed: return .failed
        case .failedRollbackUnverified: return .failedRollbackUnverified
        }
    }
}
