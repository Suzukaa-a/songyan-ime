import CandidateKit
import Foundation
import KeyboardCore
import LayoutKit
import OSLog

// Compile the unmodified controller body outside UIKit. These enums contain only
// the host traits it reads; neither input state nor controller behavior is stubbed.
public enum UIKeyboardType {
    case `default`, asciiCapable, numbersAndPunctuation, URL, emailAddress, numberPad, decimalPad,
        asciiCapableNumberPad, phonePad, namePhonePad, twitter, webSearch
}
public enum UIReturnKeyType {
    case `default`, go, google, yahoo, search, join, next, route, send, done, emergencyCall, `continue`
}
public enum UIKeyboardAppearance { case `default`, dark, light }
public enum UITextAutocapitalizationType { case none, words, sentences, allCharacters }
enum KeyboardLifecycleDiagnostics { static func emit(_ event: String, _ values: [String: String]) {} }
enum KeyboardStallReport { static func begin(_ kind: String) -> () -> Void { {} } }
extension Logger {
    static let keyboardController = Logger(subsystem: "app.songyan.ime", category: "KeyboardController")
}

// RimeBackend is only a production downcast for diagnostics/persistence. The
// behavioral fixture below uses EngineBackend and real InputSession instead.
class RimeBackend: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("controller-regression")
    var lastErrorText: String?
    var optionPersistenceError: Error?
    var onOptionPersistenceCompleted: (@MainActor (Error?) -> Void)?
    var statusSummary: String { "fixture" }
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {}
    func processKey(_ keyValue: String) throws -> EngineSnapshot { EngineSnapshot() }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { EngineSnapshot() }
    func nextPage() throws -> EngineSnapshot { EngineSnapshot() }
    func previousPage() throws -> EngineSnapshot { EngineSnapshot() }
    func currentSnapshot() -> EngineSnapshot { EngineSnapshot() }
    func shutdown() {}
}

final class ProbeEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("controller-regression")
    var statusSummary: String { "fixture" }
    var state = EngineSnapshot()
    var selectedAbsolute: Int?
    var probeGate: DispatchSemaphore?
    private let lock = NSLock()
    private var didStartProbe = false
    private var queriedPrefixes: [String] = []
    var probeStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didStartProbe
    }
    var prefixes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return queriedPrefixes
    }
    var supportsReadOnlyBrowsing: Bool { true }
    /// Puts this code key into a real composing state (default nil = every key commits directly, leaving other cases unaffected).
    var composingCode: String?
    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws { state.schemaID = schemaID }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        if keyValue == "Esc" {
            state.isPrediction = false
            state.candidates = []
            return state
        }
        // Real engine semantics: confirm (newline) ends the composition and commits its content. Without this,
        // `commitComposition` would correctly refuse later direct input because "the composition is still open" -
        // which is an incomplete fixture, not a production defect.
        if keyValue == "\n", state.isComposing {
            var confirmed = EngineSnapshot(committed: state.preedit)
            confirmed.schemaID = state.schemaID
            var cleared = EngineSnapshot()
            cleared.schemaID = state.schemaID
            state = cleared
            return confirmed
        }
        if let composingCode, keyValue == composingCode {
            var composing = state
            composing.isComposing = true
            composing.preedit = keyValue
            composing.committed = ""
            state = composing
            return composing
        }
        var result = state
        result.committed = keyValue
        return result
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot { try selectCandidateAbsolute(index) }
    func selectCandidateAbsolute(_ index: Int) throws -> EngineSnapshot {
        selectedAbsolute = index
        var result = EngineSnapshot(committed: "c\(index)")
        result.schemaID = state.schemaID
        state = EngineSnapshot()
        return result
    }
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        Array(fromIndex..<min(5, fromIndex + count)).enumerated().map {
            Candidate(index: $0.offset, text: "c\($0.element)")
        }
    }
    func wordCompletionSchemas(sourceSchemaID: String) throws -> [String] {
        lock.lock()
        didStartProbe = true
        lock.unlock()
        if let probeGate { precondition(probeGate.wait(timeout: .now() + 5) == .success) }
        return ["english"]
    }
    func wordCompletions(prefix: String, schemaID: String, limit: Int) throws -> [String]? {
        lock.lock()
        queriedPrefixes.append(prefix)
        lock.unlock()
        return prefix == "th" ? ["the", "this"] : [prefix + "word", prefix + "words"]
    }
    func nextPage() throws -> EngineSnapshot { state }
    func previousPage() throws -> EngineSnapshot { state }
    func currentSnapshot() -> EngineSnapshot { state }
    func shutdown() {}
}

