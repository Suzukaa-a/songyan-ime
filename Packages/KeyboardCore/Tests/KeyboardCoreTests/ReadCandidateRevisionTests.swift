import XCTest

@testable import KeyboardCore

/// Read-only cross-page browsing (candidate-browse writer) must not count as an input change: `readCandidatePage`
/// bypasses `apply`, so it does not bump `compositionRevision` or change the snapshot/display. This test pins that invariant.
private final class ReadBrowseEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("read-browse")
    var readOnlyEnabled = true
    var supportsReadOnlyBrowsing: Bool { readOnlyEnabled }
    var currentSchemaID = "keyboard_3d7821f984693864ae91_14"
    /// When non-nil, the read-only read throws (simulating an unavailable engine / failed read) to verify error propagation.
    var readFailure: EngineBackendError?
    private var input = ""
    private var composing = false
    private var cached = EngineSnapshot()
    private(set) var readCount = 0

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func validateSchema(_ schemaID: String) throws {}
    func selectSchema(_ schemaID: String) throws {
        currentSchemaID = schemaID
        input = ""
        composing = false
        cached = produce()
    }
    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        if keyValue == "\u{08}" {
            if !input.isEmpty { input.removeLast() }
        } else if keyValue == "\n" {
            input = ""
        } else {
            input += keyValue
        }
        composing = !input.isEmpty
        cached = produce()
        return cached
    }
    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        var s = produce()
        s.committed = "好"
        input = ""
        composing = false
        cached = s
        return s
    }
    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }
    func currentSnapshot() -> EngineSnapshot {
        var s = cached
        s.committed = ""
        return s
    }
    func shutdown() {}
    var statusSummary: String { "read-browse" }

    /// Mirrors the production mapping: engine-owned slot metadata is attached by
    /// PAGE-LOCAL slot (absolute % pageSize), so it is stable across pages.
    static let slotKeys = ["a", "s", "d", "f", "g"]
    static let slotLabels = ["甲", "乙", "丙", "丁", "戊"]

    func readCandidates(fromIndex: Int, count: Int) throws -> [Candidate] {
        readCount += 1
        if let readFailure { throw readFailure }
        let pageSize = Self.slotKeys.count
        return (0..<count).map {
            let slot = (fromIndex + $0) % pageSize
            return Candidate(
                index: $0, text: "p\(fromIndex + $0)",
                selectKey: Self.slotKeys[slot], selectLabel: Self.slotLabels[slot])
        }
    }

    private func produce() -> EngineSnapshot {
        var s = EngineSnapshot(
            candidates: composing ? [Candidate(index: 0, text: "你")] : [],
            preedit: input, rawInput: input, isComposing: composing,
            highlightedIndex: composing ? 0 : -1, pageIndex: 0, pageSize: 5, isLastPage: false)
        s.schemaID = currentSchemaID
        s.preeditSelStart = 0
        s.preeditSelEnd = input.utf8.count
        s.preeditCaretByte = input.utf8.count
        s.preeditSelection = NSRange(location: (input as NSString).length, length: 0)
        return s
    }
}

@MainActor
final class ReadCandidateRevisionTests: XCTestCase {

    func testReadCandidatePageDoesNotAdvanceRevisionOrSnapshot() throws {
        let engine = ReadBrowseEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        session.tap(.code("b"))
        session.tap(.code("u"))
        XCTAssertTrue(session.snapshot.isComposing, "the composition is established")
        let revision = session.compositionRevision
        let snapshot = session.snapshot

        let page = try session.readCandidatePage(pageIndex: 1)
        XCTAssertEqual(engine.readCount, 1)
        XCTAssertEqual(
            page.map(\.text), ["p5", "p6", "p7", "p8", "p9"],
            "a read-only fetch by absolute offset takes a slice without changing the current page/highlight")
        XCTAssertEqual(
            session.compositionRevision, revision,
            "read-only browsing is not an input change and must not bump the revision")
        XCTAssertEqual(session.snapshot, snapshot, "read-only browsing must not change the snapshot/display")
    }

    func testReadCandidatePageWithoutCapabilityReturnsEmptyAndDoesNotTouchState() throws {
        // An engine without read-only browsing (default) returns empty = normal termination (not a failure), and revision is unchanged too.
        let engine = ReadBrowseEngine()
        engine.readOnlyEnabled = false
        let session = InputSession(engine: engine, layout: .merged14)
        session.tap(.code("b"))
        let revision = session.compositionRevision
        XCTAssertEqual(try session.readCandidatePage(pageIndex: 0), [])
        XCTAssertEqual(engine.readCount, 0)
        XCTAssertEqual(session.compositionRevision, revision)
    }

    /// A read-only cross-page read must keep each page slot's scheme select key/label (consistent by page-local index)
    /// and must not drop labels on later pages.
    func testReadOnlyPageKeepsSchemaSlotLabels() throws {
        let engine = ReadBrowseEngine()
        let session = InputSession(engine: engine, layout: .merged14)
        session.tap(.code("b"))
        let page0 = try session.readCandidatePage(pageIndex: 0)
        let page1 = try session.readCandidatePage(pageIndex: 1)
        XCTAssertEqual(page0.map(\.selectKey), ReadBrowseEngine.slotKeys)
        XCTAssertEqual(page0.map(\.selectLabel), ReadBrowseEngine.slotLabels)
        XCTAssertEqual(
            page1.map(\.selectKey), ReadBrowseEngine.slotKeys,
            "page-local slot key is stable across pages")
        XCTAssertEqual(
            page1.map(\.selectLabel), ReadBrowseEngine.slotLabels,
            "page-local slot label is stable across pages (no dropped labels)")
    }

    /// A read failure must propagate (retryable) and not collapse into empty; otherwise that page would be treated as EOF and skipped permanently.
    func testReadCandidatePagePropagatesReadFailure() {
        let engine = ReadBrowseEngine()
        engine.readFailure = .operationFailed("engine down")
        let session = InputSession(engine: engine, layout: .merged14)
        session.tap(.code("b"))
        let revision = session.compositionRevision
        XCTAssertThrowsError(try session.readCandidatePage(pageIndex: 1))
        XCTAssertEqual(session.compositionRevision, revision, "a failure likewise must not change state")
    }
}
