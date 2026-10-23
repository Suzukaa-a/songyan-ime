import XCTest

@testable import KeyboardCore

/// Information-architecture tests for the generic Rime front end.
///
/// Uses a multi-schema fixture that is **neither rime-ice nor pinyin** (`Fixtures/generic-multi-schema.json`,
/// shape-code / dialect / zhuyin / stroke) to prove:
///  - the input-method list comes entirely from the resource snapshot, with no hardcoded rime_ice / full pinyin / flypy / 9-key;
///  - 26 / 14 / 9 are front-end keyboard capabilities, combined with input methods only through `availableCombinations` /
///    `incompatibilityReason`, and not bound to source identity;
///  - the select-and-apply flow keeps the source identity and does not fall back across sources;
///  - ordinary UI copy does not leak internal terminology.
final class GenericInputConfigurationTests: XCTestCase {

    private struct Fixture: Decodable {
        let name: String
        let schemas: [KeyboardSchemaDescriptor]
        let layoutEntries: [KeyboardResourceSet.LayoutEntry]
        let preferredLayouts: [String: KeyboardLayoutKind]
    }

    private let shared = URL(fileURLWithPath: "/tmp/generic/shared")
    private let user = URL(fileURLWithPath: "/tmp/generic/user")

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "generic-multi-schema", withExtension: "json"),
            "missing generic multi-schema fixture")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func genericSet(_ fixture: Fixture) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: "user-scheme-generic", name: fixture.name,
            sharedDirectory: shared, userDirectory: user,
            layoutEntries: fixture.layoutEntries, schemas: fixture.schemas)
    }

    // MARK: - 1) The input-method list is dynamic and source-agnostic

    func testFixtureIsNeitherRimeIceNorPinyin() throws {
        let fixture = try fixture()
        XCTAssertFalse(fixture.name.contains("雾凇"))
        XCTAssertFalse(fixture.name.lowercased().contains("rime"))
        for schema in fixture.schemas {
            XCTAssertFalse(BuiltinTemplateSchemas.sourceSchemaIDs.contains(schema.id))
            XCTAssertFalse(schema.id.lowercased().contains("rime"))
            XCTAssertFalse(schema.name.contains("拼音"), "the fixture must be a non-pinyin source: \(schema.name)")
        }
        XCTAssertGreaterThan(fixture.schemas.count, 2, "the multi-schema fixture needs at least 3 schemas")
    }

    func testInputMethodsComeFromSnapshotNotHardcoded() throws {
        let fixture = try fixture()
        let choices = InputConfigurationChoices(resourceSet: genericSet(fixture))
        XCTAssertEqual(choices.inputMethods.map(\.id), fixture.schemas.map(\.id))
        XCTAssertEqual(choices.inputMethods.map(\.name), fixture.schemas.map(\.displayName))
        // Any naming is presented as is: there is no hardcoded replacement such as "full pinyin / flypy / 9-key".
        XCTAssertTrue(choices.inputMethods.contains { $0.name == "倉頡五代" })
        XCTAssertTrue(choices.inputMethods.contains { $0.name == "粵語 Jyutping" })
        XCTAssertTrue(choices.inputMethods.contains { $0.name == "筆畫輸入" })
    }

    // MARK: - 2) Layout availability is decided by capability, not bound to source identity

    func testLayoutAvailabilityIsCapabilityDriven() throws {
        let fixture = try fixture()
        let set = genericSet(fixture)
        let choices = InputConfigurationChoices(resourceSet: set)

        // An input method that declares 26-key is available; an undeclared compact layout (14-key) is not available: a compact layout must be
        // explicitly declared by the author/adapter and is never guessed from source identity or the alphabet.
        XCTAssertTrue(choices.isAvailable(schemaID: "cangjie5", layout: .qwerty26))
        XCTAssertFalse(choices.isAvailable(schemaID: "cangjie5", layout: .merged14))
        XCTAssertFalse(choices.isAvailable(schemaID: "cangjie5", layout: .phone9))
        XCTAssertEqual(
            choices.reason(schemaID: "cangjie5", layout: .phone9),
            UserTerminology.layoutUnavailableReason(.phone9))
        XCTAssertFalse(
            choices.isAvailable(schemaID: "cangjie5", layout: .merged14),
            "14-key is a front-end compact capability that only an adapter/author may declare, never granted by source identity"
        )

        // The dialect scheme declares 9-key: 9-key is available; 26-key is available under the real publication semantics of the same resource
        // when "that input method is selected" (the alphabet is Latin), rather than inferred from source identity or name.
        XCTAssertTrue(choices.isAvailable(schemaID: "jyut6ping3", layout: .phone9))
        XCTAssertTrue(choices.isAvailable(schemaID: "jyut6ping3", layout: .qwerty26))
        XCTAssertFalse(choices.isAvailable(schemaID: "jyut6ping3", layout: .merged14))

        // The stroke scheme's alphabet is Latin code keys (hspnz): it can send code keys directly from 26-key; a compact capability such as 9-key
        // is still available only when the author/adapter declares it explicitly.
        XCTAssertTrue(choices.isAvailable(schemaID: "stroke_hspnz", layout: .qwerty26))
        XCTAssertFalse(choices.isAvailable(schemaID: "stroke_hspnz", layout: .phone9))

        // An input method with a pure digit code table (no Latin letters, no declaration): 26-key is truly unavailable, with an ordinary-language
        // reason given in place; a compact layout is still selectable (it is prepared automatically when starting use).
        XCTAssertFalse(choices.isAvailable(schemaID: "numeric_radical", layout: .qwerty26))
        let numericReason = try XCTUnwrap(choices.reason(schemaID: "numeric_radical", layout: .qwerty26))
        XCTAssertNil(UserTerminology.leaksInternalTerminology(numericReason), numericReason)
        XCTAssertFalse(choices.canStartUsing(schemaID: "numeric_radical", layout: .qwerty26))

        // The supported layouts are the union of each input method's available layouts, listing only the really available ones.
        XCTAssertEqual(choices.supportedLayouts, [.qwerty26, .phone9])

        // Compact layouts (14 / 9 keys): not available and **not selectable** while the install fact does not hold; there is no pseudo-state of "tick it first,
        // prepare later" (adding a compact keyboard goes through the separate "add keyboard" transaction).
        let t9 = try XCTUnwrap(choices.layouts(for: "cangjie5").first { $0.layout == .phone9 })
        XCTAssertFalse(t9.isAvailable, "not generated must not be called available")
        XCTAssertFalse(t9.isSelectable, "unavailable means not selectable")
        XCTAssertFalse(choices.canStartUsing(schemaID: "cangjie5", layout: .phone9))
        XCTAssertFalse(choices.isAvailable(schemaID: "cangjie5", layout: .phone9))
        // The supported list reports only the really available layouts.
        XCTAssertFalse(choices.supportedLayouts.contains(.merged14))
        // Every unavailable reason leaks no internal terminology and never mentions "style / key type / pairing".
        for method in choices.inputMethods {
            for choice in method.layouts where !choice.isAvailable {
                let reason = try XCTUnwrap(choice.reason)
                XCTAssertNil(UserTerminology.leaksInternalTerminology(reason), reason)
            }
        }
    }

    func testKeyboardLayoutsAreFrontendCapabilitiesNotSourceBrands() {
        // The same front-end layout names hold for any source.
        XCTAssertEqual(UserTerminology.layoutName(.qwerty26), "26 键")
        XCTAssertEqual(UserTerminology.layoutName(.merged14), "14 键")
        XCTAssertEqual(UserTerminology.layoutName(.merged18), "18 键")
        XCTAssertEqual(UserTerminology.layoutName(.phone9), "9 键")
        XCTAssertEqual(
            KeyboardLayoutKind.allCases.map(\.userTitle),
            ["26 键", "14 键", "18 键", "9 键"])
    }

    // MARK: - 3) The select flow keeps source identity and does not cross sources

    func testSelectionFlowKeepsSourceIdentity() throws {
        let fixture = try fixture()
        let set = genericSet(fixture)
        let selected = set.selecting(schemaID: "jyut6ping3", layout: .phone9)
        XCTAssertEqual(selected.selectedSchemaID, "jyut6ping3")
        XCTAssertEqual(selected.preferredLayout, .phone9)
        XCTAssertEqual(selected.id, set.id, "derivation does not change the source identity")
        XCTAssertEqual(selected.schemas, set.schemas)
        XCTAssertTrue(selected.availableCombinations.contains { $0.schemaID == "jyut6ping3" && $0.layout == .phone9 })

        // A source-restricted startup selection never crosses into another schema.
        let boot = set.bootSelection(candidates: [.phone9, .qwerty26], restrictedToSource: "jyut6ping3")
        XCTAssertEqual(boot?.layout, .phone9)
        XCTAssertEqual(boot?.schemaID, "jyut6ping3")
        XCTAssertNil(set.bootSelection(candidates: [.qwerty26], restrictedToSource: "jyut6ping3"))
        // The 26-key of another source remains available on its own.
        let cangjie = set.bootSelection(candidates: [.qwerty26], restrictedToSource: "cangjie5")
        XCTAssertEqual(cangjie?.schemaID, "cangjie5")
    }

    /// When an attempt to prepare fails, the combination is not marked available and the existing selection is unchanged (the schema identity is kept,
    /// an invalid layout preference is dropped rather than silently substituted).
    func testFailedCompactAttemptIsNotMarkedAvailableAndKeepsSelection() throws {
        let fixture = try fixture()
        let set = genericSet(fixture)
        let choices = InputConfigurationChoices(resourceSet: set)
        // A non-pinyin shape-code schema does not declare 9-key: the install fact does not hold -> unavailable, not selectable.
        XCTAssertFalse(choices.isAvailable(schemaID: "cangjie5", layout: .phone9))
        XCTAssertFalse(choices.canStartUsing(schemaID: "cangjie5", layout: .phone9))
        XCTAssertFalse(choices.supportedLayouts.contains(.merged14))
        XCTAssertFalse(
            choices.supportedLayouts.contains(.phone9)
                && choices.inputMethods
                    .first { $0.id == "cangjie5" }!.availableLayouts.contains(.phone9),
            "not generated does not mean available")

        // The existing selection (26-key) stays unchanged after a failed attempt at an unprepared combination:
        // selecting keeps the schema identity; for a nonexistent combination it drops the layout preference and never invents a combination.
        let applied = set.selecting(schemaID: "cangjie5", layout: .qwerty26)
        XCTAssertEqual(applied.selectedSchemaID, "cangjie5")
        XCTAssertEqual(applied.preferredLayout, .qwerty26)
        let afterFailedAttempt = applied.selecting(schemaID: "cangjie5", layout: .phone9)
        XCTAssertEqual(afterFailedAttempt.selectedSchemaID, "cangjie5", "source/input-method identity is kept")
        XCTAssertNil(afterFailedAttempt.preferredLayout, "an unprepared combination is not written into the preference")
        XCTAssertEqual(afterFailedAttempt.id, set.id)
        XCTAssertTrue(
            afterFailedAttempt.availableCombinations.contains { $0.schemaID == "cangjie5" && $0.layout == .qwerty26 },
            "existing available combinations are unaffected")
    }

    func testInputConfigurationChoicesDefaultsFollowCapabilityOnly() throws {
        let fixture = try fixture()
        let choices = InputConfigurationChoices(resourceSet: genericSet(fixture))
        // A preference is kept if selectable; if the preference is unavailable (install fact does not hold) it falls back to the first available layout, never inventing a combination.
        XCTAssertEqual(choices.firstAvailableLayout(for: "cangjie5", preferred: .qwerty26), .qwerty26)
        XCTAssertEqual(
            choices.firstAvailableLayout(for: "cangjie5", preferred: .phone9), .qwerty26,
            "an unconfirmed compact layout must not be a preference landing point")
        XCTAssertEqual(choices.firstAvailableLayout(for: "jyut6ping3"), .qwerty26)
        XCTAssertEqual(choices.firstAvailableLayout(for: "jyut6ping3", preferred: .phone9), .phone9)
        XCTAssertNil(choices.firstAvailableLayout(for: "nonexistent"))
        XCTAssertTrue(choices.canStartUsing(schemaID: "jyut6ping3", layout: .phone9))
        XCTAssertFalse(
            choices.canStartUsing(schemaID: "numeric_radical", layout: .qwerty26),
            "26-key is genuinely unavailable for this input method; no combination is invented")
        // The 9-key companion of a pure digit code table source is produced by the "add keyboard" transaction; a bare snapshot without artifacts is not selectable.
        XCTAssertFalse(choices.canStartUsing(schemaID: "numeric_radical", layout: .phone9))
        XCTAssertFalse(choices.canStartUsing(schemaID: "", layout: .qwerty26))
        XCTAssertEqual(choices.firstUsableInputMethod()?.id, "cangjie5")
    }

    func testEmptySnapshotYieldsNoInventedInputMethod() {
        let empty = KeyboardResourceSet(
            id: "user-scheme-empty", name: "空来源",
            sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], schemas: [], selectedSchemaID: nil)
        let choices = InputConfigurationChoices(resourceSet: empty)
        XCTAssertTrue(choices.isEmpty)
        XCTAssertFalse(
            choices.canStartUsing(schemaID: "rime_ice", layout: .qwerty26),
            "must not invent an available combination for an unknown schema")
    }

    /// When a legacy resource/built-in package declares only layoutEntries (no descriptors), the input methods still come from the resource declaration,
    /// with dynamic order and available layouts; an empty descriptor list is not an empty enabled list.
    func testLegacyLayoutEntryOnlyResourceStillYieldsDynamicInputMethods() {
        let set = KeyboardResourceSet(
            id: "user-scheme-legacy", name: "旧资源",
            sharedDirectory: shared, userDirectory: user,
            layoutEntries: [
                .init(layout: .phone9, schemaID: "dialect_nine"),
                .init(layout: .qwerty26, schemaID: "cangjie_shape"),
            ],
            schemas: [])
        let choices = InputConfigurationChoices(resourceSet: set)
        XCTAssertEqual(choices.inputMethods.map(\.id), ["dialect_nine", "cangjie_shape"])
        XCTAssertTrue(choices.isAvailable(schemaID: "dialect_nine", layout: .phone9))
        XCTAssertFalse(choices.isAvailable(schemaID: "dialect_nine", layout: .qwerty26))
        XCTAssertTrue(choices.isAvailable(schemaID: "cangjie_shape", layout: .qwerty26))
        XCTAssertEqual(choices.supportedLayouts, [.qwerty26, .phone9])
    }
}