@main struct ControllerInputChecks {
    @MainActor static func eventually(_ message: String, _ predicate: () -> Bool) async {
        for _ in 0..<500 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure(message)
    }

    @MainActor static func letters(ascii: Bool) {
        let engine = ProbeEngine()
        engine.state.isAsciiMode = ascii
        let controller = KeyboardController(engine: engine)
        if !ascii { controller.setInputMode(.english) }
        var commits: [String] = []
        var accepts = true
        controller.onDispatchCommit = { text in
            if accepts { commits.append(text) }
            return accepts
        }
        controller.handleShiftTap()
        controller.handle(.letterVariant("á"))
        precondition(commits == ["Á"] && controller.shiftState == .off, "variant must consume once")
        controller.handle(.code("b"))
        precondition(commits.last == "b")
        controller.handleShiftDoubleTap()
        controller.handle(.letterVariant("é"))
        precondition(commits.last == "É" && controller.shiftState == .locked)
        controller.handleShiftTap()
        controller.handleShiftTap()
        accepts = false
        controller.handle(.letterVariant("á"))
        precondition(controller.shiftState == .once, "refused variant must keep shift")
        controller.handle(.code("a"))
        precondition(controller.shiftState == .once, "refused ordinary letter must keep shift")
        accepts = true
        controller.handle(.literal("á"))
        precondition(commits.last == "á" && controller.shiftState == .once, "DIY literal stays verbatim")
        controller.handle(.letterVariant("1"))
        precondition(controller.shiftState == .once)
        controller.handle(.letterVariant("á"))
        precondition(commits.last == "Á" && controller.shiftState == .off)
        controller.updateHostTraits(
            keyboardType: .default, returnKeyType: .default,
            keyboardAppearance: .default, autocapitalizationType: .allCharacters, beforeCursor: "word")
        controller.handle(.letterVariant("é"))
        controller.handle(.code("b"))
        precondition(
            commits.suffix(2) == ["É", "B"] && controller.shiftState == .once,
            "allCharacters re-arms after both input routes")
        controller.retire()
    }

