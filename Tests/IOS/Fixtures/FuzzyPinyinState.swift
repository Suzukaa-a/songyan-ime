// Fuzzy pinyin settings state: the production refresh/anchor decisions, driven by a
// scripted published read. The test file splices in the real FuzzyPinyinCenter code;
// everything around it is a typed boundary stub.
import Foundation
import Combine


// MARK: - Minimal typed boundary stubs (only what the extracted production code names)

struct PublishedKeyboard: Equatable, Sendable {
    let schemaID: String
    let layout: String
}

enum KeyboardRecipeStore {
    enum ResourceKind: Equatable, Sendable { case userScheme, userDictionary }
    struct Activation: Equatable, Sendable {
        var kind: ResourceKind = .userScheme
        var packageID: String?
        var revision: String = "rev-1"
        var generation: String = "gen-1"
        var hostInstallationGeneration: String? = "host-1"
        var selectedSchemaID: String?
        var selectedLayout: String?
        var keyboards: [PublishedKeyboard] = []
    }
}

enum FuzzyPinyin {
    struct Target: Equatable, Sendable { let schemaID: String; let namespace: String }
    struct Pair: Equatable, Sendable { let id: String }
    static let allPairs: [Pair] = [Pair(id: "z-zh"), Pair(id: "c-ch"), Pair(id: "s-sh")]
    static func pair(id: String) -> Pair? { allPairs.first { $0.id == id } }
}

enum HostLog { static func append(_ line: String) {} }

/// Stands in for an engine that could not be inspected this time.
struct TransientFailure: Error {}

/// Scripted stand-in for the native support boundary: the check decides whether an input
/// method is supported instead of starting a real engine. Typed boundary only -- no engine,
/// no redeploy, no user data.
enum ScriptedSupport {
    /// One answer per probe; an empty queue answers true (the supported default).
    static var answers: [Result<Bool, Error>] = []
    /// How many times the production gate actually consulted the boundary.
    static var probes = 0
    /// Runs while a probe is in flight -- that is, from inside the await the caller is parked
    /// on -- so a check can inspect the page at exactly that moment without any gate.
    static var duringProbe: (() -> Void)?
    static func reset(_ next: [Result<Bool, Error>] = []) {
        answers = next; probes = 0; duringProbe = nil
    }
    static func next() async throws -> Bool {
        probes += 1
        let hook = duringProbe
        hook?()
        guard !answers.isEmpty else { return true }
        return try answers.removeFirst().get()
    }
}

/// An async gate a read can park on, so a check can decide what happens while a read is still
/// in flight without blocking the main actor.
actor AsyncGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if opened { continuation.resume() } else { waiters.append(continuation) }
        }
    }
    func release() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Scripted stand-in for the off-main published read: the probe never touches disk. A read can
/// be parked on a gate to model one that completes after a newer read or a save.
enum ScriptedReads {
    static var results: [Result<FuzzyPinyinCenter.PublishedContext?, Error>] = []
    static var index = 0
    /// Reads at these indexes park until the gate is released.
    static var gates: [Int: AsyncGate] = [:]
    /// Called with the index of each read as it starts.
    static var onEnter: ((Int) -> Void)?
    static func reset(_ next: [Result<FuzzyPinyinCenter.PublishedContext?, Error>] = []) {
        results = next; index = 0; gates = [:]; onEnter = nil
    }
    static func next() async throws -> FuzzyPinyinCenter.PublishedContext? {
        let current = index
        index += 1
        onEnter?(current)
        if let gate = gates[current] { await gate.wait() }
        guard current < results.count else { return nil }
        return try results[current].get()
    }
}

@MainActor
final class FuzzyPinyinCenter: ObservableObject {
    static let shared = FuzzyPinyinCenter()
    /// Production value, declared outside the extracted slice so the preference keys match.
    static let preferencePrefix = "app.songyan.settings.fuzzyPinyin."

    @Published private(set) var state: State = .loading
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var failure: String?
    @Published var draft: Set<String> = []

/* PRODUCTION_PREFS */

/* PRODUCTION_STATE */

/* PRODUCTION_CONTEXT */

    private(set) var applyTask: Task<Void, Never>?
    private(set) var displayed: PublishedContext?
    private var refreshToken = UUID()
    private var failureAnchor: PublishedContext?
    /// The context a support answer belongs to, and that answer. Production keeps these
    /// private; the checks read them to see what the gate cached.
    var supportContext: PublishedContext?
    var supportAllowed = false

    // MARK: - Scripted read and the save-state seams

