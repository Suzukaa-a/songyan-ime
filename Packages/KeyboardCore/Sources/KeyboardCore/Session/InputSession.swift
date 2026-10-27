import Foundation
import os

// MARK: - Input session (consumer-side state machine)
//
// Holds an EngineBackend and the current layout, translates keycap actions into engine
// calls and broadcasts state. Both the host app's typing area and the KeyboardExtension's
// UIInputViewController use it directly so behavior matches. UI must never mutate engine
// state directly; everything goes through this session.

/// Input mode: Chinese composition / English (ASCII) direct input.
public enum InputMode: Equatable, Sendable {
    /// Chinese: letter/digit codes go to the engine for composition (default).
    case chinese
    /// English: letters/digits/space/return/symbols are committed directly, bypassing the engine and composition.
    case english
}

/// A serial queue that owns engine work off the main thread (the keyboard's engine
/// operation queue).
public protocol EngineWorkQueue: AnyObject {
    func async(_ work: @escaping @Sendable () -> Void)
}

@MainActor
public final class InputSession {
    public let engine: EngineBackend
    public private(set) var layout: KeyboardLayoutKind
    public private(set) var selectedSchemaID: String
    public private(set) var mode: InputMode = .chinese
    public private(set) var snapshot: EngineSnapshot = EngineSnapshot()
    public private(set) var options: [EngineOptionState] = []
    /// Real engine-state version, incremented on every `apply` (real engine action/refresh).
    /// The host uses it as part of the candidate-set identity so that a set with the same raw
    /// code is invalidated when options/reconversion/learning/session change. Read-only
    /// browsing (readCandidatePage) does not increment it.
    public private(set) var compositionRevision = 0
    /// Whether the current physical definition is proven to support compact spelling
    /// (composition disambiguation / read-only reading browse).
    ///
    /// Injected by the front end after computing it from the real `LayoutDefinition`
    /// structure (`CompactSpellingLayout`). Defaults to false (fail closed): until injected, no
    /// layout kind reaches `ambiguitySpellings()` / `readCandidatesWithReadings(...)` /
    /// `applyAmbiguityOption(...)` / `restoreAmbiguity(...)`.
    /// This is the last gate guaranteeing a 26-key definition (even one whose builtinLayout is
    /// mislabelled phone9/merged14) causes zero queries and zero rewrites: kind describes the input
    /// method, not physical key layout.
    public var compactSpellingLayout: Bool = false {
        didSet {
            let eligible = compactSpellingLayout
            spellingDemandEligible.withLock { $0 = eligible }
        }
    }
    /// Mirror of `compactSpellingLayout` that the engine queue reads through `spellingDemand`.
    private nonisolated let spellingDemandEligible = OSAllocatedUnfairLock(initialState: false)
    /// True only when the current physical definition structurally matches a
    /// telephone keypad. Combined with an all-digit engine `rawInput`, this is the
    /// fail-closed protection for imported 9-key adapters that cannot provide a
    /// trusted canonical display capability.
    public var numericTransportLayout: Bool = false

    public func reloadOptions() {
        drainPendingCodes()
        guard !retired else { return }
        do { options = try engine.optionStates() } catch {
            options = []
            onError?(error)
        }
        onUpdate?()
    }

    public func setOption(_ name: String, value: Bool) throws {
        drainPendingCodes()
        guard !retired else { throw EngineBackendError.notReady }
        do {
            let updated = try engine.setOption(name, value: value)
            options = try engine.optionStates()
            apply(mode == .english ? EngineSnapshot() : updated)
        } catch {
            reloadOptions()
            // The backend may have changed state before a persistence failure.
            apply(mode == .english ? EngineSnapshot() : engine.currentSnapshot())
            throw error
        }
    }
    /// Layout→schema mapping of the current resource set; nil = the built-in template pairing (`BuiltinTemplateSchemas`).
    /// If the set lacks a layout, `select(layout:)` refuses the switch and reports unsupportedSchema.
    public let resourceSet: KeyboardResourceSet?

