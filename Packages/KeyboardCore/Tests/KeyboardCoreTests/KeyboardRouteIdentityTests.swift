import KeyboardCore
import XCTest

/// Route identity and boot ledger: a ready engine is reused on a same-process return, and restarts
/// only when the generation, source schema, layout or user directory really changes.
final class KeyboardRouteIdentityTests: XCTestCase {

    private func key(
        gen: String? = "gen-a", schema: String? = "rime_ice",
        layout: KeyboardLayoutKind = .qwerty26,
        user: String = "/u/a", resource: String? = "pkg-a"
    ) -> KeyboardRouteKey {
        KeyboardRouteKey(
            resourceID: resource, publicationGeneration: gen,
            sharedDirectory: URL(fileURLWithPath: "/s"),
            userDirectory: URL(fileURLWithPath: user),
            prebuiltDirectory: URL(fileURLWithPath: "/p"),
            sourceSchemaID: schema, layout: layout)
    }

    private func readyState(_ ready: KeyboardRouteKey) -> KeyboardRouteState {
        var state = KeyboardRouteState()
        let token = state.beginBoot()
        XCTAssertTrue(state.commitReady(ready, token: token))
        return state
    }

    func testIdenticalRouteIsReusedAndAnyChangeRestarts() {
        let state = readyState(key())
        XCTAssertTrue(state.canReuse(key(), isReady: true))
        XCTAssertFalse(state.canReuse(key(gen: "gen-b"), isReady: true))
        XCTAssertFalse(state.canReuse(key(schema: "double_pinyin_flypy"), isReady: true))
        XCTAssertFalse(state.canReuse(key(layout: .merged14), isReady: true))
        XCTAssertFalse(state.canReuse(key(user: "/u/b"), isReady: true))
    }

    func testNotReadyNeverReusesTheRunningRoute() {
        XCTAssertFalse(readyState(key()).canReuse(key(), isReady: false))
        XCTAssertFalse(KeyboardRouteState().canReuse(key(), isReady: true))
    }

    func testRepeatedBeginBootInvalidatesEarlierTokens() {
        var state = KeyboardRouteState()
        let first = state.beginBoot()
        XCTAssertTrue(state.isCurrent(first))
        let second = state.beginBoot()
        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(second))
    }

    func testConcurrentBootOfSameTargetIsDeduplicated() {
        var state = KeyboardRouteState()
        _ = state.beginBoot()
        state.notePending(key())
        XCTAssertTrue(state.canReuse(key(), isReady: false))
    }

    func testChangedTargetWhileBootingStartsANewGeneration() {
        var state = KeyboardRouteState()
        let first = state.beginBoot()
        state.notePending(key(schema: "rime_ice"))
        XCTAssertFalse(state.canReuse(key(schema: "double_pinyin_flypy"), isReady: false))
        let second = state.beginBoot()
        XCTAssertFalse(state.commitReady(key(schema: "rime_ice"), token: first))
        XCTAssertNil(state.running)
        XCTAssertTrue(state.commitReady(key(schema: "double_pinyin_flypy"), token: second))
        XCTAssertEqual(state.running, key(schema: "double_pinyin_flypy"))
    }

    func testCancelDuringBootLeavesNoReusableRoute() {
        var state = KeyboardRouteState()
        let token = state.beginBoot()
        state.notePending(key())
        state.cancel()
        XCTAssertFalse(state.isCurrent(token))
        XCTAssertNil(state.running)
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.commitReady(key(), token: state.beginBoot()))
    }

    func testClearPendingIgnoresStaleToken() {
        var state = KeyboardRouteState()
        let stale = state.beginBoot()
        _ = state.beginBoot()
        state.notePending(key())
        state.clearPending(token: stale)
        XCTAssertEqual(state.pending, key())
    }

    func testInRunLayoutSwitchUpdatesRunningIdentitySoNextAppearReuses() {
        var state = readyState(key(layout: .qwerty26))
        state.updateRunning(key(layout: .merged14))
        XCTAssertTrue(state.canReuse(key(layout: .merged14), isReady: true))
        XCTAssertFalse(state.canReuse(key(layout: .qwerty26), isReady: true))
    }

    func testUpdateRunningIsNoOpWithoutReadyRoute() {
        var state = KeyboardRouteState()
        state.updateRunning(key(layout: .merged14))
        XCTAssertNil(state.running)
    }

    func testDiagnosticNamesPublicationIdentityOnly() {
        let description = key(gen: "0123456789abcdef").diagnosticDescription
        XCTAssertEqual(description, "resource=pkg-a gen=01234567 layout=\(KeyboardLayoutKind.qwerty26.rawValue)")
    }
}
