import CandidateKit
import Combine
import Foundation
import KeyboardCore
import LayoutKit
import UniformTypeIdentifiers

// The platform/backend seam is reused from the existing complete-controller probe.
enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = true
    static let groupID = "test.idle-paste-policy"
    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
}
enum KeyboardFeedbackPreferences { static var defaults: UserDefaults { .standard } }

private final class IdleEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("idle-paste-policy")
    var statusSummary: String { "fixture" }
    var state = EngineSnapshot()
    var unavailable: String?
    var inputUnavailableReason: String? { unavailable }
    var failsKey = false
    var failsCandidateRead = false
    var supportsReadOnlyBrowsing: Bool { true }
    var readingGate: DispatchSemaphore?
    var ambiguityGate: DispatchSemaphore?
    let readingEntered = DispatchSemaphore(value: 0)
    let ambiguityEntered = DispatchSemaphore(value: 0)
    var report: AmbiguitySpellingsReport?

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { state.schemaID = schemaID }
    func currentSnapshot() -> EngineSnapshot { state }
    func processKey(_ key: String) throws -> EngineSnapshot {
        if failsKey { throw EngineBackendError.operationFailed("fixture-key-failure") }
        return state
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { state }
    func nextPage() throws -> EngineSnapshot { state }
    func previousPage() throws -> EngineSnapshot { state }
    func shutdown() {}
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        precondition(!Thread.isMainThread)
        if failsCandidateRead { throw EngineBackendError.operationFailed("fixture-page-failure") }
        return []
    }
    func readCandidatesWithReadings(fromIndex: Int, count: Int) throws -> [ReadingCandidate]? {
        precondition(!Thread.isMainThread)
        readingEntered.signal()
        if let readingGate { precondition(readingGate.wait(timeout: .now() + 5) == .success) }
        return fromIndex == 0 ? [ReadingCandidate(index: 0, text: "candidate", syllables: ["ni"])] : []
    }
    func ambiguitySpellings() throws -> AmbiguitySpellingsReport? {
        precondition(!Thread.isMainThread)
        ambiguityEntered.signal()
        if let ambiguityGate { precondition(ambiguityGate.wait(timeout: .now() + 5) == .success) }
        return report
    }
}

/* PRODUCTION_DEFINITION_MEMO */

// Only SwiftUI-owned state is substituted. Layout facts and the getter and
// observation/eligibility statements below are copied verbatim from production.
@MainActor private final class IdlePanelProbe {
    struct HeaderPlan { var headerHeight: Double }
    let controller: KeyboardController
    let quickSymbols: T9QuickSymbolModel
    let quickPasteSlot: QuickPasteSlotLease
    var host: AnyHashable? = "same-document:same-selection"
    var statusMessage: String?
    var quickPasteError: String?
    var showsAllCandidates = false
    var showsUtilitiesMenu = false
    var showsSymbolLibrary = false
    var page: KeyboardControlPolicy.Page = .letters
    var selectedDefinition: LayoutDefinition? = BuiltinLayouts.phone9
    var pageDefinition: KeyboardPageDefinition?
    var activeSplit: LayoutSplitConfiguration? { selectedDefinition?.split }
    private var definitionFacts: DefinitionResolutionMemo.Facts {
        DefinitionResolutionMemo.Facts(usable: BuiltinLayouts.all, active: selectedDefinition)
    }

    /* PRODUCTION_DEFINITION_CHROME */

    init(
        controller: KeyboardController, quickSymbols: T9QuickSymbolModel,
        lease: QuickPasteSlotLease? = nil
    ) {
        self.controller = controller
        self.quickSymbols = quickSymbols
        quickPasteSlot = lease ?? QuickPasteSlotLease()
    }

    /* PRODUCTION_IDLE_GETTER */
    /* PRODUCTION_SYMBOL_ERROR_GETTER */

