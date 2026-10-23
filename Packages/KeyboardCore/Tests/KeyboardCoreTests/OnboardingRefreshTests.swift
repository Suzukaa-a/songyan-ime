import XCTest

@testable import KeyboardCore

/// The onboarding refresh key triggers a re-read only on first appearance, returning to foreground, and install/apply state changes;
/// switching steps does not rescan sources.
final class OnboardingRefreshTests: XCTestCase {

    /// The first-frame key is stable: `.task(id:)` does not re-trigger while refreshTick is unchanged.
    func testKeyIsStableWhenNothingChanges() {
        let first = OnboardingRefreshKey(refreshTick: 0)
        let same = OnboardingRefreshKey(refreshTick: 0)
        XCTAssertEqual(first, same)
    }

    /// Paging does not make the expensive source scan re-run.
    func testNavigationKeepsKey() {
        XCTAssertEqual(
            OnboardingRefreshKey(refreshTick: 0),
            OnboardingRefreshKey(refreshTick: 0))
    }

    /// Returning to foreground / install-apply changes (refreshTick increments) change the key and trigger one structured refresh.
    func testRefreshTickChangeChangesKey() {
        XCTAssertNotEqual(
            OnboardingRefreshKey(refreshTick: 0),
            OnboardingRefreshKey(refreshTick: 1))
    }

    /// Every real state refresh uses a different key.
    func testDistinctRefreshTicks() {
        let base = OnboardingRefreshKey(refreshTick: 3)
        XCTAssertNotEqual(base, OnboardingRefreshKey(refreshTick: 4))
        XCTAssertEqual(base, OnboardingRefreshKey(refreshTick: 3))
        XCTAssertEqual(base, OnboardingRefreshKey(refreshTick: 3))
    }

    // MARK: - Pure-value status-row derivation (moves the activation read off the main thread)

    private func inputs(
        resourceID: String = "pkg-a", enabled: Bool = true,
        kind: String = "userScheme", config: String = "已安装来源",
        inputMethod: String? = "全拼", layout: String? = "26 键"
    )
        -> AppliedSelectionDisplayInputs
    {
        AppliedSelectionDisplayInputs(
            resourceID: resourceID, recipeEnabled: enabled,
            resourceKind: kind, displayConfigName: config,
            selectedInputMethodName: inputMethod,
            selectedLayoutName: layout)
    }

    func testDisplaySummaryUnconfiguredWhenNoRecord() {
        let summary = AppliedSelectionDisplaySummary.make(from: nil)
        XCTAssertEqual(summary.statusLine, ProductionInputAvailability.unconfiguredTitle)
        XCTAssertFalse(summary.hasRealScheme)
    }

    func testDisplaySummaryUnconfiguredWhenDisabled() {
        let summary = AppliedSelectionDisplaySummary.make(from: inputs(enabled: false))
        XCTAssertFalse(summary.hasRealScheme)
        XCTAssertEqual(summary.statusLine, ProductionInputAvailability.unconfiguredTitle)
    }

    /// Built-in package does not count as a real product scheme (consistent with `isBuiltin`).
    func testDisplaySummaryUnconfiguredForBuiltinPackage() {
        let summary = AppliedSelectionDisplaySummary.make(
            from: inputs(resourceID: ProductionInputAvailability.builtinResourceID))
        XCTAssertFalse(summary.hasRealScheme)
    }

    /// Real scheme: the source name plus input method/layout make one sentence.
    func testDisplaySummaryJoinsSourceInputMethodAndLayout() {
        let summary = AppliedSelectionDisplaySummary.make(from: inputs())
        XCTAssertTrue(summary.hasRealScheme)
        XCTAssertTrue(summary.statusLine.contains("已安装来源"), summary.statusLine)
        XCTAssertTrue(summary.statusLine.contains("全拼"), summary.statusLine)
        XCTAssertTrue(summary.statusLine.contains("26 键"), summary.statusLine)
    }

    func testDisplaySummaryUsesConfigNameForCustomPinyin() {
        let summary = AppliedSelectionDisplaySummary.make(
            from: inputs(resourceID: "user-pinyin", kind: "userDictionary", config: "自定义拼音"))
        XCTAssertTrue(summary.hasRealScheme)
        XCTAssertTrue(summary.statusLine.contains("自定义拼音"), summary.statusLine)
    }

    // MARK: - Shared-container status row (derived by KeyboardSelectionCenter, pure value)

