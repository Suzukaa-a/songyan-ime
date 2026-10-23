import XCTest

@testable import KeyboardCore

// Minimal regression for three features:
//  1. InputSession.apply keeps paging metadata (pageIndex/pageSize/isLastPage);
//  2. standalone English QWERTY row data + three-state Shift (once resets after a letter / double-tap locks);
//  3. the moveCursor(by:) host-callback hook (confirm first, then move, while composing).
// No defensive matrix; each test verifies one real semantic.

// MARK: - Paging metadata regression (the engine provides real paging fields)

/// Pageable stub engine: 3 pages x pageSize 3; paging/keys/selection return the full paging fields.
private final class PagedStubEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("分页回归桩")
    private var code = ""
    private var page = 0
    let pageSize = 3
    let pageCount = 3
    var asciiMode = false
    private(set) var processedKeys: [String] = []

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {
        code = ""
        page = 0
    }
    func shutdown() {
        code = ""
        page = 0
    }
    var statusSummary: String { "PagedStubEngine" }

    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        processedKeys.append(keyValue)
        if keyValue == "\u{08}" {
            if !code.isEmpty { code.removeLast() }
        } else if code.count < 3 {
            code.append(keyValue)
        }
        return snapshot()
    }

    func nextPage() throws -> EngineSnapshot {
        page = min(pageCount - 1, page + 1)
        return snapshot()
    }

    func previousPage() throws -> EngineSnapshot {
        page = max(0, page - 1)
        return snapshot()
    }

    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        guard code.isEmpty ? false : index >= 0 && index < pageSize else {
            throw EngineBackendError.operationFailed("无候选")
        }
        let text = "词\(page * pageSize + index)"
        code = ""
        page = 0
        var snap = snapshot()
        snap.committed = text
        return snap
    }

    // MARK: Read-only cross-page browsing (does not change page/highlight/candidate cache)

    var supportsReadOnlyBrowsing: Bool { true }

    /// Returns candidates by absolute index offset and **does not change** `page` (contrast with nextPage/previousPage).
    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        guard !code.isEmpty, pageSize > 0, fromIndex >= 0, count > 0 else { return [] }
        let total = pageSize * pageCount
        var result: [Candidate] = []
        var absolute = fromIndex
        while result.count < count, absolute < total {
            result.append(Candidate(index: absolute % pageSize, text: "词\(absolute)"))
            absolute += 1
        }
        return result
    }

    func currentSnapshot() -> EngineSnapshot { snapshot() }

    private func snapshot() -> EngineSnapshot {
        let composing = !code.isEmpty
        let candidates: [Candidate] =
            composing
            ? (0..<pageSize).map { Candidate(index: $0, text: "词\(page * pageSize + $0)") }
            : []
        var result = EngineSnapshot(
            committed: "",
            candidates: candidates,
            preedit: composing ? code : "",
            rawInput: composing ? code : "",
            isComposing: composing,
            highlightedIndex: composing ? 0 : -1,
            pageIndex: page,
            pageSize: composing ? pageSize : 0,
            isLastPage: page == pageCount - 1
        )
        result.isAsciiMode = asciiMode
        return result
    }
}

@MainActor
final class PaginationMetadataRegressionTests: XCTestCase {

    private func makeSession() throws -> InputSession {
        let engine = PagedStubEngine()
        try engine.selectSchema("songyan_quanpin")
        return InputSession(engine: engine, layout: .qwerty26)
    }

    func testPageMetadataSurvivesEverySnapshotRebuild() throws {
        let session = try makeSession()
        session.tap(.code("n"))
        session.nextPage()  // page 0 → 1
        XCTAssertEqual(session.snapshot.pageIndex, 1)

        // Regression: the apply on the next key used to rebuild the snapshot and reset pageIndex/pageSize/isLastPage to defaults,
        // leaving canPageForward/canPageBackward always false. They must still be kept after a key press.
        session.tap(.code("i"))  // triggers an apply rebuild
        XCTAssertEqual(session.snapshot.pageIndex, 1)
        XCTAssertEqual(session.snapshot.pageSize, 3)
        XCTAssertFalse(session.snapshot.isLastPage)
        XCTAssertTrue(session.snapshot.canPageBackward)
        XCTAssertTrue(session.snapshot.canPageForward)
        XCTAssertEqual(session.snapshot.candidates.map(\.index), [0, 1, 2])
    }

