import Foundation

/// User-model terminology for input configuration (the single literal source shared by Host and the keyboard extension).
///
/// User model (a generic Rime front end, not designed around any particular source). The host app
/// has two places to act: 输入方案 (what is installed) and 我的键盘 (what is on the keyboard).
///  - Input scheme: an installable unit of data (a source). A source can contain
///    any number of schemes with any names; the list always comes from the resource snapshot's enabled list.
///  - Input method: a concrete way of typing within a scheme (a schema, e.g. full pinyin,
///    Xiaohe Shuangpin, 9-key, shape-code, dialect). Display names come from the resource
///    snapshot; no schema ID is hard-coded. It is only a group heading in 我的键盘 and a read-only
///    list on a scheme's detail page, never a separate place to choose.
///  - Keyboard layout: a front-end keyboard capability (26 / 14 / 9 / custom key layout),
///    independent of source identity; whether an input method works with a layout is decided
///    only by resource capability (`availableCombinations` / `incompatibilityReason`).
///  - Keyboard appearance: colors / fonts / candidate-area light-dark (separate entry).
///  - Dictionary: supplementary vocabulary (separate entry).
///
/// Internal terms that must not appear in ordinary UI are listed in `bannedInternalTerms`;
/// the copy gate is `leaksInternalTerminology`.
public enum UserTerminology: Sendable {

    // MARK: - Objects and groups

    /// An installable/usable unit of data.
    public static let inputScheme = "输入方案"
    /// A concrete way of typing within a scheme (schema).
    public static let inputMethod = "输入方式"
    /// Front-end keyboard layout (26 / 14 / 9 / custom).
    public static let keyboardLayout = "键盘布局"
    /// Colors/fonts/candidate-area light-dark.
    public static let keyboardAppearance = "键盘外观"
    /// Supplementary vocabulary.
    public static let dictionary = "词库"
    /// Language model that predicts whole sentences from the composition.
    public static let grammarModel = "语法模型"
    /// A set of added "input method + keyboard layout" combinations (managed in the main app, switched by long-press in the keyboard).
    public static let userKeyboard = "我的键盘"

    // MARK: - Status (identical wording in Host and keyboard)

    /// Has become the current selection.
    public static let statusInUse = "正在使用"
    /// Installed but not the current selection.
    public static let statusNotApplied = "未使用"

    // MARK: - Actions

    /// Apply action: switch to a keyboard in 我的键盘, or to a scheme without one (custom pinyin).
    public static let startUsing = "使用"
    /// Apply action when a newer version is installed.
    public static let startUsingNewVersion = "使用新版本"
    /// Add entry.
    public static let addInputScheme = "添加输入方案"

    // MARK: - Failure and retry (plain wording)

    /// Plain wording when reading the current selection fails (cause and retry entry are supplied in place by the caller).
    public static let readFailureWithRetry = "无法读取当前选择，请重试。"

    /// Generic plain wording for an operation that did not complete. Raw errors show only in
    /// developer options; the ordinary flow shows no internal prefix or low-level error string.
    public static let genericOperationFailure = "操作未完成，请重试。"

    // MARK: - Home summary

    /// Prefix of the in-use summaries.
    public static let inUsePrefix = "正在使用"

    /// Scheme summary: "In use: <scheme> · <input method> · <keyboard layout>" (Chinese wording).
    ///
    /// `scheme == nil` means there is no usable product input scheme (Release does not pass built-in package off as usable).
    public static func inUseSummary(scheme: String?, inputMethod: String?, layout: String?) -> String {
        guard let scheme, !scheme.isEmpty else { return ProductionInputAvailability.unconfiguredTitle }
        var parts = [scheme]
        if let inputMethod, !inputMethod.isEmpty, inputMethod != scheme { parts.append(inputMethod) }
        if let layout, !layout.isEmpty { parts.append(layout) }
        return "\(inUsePrefix)：\(parts.joined(separator: " · "))"
    }

    /// Home 我的键盘 row: the keyboard in use, "In use: <input method> · <keyboard layout>".
    /// Either part may be missing; with neither there is nothing to report.
    public static func currentKeyboardSummary(inputMethod: String?, layout: KeyboardLayoutKind?) -> String? {
        let parts = [inputMethod, layout.map(layoutName)].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return "\(inUsePrefix)：\(parts.joined(separator: " · "))"
    }