    /// Repeated taps of the idle first key rotate through symbols (nine-key, "item 4 onward").
    ///
    /// Real contract (everything goes through production `cycleT9Punctuation(symbols:)`; its logic is not copied):
    /// 1. On an empty field the first tap inserts item 1;
    /// 2. A second tap within 0.8 s with the document context unchanged -> **replaces** the previous item with the next, cycling back to item 1;
    /// 3. While composing, the call returns false (the first key is still a segment delimiter, not taken over by rotation);
    /// 4. After retirement it returns false (no more document writes).
    @MainActor static func punctuationCycle() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        var commits: [String] = []
        // Host semantics: an accepted commit really enters the document, so the context read-back sees it.
        controller.onDispatchCommit = { text in
            commits.append(text)
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            // Production semantics: replacement is allowed only while the document suffix still equals expected.
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let symbols = ["！", "、", "…"]

        precondition(controller.cycleT9Punctuation(symbols: symbols), "empty field must insert the first symbol")
        precondition(document == "！" && commits == ["！"], "first tap inserts symbols[0]")

        precondition(controller.cycleT9Punctuation(symbols: symbols), "second tap must advance")
        precondition(document == "、", "second tap must replace, not append: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "third tap must advance")
        precondition(document == "…", "third tap: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "fourth tap must wrap")
        precondition(document == "！", "cycle must wrap to the first symbol: \(document)")

        // Empty order: nothing may be inserted, and it must not crash.
        precondition(!controller.cycleT9Punctuation(symbols: []), "empty order must be refused")
        precondition(document == "！")

        // While composing: the first key is still a delimiter and rotation must not take over (enter composing via the real engine, without changing controller visibility).
        engine.composingCode = "n"
        controller.handle(.code("n"))
        precondition(controller.snapshot.isComposing, "fixture must be composing")
        precondition(!controller.cycleT9Punctuation(symbols: symbols), "composing must refuse the cycle")
        precondition(document == "！", "composing must not write the document")
        engine.composingCode = nil

        controller.retire()
        precondition(!controller.cycleT9Punctuation(symbols: symbols), "retired controller must refuse")
    }

    /// The "1" selected by long-pressing the first key goes through a **plain literal action** and does not take part in rotation.
    ///
    /// The panel branches on the selected cap (rotation only when `selected == cap`), so what actually runs when the finger lifts after a long-press on 1
    /// is `handleDefinitionAction(.literal("1"))` -> `handleKey` -> one ordinary commit.
    /// This pins that semantics with a real controller:
    /// 1. Idle long-press 1 = insert `1`, and does **not** replace/advance any rotation item;
    /// 2. The rotation pointer is unaffected by the long-press: a short tap right after still starts from item 1;
    /// 3. Long-press 1 while composing = commit the composition first, then insert `1` (existing commit semantics; not a delimiter, not rotation).
    @MainActor static func firstKeyLongPressInsertsOne() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        var commits: [String] = []
        controller.onDispatchCommit = { text in
            commits.append(text)
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let symbols = ["！", "、", "…"]

        // Long-press 1: plain literal commit.
        controller.handle(.literal("1"))
        precondition(document == "1", "long press 1 must insert the digit: \(document)")
        precondition(commits == ["1"], "exactly one commit: \(commits)")

        // The rotation pointer is unaffected by the long-press: a short tap right after is still item 1 (replace, not advance).
        precondition(controller.cycleT9Punctuation(symbols: symbols), "cycle after long press")
        precondition(
            document == "1！", "a short tap inserts from item 1 and does not continue the long-press: \(document)")
        precondition(controller.cycleT9Punctuation(symbols: symbols), "second short tap advances")
        precondition(document == "1、", "second short tap replaces: \(document)")

        // Long-press 1 while composing: commit the composition first (existing semantics), then insert 1; no delimiter, no rotation.
        let engine2 = ProbeEngine()
        engine2.composingCode = "n"
        let composing = KeyboardController(engine: engine2)
        var composingDocument = ""
        composing.onDispatchCommit = { text in
            composingDocument += text
            return true
        }
        composing.onReadDocumentContext = { composingDocument }
        composing.onReplaceLiteralSuffix = { expected, old, new in
            guard composingDocument.hasSuffix(expected), composingDocument.hasSuffix(old) else { return false }
            composingDocument.removeLast(old.count)
            composingDocument += new
            return true
        }
        composing.handle(.code("n"))
        precondition(composing.snapshot.isComposing, "fixture must be composing")
        let beforeDigits = composingDocument
        precondition(
            !composing.cycleT9Punctuation(symbols: symbols),
            "a short tap while composing is still a delimiter: rotation must refuse")
        precondition(composingDocument == beforeDigits, "rotation while composing must not write the document")
        composing.handle(.literal("1"))
        precondition(
            composingDocument.hasSuffix("1"),
            "long-press 1 while composing must still insert the digit: \(composingDocument)")
        precondition(
            !composingDocument.hasSuffix("'"),
            "long-press 1 must never be treated as a delimiter: \(composingDocument)")
        composing.retire()
        controller.retire()
    }

    @MainActor static func probeWhileTyping() async {
        let engine = ProbeEngine()
        engine.state.schemaID = "source"
        let gate = DispatchSemaphore(value: 0)
        engine.probeGate = gate
        let controller = KeyboardController(engine: engine)
        controller.onDispatchCommit = { _ in true }
        controller.setInputMode(.english)
        await eventually("probe never started") { engine.probeStarted }
        controller.handle(.code("h"))
        controller.handle(.code("e"))
        precondition(controller.englishSuggestions.isEmpty)
        gate.signal()
        await eventually("probe completion did not query the current word") {
            controller.englishSuggestions == ["heword", "hewords"]
        }
        precondition(engine.prefixes == ["th", "he"], "query the current word once")
        controller.retire()
    }

    @MainActor static func probeAfterLeavingABC() async {
        let engine = ProbeEngine()
        engine.state.schemaID = "source"
        let gate = DispatchSemaphore(value: 0)
        engine.probeGate = gate
        let controller = KeyboardController(engine: engine)
        controller.onDispatchCommit = { _ in true }
        controller.setInputMode(.english)
        await eventually("probe never started") { engine.probeStarted }
        controller.handle(.code("h"))
        controller.setInputMode(.chinese)
        gate.signal()
        await eventually("probe did not finish") { controller.englishSuggestionsSupported == true }
        precondition(
            controller.englishSuggestions.isEmpty && engine.prefixes == ["th"],
            "late probe must not query the abandoned word")
        controller.retire()
    }

    @MainActor static func predictionPaging() async {
        let engine = ProbeEngine()
        engine.state = EngineSnapshot(
            candidates: [Candidate(index: 0, text: "c0"), Candidate(index: 1, text: "c1")],
            pageSize: 2, isLastPage: false)
        engine.state.isPrediction = true
        let controller = KeyboardController(engine: engine)
        var commits: [String] = []
        var nonnilMarks = 0
        controller.onDispatchCommit = {
            commits.append($0)
            return true
        }
        controller.onMarkedComposition = { if $0 != nil { nonnilMarks += 1 } }
        precondition(!controller.snapshot.isComposing && controller.candidateBrowser.hasMore)
        controller.loadMoreCandidates()
        await eventually("prediction next pages were not loaded") { controller.candidateBrowser.count == 5 }
        precondition(!controller.candidateBrowser.hasMore && nonnilMarks == 0 && commits.isEmpty)
        controller.selectCandidate(pageIndex: 2, pageLocalIndex: 0)
        precondition(engine.selectedAbsolute == 4 && commits == ["c4"])
        precondition(controller.candidateBrowser.isEmpty && nonnilMarks == 0)
        controller.retire()
    }

    /// For the built-in nine-key digits 2-9, long-press and tap must be two distinct semantic paths:
    /// - tap = `.code(digit)`: handed to the engine (composition/candidates);
    /// - long-press = `.literal(digit)`: types the digit directly, bypassing engine composition.
    /// If both behave the same, the declared long-press secondary key was lost (the generic letter policy returns empty for digit-code keys).
    @MainActor static func t9DigitLongPressIsLiteralNotCode() {
        let engine = ProbeEngine()
        let controller = KeyboardController(engine: engine)
        var document = ""
        controller.onDispatchCommit = { text in
            document += text
            return true
        }
        controller.onReadDocumentContext = { document }
        controller.onReplaceLiteralSuffix = { expected, old, new in
            guard document.hasSuffix(expected), document.hasSuffix(old) else { return false }
            document.removeLast(old.count)
            document += new
            return true
        }
        let alphabet = "abcdefghijklmnopqrstuvwxyz"

        // The declaration must really provide a "long-press types the digit" secondary key, otherwise the semantic assertions below are meaningless.
        for digit in ["2", "3", "4", "5", "6", "7", "8", "9"] {
            let key = BuiltinLayouts.phone9.rows.flatMap(\.keys)
                .first { $0.action.type == .code && $0.action.value == digit }
            precondition(key != nil, "the built-in nine-key must declare digit key \(digit)")
            precondition(
                BuiltinLayouts.t9DigitKeyUsesDeclaredAlternates(key!),
                "\(digit) must take the declared path (otherwise the long-press secondary key is empty)")
            let declared = key!.longPress ?? []
            precondition(
                declared.count == 1 && declared[0].action == .init(.literal, value: digit),
                "the declared long-press of \(digit) must be literal \(digit), got \(declared.map(\.action))")
            // The generic policy returns empty for this key - it cannot go through that path.
            let policy = AlternateKeyPolicy.options(
                for: .init(
                    keyLabel: digit, mergedGroup: key!.label.lowercased(),
                    secondaryLiterals: declared.compactMap { $0.action.value },
                    page: .letters, language: .chinese, schemaAlphabet: alphabet))
            precondition(policy.isEmpty, "\(digit) generic policy is expected to return empty")
        }

        // Long-press path: literal types directly, the digit appears in the document at once (no composition).
        controller.handle(.literal("6"))
        precondition(document == "6", "long-press 6 must type the digit directly: \(document)")
        precondition(!controller.snapshot.isComposing, "typing a digit directly must not leave a composition")
        controller.handle(.literal("2"))
        precondition(document == "62", "long-press 2 must type the digit directly: \(document)")

        // Tap path: the code goes to the engine (ProbeEngine returns commit/composition with real-engine semantics).
        controller.handle(.code("6"))
        precondition(document.hasSuffix("6"), "a digit-code tap must still go through the engine: \(document)")
        controller.retire()
    }

    @MainActor static func main() async {
        letters(ascii: false)
        letters(ascii: true)
        punctuationCycle()
        firstKeyLongPressInsertsOne()
        t9DigitLongPressIsLiteralNotCode()
        await probeWhileTyping()
        await probeAfterLeavingABC()
        await predictionPaging()
        print("controller input regression checks passed")
    }
}