    var input: QuickPasteIdleInput { quickPasteIdleInput }
    func render(headerHeight: Double = 44) {
        let plan = HeaderPlan(headerHeight: headerHeight)
        /* PRODUCTION_RENDER_OBSERVATION */
    }
    func asyncInsertionContext() -> AnyHashable? { host }
    func context() -> AnyHashable? {
        /* PRODUCTION_INPUT_CONTEXT */
    }
    func insert(_ text: String) -> Bool {
        let controller: KeyboardController? = self.controller
        let pasteLiteral: ((String) -> Bool)? = nil
        /* PRODUCTION_INSERT_OUTLET */
    }
    func receiveError(_ error: String?) {
        /* PRODUCTION_ERROR_RESULT */
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class IdlePasteFeed: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let progress = CancelFlag()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?

    func item() -> QuickPasteItem {
        QuickPasteItem {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    precondition(self.continuation == nil)
                    self.continuation = continuation
                    self.lock.unlock()
                    self.entered.signal()
                }
            } onCancel: {
                self.progress.set()
                self.lock.lock()
                let pending = self.continuation
                self.continuation = nil
                self.lock.unlock()
                pending?.resume(throwing: CancellationError())
            }
        }
    }
    func emit(_ url: URL) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        precondition(pending != nil)
        pending?.resume(returning: try! String(contentsOf: url, encoding: .utf8))
    }
}

@main struct IdlePasteChecks {
    static let atoms: [(String, WritableKeyPath<QuickPasteIdleInput, Bool>)] = [
        ("composition", \.isComposing), ("prediction", \.hasPrediction),
        ("candidates", \.hasCandidates), ("English suggestions", \.hasEnglishSuggestions),
        ("unfinished English word", \.hasActiveEnglishInput), ("status", \.hasStatus),
        ("composition fallback", \.hasCompositionFallback), ("readings", \.hasReadingContent),
        ("pending queries", \.hasPendingQueries), ("expanded", \.isExpanded), ("covered", \.isCovered),
    ]