    /// Home 输入方案 row: how many schemes are installed and which one the keyboard uses.
    public static func installedSchemeSummary(count: Int, inUse: String?) -> String {
        let installed = installedSourceSummary(count: count)
        guard count > 0, let inUse, !inUse.isEmpty else { return installed }
        return "\(installed)，\(inUsePrefix)「\(inUse)」"
    }

    /// Installed source count. The installed source count is never called a "scheme count".
    public static func installedSourceSummary(count: Int) -> String {
        count <= 0
            ? ProductionInputAvailability.unconfiguredCountSummary
            : "已安装 \(count) 个输入方案"
    }

    // MARK: - Dynamic dimension display

    /// User-facing keyboard layout name (same in Host and keyboard).
    public static func layoutName(_ layout: KeyboardLayoutKind) -> String { layout.userTitle }

    /// Input method display name (from the resource snapshot, always dynamic).
    public static func inputMethodName(_ schema: KeyboardSchemaDescriptor) -> String { schema.displayName }

    /// Resolves the input method display name from the publication record. Returns nil when no
    /// user-readable name can be resolved; an internal schema ID is never shown as ordinary text.
    public static func inputMethodName(
        schemaID: String?,
        schemas: [KeyboardSchemaDescriptor]?
    ) -> String? {
        guard let schemaID else { return nil }
        if let named = schemas?.first(where: { $0.id == schemaID }), !named.name.isEmpty {
            return named.displayName
        }
        let normalized = KeyboardSchemaDescriptor(id: schemaID, name: "").displayName
        return normalized == schemaID ? nil : normalized
    }

    /// The "Input methods: A, B" line; nil when there are no input methods (no placeholder is invented).
    public static func inputMethodLine(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "\(inputMethod)：\(cleaned.joined(separator: "、"))"
    }

    /// The "Keyboard layouts: 26-key, 9-key" line; nil when no layout is available.
    public static func keyboardLayoutLine(_ names: [String]) -> String? {
        let cleaned = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "\(keyboardLayout)：\(cleaned.joined(separator: "、"))"
    }

    /// Plain-language reason when the input method does not support a layout (avoids the banned terms).
    public static func layoutUnavailableReason(_ layout: KeyboardLayoutKind) -> String {
        "此输入方式暂不支持「\(layoutName(layout))」，请改用其他键盘布局。"
    }

    // MARK: - User keyboards (input method + keyboard layout)

    /// Add entry (main app).
    public static let addUserKeyboard = "添加键盘"
    /// Marks the current item in the switcher.
    public static let userKeyboardCurrent = "当前键盘"
    /// Plain-language explanation when the scheme offers no keyboard at all.
    public static let userKeyboardEmptyHint = "这个输入方案没有可用的键盘。"
    /// Hint row when the in-keyboard switcher is empty (not tappable; only says where to add).
    public static let userKeyboardSwitcherEmpty = "尚未添加键盘 · 请在松烟 App 的「我的键盘」中添加"

    /// Read-only explanation when the management transaction is not wired up (plain language).
    public static let userKeyboardReadOnlyNotice =
        "这里暂时无法修改。请在「输入方案」中打开方案，再从它的「我的键盘」添加。"

    // MARK: - User keyboard management page (main app)

    /// The keyboard is not using any input scheme (status sentence shared by home, onboarding, and the user keyboard page).
    public static let userKeyboardNoSource = "键盘还没有使用任何输入方案。"

    /// How to make the keyboard start using an input scheme. Schemes with 我的键盘 switch there;
    /// those without (custom pinyin) have their own "start using" button.
    public static let userKeyboardHowToStart =
        "请在「\(inputScheme)」中打开要用的方案，在它的「\(userKeyboard)」里轻点「\(startUsing)」；"
        + "没有「\(userKeyboard)」的方案，直接轻点「\(startUsing)」。"

    /// Full explanation for the user keyboard page's "not using any input scheme" state.
    public static var userKeyboardNeedsSourceHint: String { userKeyboardNoSource + userKeyboardHowToStart }

    /// Management page footnote: what the toggles and "Use" do, and how they relate to the in-keyboard switch list.
    public static let userKeyboardFootnote =
        "勾选后点「保存」加入键盘，长按中英键可切换；轻点「\(startUsing)」立即换用。"