    func testLastPageStateAndCandidateSelectionOnLaterPage() throws {
        let session = try makeSession()
        session.tap(.code("n"))
        session.nextPage()
        session.nextPage()  // page 2 = last page
        XCTAssertTrue(session.snapshot.isLastPage)
        XCTAssertFalse(session.snapshot.canPageForward)
        XCTAssertTrue(session.snapshot.canPageBackward)

        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.selectCandidate(2)  // the 3rd candidate on the last page
        XCTAssertEqual(committed, ["词8"])
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertTrue(session.snapshot.candidates.isEmpty)
    }

    /// Absolute selection after continuous cross-page display: an absolute index on the same page lands on the right candidate; across pages, on an engine
    /// without absolute capability, it fails explicitly and keeps the composition (a concatenated index is not committed as an in-page ordinal).
    func testAbsoluteSelectionSamePageCommitsAndCrossPageRejects() throws {
        let session = try makeSession()
        session.tap(.code("n"))
        session.nextPage()  // page 1
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.selectCandidateAbsolute(4)  // in-page 1 of page1
        XCTAssertEqual(committed, ["词4"])
        XCTAssertFalse(session.snapshot.isComposing)

        let crossPage = try makeSession()
        crossPage.tap(.code("n"))  // page 0
        var errors: [Error] = []
        crossPage.onError = { errors.append($0) }
        crossPage.selectCandidateAbsolute(5)  // belongs to page1; the stub engine has no absolute capability
        XCTAssertFalse(errors.isEmpty)
        XCTAssertTrue(crossPage.snapshot.isComposing, "a failure must keep the composition")
    }

    /// Read-only cross-page browsing is a production contract: reading another page must not change the engine's current page/highlight/preedit/candidates,
    /// must not trigger onUpdate or bump the revision; a real nextPage must change them.
    func testReadOnlyBrowseDoesNotMutateEngineState() throws {
        let session = try makeSession()
        session.tap(.code("n"))
        session.tap(.code("i"))  // composing, page 0
        let before = session.snapshot
        let revisionBefore = session.compositionRevision
        var updates = 0
        session.onUpdate = { updates += 1 }

        let page1 = try session.readCandidatePage(pageIndex: 1)
        XCTAssertEqual(page1.map(\.text), ["词3", "词4", "词5"], "a read-only read returns the real candidates of page 1")
        XCTAssertEqual(page1.map(\.index), [0, 1, 2], "in-page index is 0-based, for composing absolute indices")
        // Read-only browsing: engine-visible state is untouched.
        XCTAssertEqual(
            session.snapshot, before,
            "read-only browsing must not change the snapshot (page/highlight/candidates/preedit)")
        XCTAssertEqual(session.snapshot.pageIndex, before.pageIndex)
        XCTAssertEqual(session.snapshot.highlightedIndex, before.highlightedIndex)
        XCTAssertEqual(session.snapshot.preedit, before.preedit)
        XCTAssertEqual(
            session.compositionRevision, revisionBefore, "read-only browsing must not bump the real state revision")
        XCTAssertEqual(updates, 0, "read-only browsing must not trigger onUpdate (so marked text does not change)")

        // Contrast: a real page turn changes page/revision and fires onUpdate.
        session.nextPage()
        XCTAssertNotEqual(session.snapshot.pageIndex, before.pageIndex)
        XCTAssertNotEqual(session.compositionRevision, revisionBefore)
        XCTAssertGreaterThan(updates, 0)
    }
}

// MARK: - English QWERTY row data + three-state Shift

@MainActor
final class EnglishShiftRegressionTests: XCTestCase {

    func testObservedEngineASCIIModeUsesVisibleShiftButKeepsEngineAsOwner() throws {
        let engine = PagedStubEngine()
        engine.asciiMode = true
        let session = InputSession(engine: engine, layout: .qwerty26)
        session.refresh()
        XCTAssertEqual(session.mode, .chinese, "frontend direct mode remains independent")
        XCTAssertTrue(session.snapshot.isAsciiMode)
        session.tapShift()
        session.tap(.code("a"))
        XCTAssertEqual(engine.processedKeys.last, "A", "ASCII-mode key still travels through engine")
        XCTAssertEqual(session.shiftState, .off, "once is consumed by the visible ASCII letter")
        XCTAssertTrue(session.snapshot.isAsciiMode)
    }

    func testLetterVariantKeyIdentitySurvivesUnrelatedViewUpdates() {
        let cap = KeyCap(id: "en-a-alternate", title: "á", action: .letterVariant("á"))
        XCTAssertEqual(
            cap, cap, "Reflexive equality is required to avoid cancelling an active alternate picker on every update")
        XCTAssertEqual([cap], [cap])
        XCTAssertNotEqual(cap.action, .letterVariant("à"))
        XCTAssertNotEqual(cap.action, .literal("á"), "DIY literals must remain distinct from Shift-aware variants")
    }

