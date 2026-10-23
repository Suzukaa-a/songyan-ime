import XCTest

@testable import KeyboardCore

// Two behaviours:
//  1. An explicit DIY joint switch and a direct schema selection must check the resource set's
//     enabled members during the read-only pre-check: with default={b} and a only a compiled dependency, DIY->a does not confirm the composition,
//     does not really select, and does not change layout/schema; old metadata is rebuilt from the real enabled set and an empty table never lets it through.
//  2. Supplement keys = alphabet - actually rendered .code, as a single set difference (not built-in minus first and then DIY),
//     so when the DIY lacks a, a must be supplemented; multi-character/whitespace follow the existing mapping and are not guessed.

// MARK: - Stub engine: compiled dependencies can pass the pre-check (validateSchema does not throw)

/// Accepts any schema (simulating a "compiled, activatable" dependency scheme), recording real selects
/// and key sequences so assertions can show "a target outside the list never reached the real select / the confirm key was never sent".
private final class SelectRecordingEngine: EngineBackend {
    let kind: EngineBackendKind = .demoSimulator("测试引擎")
    private(set) var selectedSchemaIDs: [String] = []
    private(set) var processedKeys: [String] = []
    private var activeSchema: String
    private var composing = ""
    var availableSchemas: [KeyboardSchemaDescriptor] = ["b", "c", "songyan_quanpin", "songyan_flypy"].map {
        .init(id: $0, name: $0)
    }

    init(schemaID: String) { self.activeSchema = schemaID }

    func setup(sharedDirectory: URL, userDirectory: URL) throws {}
    func selectSchema(_ schemaID: String) throws {
        selectedSchemaIDs.append(schemaID)
        activeSchema = schemaID
        composing = ""
    }
    // validateSchema uses the protocol default no-op: compiled dependencies pass the pre-check on the engine side.

    func processKey(_ keyValue: String) throws -> EngineSnapshot {
        processedKeys.append(keyValue)
        composing += keyValue
        return currentSnapshot()
    }

    func selectCandidate(_ index: Int) throws -> EngineSnapshot {
        composing = ""
        var snap = currentSnapshot()
        snap.committed = "词\(index)"
        return snap
    }

    func nextPage() throws -> EngineSnapshot { currentSnapshot() }
    func previousPage() throws -> EngineSnapshot { currentSnapshot() }

    func currentSnapshot() -> EngineSnapshot {
        var snap = EngineSnapshot(
            committed: "", candidates: [],
            preedit: composing, rawInput: composing,
            isComposing: !composing.isEmpty)
        snap.schemaID = activeSchema
        return snap
    }

    func shutdown() { composing = "" }
    var statusSummary: String { "SelectRecordingEngine(\(activeSchema))" }
}

// MARK: - State machine samples

@MainActor
final class EnabledMembershipTests: XCTestCase {
    private let shared = URL(fileURLWithPath: "/tmp/enabled-membership/shared")
    private let user = URL(fileURLWithPath: "/tmp/enabled-membership/user")

