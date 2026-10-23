import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit

private final class LiteralFailureEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("external-literal-regression")
    var statusSummary: String { "fixture" }
    var state = EngineSnapshot()
    var inputUnavailableReason: String?
    var selectionFails = false
    var keys: [String] = []
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { state.schemaID = schemaID }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        keys.append(keyValue)
        throw EngineBackendError.operationFailed("fixed-fixture-key-failure")
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        if selectionFails { throw EngineBackendError.operationFailed("fixed-fixture-confirm-failure") }
        state = EngineSnapshot()
        return EngineSnapshot(committed: "confirmed-fixture")
    }
    func nextPage() throws -> EngineSnapshot { state }
    func previousPage() throws -> EngineSnapshot { state }
    func currentSnapshot() -> EngineSnapshot { state }
    func shutdown() {}
}

@main struct ExternalLiteralChecks {
    @MainActor static func eventually(_ reason: String, _ predicate: () -> Bool) async {
        for _ in 0..<1500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure(reason)
    }

    @MainActor static func type(_ text: String, into controller: KeyboardController) {
        for character in text {
            controller.handle(character == " " ? .space : .code(String(character)))
        }
    }

    @MainActor static func englishController() async -> (ProbeEngine, KeyboardController) {
        let engine = ProbeEngine()
        engine.state.schemaID = "source"
        let controller = KeyboardController(engine: engine)
        controller.onDispatchCommit = { _ in true }
        controller.setInputMode(.english)
        await eventually("English source capability did not resolve") { controller.englishSuggestionsSupported == true }
        return (engine, controller)
    }

    @MainActor static func noCompletionCacheOrCrossWordLearning() async throws {
        let (engine, controller) = await englishController()
        defer { controller.retire() }
        type("g", into: controller)
        await eventually("ordinary completion did not resolve") {
            controller.englishSuggestions == ["gword", "gwords"]
        }
        let queried = engine.prefixes
        let before = controller.commitSequence
        precondition(controller.insertExternalLiteral("externalfragment"))
        precondition(
            controller.commitSequence == before + 1 && controller.englishSuggestions.isEmpty,
            "external dispatch must count, but clear the old completion row")
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(engine.prefixes == queried, "external text must never become an English completion prefix")
        type("m", into: controller)
        await eventually("ordinary tracking did not resume") { controller.englishSuggestions == ["mword", "mwords"] }
        precondition(engine.prefixes.last == "m", "normal letters must not append to an external word")

        controller.resetEnglishWord()
        type("r", into: controller)
        let beforePending = engine.prefixes
        precondition(controller.insertExternalLiteral("externalanchor externalnext "))
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(engine.prefixes == beforePending, "the abandoned pending word query must be cancelled")
        type("typedafter ", into: controller)
        controller.resetEnglishWord()
        type("externalanchor ", into: controller)
        precondition(controller.englishSuggestions.isEmpty, "an external word pair must not be learned")
        controller.resetEnglishWord()
        type("externalnext ", into: controller)
        precondition(
            controller.englishSuggestions.isEmpty, "external trailing context must not learn the next typed word")

        controller.resetEnglishWord()
        type("typedanchor learnedword ", into: controller)
        controller.resetEnglishWord()
        type("typedanchor ", into: controller)
        precondition(
            controller.englishSuggestions == ["learnedword"], "ordinary key-driven word pairs must still learn")
        let beforeEmpty = controller.commitSequence
        precondition(!controller.insertExternalLiteral(""))
        precondition(controller.commitSequence == beforeEmpty)
        type("q", into: controller)
        await eventually("failed external call did not restore normal tracking") {
            controller.englishSuggestions == ["qword", "qwords"]
        }
        print(
            "PASS: external text neither becomes a completion prefix nor trains word pairs; ordinary tracking and learning resume"
        )
    }