/// User-terminology gate: centralized constants + composition functions, to keep Host/keyboard copy from drifting back to internal terminology.
final class UserTerminologyTests: XCTestCase {

    func testCoreTermsAreFrozen() {
        XCTAssertEqual(UserTerminology.inputScheme, "输入方案")
        XCTAssertEqual(UserTerminology.inputMethod, "输入方式")
        XCTAssertEqual(UserTerminology.keyboardLayout, "键盘布局")
        XCTAssertEqual(UserTerminology.keyboardAppearance, "键盘外观")
        XCTAssertEqual(UserTerminology.dictionary, "词库")
        XCTAssertEqual(UserTerminology.statusInUse, "正在使用")
        XCTAssertEqual(UserTerminology.statusNotApplied, "未使用")
        XCTAssertEqual(UserTerminology.startUsing, "使用")
    }

    func testSummaryLinesUseFrozenTerms() {
        XCTAssertEqual(
            UserTerminology.inUseSummary(scheme: "通用形码包", inputMethod: "倉頡五代", layout: "26 键"),
            "正在使用：通用形码包 · 倉頡五代 · 26 键")
        XCTAssertEqual(
            UserTerminology.inUseSummary(scheme: "自然码双拼", inputMethod: "自然码双拼", layout: "26 键"),
            "正在使用：自然码双拼 · 26 键")
        // Do not falsely claim availability when unconfigured.
        XCTAssertEqual(
            UserTerminology.inUseSummary(scheme: nil, inputMethod: nil, layout: nil),
            ProductionInputAvailability.unconfiguredTitle)
        XCTAssertEqual(
            UserTerminology.inUseSummary(scheme: "", inputMethod: "A", layout: "26 键"),
            ProductionInputAvailability.unconfiguredTitle)

        XCTAssertEqual(UserTerminology.inputMethodLine(["倉頡五代", "五笔86"]), "输入方式：倉頡五代、五笔86")
        XCTAssertEqual(UserTerminology.keyboardLayoutLine(["26 键", "9 键"]), "键盘布局：26 键、9 键")
        XCTAssertNil(UserTerminology.inputMethodLine([]))
        XCTAssertNil(UserTerminology.keyboardLayoutLine(["  "]))
    }