    /// Called on state changes (candidates/preedit/composition state).
    public var onUpdate: (() -> Void)?
    /// Called on engine errors (e.g. real engine not ready).
    public var onError: ((Error) -> Void)?
    /// Called with text to commit (insert into the host text field / text proxy) each time the engine produces a commit.
    public var onCommitted: ((String) -> Void)?
    /// Preferred output route. True means dispatched to a live host outlet, not document acceptance.
    public var onDispatchCommit: ((String) -> Bool)?
    public var inputUnavailableReason: String? { engine.inputUnavailableReason }
    /// Host hook for relative cursor movement (argument = character offset, e.g. -2 = two left).
    /// The session/controller never touches UITextDocumentProxy or the host text field:
    ///  - the keyboard extension should wire it to `adjustTextPosition(byCharacterOffset:)`;
    ///  - the host app's typing area implements it only if it can move the selection exactly;
    ///    otherwise it stays nil (nil = no movement, never faked).
    public var onMoveCursor: ((Int) -> Void)?
    /// Shift tri-state for direct English input (off/once/locked). The UI calls `tapShift()` /
    /// `doubleTapShift()` for single/double taps; `onUpdate` fires after every change.
    public private(set) var shiftState: ShiftState = .off

    public init(
        engine: EngineBackend, layout: KeyboardLayoutKind,
        resourceSet: KeyboardResourceSet? = nil
    ) {
        self.engine = engine
        self.layout = layout
        let resolved: KeyboardResourceSet?
        if let resourceSet, resourceSet.selectedSchemaID != nil || !resourceSet.schemas.isEmpty {
            let runtime = engine.availableSchemas
            let schemas =
                resourceSet.schemas.isEmpty
                ? runtime
                : (engine.kind == .rime
                    ? resourceSet.schemas.filter { source in runtime.contains { $0.id == source.id } }
                    : resourceSet.schemas)
            resolved = KeyboardResourceSet(
                id: resourceSet.id, name: resourceSet.name,
                sharedDirectory: resourceSet.sharedDirectory, userDirectory: resourceSet.userDirectory,
                layoutEntries: resourceSet.layoutEntries, prebuiltDirectory: resourceSet.prebuiltDirectory,
                schemas: schemas, selectedSchemaID: resourceSet.selectedSchemaID,
                preferredLayout: resourceSet.preferredLayout, sourceRevision: resourceSet.sourceRevision,
                publicationGeneration: resourceSet.publicationGeneration,
                publishedKeyboards: resourceSet.publishedKeyboards,
                englishCandidateRoutes: resourceSet.englishCandidateRoutes,
                encodingAdapters: resourceSet.encodingAdapters)
        } else {
            resolved = resourceSet
        }
        self.resourceSet = resolved
        let actualSchema = engine.currentSnapshot().schemaID
        let initial =
            actualSchema.isEmpty
            ? (resourceSet?.schemaID(for: layout) ?? BuiltinTemplateSchemas.defaultSchemaID(for: layout) ?? "")
            : actualSchema
        self.selectedSchemaID = resourceSet?.sourceSchemaID(initial) ?? initial
        // The composition spelling request is the fail-closed gate before engine decoding. It follows
        // the physically proven `compactSpellingLayout` (injected by the front end from the real
        // `LayoutDefinition`; false by default and during switch transactions), not
        // `KeyboardLayoutKind`: a 26-key definition mislabelled merged14 must still decode nothing,
        // so `requiresSpellingDisplay` is never consulted here. The closure is evaluated on the
        // engine's serial queue, so snapshots produced on a failed-switch fallback path still use
        // the qualification in effect at the time. DemoEngine's setter is a no-op.
        engine.spellingDemand = { @Sendable [weak self] in self?.spellingDemandEligible.withLock { $0 } ?? false }
    }

    /// Kind-level hint that the layout is a compact spelling layout (14-key merged / 9-key digits).
    /// It is not the engine decode gate; the real gate is the injected `compactSpellingLayout`.
    /// 26-key full pinyin/shuangpin preedit is already pinyin and needs no request.
    public var requiresSpellingDisplay: Bool { layout.requiresSpellingDisplay }