    func testKeyboardStatusLineRealPublication() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: "userScheme", selectedSchemaID: "rime_ice",
            requiredSchemaIDs: ["rime_ice"], hasRealPublication: true, publicationName: "rime-ice")
        let line = snapshot.keyboardStatusLine(requiresFullAccessNote: true)
        XCTAssertEqual(line, "可以读写共享数据；已选择「rime-ice」（下次打开键盘时生效，需要开启「允许完全访问」）")
    }

    func testKeyboardStatusLineUnconfiguredWithAndWithoutFullAccessNote() {
        let snapshot = AppliedSelectionSnapshot.none
        XCTAssertEqual(
            snapshot.keyboardStatusLine(requiresFullAccessNote: true),
            "可以读写共享数据；\(ProductionInputAvailability.unconfiguredTitle)（下次打开键盘时生效，需要开启「允许完全访问」）")
        XCTAssertEqual(
            snapshot.keyboardStatusLine(requiresFullAccessNote: false),
            "可以读写共享数据；\(ProductionInputAvailability.unconfiguredTitle)")
    }

    /// Enabled but only built-in package (not a real publication): not called "selected".
    func testKeyboardStatusLineBuiltinIsNotAnnouncedAsSelected() {
        let snapshot = AppliedSelectionSnapshot(
            recipeEnabled: true, resourceKind: "userScheme", selectedSchemaID: nil,
            requiredSchemaIDs: [], hasRealPublication: false,
            publicationName: ProductionInputAvailability.builtinDisplayName)
        XCTAssertEqual(
            snapshot.keyboardStatusLine(requiresFullAccessNote: true),
            "可以读写共享数据；\(ProductionInputAvailability.unconfiguredTitle)（下次打开键盘时生效，需要开启「允许完全访问」）")
    }

    // MARK: - Current input-method resolution (pure currentSchemaID policy)

    func testCurrentSchemaIDForUserSchemeMatchesPackage() {
        XCTAssertEqual(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: "wb", requiredSchemaIDs: [], forPackageID: "pkg-a"), "wb")
        XCTAssertNil(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: "wb", requiredSchemaIDs: [], forPackageID: "pkg-b"))
    }

    func testCurrentSchemaIDRequiresEnabledAndFallsBackToRequired() {
        XCTAssertNil(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: false, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: "wb", requiredSchemaIDs: [], forPackageID: "pkg-a"))
        XCTAssertEqual(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: nil, requiredSchemaIDs: ["rime_ice", "flypy"],
                forPackageID: "pkg-a"), "rime_ice")
        XCTAssertNil(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userDictionary", packageID: nil,
                selectedSchemaID: "songyan_quanpin", requiredSchemaIDs: [], forPackageID: "pkg-a"))
    }

    /// The built-in scheme is in use with nothing published (the keyboard's fallback) and when
    /// one of its own keyboards is published; another scheme's publication takes it out of use.
    func testBuiltinSchemeIsInUseAsFallbackAndWhenPublished() {
        let builtin = ProductionInputAvailability.builtinPackageID
        XCTAssertEqual(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: nil, resourceKind: nil, packageID: nil,
                selectedSchemaID: nil, requiredSchemaIDs: [], forPackageID: builtin), BuiltinTemplateSchemas.quanpin)
        XCTAssertEqual(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: false, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: "wb", requiredSchemaIDs: [], forPackageID: builtin), BuiltinTemplateSchemas.quanpin)
        XCTAssertEqual(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userScheme", packageID: builtin,
                selectedSchemaID: BuiltinTemplateSchemas.flypy, requiredSchemaIDs: [], forPackageID: builtin),
            BuiltinTemplateSchemas.flypy)
        XCTAssertNil(
            ActiveSchemaResolver.currentSchemaID(
                recipeEnabled: true, resourceKind: "userScheme", packageID: "pkg-a",
                selectedSchemaID: "wb", requiredSchemaIDs: [], forPackageID: builtin))
    }

    /// A detail row shows either 正在使用 or one action, never both.
    func testInputMethodRowShowsInUseOrOneAction() {
        let current = ActiveSchemaResolver.currentSchemaID(
            recipeEnabled: true, resourceKind: "userScheme", packageID: ProductionInputAvailability.builtinPackageID,
            selectedSchemaID: BuiltinTemplateSchemas.flypy, requiredSchemaIDs: [],
            forPackageID: ProductionInputAvailability.builtinPackageID)
        XCTAssertEqual(
            ActiveSchemaResolver.state(
                of: BuiltinTemplateSchemas.flypy, currentSchemaID: current,
                revisionIsCurrent: true), .inUse)
        XCTAssertEqual(
            ActiveSchemaResolver.state(
                of: BuiltinTemplateSchemas.quanpin, currentSchemaID: current,
                revisionIsCurrent: true), .use)
        XCTAssertEqual(
            ActiveSchemaResolver.state(
                of: BuiltinTemplateSchemas.flypy, currentSchemaID: current,
                revisionIsCurrent: false), .useNewVersion)
        XCTAssertEqual(ActiveSchemaResolver.state(of: "wb", currentSchemaID: nil, revisionIsCurrent: true), .use)
    }
}
