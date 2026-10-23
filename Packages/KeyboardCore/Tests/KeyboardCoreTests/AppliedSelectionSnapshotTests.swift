import XCTest

@testable import KeyboardCore

/// Pure-value regression for `AppliedSelectionSnapshot`: the scheme detail's "in use /
/// current input method" must be derivable from an immutable snapshot, with no synchronous disk read on every redraw.
final class AppliedSelectionSnapshotTests: XCTestCase {

    private let userScheme = "userScheme"
    private let userDictionary = "userDictionary"

    func testEmptySnapshotIsNotAppliedAndHasNoSchemas() {
        let none = AppliedSelectionSnapshot.none
        XCTAssertFalse(none.isApplied(resourceKind: userScheme))
        XCTAssertTrue(none.activeSchemaIDs(resourceKind: userScheme).isEmpty)
    }

    func testEnabledSnapshotOfMatchingKindIsApplied() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice", "double_pinyin_flypy"])
        XCTAssertTrue(snapshot.isApplied(resourceKind: userScheme))
        XCTAssertFalse(
            snapshot.isApplied(resourceKind: userDictionary),
            "a kind mismatch must not be shown as in use")
    }

    /// Explicit selection: only the selected item counts; the whole enabled list is not treated as in use.
    func testSelectedSchemaWinsWhenExplicit() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "double_pinyin_flypy",
            requiredSchemaIDs: ["rime_ice", "double_pinyin_flypy"])
        XCTAssertEqual(snapshot.activeSchemaIDs(resourceKind: userScheme), ["double_pinyin_flypy"])
    }

    /// No explicit selection: falls back to the full enabled list (same semantics as the old `currentSchemaIDs`).
    func testRequiredSchemasFallbackWhenNoExplicitSelection() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userDictionary,
            selectedSchemaID: nil, requiredSchemaIDs: ["a", "b", "c"])
        XCTAssertEqual(snapshot.activeSchemaIDs(resourceKind: userDictionary), ["a", "b", "c"])
    }

    /// When not enabled, a schema must not count as in use even if present.
    func testDisabledSnapshotIsNeverApplied() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: false, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice"])
        XCTAssertFalse(snapshot.isApplied(resourceKind: userScheme))
        XCTAssertTrue(snapshot.activeSchemaIDs(resourceKind: userScheme).isEmpty)
    }

    /// Value semantics: equal fields compare equal, used for `@State`/`onChange` de-duplication.
    func testEquatable() {
        let a = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice"])
        let b = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice"])
        let c = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "other", requiredSchemaIDs: ["rime_ice"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Keep the old snapshot / clear the error

    /// A read failure must **keep the previous snapshot** and report the error (no flicker to blank).
    func testFailureKeepsPreviousSnapshotAndSurfacesError() {
        let previous = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice"], revision: "r1")
        let (snapshot, error) = AppliedSelectionSnapshot.resolve(
            previous: previous,
            outcome: AppliedSelectionLoadOutcome(snapshot: nil, error: "状态读取失败"))
        XCTAssertEqual(snapshot, previous, "a failure must keep the old snapshot")
        XCTAssertEqual(error, "状态读取失败")
    }

    /// Success must replace the snapshot and clear the error.
    func testSuccessReplacesSnapshotAndClearsError() {
        let previous = AppliedSelectionSnapshot.none
        let fresh = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userDictionary,
            selectedSchemaID: "wb", requiredSchemaIDs: ["wb"], revision: "r2",
            dictionaryName: "我的词库")
        let (snapshot, error) = AppliedSelectionSnapshot.resolve(
            previous: previous,
            outcome: AppliedSelectionLoadOutcome(snapshot: fresh, error: nil))
        XCTAssertEqual(snapshot, fresh)
        XCTAssertNil(error)
    }

    /// "No publication record" is a successfully read empty snapshot and must clear the old selection; Optional.none
    /// must not stand in for failure and leave a revoked scheme in the UI.
    func testSuccessfulEmptySnapshotClearsPreviousSelection() {
        let previous = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userScheme,
            selectedSchemaID: "rime_ice", requiredSchemaIDs: ["rime_ice"])
        let (snapshot, error) = AppliedSelectionSnapshot.resolve(
            previous: previous,
            outcome: AppliedSelectionLoadOutcome(
                snapshot: AppliedSelectionSnapshot.none,
                error: nil))
        XCTAssertEqual(snapshot, .none)
        XCTAssertNil(error)
    }

    /// Revision and dictionary name are readable as pure-value fields (for the "new version installed, not applied" check).
    func testRevisionAndDictionaryNameAreCarried() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: userDictionary,
            selectedSchemaID: nil, requiredSchemaIDs: ["a"], revision: "rev-9", dictionaryName: "词库A")
        XCTAssertEqual(snapshot.revision, "rev-9")
        XCTAssertEqual(snapshot.dictionaryName, "词库A")
    }

    func testDisplayConfigNameIsCarriedForHomeSummary() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: "userScheme",
            selectedSchemaID: "custom", requiredSchemaIDs: ["custom"],
            publicationName: "source-identity", displayConfigName: "我的方案")
        XCTAssertEqual(snapshot.displayConfigName, "我的方案")
        XCTAssertEqual(snapshot.publicationName, "source-identity")
    }
}