    func testInstalledSourceSummaryNeverCalledSchemeCount() {
        XCTAssertEqual(
            UserTerminology.installedSourceSummary(count: 0),
            ProductionInputAvailability.unconfiguredCountSummary)
        XCTAssertEqual(UserTerminology.installedSourceSummary(count: 3), "已安装 3 个输入方案")
        // Input scheme = the installable unit (consistent with UserTerminology.inputScheme); the internal way of typing is called the input method.
        let summary = UserTerminology.installedSourceSummary(count: 3)
        XCTAssertFalse(summary.contains("来源"))
        XCTAssertFalse(summary.contains("方案数量"))
        XCTAssertEqual(ProductionInputAvailability.installationSummary(sources: 3), "已安装 3 个输入方案")
    }

    func testStatusWordsUnifiedAcrossHostAndKeyboard() {
        for text in [
            ProductionInputAvailability.runtimeUnconfiguredSchemeName,
            ProductionInputAvailability.runtimeUnconfiguredReason,
            ProductionInputAvailability.runtimeUnconfiguredNotice,
        ] {
            XCTAssertNil(UserTerminology.leaksInternalTerminology(text), text)
        }
    }

    func testBannedTerminologyGateCatchesDrift() {
        XCTAssertNil(UserTerminology.leaksInternalTerminology("输入方式：倉頡五代"))
        XCTAssertNotNil(UserTerminology.leaksInternalTerminology("此方案有 3 个 schema"))
        XCTAssertNotNil(UserTerminology.leaksInternalTerminology("键盘样式"))
        XCTAssertNotNil(UserTerminology.leaksInternalTerminology("26 键型"))
        XCTAssertNotNil(UserTerminology.leaksInternalTerminology("方案配对"))
        XCTAssertNotNil(UserTerminology.leaksInternalTerminology("recipe 安装完成"))
    }
}