    /// Saving in progress.
    public static let userKeyboardSaving = "正在保存键盘…"

    /// Explanation when saving is blocked because no keyboard is turned on in the draft.
    public static let userKeyboardSaveNeedsOne = "至少打开一个键盘才能保存。"

    /// Accessibility values of the toggle.
    public static let userKeyboardAdded = "已添加"
    public static let userKeyboardNotAdded = "未添加"
    /// The management page toggles edit a draft; before saving they must not be read as "added".
    public static let userKeyboardSelected = "已选择"
    public static let userKeyboardNotSelected = "未选择"
    public static let userKeyboardDraftHint = "保存后生效"

    /// Accessibility label of the toggle: reads both input method and layout (group titles are not read per item).
    public static func userKeyboardToggleLabel(inputMethod: String, layout: KeyboardLayoutKind) -> String {
        let name = inputMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? layoutName(layout) : "\(name)，\(layoutName(layout))"
    }

    /// Message after "Use" switched the keyboard.
    public static func userKeyboardNowUsing(_ title: String) -> String {
        "已换用「\(title)」。"
    }

    /// Message for a successful save.
    public static func userKeyboardSaved(count: Int) -> String {
        "已保存，共 \(max(0, count)) 个键盘。"
    }

    /// Sentence appended after a failed or rejected write: the list is unchanged.
    public static let userKeyboardListUnchanged = "当前键盘列表没有改变。"

    /// Plain message for a failed user keyboard operation.
    ///
    /// The publication transaction's structured error (`UserKeyboardPublicationError`, always
    /// thrown before any write) carries a plain-language reason: it is used as-is, with a note
    /// that the list is unchanged. Other errors may carry internal detail, so only the caller's
    /// generic message is used; an empty reason or one containing internal terms also falls back.
    public static func userKeyboardFailureMessage(_ error: Error, fallback: String) -> String {
        guard let publication = error as? UserKeyboardPublicationError,
            let raw = publication.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty, leaksInternalTerminology(raw) == nil
        else { return fallback }
        let ended = raw.last.map { "。！？.!?".contains($0) } ?? false
        return (ended ? raw : raw + "。") + userKeyboardListUnchanged
    }

    // MARK: - Trial typing (main app)

    /// General explanation on the trial page: what is typed and how to change keyboards.
    public static let tryUsesCurrentScheme =
        "长按中英键切换键盘。"

    /// Source detail only knows the published selection. `howToUse` is an imperative phrase
    /// without a trailing period (see `tryHowToUseViaUserKeyboard` etc.).
    public static func trySourceContext(name: String, inUse: Bool, howToUse: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "这个\(inputScheme)" : "「\(trimmed)」"
        return inUse
            ? "键盘正在使用\(label)。"
            : "键盘没有在使用\(label)。要试打\(label)，\(howToUse)。"
    }

    /// Switch to it via the source's own "user keyboard".
    public static let tryHowToUseViaUserKeyboard =
        "请先回到上一页，在「\(userKeyboard)」里轻点要用的键盘下方的「\(startUsing)」"

    /// Switch to it via "start using".
    public static let tryHowToUseViaStartUsing = "请先回到上一页点「\(startUsing)」"

    /// Accessibility label/hint of the tools entry.
    public static let keyboardUtilitiesOpenLabel = "打开键盘设置"

    /// Tools entry in the "ABC/Chinese" long-press menu (separate from the candidate bar).
    public static let keyboardMoreTools = "键盘设置…"
    /// Entry from the keyboard's own settings to the app that owns the rest of the configuration.
    public static let openHostApp = "打开「松烟」App"

    // MARK: - Copy gate

    /// Internal terms banned from ordinary UI (case-insensitive match).
    public static let bannedInternalTerms = [
        "schema", "recipe", "resource", "deploy", "prism", "algebra", "generation",
        "键型", "键盘样式", "方案配对",
        "部署", "发布", "配方", "绑定", "幂等", "共享容器", "processor", "lua_",
    ]

    /// Returns the first internal term leaked in the text; nil if none.
    public static func leaksInternalTerminology(_ text: String) -> String? {
        bannedInternalTerms.first { text.localizedCaseInsensitiveContains($0) }
    }
}
