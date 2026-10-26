import XCTest

@testable import KeyboardCore

/// "User keyboard" read model and runtime-side filtering (pure value, schema-agnostic).
///
/// This does **not** test the roster persistence format: the publication fact has a single source, `KeyboardRecipeStore`,
/// and this package defines no roster file of its own. Tests only cover the read model, identity/display names, and
/// the "roster ∩ current resource capability" filter.
final class UserKeyboardTests: XCTestCase {

    private let shared = URL(fileURLWithPath: "/tmp/user-keyboards/shared")
    private let user = URL(fileURLWithPath: "/tmp/user-keyboards/user")

    private func combination(
        _ schemaID: String, _ layout: KeyboardLayoutKind,
        name: String
    ) -> KeyboardResourceSet.Combination {
        .init(schemaID: schemaID, engineSchemaID: schemaID, layout: layout, name: name)
    }

    // MARK: - Value semantics

    func testKeyboardIdentityAndTitle() {
        let keyboard = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        XCTAssertEqual(keyboard.id, "cangjie5:qwerty26")
        XCTAssertEqual(keyboard.title, "倉頡五代 · 26 键")
        // Identity is decided only by the combination: same name with a different layout is two items.
        XCTAssertNotEqual(
            keyboard.id,
            UserKeyboard(
                inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
                layout: .phone9
            ).id)
    }

    func testKeyboardTitleFallsBackToLayoutWithoutLeakingID() {
        let unnamed = UserKeyboard(inputMethodID: "jyut6ping3", inputMethodName: "   ", layout: .phone9)
        XCTAssertEqual(unnamed.title, "9 键")
        XCTAssertNil(UserTerminology.leaksInternalTerminology(unnamed.title))
        XCTAssertFalse(unnamed.title.contains(unnamed.inputMethodID))
    }

    func testIsCurrentMatchesBothDimensions() {
        let keyboard = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        XCTAssertTrue(keyboard.isCurrent(schemaID: "cangjie5", layout: .qwerty26))
        XCTAssertFalse(
            keyboard.isCurrent(schemaID: "cangjie5", layout: .phone9),
            "the same input method with a different layout is not the current keyboard")
        XCTAssertFalse(keyboard.isCurrent(schemaID: "wubi86", layout: .qwerty26))
    }

    func testCurrentTitleUsesOnlyThePublishedSchemaAndLayout() {
        let keys = [
            UserKeyboard(inputMethodID: "phonetic", inputMethodName: "拼音", layout: .qwerty26),
            UserKeyboard(inputMethodID: "shape", inputMethodName: "形码", layout: .qwerty26),
            UserKeyboard(inputMethodID: "shape", inputMethodName: "形码", layout: .phone9),
        ]
        XCTAssertEqual(
            UserKeyboardRoster.currentTitle(
                schemaID: "shape", layout: .qwerty26,
                in: keys), "形码 · 26 键")
        XCTAssertEqual(
            UserKeyboardRoster.currentTitle(
                schemaID: "shape", layout: .phone9,
                in: keys), "形码 · 9 键")
        XCTAssertNil(
            UserKeyboardRoster.currentTitle(
                schemaID: "phonetic", layout: .merged14,
                in: keys))
        XCTAssertNil(
            UserKeyboardRoster.currentTitle(
                schemaID: "missing", layout: .qwerty26,
                in: keys))
    }

    // MARK: - Runtime filter (the sole construction entry of the long-press switch list)

