import XCTest

@testable import KeyboardCore

/// Return without candidates commits the engine's raw input. On an adapter whose alphabet
/// takes the exact tokens, the engine read each token as its letter, so the host gets the
/// letter; any other commit stays as typed.
@MainActor
final class ExactTokenCommitTests: XCTestCase {
    /// Offers 你 for a leading `ni` and nothing else. Return commits the confirmed text and
    /// then the raw input after it, as librime's express_editor does, unless the schema says
    /// otherwise.
    private final class RawReturnEngine: EngineBackend {
        private var input = ""
        private var confirmed = ""
        private var consumed = 0
        var alphabet: String?
        var asciiMode = false
        var returnCommit: ((String) -> String)?
        var kind: EngineBackendKind { .demoSimulator("raw") }
        var statusSummary: String { "raw" }
        func setup(sharedDirectory: URL, userDirectory: URL) throws {}
        func validateSchema(_ schemaID: String) throws {}
        func selectSchema(_ schemaID: String) throws {}
        func spellerAlphabet(schemaID: String) -> String? { schemaID == "adapter" ? alphabet : nil }
        func processKey(_ keyValue: String) throws -> EngineSnapshot {
            if keyValue == "\n" {
                let commit = confirmed + input.dropFirst(consumed)
                (input, confirmed, consumed) = ("", "", 0)
                var snapshot = EngineSnapshot(committed: returnCommit?(commit) ?? commit)
                snapshot.schemaID = "adapter"
                return snapshot
            }
            if keyValue == "Esc" { (input, confirmed, consumed) = ("", "", 0) } else { input += keyValue }
            return currentSnapshot()
        }
        func selectCandidate(_ index: Int) throws -> EngineSnapshot {
            if confirmed.isEmpty, input.hasPrefix("ni") { (confirmed, consumed) = ("你", 2) }
            return currentSnapshot()
        }
        func nextPage() throws -> EngineSnapshot { currentSnapshot() }
        func previousPage() throws -> EngineSnapshot { currentSnapshot() }
        func currentSnapshot() -> EngineSnapshot {
            let preedit = confirmed + input.dropFirst(consumed)
            let candidates = confirmed.isEmpty && input.hasPrefix("ni") ? [Candidate(index: 0, text: "你")] : []
            var snapshot = EngineSnapshot(
                candidates: candidates, preedit: preedit, rawInput: input, isComposing: !input.isEmpty)
            snapshot.preeditSelStart = confirmed.utf8.count
            snapshot.preeditSelEnd = preedit.utf8.count
            snapshot.schemaID = "adapter"
            snapshot.isAsciiMode = asciiMode
            return snapshot
        }
        func shutdown() {}
    }

    private static let adapterAlphabet = "!#%*+<>@^_abcdefghijklmnopqrstuvwxyz|~"

    private func confirm(
        _ keys: [String], layout: KeyboardLayoutKind = .merged14, alphabet: String? = adapterAlphabet,
        asciiMode: Bool = false, selectingFirst: Bool = false, returnCommit: ((String) -> String)? = nil
    ) -> [String] {
        let engine = RawReturnEngine()
        engine.alphabet = alphabet
        engine.asciiMode = asciiMode
        engine.returnCommit = returnCommit
        let session = InputSession(engine: engine, layout: layout)
        var commits: [String] = []
        session.onCommitted = { commits.append($0) }
        keys.forEach { session.tap(.code($0)) }
        if selectingFirst { session.selectCandidate(0) }
        XCTAssertTrue(session.snapshot.isComposing && session.snapshot.candidates.isEmpty)
        session.commitComposition()
        XCTAssertFalse(session.snapshot.isComposing)
        return commits
    }

    private func token(_ letter: Character, in fold: CompactFold = .merged14) throws -> String {
        String(try XCTUnwrap(fold.exactTokens[letter]))
    }

    func testExactPicksCommitAsLetters() throws {
        let q = try token("q"), d = try token("d")
        XCTAssertEqual(confirm([q]), ["q"])
        XCTAssertEqual(confirm([q, "w", d]), ["qwd"])
        XCTAssertEqual(confirm([try token("s", in: .merged18), "a"], layout: .merged18), ["sa"])
    }

    /// The engine reads any exact token as its letter, whichever key typed it.
    func testEveryExactTokenSpellsItsLetter() throws {
        let q = try token("q")
        XCTAssertEqual(confirm([q, q]), ["qq"])
    }

    func testSchemaDefinedReturnCommitIsUnchanged() throws {
        let q = try token("q")
        XCTAssertEqual(confirm(["a", q]) { _ in "done" + q }, ["done" + q])
    }

    func testAsciiModeCommitsUnchanged() throws {
        let q = try token("q")
        XCTAssertEqual(confirm(["a", q], asciiMode: true), ["a" + q])
    }

    func testSchemasWithoutExactTokensCommitUnchanged() throws {
        let q = try token("q")
        XCTAssertEqual(confirm(["a", q], alphabet: "abcdefghijklmnopqrstuvwxyz"), ["a" + q])
        XCTAssertEqual(confirm(["a", q], alphabet: nil), ["a" + q])
        XCTAssertEqual(confirm(["q", "!"], layout: .qwerty26), ["q!"])
    }

    /// Rime commits the selected 你 and then the raw `!` after it.
    func testPartialSelectionSpellsOnlyTheRawTail() throws {
        let q = try token("q")
        XCTAssertEqual(confirm(["n", "i", q], selectingFirst: true), ["你q"])
        XCTAssertEqual(confirm(["n", "i", "a", q], selectingFirst: true), ["你aq"])
    }

    func testPartialSelectionWithAnotherPrefixIsUnchanged() throws {
        let q = try token("q")
        let replaced = confirm(["n", "i", q], selectingFirst: true) { "您" + $0.dropFirst() }
        XCTAssertEqual(replaced, ["您" + q])
        let rewritten = confirm(["n", "i", q], selectingFirst: true) { $0 + "!" }
        XCTAssertEqual(rewritten, ["你" + q + "!"])
    }
}
