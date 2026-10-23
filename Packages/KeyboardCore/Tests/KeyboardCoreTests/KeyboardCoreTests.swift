import XCTest

@testable import KeyboardCore

// Baseline: Tests/EngineFixtures/Builtin/encodings.tsv (built-in package fixture, original data).
// Only entries present in the demo word list are compared; uncovered syllables are returned as nil/skipped by LayoutCodeProjector.

@MainActor
final class LayoutCodeProjectorTests: XCTestCase {

    private func assertCodes(
        _ text: String,
        pinyin: String,
        flypy26: String,
        flypy14: String,
        t9: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let syllables = pinyin.split(separator: " ").map(String.init)
        XCTAssertEqual(
            LayoutCodeProjector.composeCode(syllables: syllables, for: .fullPinyin),
            pinyin.replacingOccurrences(of: " ", with: ""), file: file, line: line)
        XCTAssertEqual(
            LayoutCodeProjector.composeCode(syllables: syllables, for: .xiaohe26),
            flypy26, file: file, line: line)
        XCTAssertEqual(
            LayoutCodeProjector.composeCode(syllables: syllables, for: .xiaohe14),
            flypy14, file: file, line: line)
        XCTAssertEqual(
            LayoutCodeProjector.composeCode(syllables: syllables, for: .phoneDigits),
            t9, file: file, line: line)
    }

    func testHelloAgainstFixture() {
        assertCodes("你好", pinyin: "ni hao", flypy26: "nihc", flypy14: "bugc", t9: "64426")
    }

    func testChineseAgainstFixture() {
        assertCodes("中国", pinyin: "zhong guo", flypy26: "vsgo", flypy14: "cago", t9: "94664486")
    }

    func testLearningAndWork() {
        assertCodes("学习", pinyin: "xue xi", flypy26: "xtxi", flypy14: "ztzu", t9: "98394")
        assertCodes("工作", pinyin: "gong zuo", flypy26: "gszo", flypy14: "gazo", t9: "4664986")
    }

    func testKeyboardFixture() {
        // keyboard jian pan -> 26: jm pj -> 14: jm oj -> t9: 5426726
        assertCodes("键盘", pinyin: "jian pan", flypy26: "jmpj", flypy14: "jmoj", t9: "5426726")
    }

    func testBankAndGrowth() {
        assertCodes("银行", pinyin: "yin hang", flypy26: "ybhh", flypy14: "tbgg", t9: "9464264")
        assertCodes("长大", pinyin: "zhang da", flypy26: "vhda", flypy14: "cgda", t9: "9426432")
    }

    func testT9Groups() {
        // 9-key fold: abc->2 ... wxyz->9
        XCTAssertEqual(LayoutCodeProjector.composeCode(syllables: ["nv", "hai"], for: .phoneDigits), "68424")
        XCTAssertEqual(LayoutCodeProjector.composeCode(syllables: ["er", "yue"], for: .phoneDigits), "37983")
    }

    func testSingleSyllableEdge() {
        XCTAssertEqual(LayoutCodeProjector.codeForSyllable("shuang", encoding: .xiaohe26), "ul")
        XCTAssertEqual(LayoutCodeProjector.codeForSyllable("liang", encoding: .xiaohe26), "ll")
        XCTAssertEqual(LayoutCodeProjector.codeForSyllable("er", encoding: .xiaohe26), "er")
        XCTAssertEqual(LayoutCodeProjector.codeForSyllable("men", encoding: .xiaohe26), "mf")
        // ch->i, e kept; i->u, e->e
        XCTAssertEqual(LayoutCodeProjector.codeForSyllable("che", encoding: .xiaohe14), "ue")
    }
}

@MainActor
final class DemoEngineTests: XCTestCase {

    private func makeEngine() throws -> (DemoEngine, InputSession) {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        let session = InputSession(engine: engine, layout: .qwerty26)
        return (engine, session)
    }

    func testCompositionAndCandidates() throws {
        let (_, session) = try makeEngine()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }

        "nihao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.snapshot.rawInput, "nihao")
        XCTAssertTrue(session.snapshot.candidates.contains { $0.text == "你好" })