    /// Validates the target, then confirms the current composition and switches schema. If
    /// confirmation fails, the composition and original layout are kept.
    /// With a resource set, the mapped schemaID is authoritative; a layout absent from the set
    /// is refused (e.g. a schema without 14/9-key support).
    ///
    /// Compact spelling is off during a real switch; a failed switch restores it, a successful one
    /// leaves it off until the front end re-authorizes it from the target definition.
    public func select(layout newLayout: KeyboardLayoutKind) {
        drainPendingCodes()
        guard !retired, newLayout != layout else { return }
        let previous = compactSpellingLayout
        compactSpellingLayout = false
        var succeeded = false
        defer { if !succeeded { compactSpellingLayout = previous } }
        if let resourceSet, resourceSet.usesIndependentSelection {
            guard let pair = resourceSet.combination(layout: newLayout, preferredSchemaID: selectedSchemaID) else {
                onError?(EngineBackendError.unsupportedSchema("当前输入方案没有适配此键盘布局"))
                return
            }
            let target = pair.engineSchemaID
            do { try validateSelection(target) } catch {
                refreshAfterSelectionFailure(error)
                return
            }
            guard prepareForConfigurationChange() else { return }
            do { try engine.selectSchema(target) } catch {
                refreshAfterSelectionFailure(error)
                return
            }
            layout = newLayout
            selectedSchemaID = pair.schemaID
            reloadOptions()
            refresh()
            succeeded = true
            return
        }
        let schemaID: String
        if let resourceSet {
            guard let mapped = resourceSet.schemaID(for: newLayout) else {
                onError?(
                    EngineBackendError.unsupportedSchema(
                        "键盘布局 \(newLayout.rawValue) 在此输入方案中不可用"))
                return
            }
            schemaID = mapped
        } else if let template = BuiltinTemplateSchemas.defaultSchemaID(for: newLayout) {
            schemaID = template
        } else {
            onError?(EngineBackendError.unsupportedSchema(newLayout.rawValue))
            return
        }
        do {
            try validateSelection(schemaID)
            guard prepareForConfigurationChange() else { return }
            try engine.selectSchema(schemaID)
            selectedSchemaID = schemaID
            layout = newLayout
            reloadOptions()
            refresh()
            succeeded = true
        } catch {
            refreshAfterSelectionFailure(error)
        }
    }

    public func selectSchema(_ schemaID: String) {
        drainPendingCodes()
        guard !retired else { return }
        guard schemaID != selectedSchemaID else { return }
        if let resourceSet {
            let pairs = resourceSet.availableCombinations.filter { $0.schemaID == schemaID }
            guard let pair = pairs.first(where: { $0.layout == layout }) ?? pairs.first else {
                onError?(EngineBackendError.unsupportedSchema("当前输入方案没有可用的键盘布局"))
                return
            }
            select(layout: pair.layout, boundSchemaID: schemaID)
            return
        }
        do {
            try validateSelection(schemaID)
            guard prepareForConfigurationChange() else { return }
            try engine.selectSchema(schemaID)
            selectedSchemaID = schemaID
            reloadOptions()
            refresh()
        } catch { refreshAfterSelectionFailure(error) }
    }

    /// Explicit layout association: validate both targets, then confirm once and switch atomically.
    public func select(layout newLayout: KeyboardLayoutKind, boundSchemaID: String) {
        drainPendingCodes()
        guard !retired else { return }
        guard newLayout != layout || boundSchemaID != selectedSchemaID else { return }
        let previous = compactSpellingLayout
        compactSpellingLayout = false
        var succeeded = false
        defer { if !succeeded { compactSpellingLayout = previous } }
        do {
            let target = try engineSchemaID(source: boundSchemaID, layout: newLayout)
            try validateSelection(target)
            if let reason = resourceSet?.incompatibilityReason(layout: newLayout, schemaID: boundSchemaID) {
                throw EngineBackendError.unsupportedSchema(reason)
            }
            guard prepareForConfigurationChange() else { return }
            try engine.selectSchema(target)
            selectedSchemaID = boundSchemaID
            layout = newLayout
            reloadOptions()
            refresh()
            succeeded = true
        } catch { refreshAfterSelectionFailure(error) }
    }