    /// With nothing published the bundled fallback still offers every layout of 内置全拼.
    func testBuiltinFallbackListsEveryLayoutOfTheFallbackInputMethod() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let fallback = KeyboardResourceSet.builtin(sharedDirectory: directory, userDirectory: directory)
        let runnable = UserKeyboardRoster.runnable(
            UserKeyboardRoster.builtinFallback,
            combinations: fallback.availableCombinations)
        XCTAssertEqual(runnable.map(\.layout), KeyboardLayoutKind.allCases)
        XCTAssertTrue(runnable.allSatisfy { $0.inputMethodID == BuiltinTemplateSchemas.quanpin })
    }

    func testRunnableKeepsPublishedOrderAndDropsUnavailable() {
        let a = UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "倉頡五代", layout: .qwerty26)
        let b = UserKeyboard(inputMethodID: "jyut6ping3", inputMethodName: "粵語 Jyutping", layout: .phone9)
        let unavailable = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .merged14)
        guard let jyut = KeyboardLayoutKind(rawValue: "phone9") else { return XCTFail("missing phone9") }

        let runnable = UserKeyboardRoster.runnable(
            [b, unavailable, a],
            combinations: [
                combination("cangjie5", .qwerty26, name: "倉頡五代"),
                combination("jyut6ping3", jyut, name: "粵語 Jyutping"),
            ])
        XCTAssertEqual(runnable.map(\.id), [b.id, a.id], "keep publication order, filter out unrunnable items")
        XCTAssertFalse(
            runnable.contains { $0.id == unavailable.id },
            "an unpublished combination never appears")
    }

    func testRunnableIsEmptyWhenNothingPublished() {
        let combinations = [combination("cangjie5", .qwerty26, name: "倉頡五代")]
        XCTAssertTrue(
            UserKeyboardRoster.runnable([], combinations: combinations).isEmpty,
            "with no added keyboards nothing is invented from the available combinations")
    }

    func testRunnableUsesCurrentResourceNameAndDeduplicates() {
        let stale = UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "旧名", layout: .qwerty26)
        let runnable = UserKeyboardRoster.runnable(
            [stale, stale],
            combinations: [
                combination(
                    "cangjie5", .qwerty26,
                    name: "倉頡五代")
            ])
        XCTAssertEqual(runnable.count, 1, "defensive de-duplication")
        XCTAssertEqual(
            runnable.first?.inputMethodName, "倉頡五代",
            "the display name comes from the current resources, not a stale name")
    }

    func testRunnableNeverCrossesSources() {
        let keyboard = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        // The current resources only have the other source's combinations: published items do not appear (never hard-switch across sources).
        XCTAssertTrue(
            UserKeyboardRoster.runnable(
                [keyboard],
                combinations: [
                    combination("jyut6ping3", .qwerty26, name: "粵語 Jyutping")
                ]
            ).isEmpty)
    }

    // MARK: - Cycling (production criterion: only the published roster)

    private var cangjie26: UserKeyboard {
        UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "倉頡五代", layout: .qwerty26)
    }
    private var jyutT9: UserKeyboard {
        UserKeyboard(inputMethodID: "jyut6ping3", inputMethodName: "粵語 Jyutping", layout: .phone9)
    }

    func testCycleTargetIsNilForEmptyList() {
        // Empty roster (no keyboard added, or all unrunnable -> runnable is empty): safe no-op,
        // never falls back to any 26/14/9 layout itself.
        XCTAssertNil(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "cangjie5",
                currentLayout: .qwerty26, in: []))
        XCTAssertNil(UserKeyboardRoster.cycleTarget(currentSchemaID: "", currentLayout: .phone9, in: []))
    }

    func testCycleTargetIsNilForAllUnrunnable() {
        // "All unrunnable" shows up at the call site as runnable(...) == [], so the cycle target is nil.
        let published = [cangjie26, jyutT9]
        let runnable = UserKeyboardRoster.runnable(published, combinations: [])
        XCTAssertTrue(runnable.isEmpty)
        XCTAssertNil(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "cangjie5",
                currentLayout: .qwerty26, in: runnable))
    }

    func testCycleTargetSelectsFirstWhenCurrentIsNotInList() {
        // The current combination is not in the roster: pick the first roster item (still a published keyboard), not an unpublished layout.
        let list = [jyutT9, cangjie26]
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "wubi86",
                currentLayout: .merged14, in: list)?.id,
            jyutT9.id)
        // Same input method but the layout is not in the roster: likewise lands on the first item.
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "cangjie5",
                currentLayout: .phone9, in: list)?.id,
            jyutT9.id)
    }

    func testCycleTargetAdvancesAndWrapsWithinList() {
        let list = [jyutT9, cangjie26]
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "jyut6ping3",
                currentLayout: .phone9, in: list)?.id,
            cangjie26.id)
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "cangjie5",
                currentLayout: .qwerty26, in: list)?.id,
            jyutT9.id, "wraps around from the end to the first item")
    }

    func testCycleTargetIsNilForSingleItemThatIsAlreadyCurrent() {
        // Only one item and it is the current one: no-op (reselecting itself is meaningless), no switch occurs.
        XCTAssertNil(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "cangjie5",
                currentLayout: .qwerty26, in: [cangjie26]))
        // A single item but the current one is not in the roster: switch to it (the roster is non-empty and it is a published keyboard).
        XCTAssertEqual(
            UserKeyboardRoster.cycleTarget(
                currentSchemaID: "wubi86",
                currentLayout: .phone9, in: [cangjie26])?.id,
            cangjie26.id)
    }

    // MARK: - Management protocol (the test brings its own fixture, not in production)

    @MainActor
    func testCandidateIdentityAndDisplay() {
        let candidate = UserKeyboardCandidate(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .merged14)
        XCTAssertEqual(candidate.id, "cangjie5:merged14")
        XCTAssertEqual(candidate.keyboard().title, "倉頡五代 · 14 键")
        let unnamed = UserKeyboardCandidate(inputMethodID: "x", inputMethodName: "  ", layout: .phone9)
        XCTAssertEqual(unnamed.inputMethodNameOrLayout, "9 键")
    }

    @MainActor
    func testFakeManagerAddAndRemoveKeepPublishedListConsistent() async throws {
        let candidate = UserKeyboardCandidate(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        let manager = FakeUserKeyboardManager(addable: [candidate])
        XCTAssertTrue(manager.supportsManagement)
        let addable = try await manager.addableKeyboards()
        XCTAssertEqual(addable, [candidate])

        let added = try await manager.addKeyboard(candidate)
        XCTAssertTrue(added.contains("倉頡五代"))
        XCTAssertEqual(manager.published, [candidate.keyboard()])
        XCTAssertEqual(manager.addCalls, [candidate])

        let removed = try await manager.removeKeyboard(candidate.keyboard())
        XCTAssertTrue(removed.contains("倉頡五代"))
        XCTAssertTrue(manager.published.isEmpty)
        XCTAssertEqual(manager.removeCalls, [candidate.keyboard()])
    }

    @MainActor
    func testFakeManagerRejectsNonAddableAndNotPublished() async throws {
        let manager = FakeUserKeyboardManager(addable: [])
        let candidate = UserKeyboardCandidate(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        do {
            _ = try await manager.addKeyboard(candidate)
            XCTFail("a non-addable combination must throw")
        } catch {
            XCTAssertEqual(error as? FakeUserKeyboardManager.Error, .notAddable)
        }
        do {
            _ = try await manager.removeKeyboard(candidate.keyboard())
            XCTFail("not in the roster must throw")
        } catch {
            XCTAssertEqual(error as? FakeUserKeyboardManager.Error, .notPublished)
        }
    }

    @MainActor
    func testReadOnlyManagerNeverReportsSuccess() async throws {
        let manager = FakeUserKeyboardManager(addable: [], published: [], supportsManagement: false)
        XCTAssertFalse(manager.supportsManagement)
        do {
            _ = try await manager.addKeyboard(
                UserKeyboardCandidate(
                    inputMethodID: "a",
                    inputMethodName: "A", layout: .phone9))
            XCTFail("a read-only implementation must not report success")
        } catch {
            XCTAssertEqual(error as? FakeUserKeyboardManager.Error, .unavailable)
        }
        for text in [
            FakeUserKeyboardManager.Error.unavailable.errorDescription,
            UserTerminology.userKeyboardEmptyHint,
            UserTerminology.userKeyboardSwitcherEmpty,
            UserTerminology.userKeyboardCurrent,
            UserTerminology.addUserKeyboard,
            UserTerminology.userKeyboardReadOnlyNotice,
            UserTerminology.keyboardUtilitiesOpenLabel,
        ] {
            XCTAssertNotNil(text)
            XCTAssertNil(UserTerminology.leaksInternalTerminology(text ?? ""), text ?? "")
        }
    }

    // MARK: - Read interface (fixture)

    func testStaticProviderReturnsFixture() async throws {
        let keyboard = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        let provider = StaticPublishedKeyboardListProvider([keyboard])
        let loaded = try await provider.publishedKeyboards()
        XCTAssertEqual(loaded, [keyboard])
        let empty = try await StaticPublishedKeyboardListProvider([]).publishedKeyboards()
        XCTAssertTrue(empty.isEmpty, "an empty roster is a normal empty state, not an error")
    }

    // MARK: - Copy

    func testUserKeyboardCopyHasNoInternalTerminology() {
        // Display-name invariant: never expose an internal id, never leak internal terminology.
        let keyboard = UserKeyboard(
            inputMethodID: "cangjie5", inputMethodName: "倉頡五代",
            layout: .qwerty26)
        XCTAssertEqual(keyboard.title, "倉頡五代 · 26 键")
        XCTAssertFalse(keyboard.title.contains("quanpin"))
        for text in [
            UserTerminology.userKeyboardEmptyHint,
            UserTerminology.userKeyboardSwitcherEmpty,
            UserTerminology.userKeyboardCurrent,
            UserTerminology.addUserKeyboard,
            UserTerminology.userKeyboardReadOnlyNotice,
            UserTerminology.keyboardUtilitiesOpenLabel,
        ] {
            XCTAssertNil(UserTerminology.leaksInternalTerminology(text), text)
        }
        XCTAssertEqual(UserTerminology.userKeyboard, "我的键盘")
    }

    // MARK: - Management page: name backfill

    func testBackfillingNamesFillsOnlyBlankNamesFromSameSourceCandidates() {
        let unnamed26 = UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "", layout: .qwerty26)
        let unnamed9 = UserKeyboard(inputMethodID: "cangjie5", inputMethodName: "  ", layout: .phone9)
        let named = UserKeyboard(inputMethodID: "wubi86", inputMethodName: "旧名", layout: .qwerty26)
        let orphan = UserKeyboard(inputMethodID: "gone", inputMethodName: "", layout: .merged14)
        let candidates = [
            UserKeyboardCandidate(inputMethodID: "cangjie5", inputMethodName: "", layout: .merged14),
            UserKeyboardCandidate(inputMethodID: "cangjie5", inputMethodName: "倉頡五代", layout: .qwerty26),
            UserKeyboardCandidate(inputMethodID: "wubi86", inputMethodName: "五笔86", layout: .qwerty26),
        ]
        let filled = UserKeyboardRoster.backfillingNames(
            [unnamed26, named, unnamed9, orphan],
            from: candidates)
        // Order and identity unchanged; no items added or removed.
        XCTAssertEqual(filled.map(\.id), [unnamed26.id, named.id, unnamed9.id, orphan.id])
        // An empty name is filled in from the input method ID (empty-name candidates do not participate).
        XCTAssertEqual(filled[0].inputMethodName, "倉頡五代")
        XCTAssertEqual(filled[2].inputMethodName, "倉頡五代")
        // An existing name is not overwritten; names absent from the candidates stay neutral (the UI falls back to a generic name, not an internal ID).
        XCTAssertEqual(filled[1].inputMethodName, "旧名")
        XCTAssertEqual(filled[3].inputMethodName, "")
        XCTAssertEqual(filled[3].title, "14 键")
        XCTAssertEqual(UserKeyboardRoster.backfillingNames([unnamed26], from: []), [unnamed26])
    }

    // MARK: - Management page: failure text

    func testFailureMessageSurfacesStructuredReasonAndListUnchanged() {
        let fallback = "未能保存键盘。当前键盘列表没有改变，请重试。"
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(UserKeyboardPublicationError.busy, fallback: fallback),
            "另一项键盘操作正在进行，请稍后。当前键盘列表没有改变。")
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(
                UserKeyboardPublicationError.unavailable("所选输入方式与9 键当前无法配合使用。"),
                fallback: fallback),
            "所选输入方式与9 键当前无法配合使用。当前键盘列表没有改变。")
        // A missing period in the reason is added so the two sentences are not glued together.
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(
                UserKeyboardPublicationError.unavailable(" 请至少保留一个键盘 "), fallback: fallback),
            "请至少保留一个键盘。当前键盘列表没有改变。")
        for error in [
            UserKeyboardPublicationError.busy, .sourceNotInstalled, .notAdded,
            .noAddableKeyboards, .unavailable("此输入方案已变更，请重新选择。"),
        ] {
            let message = UserTerminology.userKeyboardFailureMessage(error, fallback: fallback)
            XCTAssertTrue(message.hasSuffix(UserTerminology.userKeyboardListUnchanged), message)
            XCTAssertNil(UserTerminology.leaksInternalTerminology(message), message)
            XCTAssertFalse(message.contains("发布"), message)
        }
    }

    func testFailureMessageFallsBackForUnstructuredOrLeakingErrors() {
        struct EngineError: LocalizedError {
            var errorDescription: String? { "deploy failed: missing build/foo.schema.yaml" }
        }
        let fallback = "未能保存键盘。当前键盘列表没有改变，请重试。"
        // Unstructured errors may carry internal details: only a generic message is given.
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(EngineError(), fallback: fallback),
            fallback)
        // Structured but with an empty reason or internal terminology: likewise falls back.
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(
                UserKeyboardPublicationError.unavailable("   "), fallback: fallback), fallback)
        XCTAssertEqual(
            UserTerminology.userKeyboardFailureMessage(
                UserKeyboardPublicationError.unavailable("schema 编译失败"), fallback: fallback), fallback)
    }

    // MARK: - Management page and trial typing: copy

    func testManagementCopyIsPlainAndNamesBothDimensions() {
        XCTAssertEqual(
            UserTerminology.userKeyboardToggleLabel(inputMethod: "倉頡五代", layout: .phone9),
            "倉頡五代，9 键")
        // With no input method name only the layout name is read, never an internal ID.
        XCTAssertEqual(UserTerminology.userKeyboardToggleLabel(inputMethod: " ", layout: .merged14), "14 键")
        XCTAssertEqual(UserTerminology.userKeyboardAdded, "已添加")
        XCTAssertEqual(UserTerminology.userKeyboardNotAdded, "未添加")
        XCTAssertEqual(UserTerminology.userKeyboardSaved(count: 3), "已保存，共 3 个键盘。")
        XCTAssertEqual(UserTerminology.userKeyboardSaveNeedsOne, "至少打开一个键盘才能保存。")
        XCTAssertEqual(UserTerminology.userKeyboardListUnchanged, "当前键盘列表没有改变。")
        XCTAssertTrue(UserTerminology.userKeyboardNeedsSourceHint.hasPrefix(UserTerminology.userKeyboardNoSource))
        // Switching happens in the scheme's own 我的键盘; a scheme without one has its own "Use".
        XCTAssertTrue(UserTerminology.userKeyboardHowToStart.contains("「我的键盘」"))
        XCTAssertTrue(UserTerminology.userKeyboardHowToStart.contains("「使用」"))
        XCTAssertFalse(UserTerminology.userKeyboardHowToStart.contains(UserTerminology.inputMethod))
        // Footnote: "Save", "Use", and how it relates to the in-keyboard long-press list.
        let footnote = UserTerminology.userKeyboardFootnote
        for part in ["「保存」", "「使用」", "长按中英键"] {
            XCTAssertTrue(footnote.contains(part), part)
        }

        let plain = [
            UserTerminology.userKeyboardNoSource, UserTerminology.userKeyboardHowToStart,
            UserTerminology.userKeyboardNeedsSourceHint, footnote,
            UserTerminology.userKeyboardSaving, UserTerminology.userKeyboardSaveNeedsOne,
            UserTerminology.userKeyboardSaved(count: 1), UserTerminology.userKeyboardListUnchanged,
            UserTerminology.userKeyboardNowUsing("倉頡五代 · 9 键"),
            UserTerminology.tryUsesCurrentScheme, UserTerminology.tryHowToUseViaUserKeyboard,
            UserTerminology.tryHowToUseViaStartUsing,
            UserTerminology.trySourceContext(name: "A", inUse: true, howToUse: "x"),
            UserTerminology.trySourceContext(
                name: "A", inUse: false,
                howToUse: UserTerminology.tryHowToUseViaUserKeyboard),
        ]
        for text in plain {
            XCTAssertNil(UserTerminology.leaksInternalTerminology(text), text)
            for jargon in ["生成", "验证", "发布", "重载", "适配", "CAS", "route"] {
                XCTAssertFalse(text.contains(jargon), "\(jargon)：\(text)")
            }
        }
    }

    /// Home rows: 输入方案 says what is installed, 我的键盘 says which keyboard is in use.
    func testHomeSummariesSplitSchemesFromKeyboards() {
        XCTAssertEqual(
            UserTerminology.currentKeyboardSummary(inputMethod: "倉頡五代", layout: .phone9), "正在使用：倉頡五代 · 9 键")
        XCTAssertEqual(UserTerminology.currentKeyboardSummary(inputMethod: nil, layout: .qwerty26), "正在使用：26 键")
        XCTAssertNil(UserTerminology.currentKeyboardSummary(inputMethod: "", layout: nil))
        XCTAssertEqual(
            UserTerminology.installedSchemeSummary(count: 2, inUse: "通用形码包"), "已安装 2 个输入方案，正在使用「通用形码包」")
        XCTAssertEqual(UserTerminology.installedSchemeSummary(count: 2, inUse: nil), "已安装 2 个输入方案")
        XCTAssertFalse(
            UserTerminology.installedSchemeSummary(count: 1, inUse: "A").contains(UserTerminology.inputMethod))
    }

    func testTrySourceContextIsTruthfulAboutWhetherSourceIsInUse() {
        XCTAssertEqual(
            UserTerminology.trySourceContext(name: "通用形码包", inUse: true, howToUse: "忽略"),
            "键盘正在使用「通用形码包」。")
        XCTAssertEqual(
            UserTerminology.trySourceContext(
                name: "通用形码包", inUse: false,
                howToUse: UserTerminology.tryHowToUseViaUserKeyboard),
            "键盘没有在使用「通用形码包」。要试打「通用形码包」，"
                + "请先回到上一页，在「我的键盘」里轻点要用的键盘下方的「使用」。")
        XCTAssertEqual(
            UserTerminology.trySourceContext(
                name: "自定义拼音", inUse: false,
                howToUse: UserTerminology.tryHowToUseViaStartUsing),
            "键盘没有在使用「自定义拼音」。要试打「自定义拼音」，"
                + "请先回到上一页点「使用」。")
        // With no name, use a neutral term, leaving no empty quotes.
        XCTAssertEqual(
            UserTerminology.trySourceContext(name: " ", inUse: true, howToUse: ""),
            "键盘正在使用这个输入方案。")
    }
}