    private func makeEnglishSession() throws -> InputSession {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        let session = InputSession(engine: engine, layout: .qwerty26)
        session.setMode(.english)
        return session
    }

    func testEnglishRowsProvideFull26LowercaseQWERTY() {
        let rows = KeyboardLayoutTable.englishRows(displayShift: .off)
        let caps = rows.flatMap(\.caps)
        XCTAssertEqual(caps.count, 26)
        let codes = caps.compactMap { cap -> String? in
            if case .code(let c) = cap.action { return c }
            return nil
        }
        XCTAssertEqual(Set(codes).sorted().joined(), "abcdefghijklmnopqrstuvwxyz")
        XCTAssertEqual(caps.map(\.title), codes, "off shows lowercase")
        XCTAssertEqual(Set(caps.map(\.id)).count, 26, "key ids are unique")
    }

    func testEnglishRowsShiftDisplayUppercaseTitlesButActionsStayLowercase() {
        let off = KeyboardLayoutTable.englishRows(displayShift: .off).flatMap(\.caps)
        let once = KeyboardLayoutTable.englishRows(displayShift: .once).flatMap(\.caps)
        XCTAssertEqual(off.map(\.id), once.map(\.id), "Shift toggling should not change key identity")
        for (lower, upper) in zip(off, once) {
            XCTAssertEqual(upper.title, lower.title.uppercased())
            XCTAssertEqual(
                upper.action, lower.action,
                "the action is always lowercase .code; final casing is decided by the session")
        }
    }

    func testShiftOnceUppercasesNextLetterThenResets() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tapShift()
        XCTAssertEqual(session.shiftState, .once)
        session.tap(.code("a"))
        XCTAssertEqual(committed, ["A"])
        XCTAssertEqual(session.shiftState, .off, "once resets after a letter is typed")
        session.tap(.code("b"))
        XCTAssertEqual(committed, ["A", "b"])
    }

    func testLetterVariantUsesShiftOnceAndLock() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tap(.letterVariant("á"))
        session.tapShift()
        session.tap(.letterVariant("á"))
        XCTAssertEqual(session.shiftState, .off)
        session.doubleTapShift()
        session.tap(.letterVariant("á"))
        XCTAssertEqual(session.shiftState, .locked)
        XCTAssertEqual(committed, ["á", "Á", "Á"])
        XCTAssertFalse(session.snapshot.isComposing, "Letter variants must never become Rime codes")
    }

    func testVerbatimLiteralsAndNonlettersDoNotConsumeVariantShift() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tapShift()
        session.tap(.literal("á"))  // An explicit DIY literal is not an alphabetic alternate.
        session.tap(.literal("a.b@example.com 3.14"))
        session.tap(.letterVariant("1"))
        session.tap(.letterVariant("!"))
        XCTAssertEqual(session.shiftState, .once)
        XCTAssertEqual(committed, ["á", "a.b@example.com 3.14", "1", "!"])
        session.setMode(.chinese)
        session.tap(.letterVariant("á"))
        XCTAssertEqual(committed.last, "á")
        XCTAssertEqual(session.mode, .chinese)
    }

    func testShiftOnceNotConsumedByDigitsOrSymbolsOrSpace() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.tapShift()
        session.insertLiteral("5")  // digit
        session.tap(.literal("，"))  // symbol
        session.tap(.space)  // space
        XCTAssertEqual(committed, ["5", "，", " "])
        XCTAssertEqual(session.shiftState, .once, "once is consumed only by English letters")
        session.tap(.code("c"))
        XCTAssertEqual(committed, ["5", "，", " ", "C"])
        XCTAssertEqual(session.shiftState, .off)
    }

    func testShiftDoubleTapLocksUntilSingleTapReleases() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.doubleTapShift()
        XCTAssertEqual(session.shiftState, .locked)
        session.tap(.code("h"))
        session.tap(.code("i"))
        XCTAssertEqual(committed, ["H", "I"])
        XCTAssertEqual(session.shiftState, .locked, "locked typing of several letters does not reset")
        session.tapShift()
        XCTAssertEqual(session.shiftState, .off, "a single tap releases the lock")
        session.tap(.code("j"))
        XCTAssertEqual(committed, ["H", "I", "j"])
    }

    func testAutomaticShiftCapitalizesOnceWithoutOverridingManualLock() throws {
        let session = try makeEnglishSession()
        var committed: [String] = []
        session.onCommitted = { committed.append($0) }
        session.setAutomaticShift(true)
        XCTAssertEqual(session.shiftState, .once)
        session.tap(.code("a"))
        XCTAssertEqual(session.shiftState, .off)
        session.tap(.code("b"))
        XCTAssertEqual(committed, ["A", "b"])
        session.doubleTapShift()
        session.setAutomaticShift(false)
        XCTAssertEqual(session.shiftState, .locked)
        session.tap(.code("c"))
        XCTAssertEqual(committed.last, "C")
    }

    func testAutomaticShiftCannotArmDuringChineseComposition() throws {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        let session = InputSession(engine: engine, layout: .qwerty26)
        session.setAutomaticShift(true)
        XCTAssertEqual(session.shiftState, .off)
        session.tap(.code("n"))
        XCTAssertEqual(session.snapshot.rawInput, "n")
    }

    func testShiftStateResetsOnModeSwitch() throws {
        let session = try makeEnglishSession()
        session.doubleTapShift()
        XCTAssertEqual(session.shiftState, .locked)
        session.setMode(.chinese)
        XCTAssertEqual(session.shiftState, .off, "leaving English resets Shift")
        session.tapShift()  // a single tap in Chinese mode is a no-op
        XCTAssertEqual(session.shiftState, .off)
        session.setMode(.english)
        XCTAssertEqual(session.shiftState, .off, "re-entering English also starts from off")
    }
}