    /// Explicit revalidation is separate from selecting the already-selected menu item.
    /// Confirmation occurs once before the side-effecting activation validator.
    public func revalidateCurrentSchema() {
        drainPendingCodes()
        guard !retired else { return }
        do {
            let target = try engineSchemaID(source: selectedSchemaID, layout: layout)
            try validateSelection(target)
            guard prepareForConfigurationChange() else { return }
            try engine.selectSchema(target)
            reloadOptions()
            refresh()
        } catch { refreshAfterSelectionFailure(error) }
    }

    /// The engine schema running `source` on `layout`; a layout the resource set cannot run is refused.
    private func engineSchemaID(source: String, layout: KeyboardLayoutKind) throws -> String {
        guard let resourceSet else { return source }
        guard let engine = resourceSet.engineSchemaID(source: resourceSet.sourceSchemaID(source), layout: layout) else {
            throw EngineBackendError.unsupportedSchema(UserTerminology.layoutUnavailableReason(layout))
        }
        return engine
    }

    private func validateSelection(_ schemaID: String) throws {
        try engine.validateSchema(schemaID)
        if let reason = resourceSet?.enabledMembershipReason(schemaID: schemaID, engineSchemas: engine.availableSchemas)
        {
            throw EngineBackendError.unsupportedSchema(reason)
        }
    }

    private func refreshAfterSelectionFailure(_ error: Error) {
        // Read-only snapshots must never replay the commit produced by confirmation.
        var state = engine.currentSnapshot()
        state.committed = ""
        if inputUnavailableReason != nil {
            selectedSchemaID = resourceSet?.sourceSchemaID(state.schemaID) ?? state.schemaID
            options = []
        }
        apply(state)
        onError?(error)
    }

    /// User-requested resource/layout transitions must call this before teardown.
    /// Idle initialization/restoration has no commit. A failed or partial confirmation
    /// keeps the current composition and rejects the transition.
    /// Compact spelling is off while the composition is confirmed and restored afterwards.
    @discardableResult
    public func prepareForConfigurationChange() -> Bool {
        drainPendingCodes()
        guard !retired else { return false }
        let previous = compactSpellingLayout
        compactSpellingLayout = false
        defer { compactSpellingLayout = previous }
        return commitComposition()
    }

    // MARK: Input mode and direct input (everyday keyboard semantics)

    /// Switches input mode. Before entering English the current composition is confirmed
    /// (commitComposition); if confirmation fails or a composition remains, Chinese mode is kept.
    /// The English page shows no candidates/preedit. Switching back to Chinese re-reads engine state.
    public func setMode(_ newMode: InputMode) {
        drainPendingCodes()
        guard !retired, newMode != mode else { return }
        // Post-commit prediction is not a composition: it survives the switch to the English page (still tappable there) and is neither dismissed nor auto-selected.
        let keepsPrediction = newMode == .english && snapshot.isPrediction
        if newMode == .english, !keepsPrediction {
            guard commitComposition() else { return }
        }
        mode = newMode
        // Shift is transient English-input state: any mode switch resets it to off so a previous
        // uppercase state can't leak into the next session. Chinese codes always go to the engine lowercase.
        shiftState = .off
        if newMode == .english {
            // Engine state is unchanged; only display fields (candidates/preedit) are cleared since English input has no composition. Prediction candidates are kept.
            apply(keepsPrediction ? snapshot : EngineSnapshot())
        } else {
            refresh()
        }
    }

    // MARK: Shift tri-state (direct English mode; called after the UI recognizes single/double tap)

    /// Shift single tap: `off → once` (next letter uppercase); a tap in `once` or `locked` resets
    /// to `off` (releasing Caps Lock). Effective in front-end English mode or when the engine
    /// reports `ascii_mode`; a no-op in normal Chinese composition.
    public func tapShift() {
        guard mode == .english || snapshot.isAsciiMode else { return }
        switch shiftState {
        case .off:
            shiftState = .once
        case .once, .locked:
            shiftState = .off
        }
        onUpdate?()
    }