        session.selectCandidate(0)
        XCTAssertEqual(committed, ["你好"])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testSpaceCommitsFirstCandidate() throws {
        let (_, session) = try makeEngine()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        "zhongguo".forEach { session.tap(.code(String($0))) }
        session.tap(.space)
        XCTAssertEqual(committed, ["中国"])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testSpaceWithoutCompositionInsertsSpace() throws {
        let (_, session) = try makeEngine()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tap(.space)
        XCTAssertEqual(committed, [" "])
    }

    func testEnterWithoutCompositionRequestsNewline() throws {
        let (_, session) = try makeEngine()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tap(.enter)
        XCTAssertEqual(committed, ["\n"])
    }

    func testBackspaceRemovesCodeChar() throws {
        let (_, session) = try makeEngine()
        "nihao".forEach { session.tap(.code(String($0))) }
        session.tap(.backspace)
        XCTAssertEqual(session.snapshot.rawInput, "niha")
    }

    func testSchemaSwitchResetsComposition() throws {
        let (_, session) = try makeEngine()
        session.onDispatchCommit = { _ in true }
        "nihao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        session.select(layout: .merged14)
        XCTAssertEqual(session.layout, .merged14)
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testFourteenKeyCompositionUsesMergedCode() throws {
        let (_, session) = try makeEngine()
        session.select(layout: .merged14)
        // "你好" in 14-key full pinyin = ni hao folded -> bugao
        "bugao".forEach { session.tap(.code(String($0))) }
        XCTAssertEqual(session.snapshot.rawInput, "bugao")
        XCTAssertTrue(session.snapshot.candidates.contains { $0.text == "你好" })
    }

    func testT9KeyOneIsIgnored() throws {
        let (_, session) = try makeEngine()
        session.select(layout: .phone9)
        session.tap(.code("1"))
        XCTAssertEqual(session.snapshot.rawInput, "")
        session.tap(.code("6"))
        session.tap(.code("4"))
        XCTAssertEqual(session.snapshot.rawInput, "64")
    }

    func testEngineKindIsDemo() throws {
        let (engine, _) = try makeEngine()
        guard case .demoSimulator = engine.kind else {
            return XCTFail("engine.kind must be .demoSimulator")
        }
        XCTAssertFalse(engine.kind.isRealRime)
    }
}

@MainActor
final class InputSessionModeTests: XCTestCase {

    /// Engine/session helper: collects onCommitted order to assert "confirm before direct insert".
    private func makeSession() throws -> (DemoEngine, InputSession, () -> [String]) {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        let session = InputSession(engine: engine, layout: .qwerty26)
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        return (engine, session, { committed })
    }

    func testInsertLiteralWhenIdle() throws {
        let (_, session, committed) = try makeSession()
        session.insertLiteral("，")
        XCTAssertEqual(committed(), ["，"])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testInsertLiteralCommitsCompositionFirst() throws {
        let (_, session, committed) = try makeSession()
        "nihao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        session.insertLiteral("，")
        // The composition confirms "你好" first, then the symbol is inserted directly: nothing typed is lost or swallowed.
        XCTAssertEqual(committed(), ["你好", "，"])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testLiteralKeyActionRoutesToInsertLiteral() throws {
        let (_, session, committed) = try makeSession()
        "nihao".forEach { session.tap(.code(String($0))) }
        session.tap(.literal("1"))
        XCTAssertEqual(committed(), ["你好", "1"])
    }

    func testCommitCompositionWithoutCandidatesCommitsRawCode() throws {
        let (_, session, committed) = try makeSession()
        // "qq" has no dictionary prefix: the composition has codes but no candidates -> Return commits the raw composition text.
        "qq".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty)
        session.commitComposition()
        XCTAssertEqual(committed(), ["qq"])
        XCTAssertFalse(session.snapshot.isComposing)
    }

    func testSetEnglishModeCommitsThenLettersInsertLiterally() throws {
        let (_, session, committed) = try makeSession()
        "nihao".forEach { session.tap(.code(String($0))) }
        session.setMode(.english)
        XCTAssertEqual(session.mode, .english)
        XCTAssertEqual(committed(), ["你好"])
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty, "the English page shows no composition leftovers")
        session.tap(.code("a"))
        session.tap(.space)
        session.tap(.enter)
        XCTAssertEqual(committed(), ["你好", "a", " ", "\n"])
    }

    func testEnglishBackToChineseComposesAgain() throws {
        let (_, session, committed) = try makeSession()
        session.setMode(.english)
        session.tap(.code("x"))
        session.setMode(.chinese)
        XCTAssertEqual(session.mode, .chinese)
        "nihao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.contains { $0.text == "你好" })
        XCTAssertEqual(committed(), ["x"])
    }
}

@MainActor
final class KeyboardLayoutTableTests: XCTestCase {
    func testAllLayoutsProduceRowsWithActions() {
        for layout in KeyboardLayoutKind.allCases {
            let rows = KeyboardLayoutTable.rows(for: layout)
            XCTAssertFalse(rows.isEmpty, "\(layout) should have rows")
            let caps = rows.flatMap(\.caps)
            XCTAssertFalse(caps.isEmpty)
            XCTAssertEqual(Set(caps.map(\.id)).count, caps.count, "key ids must be unique")
            // control row exists in every layout
            XCTAssertTrue(caps.contains { $0.action == .space })
            XCTAssertTrue(caps.contains { $0.action == .backspace })
            XCTAssertTrue(caps.contains { $0.action == .enter })
            XCTAssertTrue(caps.contains { $0.action == .switchKeyboard })
            XCTAssertTrue(caps.contains { $0.action == .cycleLayout })
        }
    }

    func testFourteenKeyReps() {
        let rows = KeyboardLayoutTable.mainRows(for: .merged14)
        let codes = rows.flatMap(\.caps).compactMap { cap -> String? in
            if case .code(let c) = cap.action { return c }
            return nil
        }
        // 14 logical keys
        XCTAssertEqual(codes.count, 14)
        XCTAssertEqual(Set(codes).sorted().joined(), "abcdegjlmoqtuz")
    }
}