    @MainActor static func nestedExternalScopes() async throws {
        let (engine, controller) = await englishController()
        defer { controller.retire() }
        var delivered: [String] = []
        var nested = false
        controller.onDispatchCommit = { text in
            if text == "outerfixture", !nested {
                nested = true
                precondition(controller.insertExternalLiteral("nestedanchor nestedword "))
            }
            delivered.append(text)
            return true
        }
        let queried = engine.prefixes
        let count = controller.commitSequence
        precondition(controller.insertExternalLiteral("outerfixture"))
        precondition(delivered == ["nestedanchor nestedword ", "outerfixture"])
        precondition(controller.commitSequence == count + 2)
        try await Task.sleep(nanoseconds: 80_000_000)
        precondition(
            engine.prefixes == queried, "an inner scope must not restore tracking before its outer scope finishes")
        controller.resetEnglishWord()
        type("nestedanchor ", into: controller)
        precondition(controller.englishSuggestions.isEmpty, "nested external pairs must not train")
        type("z", into: controller)
        await eventually("nested depth did not restore normal completion") {
            controller.englishSuggestions == ["zword", "zwords"]
        }
        print(
            "PASS: nested external scopes preserve accepted commit counts and restore ordinary tracking only after the outer call"
        )
    }

    @MainActor static func originalLiteralConfirmationAndFailures() {
        let external = "fixed external\nsecond line"
        for refusal in [0, 1, 2, 3] {
            let engine = LiteralFailureEngine()
            engine.state.isComposing = true
            engine.state.rawInput = "ni"
            engine.state.candidates = [Candidate(index: 0, text: "confirmed-fixture")]
            engine.selectionFails = refusal == 3
            let controller = KeyboardController(engine: engine)
            var attempts: [String] = []
            var accepted: [String] = []
            controller.onDispatchCommit = { text in
                attempts.append(text)
                let accepts = refusal == 0 || refusal == 2 && text == "confirmed-fixture"
                if accepts { accepted.append(text) }
                return accepts
            }
            let result = controller.insertExternalLiteral(external)
            if refusal == 0 {
                precondition(result && attempts == ["confirmed-fixture", external] && accepted == attempts)
                precondition(controller.commitSequence == 2)
            } else if refusal == 1 {
                precondition(!result && attempts == ["confirmed-fixture"] && accepted.isEmpty)
                precondition(controller.commitSequence == 0)
            } else if refusal == 2 {
                precondition(
                    !result && attempts == ["confirmed-fixture", external] && accepted == ["confirmed-fixture"])
                precondition(
                    controller.commitSequence == 1,
                    "a confirmed composition is not a successful dependent external literal")
            } else {
                precondition(!result && attempts.isEmpty && accepted.isEmpty && controller.inputError != nil)
                precondition(controller.commitSequence == 0)
            }
            precondition(engine.keys.isEmpty, "external text must never be sent through processKey")
            controller.retire()
        }
        let unavailableEngine = LiteralFailureEngine()
        unavailableEngine.inputUnavailableReason = "fixed-unavailable-input"
        let unavailable = KeyboardController(engine: unavailableEngine)
        var writes = 0
        unavailable.onDispatchCommit = { _ in
            writes += 1
            return true
        }
        precondition(!unavailable.insertExternalLiteral(external) && writes == 0 && unavailable.commitSequence == 0)
        unavailable.retire()
        precondition(!unavailable.insertExternalLiteral(external) && writes == 0)
        let noHost = KeyboardController(engine: LiteralFailureEngine())
        precondition(!noHost.insertExternalLiteral(external) && noHost.commitSequence == 0)
        noHost.retire()
        print(
            "PASS: original literal outlet confirms composition once, refuses partial success and engine/input/host failure"
        )
    }

    @MainActor static func main() async throws {
        try await noCompletionCacheOrCrossWordLearning()
        try await nestedExternalScopes()
        originalLiteralConfirmationAndFailures()
    }
}