    static func wait(_ semaphore: DispatchSemaphore) async {
        let signaled = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
            }
        }
        precondition(signaled, "fixture operation did not start")
    }
    @MainActor static func eventually(_ reason: String, _ predicate: () -> Bool) async {
        for _ in 0..<3000 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure(reason)
    }
    @MainActor static func symbols(_ root: URL, name: String) async -> T9QuickSymbolModel {
        let model = T9QuickSymbolModel(
            sharedContainer: { root.appendingPathComponent(name) },
            observesNotifications: false, postChange: {})
        await model.reload().value
        precondition(model.error == nil)
        return model
    }
    @MainActor static func paste(_ model: QuickPasteModel, file: URL) async {
        let feed = IdlePasteFeed()
        model.receiveUserPaste([feed.item()])
        await wait(feed.entered)
        feed.emit(file)
        await eventually("paste callback did not finish") { !model.isLoading }
    }

    @MainActor static func atomicPolicies(_ file: URL) async {
        precondition(atoms.count == 11)
        for mask in 0..<(1 << atoms.count) {
            var input = QuickPasteIdleInput()
            for (index, atom) in atoms.enumerated() { input[keyPath: atom.1] = mask & (1 << index) != 0 }
            precondition(input.allowsPaste == (mask == 0), "unexpected idle eligibility for mask \(mask)")
        }
        print("PASS I1: all 2048 combinations of 11 independent blockers permit paste only for the all-idle state")
        for atom in atoms {
            var input = QuickPasteIdleInput()
            let lease = QuickPasteSlotLease()
            lease.updateEligibility(true)
            var delivered: [String] = []
            let host: AnyHashable = "unchanged-document-and-selection"
            let model = QuickPasteModel(
                inputContext: {
                    guard input.allowsPaste else { return nil }
                    return lease.context(host: host)
                },
                insertLiteral: {
                    delivered.append($0)
                    return true
                })
            model.activate()
            let baseline = lease.context(host: host)!
            let feed = IdlePasteFeed()
            model.receiveUserPaste([feed.item()])
            await wait(feed.entered)
            input[keyPath: atom.1] = true
            lease.updateEligibility(input.allowsPaste)
            precondition(lease.context(host: host) == nil)
            input[keyPath: atom.1] = false
            lease.updateEligibility(input.allowsPaste)
            precondition(input.allowsPaste && lease.context(host: host) != baseline)
            feed.emit(file)
            await eventually("ABA provider did not finish: \(atom.0)") { !model.isLoading }
            precondition(
                delivered.isEmpty && model.error == QuickPasteFailure.contextChanged.message,
                "returning to idle must not validate the old request: \(atom.0)")
            precondition(!feed.progress.isCancelled, "do not substitute deactivate/cancel for the context fence")
            await paste(model, file: file)
            precondition(delivered == ["fixed idle payload"] && model.error == nil)
        }
        print(
            "PASS I2: each blocker performs idle-blocked-idle ABA with unchanged host and still-active target; only a new idle request inserts"
        )
    }

    @MainActor static func leaseProperties() {
        let lease = QuickPasteSlotLease()
        let sourceA = PassthroughSubject<Void, Never>()
        let sourceB = PassthroughSubject<Void, Never>()
        let identityA = NSObject(), identityB = NSObject()
        let host: AnyHashable = "host-A"
        precondition(lease.context(host: host) == nil && !lease.isCurrent(identity: ObjectIdentifier(identityA)))
        lease.observe(identity: ObjectIdentifier(identityA), changes: sourceA.eraseToAnyPublisher())
        lease.updateEligibility(true)
        precondition(
            lease.isCurrent(identity: ObjectIdentifier(identityA))
                && !lease.isCurrent(identity: ObjectIdentifier(identityB)))
        let initial = lease.context(host: host)!
        precondition(lease.context(host: nil) == nil && lease.context(host: "host-B") != initial)
        lease.updateEligibility(true)
        lease.observe(identity: ObjectIdentifier(identityA), changes: sourceB.eraseToAnyPublisher())
        precondition(lease.context(host: host) == initial, "same observer identity/redraw must not churn epochs")
        sourceB.send()
        precondition(lease.context(host: host) == initial, "same identity must retain its original subscription")
        sourceA.send()
        let changed = lease.context(host: host)!
        precondition(changed != initial, "publisher fencing must be synchronous, with no run-loop yield")
        lease.observe(identity: ObjectIdentifier(identityB), changes: sourceB.eraseToAnyPublisher())
        let rebound = lease.context(host: host)!
        precondition(rebound != changed)
        sourceA.send()
        precondition(lease.context(host: host) == rebound, "retired observer must be detached")
        sourceB.send()
        precondition(lease.context(host: host) != rebound)
        print(
            "PASS I3: host identity, nil focus, synchronous epochs, stable redraws and observer replacement obey production lease semantics"
        )
    }

    @MainActor static func controllerGetter(_ root: URL) async {
        let qs = await symbols(root, name: "getter-symbols")
        let engine = IdleEngine()
        let controller = KeyboardController(engine: engine)
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        precondition(panel.input == QuickPasteIdleInput())
        for key in [\IdlePanelProbe.showsAllCandidates, \.showsUtilitiesMenu, \.showsSymbolLibrary] {
            panel[keyPath: key] = true
            precondition(!panel.input.allowsPaste)
            panel[keyPath: key] = false
            precondition(panel.input.allowsPaste)
        }
        panel.statusMessage = "real host status"
        precondition(panel.input.hasStatus && !panel.input.allowsPaste)
        panel.statusMessage = nil
        engine.state.isPrediction = true
        controller.session.refresh()
        precondition(panel.input.hasPrediction && !panel.input.isComposing && !panel.input.allowsPaste)
        engine.state.isPrediction = false
        engine.state.isComposing = true
        engine.state.rawInput = "ni"
        engine.state.preedit = "ni"
        controller.session.refresh()
        precondition(panel.input.isComposing && panel.input.hasCompositionFallback && !panel.input.allowsPaste)
        controller.reportCompositionPresentation(.awaitingHost)
        precondition(!panel.input.hasCompositionFallback && !panel.input.allowsPaste)
        engine.state = EngineSnapshot()
        controller.session.refresh()
        engine.failsKey = true
        controller.handle(.code("x"))
        precondition(controller.inputError != nil && panel.input.hasStatus && !panel.input.allowsPaste)
        engine.failsKey = false
        engine.state.preedit = "refresh clears a previous error"
        controller.session.refresh()
        precondition(controller.inputError == nil)
        engine.state.preedit = ""
        controller.session.refresh()
        engine.unavailable = "fixture-unavailable"
        controller.session.refresh()
        precondition(controller.inputUnavailableReason != nil && panel.input.hasStatus && !panel.input.allowsPaste)
        engine.unavailable = nil
        controller.session.refresh()
        precondition(panel.input.allowsPaste)
        let failedSave = await qs.replaceSymbols("")
        precondition(!failedSave && qs.error != nil && panel.input.hasStatus && !panel.input.allowsPaste)
        _ = await qs.replaceSymbols("[]")
        precondition(qs.error == nil && panel.input.allowsPaste)
        panel.render(headerHeight: 43)
        precondition(panel.input.allowsPaste && panel.context() == nil)
        panel.render()
        let eligible = panel.context()!
        panel.render()
        precondition(panel.context() == eligible)
        panel.quickPasteError = "non-modal paste error"
        panel.render()
        precondition(panel.context() == nil)
        panel.quickPasteError = nil
        panel.render()
        precondition(panel.context() != eligible)
        controller.retire()
        let suggestedController = KeyboardController(engine: ProbeEngine())
        suggestedController.onDispatchCommit = { _ in true }
        suggestedController.setInputMode(.english)
        await eventually("English completion capability did not settle") {
            suggestedController.englishSuggestionsSupported == true
        }
        let suggestedPanel = IdlePanelProbe(controller: suggestedController, quickSymbols: qs)
        suggestedController.handle(.code("h"))
        suggestedController.handle(.code("e"))
        await eventually("real English suggestions did not arrive") { !suggestedController.englishSuggestions.isEmpty }
        precondition(suggestedPanel.input.hasEnglishSuggestions && !suggestedPanel.input.allowsPaste)
        suggestedController.retire()
        print(
            "PASS I4: production root getter maps real snapshot, English suggestions, status, failure, fallback and quick-symbol errors; covers/expansion and header budget gate the slot"
        )
    }

    @MainActor static func browsingAndReadings(_ root: URL) async {
        let qs = await symbols(root, name: "reading-symbols")
        let engine = IdleEngine()
        engine.state = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "page-2")],
            pageSize: 2, isLastPage: false)
        engine.state.isPrediction = true
        engine.state.pageIndex = 2
        engine.failsCandidateRead = true
        let controller = KeyboardController(engine: engine)
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        precondition(controller.candidateBrowser.needsEarlier && panel.input.hasCandidates && !panel.input.allowsPaste)
        controller.loadMoreCandidates()
        await eventually("candidate retry was not published") { controller.candidateBrowser.hasIncompletePage }
        precondition(controller.candidateBrowser.needsEarlier && panel.input.hasCandidates && !panel.input.allowsPaste)
        controller.retire()

        let readingEngine = IdleEngine()
        let readingController = KeyboardController(engine: readingEngine)
        let readingPanel = IdlePanelProbe(controller: readingController, quickSymbols: qs)
        readingController.updateCompactSpellingLayout(true)
        let readingGate = DispatchSemaphore(value: 0)
        readingEngine.readingGate = readingGate
        readingEngine.state = EngineSnapshot(candidates: [Candidate(index: 0, text: "candidate")], pageSize: 2)
        readingEngine.state.isComposing = true
        readingEngine.state.rawInput = "ni"
        readingEngine.state.preedit = "ni"
        readingController.session.refresh()
        precondition(
            readingController.readingQueryPending && readingPanel.input.hasPendingQueries
                && !readingPanel.input.allowsPaste)
        await wait(readingEngine.readingEntered)
        precondition(readingController.readingQueryPending && readingPanel.input.hasPendingQueries)
        readingGate.signal()
        await eventually("reading page did not settle") {
            !readingController.readingQueryPending && !readingController.ambiguityQueryPending
        }
        precondition(!readingController.readingFilter.entries.isEmpty)
        readingController.selectReading("ni")
        precondition(
            readingController.readingFilter.isFiltering && readingPanel.input.hasReadingContent
                && !readingPanel.input.allowsPaste)
        readingController.retire()

        let ambiguityEngine = IdleEngine()
        let ambiguityController = KeyboardController(engine: ambiguityEngine)
        let ambiguityPanel = IdlePanelProbe(controller: ambiguityController, quickSymbols: qs)
        ambiguityController.updateCompactSpellingLayout(true)
        let ambiguityGate = DispatchSemaphore(value: 0)
        ambiguityEngine.ambiguityGate = ambiguityGate
        ambiguityEngine.report = AmbiguitySpellingsReport(
            revisionInput: "z", segment: 0..<1,
            options: ["na", "ni"], allSpellings: ["na", "ni"], lockMode: .tokenAlias, isComplete: true)
        ambiguityEngine.state.isComposing = true
        ambiguityEngine.state.rawInput = "z"
        ambiguityEngine.state.preedit = "z"
        ambiguityController.session.refresh()
        precondition(ambiguityController.ambiguityQueryPending && ambiguityPanel.input.hasPendingQueries)
        await wait(ambiguityEngine.ambiguityEntered)
        precondition(ambiguityController.ambiguityQueryPending && !ambiguityPanel.input.allowsPaste)
        ambiguityGate.signal()
        await eventually("ambiguity picker did not settle") { !ambiguityController.ambiguityQueryPending }
        precondition(
            ambiguityController.ambiguityPicker.showsPicker && ambiguityPanel.input.hasReadingContent
                && !ambiguityPanel.input.allowsPaste)
        ambiguityController.retire()
        print(
            "PASS I5: actual controller candidate needs-earlier/retry, blocked reading and ambiguity queries, reading filter and spelling picker all block idle paste"
        )
    }

    @MainActor static func englishBoundaries(_ root: URL, file: URL) async {
        let qs = await symbols(root, name: "english-symbols")
        let engine = IdleEngine()
        let controller = KeyboardController(engine: engine)
        var commits: [String] = []
        controller.onDispatchCommit = {
            commits.append($0)
            return true
        }
        controller.onRequestDeleteBackward = {}
        controller.setInputMode(.english)
        await eventually("unsupported English suggestions did not settle") {
            controller.englishSuggestionsSupported == false
        }
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        panel.render()
        let host = panel.host
        let baseline = panel.context()!
        var published: [Bool] = []
        let subscription = controller.$hasActiveEnglishInput.sink { published.append($0) }
        let model = QuickPasteModel(inputContext: panel.context, insertLiteral: panel.insert)
        model.activate()
        let feed = IdlePasteFeed()
        model.receiveUserPaste([feed.item()])
        await wait(feed.entered)
        controller.handle(.code("q"))
        precondition(controller.hasActiveEnglishInput && controller.englishSuggestions.isEmpty)
        precondition(panel.input.hasActiveEnglishInput && !panel.input.allowsPaste)
        controller.handle(.code("x"))
        controller.handle(.code("z"))
        precondition(published == [false, true], "additional characters must not republish the active-word flag")
        controller.handle(.backspace)
        controller.handle(.backspace)
        precondition(published == [false, true] && controller.hasActiveEnglishInput)
        controller.handle(.backspace)
        precondition(published == [false, true, false] && !controller.hasActiveEnglishInput)
        controller.resetEnglishWord()
        precondition(published == [false, true, false], "empty reset must not republish a word boundary")
        precondition(
            panel.input.allowsPaste && panel.host == host && panel.context() != baseline,
            "real publisher epochs must fence ABA without render/deactivate")
        feed.emit(file)
        await eventually("English ABA provider did not finish") { !model.isLoading }
        precondition(!commits.contains("fixed idle payload") && model.error == QuickPasteFailure.contextChanged.message)
        precondition(!feed.progress.isCancelled)
        await paste(model, file: file)
        precondition(
            commits.last == "fixed idle payload" && !controller.hasActiveEnglishInput,
            "fresh external paste must not seed unfinished English learning")
        precondition(model.error == nil && controller.englishSuggestions.isEmpty)
        _ = subscription
        controller.retire()
        print(
            "PASS I6: production private englishWord publishes only first/last boundaries; typing without suggestions blocks; English ABA before UI teardown rejects late files"
        )
    }

    @MainActor static func livePublisherABA(_ root: URL, file: URL) async {
        let qs = await symbols(root, name: "live-symbols")
        let engine = IdleEngine()
        let controller = KeyboardController(engine: engine)
        var delivered: [String] = []
        controller.onDispatchCommit = {
            delivered.append($0)
            return true
        }
        let panel = IdlePanelProbe(controller: controller, quickSymbols: qs)
        panel.render()
        let fixedHost = panel.host
        let model = QuickPasteModel(inputContext: panel.context, insertLiteral: panel.insert)
        model.activate()
        for source in [controller.objectWillChange, qs.objectWillChange] {
            let baseline = panel.context()!
            let feed = IdlePasteFeed()
            model.receiveUserPaste([feed.item()])
            await wait(feed.entered)
            source.send()
            precondition(
                panel.input.allowsPaste && panel.context() != baseline && panel.host == fixedHost,
                "will-change must invalidate the stamp synchronously while state is still idle")
            feed.emit(file)
            await eventually("will-change provider did not finish") { !model.isLoading }
            precondition(delivered.isEmpty && model.error == QuickPasteFailure.contextChanged.message)
            precondition(!feed.progress.isCancelled)
        }
        let baseline = panel.context()!
        let feed = IdlePasteFeed()
        model.receiveUserPaste([feed.item()])
        await wait(feed.entered)
        engine.state.isPrediction = true
        controller.session.refresh()
        precondition(!panel.input.allowsPaste)
        engine.state.isPrediction = false
        controller.session.refresh()
        precondition(panel.input.allowsPaste && panel.host == fixedHost && panel.context() != baseline)
        feed.emit(file)
        await eventually("snapshot ABA provider did not finish") { !model.isLoading }
        precondition(delivered.isEmpty && model.error == QuickPasteFailure.contextChanged.message)

        let symbolBaseline = panel.context()!
        let originalSymbols = qs.symbols
        let symbolFeed = IdlePasteFeed()
        model.receiveUserPaste([symbolFeed.item()])
        await wait(symbolFeed.entered)
        _ = await qs.replaceSymbols("[]")
        _ = await qs.replaceSymbols(originalSymbols)
        precondition(qs.symbols == originalSymbols && panel.input.allowsPaste && panel.host == fixedHost)
        precondition(panel.context() != symbolBaseline)
        symbolFeed.emit(file)
        await eventually("quick-symbol ABA provider did not finish") { !model.isLoading }
        precondition(delivered.isEmpty && model.error == QuickPasteFailure.contextChanged.message)
        await paste(model, file: file)
        precondition(delivered == ["fixed idle payload"] && model.error == nil)

        let hostFeed = IdlePasteFeed()
        model.receiveUserPaste([hostFeed.item()])
        await wait(hostFeed.entered)
        panel.host = "different-document:selection"
        hostFeed.emit(file)
        await eventually("host-change provider did not finish") { !model.isLoading }
        precondition(delivered.count == 1 && model.error == QuickPasteFailure.contextChanged.message)
        await paste(model, file: file)
        precondition(delivered.count == 2 && model.error == nil)
        let staleControllerFeed = IdlePasteFeed()
        model.receiveUserPaste([staleControllerFeed.item()])
        await wait(staleControllerFeed.entered)
        let replacement = KeyboardController(engine: IdleEngine())
        replacement.onDispatchCommit = {
            delivered.append($0)
            return true
        }
        let replacementSymbols = await symbols(root, name: "replacement-symbols")
        let replacementPanel = IdlePanelProbe(
            controller: replacement, quickSymbols: replacementSymbols,
            lease: panel.quickPasteSlot)
        replacementPanel.host = panel.host
        let oldStamp = panel.context()!
        replacementPanel.render()
        let replacementStamp = replacementPanel.context()!
        precondition(replacementStamp != oldStamp && panel.context() == nil)
        precondition(!panel.insert("stale controller dispatch"))
        controller.objectWillChange.send()
        qs.objectWillChange.send()
        precondition(replacementPanel.context() == replacementStamp, "both retired publisher sources must detach")
        replacement.objectWillChange.send()
        precondition(replacementPanel.context() != replacementStamp)
        staleControllerFeed.emit(file)
        await eventually("controller replacement did not reject old provider") { !model.isLoading }
        precondition(delivered.count == 2 && model.error == QuickPasteFailure.contextChanged.message)
        precondition(!staleControllerFeed.progress.isCancelled)
        panel.receiveError(model.error)
        precondition(
            panel.quickPasteError == nil && replacementPanel.quickPasteError == nil,
            "an old active component's onError must not populate the replacement header")
        let currentModel = QuickPasteModel(
            inputContext: replacementPanel.context, insertLiteral: replacementPanel.insert)
        currentModel.activate()
        await paste(currentModel, file: file)
        precondition(delivered.count == 3 && currentModel.error == nil)
        replacementPanel.receiveError("current non-modal error")
        precondition(replacementPanel.quickPasteError == "current non-modal error" && panel.quickPasteError == nil)
        controller.retire()
        replacement.retire()
        print(
            "PASS I7: merged actual controller/QS publishers fence same-document ABA synchronously before UI render/unmount; old identities cannot insert or leak errors into a new header"
        )
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = root.appendingPathComponent("payload.txt")
        try Data("fixed idle payload".utf8).write(to: file)
        await atomicPolicies(file)
        leaseProperties()
        await controllerGetter(root)
        await browsingAndReadings(root)
        await englishBoundaries(root, file: file)
        await livePublisherABA(root, file: file)
    }
}