// MARK: - Cursor-move callback (confirm first while composing)

@MainActor
final class MoveCursorRegressionTests: XCTestCase {

    private func makeSession() throws -> (DemoEngine, InputSession) {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        let session = InputSession(engine: engine, layout: .qwerty26)
        return (engine, session)
    }

    func testIdleDelegatesRelativeOffset() throws {
        let (_, session) = try makeSession()
        var moved: [Int] = []
        session.onMoveCursor = { moved.append($0) }
        session.moveCursor(by: -2)
        XCTAssertEqual(moved, [-2])
        XCTAssertEqual(session.snapshot.committed, "")
    }

    func testZeroOffsetDoesNothing() throws {
        let (_, session) = try makeSession()
        var moved: [Int] = []
        session.onMoveCursor = { moved.append($0) }
        session.moveCursor(by: 0)
        XCTAssertTrue(moved.isEmpty)
    }

    func testCompositionCommitsFirstThenMoves() throws {
        let (_, session) = try makeSession()
        var committed: [String] = []
        var moved: [Int] = []
        session.onCommitted = { committed.append($0) }
        session.onMoveCursor = { moved.append($0) }
        "nihao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.isComposing)
        session.moveCursor(by: 1)
        XCTAssertEqual(
            committed, ["你好"],
            "before moving, the composition is committed with confirm semantics and not silently lost")
        XCTAssertFalse(session.snapshot.isComposing)
        XCTAssertEqual(moved, [1])
    }

    func testMoveWithoutDelegateIsNoOpNotCrash() throws {
        let (_, session) = try makeSession()
        session.moveCursor(by: 3)  // onMoveCursor == nil: does not move and does not pretend to move
        XCTAssertEqual(session.snapshot.isComposing, false)
    }
}

@MainActor
final class InputSessionRetirementTests: XCTestCase {
    func testRetiredSessionNeverTouchesOldEngineOrHostWriters() {
        let engine = PagedStubEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        var commits: [String] = []
        var moves: [Int] = []
        session.onDispatchCommit = {
            commits.append($0)
            return true
        }
        session.onMoveCursor = { moves.append($0) }
        session.tap(.code("n"))
        XCTAssertEqual(engine.processedKeys, ["n"])
        let before = session.snapshot
        let schema = session.selectedSchemaID

        session.retire()
        session.retire()
        session.tap(.code("i"))
        session.tap(.literal("x"))
        session.selectCandidate(0)
        session.nextPage()
        session.moveCursor(by: 1)
        session.selectSchema("other")
        session.select(layout: .phone9)
        session.setMode(.english)
        session.refresh()

        XCTAssertEqual(engine.processedKeys, ["n"])
        XCTAssertEqual(session.snapshot, before)
        XCTAssertEqual(session.selectedSchemaID, schema)
        XCTAssertEqual(session.mode, .chinese)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(moves.isEmpty)
        XCTAssertFalse(session.commitComposition())
        XCTAssertFalse(session.discardComposition())
    }
}