/// First-launch routing: first-frame branch + landing point after strict probing (real branch assertions, not string assertions).
final class LaunchConfigurationPolicyTests: XCTestCase {

    /// **First frame**: a completed user goes straight to the home page and never enters the probe/loading state (no ProgressView flash).
    func testCompletedUserRendersMainOnFirstFrameWithoutProbe() {
        XCTAssertEqual(
            LaunchConfigurationPolicy.initialRoute(onboardingCompleted: true), .main,
            "onboardingCompleted=true must be the home page on the first frame, without going through probe")
        XCTAssertNotEqual(LaunchConfigurationPolicy.initialRoute(onboardingCompleted: true), .probe)
    }

    /// Only an incomplete user needs the async probe.
    func testIncompleteUserEntersProbeThenOnboardingOrMain() {
        XCTAssertEqual(LaunchConfigurationPolicy.initialRoute(onboardingCompleted: false), .probe)
        XCTAssertEqual(LaunchConfigurationPolicy.routeAfterProbe(hasUsableConfiguration: true), .main)
        XCTAssertEqual(LaunchConfigurationPolicy.routeAfterProbe(hasUsableConfiguration: false), .onboarding)
    }

    /// Leftover files do not count as configured; only a valid record skips (policy layer).
    func testResidualFilesDoNotSkipOnboarding() {
        XCTAssertFalse(
            LaunchConfigurationPolicy.shouldSkipOnboarding(
                hasUsableRealPublication: false, hasStrictlyDecodedInstallation: false),
            "leftover files must not skip first-time setup")
    }

    func testValidActivationSkipsOnboarding() {
        XCTAssertTrue(
            LaunchConfigurationPolicy.shouldSkipOnboarding(
                hasUsableRealPublication: true, hasStrictlyDecodedInstallation: false),
            "a strictly usable, non-built-in real publication record -> skip first-time setup")
        XCTAssertTrue(
            LaunchConfigurationPolicy.shouldSkipOnboarding(
                hasUsableRealPublication: false, hasStrictlyDecodedInstallation: true),
            "a strictly decoded install receipt -> skip first-time setup")
        XCTAssertFalse(
            LaunchConfigurationPolicy.shouldSkipOnboarding(
                hasUsableRealPublication: false, hasStrictlyDecodedInstallation: false))
    }
}