    /// Apply a host-derived one-shot capital without disturbing manual Caps Lock.
    /// The controller owns whether this one-shot is automatic or user-selected.
    public func setAutomaticShift(_ active: Bool) {
        guard mode == .english || snapshot.isAsciiMode, shiftState != .locked else { return }
        let target: ShiftState = active ? .once : .off
        guard shiftState != target else { return }
        shiftState = target
        onUpdate?()
    }

    /// Shift double tap = Caps Lock: `off/once → locked`; `locked → off`.
    /// Recognizing the double tap (two taps within ~0.3s) is the UI gesture's job; a single tap
    /// calls only `tapShift()`, so the two never stack.
    public func doubleTapShift() {
        guard mode == .english || snapshot.isAsciiMode else { return }
        shiftState = (shiftState == .locked) ? .off : .locked
        onUpdate?()
    }

    /// Commits text directly (the shared entry for digit/symbol keys and English-mode letters;
    /// corresponds to KeyAction.literal). If composing, the composition is first confirmed via
    /// `commitComposition()` and then `text` is committed, so keys pressed mid-composition aren't swallowed by the engine.
    @discardableResult
    public func insertLiteral(_ text: String) -> Bool {
        drainPendingCodes()
        guard inputAvailable(), !text.isEmpty else { return false }
        if snapshot.isComposing || snapshot.isPrediction {
            guard commitComposition() else { return false }
        }
        return dispatchCommit(text)
    }

    var retired = false

    /// Called by the owner on its UI actor before scheduling engine shutdown.
    public func retire() {
        cancelPendingCodes()
        retired = true
        onUpdate = nil
        onError = nil
        onCommitted = nil
        onDispatchCommit = nil
        onMoveCursor = nil
    }

    func inputAvailable() -> Bool {
        guard !retired else { return false }
        guard let reason = inputUnavailableReason else { return true }
        onError?(EngineBackendError.operationFailed(reason))
        return false
    }

    @discardableResult
    private func dispatchCommit(_ text: String) -> Bool {
        if let onDispatchCommit { return onDispatchCommit(text) }
        guard let onCommitted else { return false }
        onCommitted(text)
        return true
    }

    /// Confirms the current composition (the shared "confirm" semantics before space/return/English
    /// switch/symbol keys):
    ///  - candidates present: confirms the highlighted one (index 0 on the page if none highlighted);
    ///  - composing without candidates: sends return to the engine to commit the raw text (never swallows the key);
    ///  - empty composition: no-op.
    @discardableResult
    public func commitComposition() -> Bool {
        drainPendingCodes()
        guard inputAvailable() else { return false }
        // Prediction is not a composition: confirming only dismisses it and never picks a prediction word for the user.
        guard snapshot.isComposing else { return dismissPrediction() }
        do {
            let delivered: Bool
            if snapshot.candidates.isEmpty {
                // Return commits the confirmed text and then the raw input after it, where the
                // engine read every exact token as its letter; any other commit stays as the
                // schema made it.
                let raw = snapshot.rawInput
                let parts = confirmedTextAndRawTail()
                let letters = exactTokenLetters()
                var next = try engine.processKey("\n")
                if !letters.isEmpty {
                    if next.committed == raw {
                        next.committed = String(raw.map { letters[$0] ?? $0 })
                    } else if let parts, next.committed == parts.confirmed + parts.rawTail {
                        next.committed = parts.confirmed + String(parts.rawTail.map { letters[$0] ?? $0 })
                    }
                }
                delivered = apply(next)
            } else {
                let idx = snapshot.highlightedIndex
                if idx >= 0, snapshot.candidates.contains(where: { $0.index == idx }) {
                    delivered = apply(try engine.selectCandidate(idx))
                } else {
                    delivered = apply(try engine.selectCandidate(0))
                }
            }
            guard !snapshot.isComposing else {
                onError?(EngineBackendError.operationFailed("拼音组合未完成"))
                return false
            }
            // An empty engine composition does not prove that the host accepted
            // its commit. Dependent literal/cursor operations must stop on refusal.
            return delivered
        } catch {
            onError?(EngineBackendError.operationFailed("未能确认当前输入，已保留拼音组合，请重试选词。\(error)"))
            return false
        }
    }