    static func readPublished() async throws -> PublishedContext? { try await ScriptedReads.next() }

    /// Test double for the native boundary: same signature as production's private one.
    private static func nativeSupport(for context: PublishedContext) async throws -> Bool {
        try await ScriptedSupport.next()
    }

    /// Test seam: exactly the state apply() leaves when saving fails.
    func simulateSaveFailure() {
        guard let displayed else { return }
        failure = "未能保存，请重试。"
        failureAnchor = displayed
    }

    /// Test seam: the notice a save leaves when the version is installed but not yet in use.
    func simulatePendingNotice() { notice = "将在使用新版本后生效。" }

    /// Test seam: the in-flight guard save() sets before its first await.
    func setWorking(_ value: Bool) { working = value }

    /// Test seam: the status the page currently shows.
    func setStateForTesting(_ value: State) { state = value }

    /// Whether a save got past the production preamble below.
    var saveStarted = false

    /// The production save preamble -- signature, scope switch and in-flight state -- is planted
    /// here; it leaves the function body open, and the seam below closes it. The apply tail is
    /// beyond this probe's scope.
/* PRODUCTION_SAVE_PREAMBLE */
        saveStarted = true
    }

/* PRODUCTION_REFRESH */
}

func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    precondition(actual == expected, message + " (got \(actual), expected \(expected))")
}

func makeContext(packageID: String? = "pkg-a", schemaID: String = "rime_ice",
                 revision: String = "rev-1", generation: String = "gen-1",
                 hostGeneration: String? = "host-1",
                 state: FuzzyPinyinCenter.State) -> FuzzyPinyinCenter.PublishedContext {
    var activation = KeyboardRecipeStore.Activation()
    activation.kind = .userScheme
    activation.packageID = packageID
    activation.revision = revision
    activation.generation = generation
    activation.hostInstallationGeneration = hostGeneration
    activation.selectedSchemaID = schemaID
    var context = FuzzyPinyinCenter.PublishedContext(
        packageID: packageID, revision: revision, keyboard: nil, schemaID: schemaID,
        state: state, target: FuzzyPinyin.Target(schemaID: schemaID, namespace: "translator"),
        viewedActivation: activation, viewedSourceKey: "roster-key", viewedRoster: [])
    // The support gate's boundary needs both; the probe's stub never reads them, but they are
    // part of the context identity the answer is cached against.
    context.resourcesURL = URL(fileURLWithPath: "/nonexistent/resources")
    context.buildURL = URL(fileURLWithPath: "/nonexistent/build")
    return context
}

let SET_A: Set<String> = ["z-zh"]
let SET_B: Set<String> = ["s-sh"]
let EDITED: Set<String> = ["c-ch"]
let FAILURE_TEXT = "未能保存，请重试。"
let PENDING_TEXT = "将在使用新版本后生效。"