    /// default={b}, a is a compiled dependency: the runtime resource set carries only b's enabled record (publication-manifest semantics).
    private func makeSet(
        schemas: [KeyboardSchemaDescriptor],
        selectedSchemaID: String? = "b"
    ) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [.init(layout: .qwerty26, schemaID: "b")],
            schemas: schemas, selectedSchemaID: selectedSchemaID)
    }

    private func makeComposingSession() throws -> (session: InputSession, engine: SelectRecordingEngine) {
        let engine = SelectRecordingEngine(schemaID: "b")
        try engine.selectSchema("b")  // the real select in the boot phase
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: makeSet(schemas: [.init(id: "b", name: "B")]))
        session.tap(.code("n"))  // enter composition
        XCTAssertTrue(session.snapshot.isComposing)
        return (session, engine)
    }

    /// DIY joint switch to out-of-list dependency a: rejected before confirming the composition: no confirm, no select, state untouched.
    func testJointSelectionToCompiledDependencyOutsideEnabledListIsRejectedBeforeConfirm() throws {
        let (session, engine) = try makeComposingSession()
        var errors: [Error] = []
        var committed: [String] = []
        session.onError = { errors.append($0) }
        session.onCommitted = { committed.append($0) }

        session.select(layout: .qwerty26, boundSchemaID: "a")

        XCTAssertEqual(errors.count, 1, "an out-of-list target must report an error, actual \(errors)")
        guard case EngineBackendError.unsupportedSchema(let reason) = errors[0] else {
            return XCTFail("should be unsupportedSchema, actual \(errors[0])")
        }
        XCTAssertTrue(reason.contains("已启用"), "the error should list the enabled schemes: \(reason)")

        // No composition confirm: the confirm key was never sent to the engine; the composition and the original layout/schema are kept as is.
        XCTAssertFalse(engine.processedKeys.contains("\n"), "no confirm key may be sent for the switch pre-check")
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertEqual(session.snapshot.rawInput, "n")
        XCTAssertEqual(session.selectedSchemaID, "b")
        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertEqual(engine.selectedSchemaIDs, ["b"], "a must not reach the real select")
        XCTAssertTrue(committed.isEmpty, "a failure path must not commit")
    }

    /// A direct schema selection of the same out-of-list dependency: likewise rejected, state untouched.
    func testDirectSchemaSelectionOutsideEnabledListIsRejected() throws {
        let (session, engine) = try makeComposingSession()
        var errors: [Error] = []
        session.onError = { errors.append($0) }

        session.selectSchema("a")

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(session.selectedSchemaID, "b")
        XCTAssertEqual(session.layout, .qwerty26)
        XCTAssertEqual(engine.selectedSchemaIDs, ["b"])
        XCTAssertTrue(session.snapshot.isComposing)
        XCTAssertFalse(engine.processedKeys.contains("\n"))
    }

    /// A member in the list passes normally (the enabled set is not a single-point lock): c can be switched to as long as it is in schemas.
    func testEnabledMemberSelectionStillSucceeds() throws {
        let engine = SelectRecordingEngine(schemaID: "b")
        try engine.selectSchema("b")
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: makeSet(schemas: [
                .init(id: "b", name: "B"),
                .init(id: "c", name: "C"),
            ]))
        var errors: [Error] = []
        session.onError = { errors.append($0) }

        session.select(layout: .qwerty26, boundSchemaID: "c")

        XCTAssertTrue(errors.isEmpty, "an in-list member should not error: \(errors)")
        XCTAssertEqual(session.selectedSchemaID, "c")
        XCTAssertEqual(engine.selectedSchemaIDs, ["b", "c"])
    }

    /// Missing metadata requires an explicit engine enabled set, never unlimited access.
    func testEmptySchemaListResourcesUseEngineEnabledSet() throws {
        // (1) selectedSchemaID has a value but carries no publication record (legacy userScheme path).
        let engine = SelectRecordingEngine(schemaID: "b")
        try engine.selectSchema("b")
        let session = InputSession(
            engine: engine, layout: .qwerty26,
            resourceSet: makeSet(schemas: []))
        var errors: [Error] = []
        session.onError = { errors.append($0) }

        session.select(layout: .qwerty26, boundSchemaID: "a")

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(session.selectedSchemaID, "b")
        XCTAssertEqual(engine.selectedSchemaIDs, ["b"])
        session.selectSchema("c")
        XCTAssertEqual(session.selectedSchemaID, "c")
        errors = []

        // (2) builtin shape: no selectedSchemaID, layoutEntries map to the built-in schemes (schemas empty).
        let builtin = KeyboardResourceSet.builtin(sharedDirectory: shared, userDirectory: user)
        XCTAssertTrue(
            builtin.schemas.isEmpty,
            "built-in package carries no publication record and must not be blocked by the membership check")
        let engine2 = SelectRecordingEngine(schemaID: "songyan_quanpin")
        try engine2.selectSchema("songyan_quanpin")
        let session2 = InputSession(engine: engine2, layout: .qwerty26, resourceSet: builtin)
        session2.onError = { errors.append($0) }
        session2.selectSchema("songyan_flypy")
        XCTAssertEqual(session2.selectedSchemaID, "songyan_flypy")
        XCTAssertTrue(errors.isEmpty, "builtin layout/schema switching keeps the existing behavior: \(errors)")
    }

    /// The member check needs an explicit set: rejected when there is no metadata and no real enabled set.
    func testMembershipReasonSemantics() {
        let set = makeSet(schemas: [.init(id: "b", name: "B"), .init(id: "c", name: "C")])
        XCTAssertNil(set.enabledMembershipReason(schemaID: "b"))
        XCTAssertNil(set.enabledMembershipReason(schemaID: "c"))
        XCTAssertNotNil(set.enabledMembershipReason(schemaID: "a"))
        let empty = makeSet(schemas: [])
        XCTAssertNotNil(empty.enabledMembershipReason(schemaID: "a"), "missing an explicit set must be rejected")
    }
}