/// The test's own management fixture: **not in production** (the production implementation is the single Host-side adapter file).
@MainActor
private final class FakeUserKeyboardManager: UserKeyboardManaging {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case unavailable, notAddable, notPublished
        var errorDescription: String? {
            switch self {
            case .unavailable: return "当前版本只能查看键盘。"
            case .notAddable: return "此组合当前不可用。"
            case .notPublished: return "这个键盘不在当前列表中。"
            }
        }
    }

    let supportsManagement: Bool
    private(set) var published: [UserKeyboard]
    private let addable: [UserKeyboardCandidate]
    private(set) var addCalls: [UserKeyboardCandidate] = []
    private(set) var removeCalls: [UserKeyboard] = []
    private(set) var replaceCalls: [[UserKeyboard]] = []

    init(
        addable: [UserKeyboardCandidate] = [], published: [UserKeyboard] = [],
        supportsManagement: Bool = true
    ) {
        self.addable = addable
        self.published = published
        self.supportsManagement = supportsManagement
    }

    func addableKeyboards() async throws -> [UserKeyboardCandidate] {
        guard supportsManagement else { throw Error.unavailable }
        return addable
    }

    func addKeyboard(_ candidate: UserKeyboardCandidate) async throws -> String {
        guard supportsManagement else { throw Error.unavailable }
        addCalls.append(candidate)
        guard addable.contains(candidate) else { throw Error.notAddable }
        let keyboard = candidate.keyboard()
        if !published.contains(keyboard) { published.append(keyboard) }
        return "已添加 \(keyboard.title)。"
    }

    func removeKeyboard(_ keyboard: UserKeyboard) async throws -> String {
        guard supportsManagement else { throw Error.unavailable }
        removeCalls.append(keyboard)
        guard published.contains(keyboard) else { throw Error.notPublished }
        published.removeAll { $0 == keyboard }
        return "已移除 \(keyboard.title)。"
    }

    func replaceKeyboards(_ keyboards: [UserKeyboard]) async throws -> String {
        guard supportsManagement else { throw Error.unavailable }
        replaceCalls.append(keyboards)
        published = keyboards
        return "已更新 \(keyboards.count) 个我的键盘。"
    }
}