@MainActor
func runChecks() async {
    // 1) A failed save keeps the draft while the page still shows the SAME full context.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .managed(SET_A), "case1 state comes from the published context")
        expectEqual(center.draft, SET_A, "case1 draft seeded from the managed set")
        center.draft = EDITED
        center.simulateSaveFailure()
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expect(center.failure == FAILURE_TEXT, "case1 the same full context keeps the failure")
        expectEqual(center.draft, EDITED, "case1 the same full context keeps the user draft")
    }

    // 2) A -> B clears the failure and anchor and seeds B; returning to A keeps neither B.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        let b = makeContext(packageID: "pkg-b", state: .managed(SET_B))
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        center.draft = EDITED
        center.simulateSaveFailure()
        ScriptedReads.reset([.success(b)])
        await center.refresh()
        expect(center.failure == nil, "case2 switching target clears the failure")
        expectEqual(center.draft, SET_B, "case2 switching target seeds that target draft")
        center.draft = EDITED
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.draft, SET_A, "case2 returning to A must not retain B draft")
        expect(center.failure == nil, "case2 returning to A must not resurrect the failure")
    }

    // 3) Same source, input method and upstream revision, but the published generation
    //    changed: the failed draft belongs to the old generation and must reset.
    do {
        let center = FuzzyPinyinCenter()
        let before = makeContext(generation: "gen-1", state: .managed(SET_A))
        let after = makeContext(generation: "gen-2", state: .managed(SET_A))
        ScriptedReads.reset([.success(before)])
        await center.refresh()
        center.draft = EDITED
        center.simulateSaveFailure()
        ScriptedReads.reset([.success(after)])
        await center.refresh()
        expect(center.failure == nil, "case3 a new published generation clears the failed anchor")
        expectEqual(center.draft, SET_A, "case3 a new published generation reseeds the draft")
    }

    // 3b) Same revision and published generation, but the host installation generation moved.
    do {
        let center = FuzzyPinyinCenter()
        let before = makeContext(hostGeneration: "host-1", state: .managed(SET_A))
        let after = makeContext(hostGeneration: "host-9", state: .managed(SET_A))
        ScriptedReads.reset([.success(before)])
        await center.refresh()
        center.draft = EDITED
        center.simulateSaveFailure()
        ScriptedReads.reset([.success(after)])
        await center.refresh()
        expect(center.failure == nil, "case3b a new host generation clears the failed anchor")
        expectEqual(center.draft, SET_A, "case3b a new host generation reseeds the draft")
    }

    // 4) A pending notice survives a refresh of the same context and only a real context
    //    change clears it.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        let b = makeContext(packageID: "pkg-b", state: .managed(SET_B))
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        center.simulatePendingNotice()
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expect(center.notice == PENDING_TEXT, "case4 a pending notice survives a same-context refresh")
        ScriptedReads.reset([.success(b)])
        await center.refresh()
        expect(center.notice == nil, "case4 a real context change clears the pending notice")
    }

    // 5) A refresh issued while a save is in flight is ignored: it must not read, publish a
    //    state, or replace the displayed context the save is applying to.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        let b = makeContext(packageID: "pkg-b", state: .managed(SET_B))
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        let stateBefore = center.state
        let displayedBefore = center.displayed
        center.setWorking(true)
        ScriptedReads.reset([.success(b)])
        await center.refresh()
        expectEqual(center.state, stateBefore, "case5 a refresh while saving must not publish a state")
        expectEqual(center.displayed, displayedBefore, "case5 a refresh while saving must not replace the displayed context")
        expect(ScriptedReads.index == 0, "case5 an ignored refresh must not read at all")
    }

    // 6) The off state seeds the draft from the stored preference, not from an empty set:
    //    the switch must come back showing what this source + input method last chose.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(schemaID: "rime_ice", state: .off)
        FuzzyPinyinCenter.setPreferred(SET_B, packageID: a.packageID, schemaID: a.schemaID)
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .off, "case6 the off state is reported as off")
        expectEqual(center.draft, SET_B, "case6 the off state seeds from the stored preference")
    }

    // 7) A failed save on the off state keeps that stored draft too, so the user's pending
    //    choice is not silently dropped by a refresh of the same target.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(schemaID: "rime_ice", state: .off)
        FuzzyPinyinCenter.setPreferred(SET_B, packageID: a.packageID, schemaID: a.schemaID)
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        center.draft = EDITED
        center.simulateSaveFailure()
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expect(center.failure == FAILURE_TEXT, "case7 the off target keeps its failure")
        expectEqual(center.draft, EDITED, "case7 the off target keeps the edited draft")
    }
    // 8) An input method the native boundary does not support shows as unavailable with no
    //    controls, and leaves nothing for the page to act on.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .off)
        ScriptedSupport.reset([.success(false)])
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .unavailable("这个输入方式暂不支持模糊音，请选择其他输入方式。"),
                    "case8 an unsupported input method shows as unavailable")
        expect(center.displayed == nil, "case8 unsupported hides the page target")
        expectEqual(center.draft, [], "case8 unsupported offers no draft to edit")
        expect(center.failure == nil && center.notice == nil, "case8 unsupported reports no failure")
        expectEqual(center.supportAllowed, false, "case8 the answer is remembered as not allowed")
        expectEqual(center.supportContext, a, "case8 the answer is cached against the exact context")
    }

    // 9) The answer is cached per FULL context: re-showing the same one does not probe the
    //    engine again, while a change to the context does. Here only the build location
    //    differs, so a cache keyed on schema name alone would wrongly reuse the answer.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .off)
        var moved = a
        moved.buildURL = URL(fileURLWithPath: "/nonexistent/build-2")
        expect(moved != a, "case9 the two contexts must really differ")
        ScriptedSupport.reset([.success(false), .success(true)])
        ScriptedReads.reset([.success(a), .success(a), .success(moved)])
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 1, "case9 the first read probes the boundary once")
        expectEqual(center.state, .unavailable("这个输入方式暂不支持模糊音，请选择其他输入方式。"),
                    "case9 the unsupported answer is shown")
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 1, "case9 the same context reuses the cached answer")
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 2, "case9 a changed context probes again")
        expectEqual(center.state, .off, "case9 the new answer brings the controls back")
    }

    // 10) A new publication retries and can turn the controls back on: an unsupported answer
    //     must not hide the feature forever.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(revision: "rev-1", state: .managed(SET_A))
        let b = makeContext(revision: "rev-2", state: .managed(SET_A))
        ScriptedSupport.reset([.success(false), .success(true)])
        ScriptedReads.reset([.success(a), .success(b)])
        await center.refresh()
        expectEqual(center.state, .unavailable("这个输入方式暂不支持模糊音，请选择其他输入方式。"),
                    "case10 the first publication is unsupported")
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 2, "case10 a new publication probes again")
        expectEqual(center.state, .managed(SET_A), "case10 the new publication shows the controls")
        expectEqual(center.draft, SET_A, "case10 and its own draft")
    }

    // 11) A transient failure is recheckable: it must not be cached as "unsupported", so the
    //     next read probes again instead of leaving the page hidden.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .off)
        ScriptedSupport.reset([.failure(TransientFailure())])
        ScriptedReads.reset([.success(a), .success(a)])
        await center.refresh()
        expectEqual(center.state, .unavailable("暂时无法读取当前输入方式的设置。"),
                    "case11 a transient failure is reported as unreadable, not unsupported")
        expect(center.supportContext == nil, "case11 a failed probe must not be cached")
        ScriptedSupport.answers = [.success(true)]
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 2, "case11 the next read probes again")
        expectEqual(center.state, .off, "case11 and the feature shows once it is supported")
    }

    // 12) An answer that arrives after a save has started is not published; the verdict is
    //     tied to its exact context, so the next refresh reuses it without probing again.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .off)
        ScriptedSupport.reset([.success(true), .success(true)])
        ScriptedReads.reset([.success(a), .success(a)])
        ScriptedSupport.duringProbe = { center.setWorking(true) }
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 1, "case12 the probe did run")
        expectEqual(center.state, .loading, "case12 an answer overtaken by a save must not be published")
        center.setWorking(false)
        ScriptedSupport.duringProbe = nil
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 1, "case12 the next read reuses the verdict")
        expectEqual(center.supportContext, a, "case12 the answer is cached against its context")
        expectEqual(center.state, .off, "case12 and the controls appear")
    }
    // 13) A read that was already parked when a NEWER read published must not clobber it. The
    //     parked read carries an input method whose support answer is already cached as false,
    //     so it reaches the clearing branch without awaiting anything -- only the guard after
    //     the context read can stop it.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(schemaID: "rime_ice", state: .off)
        // A read whose state needs no support probe, so the parked read does not re-probe:
        // .userManaged leaves the cached answer for A in place.
        let b = makeContext(schemaID: "rime_ice", state: .userManaged)
        ScriptedSupport.reset([.success(false)])
        // 1) Prime: A is unsupported, so the answer is cached against A.
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.supportAllowed, false, "case13 the answer for A is cached as unsupported")
        expectEqual(center.state, .unavailable("这个输入方式暂不支持模糊音，请选择其他输入方式。"),
                    "case13 the controls start hidden")
        // 2) Park a second read of A, then let a newer read of B publish.
        let gate = AsyncGate()
        let entered = AsyncGate()
        ScriptedReads.reset([.success(a), .success(b)])
        ScriptedReads.gates = [0: gate]
        ScriptedReads.onEnter = { index in if index == 0 { Task { await entered.release() } } }
        let parked = Task { await center.refresh() }
        await entered.wait()
        await center.refresh()
        expectEqual(center.state, .userManaged, "case13 the newer read published its state")
        expectEqual(center.displayed, b, "case13 the newer read published its context")
        // 3) The parked read now finishes and must leave the newer state alone.
        await gate.release()
        await parked.value
        expectEqual(center.state, .userManaged, "case13 the parked read must not clobber the newer state")
        expectEqual(center.displayed, b, "case13 the parked read must not clear the newer context")
    }

    // 14) The same parked read finishing after a SAVE started must not wipe the edited draft.
    //     Here the token is unchanged, so only the save guard can stop it.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(schemaID: "rime_ice", state: .off)
        ScriptedSupport.reset([.success(false)])
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        center.draft = SET_B
        let gate = AsyncGate()
        let entered = AsyncGate()
        ScriptedReads.reset([.success(a)])
        ScriptedReads.gates = [0: gate]
        ScriptedReads.onEnter = { index in if index == 0 { Task { await entered.release() } } }
        let parked = Task { await center.refresh() }
        await entered.wait()
        center.setWorking(true)
        await gate.release()
        await parked.value
        expectEqual(center.draft, SET_B, "case14 a parked read must not wipe the draft a save is holding")
        // The read set the loading phase when it started, before parking; being dropped by the
        // save guard must not let it go on to publish its verdict.
        expectEqual(center.state, .loading,
                    "case14 the parked read must not publish its verdict while a save is in flight")
    }
    // 15) While the published read is still in flight the page reports loading, so the controls
    //     of a previous input method are never left editable while the new one is being read.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        // Prime a visible state, so a stale state would be observably wrong.
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .managed(SET_A), "case15 the page starts with the controls shown")
        let gate = AsyncGate()
        let entered = AsyncGate()
        ScriptedReads.reset([.success(a)])
        ScriptedReads.gates = [0: gate]
        ScriptedReads.onEnter = { index in if index == 0 { Task { await entered.release() } } }
        let parked = Task { await center.refresh() }
        await entered.wait()
        expectEqual(center.state, .loading, "case15 the page reports loading during the read")
        await gate.release()
        await parked.value
        expectEqual(center.state, .managed(SET_A), "case15 and settles on the read result")
    }

    // 16) The same holds while the native support check for a NEW source is in flight: the proof
    //     must not leave the previous source's controls on screen. The hook runs from inside the
    //     boundary call, so the page is inspected at the moment refresh is parked on it. The second
    //     context differs, so the cached answer cannot be reused and it really is proved again.
    do {
        let center = FuzzyPinyinCenter()
        let first = makeContext(schemaID: "rime_ice", revision: "rev-1", state: .managed(SET_A))
        let second = makeContext(schemaID: "rime_ice", revision: "rev-2", state: .managed(SET_A))
        ScriptedSupport.reset([.success(true)])
        ScriptedReads.reset([.success(first)])
        await center.refresh()
        expectEqual(center.state, .managed(SET_A), "case16 the page starts with the controls shown")
        expectEqual(ScriptedSupport.probes, 1, "case16 the first source was proved once")
        ScriptedSupport.duringProbe = {
            expectEqual(center.state, .loading, "case16 the page reports loading during the support check")
        }
        ScriptedReads.reset([.success(second)])
        await center.refresh()
        expectEqual(ScriptedSupport.probes, 2, "case16 the new source is proved again")
        expectEqual(center.state, .managed(SET_A), "case16 and settles once the check answers")
    }

    // 17) A read that completes after a newer one must not roll the page back to loading either:
    //     the phase is published once per accepted read, not by whichever read finishes last.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(schemaID: "rime_ice", state: .off)
        let b = makeContext(schemaID: "rime_ice", state: .userManaged)
        ScriptedSupport.reset([.success(false)])
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        let gate = AsyncGate()
        let entered = AsyncGate()
        ScriptedReads.reset([.success(a), .success(b)])
        ScriptedReads.gates = [0: gate]
        ScriptedReads.onEnter = { index in if index == 0 { Task { await entered.release() } } }
        let parked = Task { await center.refresh() }
        await entered.wait()
        await center.refresh()
        expectEqual(center.state, .userManaged, "case17 the newer read settles the page")
        await gate.release()
        await parked.value
        expectEqual(center.state, .userManaged, "case17 a late read must not leave the page loading")
    }
    // 18) A save is only allowed from the two states that offer the controls. While the new
    //     source is still being proved (or the page is unavailable), the previous source's
    //     controls must not be able to save anything.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .managed(SET_A))
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .managed(SET_A), "case18 the controls are offered")
        for blocked in [FuzzyPinyinCenter.State.loading, .unavailable("x"), .noSource, .userManaged] {
            center.setStateForTesting(blocked)
            center.save()
            expect(!center.saveStarted, "case18 a save from \(blocked) must be refused")
            expect(!center.working, "case18 a refused save must not go in flight")
        }
        center.setStateForTesting(.managed(SET_A))
        center.save()
        expect(center.saveStarted, "case18 a save from the managed state must start")
        expect(center.working, "case18 and go in flight")
    }

    // 19) The same for the off state, which is the other state that offers the controls.
    do {
        let center = FuzzyPinyinCenter()
        let a = makeContext(state: .off)
        ScriptedReads.reset([.success(a)])
        await center.refresh()
        expectEqual(center.state, .off, "case19 the off state is shown")
        center.save()
        expect(center.saveStarted, "case19 a save from the off state must start")
    }
    print("fuzzy pinyin state checks passed: draft/anchor/failure/notice/working/off-seed/support-gate/overtaken-read/loading-phase/save-scope")
}

await runChecks()