// MARK: - Single set-difference semantics

@MainActor
final class AdditionalCodeValuesTests: XCTestCase {
    /// The DIY definition lacks a (the built-in table containing a is irrelevant): a single set difference must supplement a.
    /// Legacy defect shape: subtracting the built-in key table first (which removes a) and then the DIY meant a could never be supplemented.
    func testMissingKeyInDIYDefinitionIsSupplied() {
        let rendered: Set<String> = Set("bcdefghijklmnopqrstuvwxyz".map(String.init))
        let values = KeyboardSchemaDescriptor.additionalCodeValues(
            alphabet: "abcdefghijklmnopqrstuvwxyz", renderedCodes: rendered)
        XCTAssertEqual(values, ["a"])
    }

    /// A single `;` (the double-pinyin scheme alphabet contains a semicolon and the 26-key layout does not render it).
    func testSingleSemicolonIsSupplied() {
        let rendered: Set<String> = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        let values = KeyboardSchemaDescriptor.additionalCodeValues(
            alphabet: "abcdefghijklmnopqrstuvwxyz;", renderedCodes: rendered)
        XCTAssertEqual(values, [";"])
    }

    /// The built-in 26 keys render a-z: when the alphabet is also a-z there is no supplement (geometry preserved).
    func testNoExtraKeysForBuiltinCoverage() {
        let rendered: Set<String> = Set("abcdefghijklmnopqrstuvwxyz".map(String.init))
        XCTAssertTrue(
            KeyboardSchemaDescriptor.additionalCodeValues(
                alphabet: "zyxwvutsrqponmlkjihgfedcba", renderedCodes: rendered
            ).isEmpty)
    }

    /// 10+ supplement keys are all given with stable ordering (the panel budget row scrolls horizontally, so the key count is not capped).
    func testManyExtraCodesAreAllPresentSorted() {
        let rendered: Set<String> = Set("qwertyuiop".map(String.init))
        let alphabet = "abcdefghijklmnopqrstuvwxyz;'.,"
        let values = KeyboardSchemaDescriptor.additionalCodeValues(
            alphabet: alphabet, renderedCodes: rendered)
        XCTAssertEqual(values.count, 20, "16 unrendered letters + 4 punctuation marks: \(values)")
        XCTAssertEqual(values.first, "'")
        XCTAssertEqual(values.last, "z")
        XCTAssertTrue(values.contains("a"))
        XCTAssertTrue(values.contains(";"))
    }

    /// Whitespace characters yield no supplement (a space in the alphabet generates no key); merged codes follow the existing mapping and are not rewritten here.
    func testWhitespaceIsIgnored() {
        let values = KeyboardSchemaDescriptor.additionalCodeValues(
            alphabet: "ab ", renderedCodes: ["a"])
        XCTAssertEqual(values, ["b"])
    }
}