    /// The converted text before the highlighted segment and the raw input after it, read
    /// from the preedit: everything before `preeditSelStart` is confirmed text, and the rest
    /// counts as raw only when it is literally the end of the raw input. Nil otherwise.
    private func confirmedTextAndRawTail() -> (confirmed: String, rawTail: String)? {
        let bytes = Array(snapshot.preedit.utf8), start = snapshot.preeditSelStart
        guard start > 0, start < bytes.count,
            let confirmed = String(bytes: bytes[..<start], encoding: .utf8),
            let tail = String(bytes: bytes[start...], encoding: .utf8),
            snapshot.rawInput.hasSuffix(tail), tail.count < snapshot.rawInput.count
        else { return nil }
        return (confirmed, tail)
    }

    /// Exact token → letter, when the running schema's alphabet takes the layout's exact
    /// tokens (a generated adapter) and the engine is reading Chinese input.
    private func exactTokenLetters() -> [Character: Character] {
        guard mode == .chinese, !snapshot.isAsciiMode, let tokens = layout.compactFold?.exactTokens, !tokens.isEmpty,
            let alphabet = engine.spellerAlphabet(schemaID: snapshot.schemaID)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: tokens.filter { alphabet.contains($1) }.map { ($1, $0) })
    }

    /// Handles one keycap action (KeyAction.literal commits directly; in English mode
    /// letters/digits/space/return are likewise committed directly, and backspace is left to the host instead of going to the engine).
    public func tap(_ action: KeyAction) {
        guard inputAvailable() else { return }
        if case .code(let value) = action, defersCodeKeys {
            deferCode(value)
            return
        }
        drainPendingCodes()
        if case .letterVariant(let text) = action {
            let consumesShift = mode == .english && text.count == 1 && text.first?.isLetter == true
            insertLiteral(consumesShift && shiftState.isActive ? text.uppercased() : text)
            if consumesShift && shiftState == .once {
                shiftState = .off
                onUpdate?()
            }
            return
        }
        if case .literal(let text) = action {
            insertLiteral(text)
            return
        }
        if mode == .english {
            switch action {
            case .code(let value):
                // Shift applies here: once/locked uppercases ASCII letters, and once resets after a
                // letter (digits/symbols don't consume it).
                let output = englishOutput(for: value)
                insertLiteral(output.text)
                if output.shiftChanged { onUpdate?() }
            case .space:
                insertLiteral(" ")
            case .enter:
                insertLiteral("\n")
            case .backspace:
                return  // an empty-composition backspace is deleted by the host text proxy; see KeyboardController
            case .switchKeyboard, .cycleLayout:
                return
            case .literal, .letterVariant:
                return  // handled above
            }
            return
        }
        do {
            switch action {
            case .code(let value):
                if snapshot.isAsciiMode {
                    // Rime owns ASCII mode, so keep the key on the engine path
                    // (key_binder/options remain authoritative) while applying
                    // the keyboard's visible Shift state to the emitted key.
                    let output = englishOutput(for: value)
                    apply(try engine.processKey(output.text))
                    if output.shiftChanged { onUpdate?() }
                } else {
                    apply(try engine.processKey(value))
                }
            case .literal(let text), .letterVariant(let text):
                insertLiteral(text)
            case .space:
                apply(try engine.processKey(" "))
            case .backspace:
                apply(try engine.processKey("\u{08}"))
            case .enter:
                apply(try engine.processKey("\n"))
            case .switchKeyboard, .cycleLayout:
                // Handled by the host/extension view layer (system input-method switch / layout
                // cycle button); the engine has no matching key.
                return
            }
        } catch {
            onError?(error)
        }
    }

    /// Selects the candidate at `index` (0-based).
    public func selectCandidate(_ index: Int) {
        guard let index = settleBeforeSelecting(index, absolute: false) else { return }
        guard inputAvailable() else { return }
        do {
            apply(try engine.selectCandidate(index))
        } catch {
            onError?(error)
        }
    }

    /// Selects a candidate by absolute cross-page index (0-based, global). Used after the front end
    /// shows several pages continuously, so a concatenated-array index isn't mistaken for a per-page index.
    /// - Parameter seenText: the tapped candidate's text when the caller shows candidates
    ///   beyond the engine's current page (see `settleBeforeSelecting`).
    public func selectCandidateAbsolute(_ index: Int, seenText: String? = nil) {
        guard let index = settleBeforeSelecting(index, absolute: true, seenText: seenText) else { return }
        guard inputAvailable() else { return }
        do {
            apply(try engine.selectCandidateAbsolute(index))
        } catch {
            onError?(error)
        }
    }

    public enum CandidateConfirmationResult: Equatable {
        case failed, partial, completed
    }

    /// Exactly one explicit selection. A changed snapshot is not proof of full
    /// confirmation or delivery. Never select a second hidden candidate here.
    public func confirmCandidateAbsolute(_ index: Int, seenText: String? = nil) -> CandidateConfirmationResult {
        guard let index = settleBeforeSelecting(index, absolute: true, seenText: seenText) else { return .failed }
        guard inputAvailable(), snapshot.isComposing || snapshot.isPrediction,
            onDispatchCommit != nil || onCommitted != nil
        else { return .failed }
        do {
            let result = try engine.selectCandidateAbsolute(index)
            let delivered = apply(result)
            if result.isComposing { return .partial }
            return delivered ? .completed : .failed
        } catch {
            onError?(error)
            return .failed
        }
    }

    public func nextPage() {
        drainPendingCodes()
        guard inputAvailable() else { return }
        do { apply(try engine.nextPage()) } catch { onError?(error) }
    }

    public func previousPage() {
        drainPendingCodes()
        guard inputAvailable() else { return }
        do { apply(try engine.previousPage()) } catch { onError?(error) }
    }

    // MARK: Cursor movement (relative offset; the host consumes it via onMoveCursor)

    /// Requests moving the cursor by `offset` characters (negative = left). The session never touches the text proxy:
    ///  - empty composition: passes `offset` straight to `onMoveCursor`;
    ///  - composing: first commits the composition via `commitComposition()` (same confirm path as
    ///    `insertLiteral`, never silently dropping typed input), then moves;
    ///  - composition can't be ended (engine error) or offset == 0: no move, no callback.
    public func moveCursor(by offset: Int) {
        drainPendingCodes()
        guard inputAvailable() else { return }
        guard offset != 0 else { return }
        if snapshot.isComposing || snapshot.isPrediction {
            guard commitComposition() else { return }
        }
        onMoveCursor?(offset)
    }

    /// Dismisses post-commit prediction (called on idle backspace, direct input, cursor move, and before switches).
    /// A no-op returning true when there is no prediction; returns false if dismissal fails
    /// (engine error or prediction remains), keeping the current state and never picking a word for the user.
    @discardableResult
    public func dismissPrediction() -> Bool {
        drainPendingCodes()
        guard !retired else { return false }
        guard snapshot.isPrediction else { return true }
        do {
            var updated = try engine.dismissPrediction()
            updated.committed = ""
            apply(updated)
            return !snapshot.isPrediction && !snapshot.isComposing
        } catch {
            onError?(error)
            return false
        }
    }

    /// Reads the engine's current state (used on page entry/activation).
    public func refresh() {
        drainPendingCodes()
        guard !retired else { return }
        apply(engine.currentSnapshot())
    }

    // MARK: Background code-key decoding (doesn't block the main thread during composition)

    /// Where code keys decode off the main thread. nil keeps every key synchronous.
    public var codeKeyQueue: EngineWorkQueue?
    /// Code keys accepted but not yet reflected in `snapshot`: the batch decoding now,
    /// then the keys typed meanwhile. The front end echoes them so no press looks lost.
    public internal(set) var pendingCodes: [String] = []
    /// Bumps on every change of `pendingCodes`; a deferred key is an effect too.
    public internal(set) var pendingCodesRevision = 0
    public var onPendingCodesChanged: (() -> Void)?
    /// Every code key after the first one of a composition decodes on `codeKeyQueue`;
    /// keys typed meanwhile go in one batch. A long ambiguous composition (a 9-key
    /// sentence) costs librime tens of milliseconds per key, and the engine queue may
    /// still be busy with the previous key's reading queries: decoding on the main
    /// thread froze the keys and let them land in bursts. Deferring only after one
    /// slow key kept that key (and every key after a fast batch) on the main thread,
    /// so long compositions still hitched every few keys.
    var batch: CodeBatch?
    /// Candidate pages after the first that a deferred batch reads in the same engine
    /// hop as its decode. The front end otherwise read them in a separate hop after the
    /// first render, and their arrival re-rendered the whole panel once more per key.
    public var codeBatchLookaheadPages = 0
    /// The candidates after the first page of the snapshot being applied, read
    /// read-only right after its decode. Set only while `onUpdate` runs for a landed batch.
    public internal(set) var candidateLookahead: (rawInput: String, pageSize: Int, candidates: [Candidate])?

    // MARK: Private

    /// Explicitly discard only the engine composition. Never emits onCommitted;
    /// the host may clear its document only after this returns true.
    ///
    /// Uses the engine's dedicated cancel (`cancelComposition`) rather than a synthesized Esc:
    /// real librime's editor Esc only steps back one segment when a previous segment exists, leaving
    /// `isComposing` true, which would count as failure here (the host's "clear" alert). The
    /// dedicated API clears unconditionally. `updated.committed` is always emptied so cancel never commits.
    ///
    /// Failure contract: if the engine throws (unavailable / state read fails after cancel),
    /// nothing is applied; the last trusted composition is kept, an error is reported and false is
    /// returned, so a failure is never folded into an empty non-composing state that would
    /// wrongly authorize the host to clear the document. Returns true only when the real state after `apply` is `!isComposing`.
    @discardableResult
    public func discardComposition() -> Bool {
        cancelPendingCodes()
        guard !retired else { return false }
        guard snapshot.isComposing || inputUnavailableReason != nil else { return true }
        do {
            var updated = try engine.cancelComposition()
            updated.committed = ""
            apply(updated)
            guard !snapshot.isComposing else {
                onError?(EngineBackendError.operationFailed("未能取消当前输入，拼音组合仍保留，请重试。"))
                return false
            }
            return true
        } catch {
            onError?(EngineBackendError.operationFailed("取消输入失败，已保留拼音组合：\(error)"))
            return false
        }
    }

    /// Shift conversion for a letter typed in direct English input (once/locked → uppercase; once resets after the letter).
    /// Applies to ASCII a–z only; digits/symbols/non-ASCII are returned unchanged and don't consume once.
    /// `shiftChanged` lets the caller fire onUpdate so the UI redraws keycap case.
    private func englishOutput(for raw: String) -> (text: String, shiftChanged: Bool) {
        guard raw.count == 1,
            let value = raw.unicodeScalars.first?.value,
            (97...122).contains(value)
        else {
            return (raw, false)
        }
        guard shiftState.isActive else { return (raw, false) }
        let upper = String(Character(UnicodeScalar(UInt32(value - 32))!))
        if shiftState == .once {
            shiftState = .off
            return (upper, true)
        }
        return (upper, false)
    }

    /// Folds an engine snapshot into session state: only `committed` is cleared (it is dispatched
    /// separately); all other engine state, including paging metadata and candidate indices, must be kept as is.
    @discardableResult
    func apply(_ newSnapshot: EngineSnapshot) -> Bool {
        compositionRevision &+= 1
        let committed = newSnapshot.committed
        snapshot = newSnapshot
        snapshot.committed = ""
        snapshot.hidesNumericTransportCode =
            snapshot.hidesNumericTransportCode
            || (numericTransportLayout
                && CompositionDisplayPolicy.isNumericTransport(rawInput: snapshot.rawInput))
        if !newSnapshot.schemaID.isEmpty {
            selectedSchemaID = resourceSet?.sourceSchemaID(newSnapshot.schemaID) ?? newSnapshot.schemaID
        }
        let delivered = !committed.isEmpty && dispatchCommit(committed)
        onUpdate?()
        return delivered
    }
}
