import CandidateKit
import KeyboardCore
import LayoutKit
import SwiftUI
import UIKit

/// One authored-page key face. The live panel and every preview draw through this same view, so a
/// copied page cannot look different from the keyboard that runs it.
struct KeyboardAuthoredPageKey: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let key: LayoutKey
    let path: KeyboardPageKeyPath
    let state: KeyboardPageAuthoredState
    let actions: KeyboardPageAuthoredActions
    let actionTable: KeyboardPageAuthoredActionTable
    var selected = false
    /// A preview selects keys instead of running them: leave a disabled-looking control tappable.
    var editorSelection = false

    var body: some View {
        Group {
            switch key.action.type {
            case .shift: shiftFace
            case .backspace: deleteFace
            case .space: spaceFace
            case .globe: globeFace
            case .enter: enterFace
            default: genericFace
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Faces

    /// Shift keeps its native single/double tap and state icon unless the author declared
    /// long-press alternates, which replace the native gestures for that key only.
    /// An authored label replaces the native glyph; automatic keeps the native face. The secondary
    /// label is author data and is drawn by every native face, not only the generic one.
    private var authorTitle: String? {
        key.titleMode == .custom && !key.label.isEmpty ? key.label : nil
    }

    @ViewBuilder private var shiftFace: some View {
        if (key.longPress ?? []).isEmpty {
            // Editor selection uses a release-time tap instead of Shift's runtime
            // touch-down and double-tap behavior; the native face retains its dimming.
            ShiftKey(
                state: state.shiftState, isEnglishMode: state.isEnglishMode,
                customTitle: authorTitle, subtitle: subtitle,
                tap: { actions.primary(path, LayoutAction(.shift)) },
                doubleTap: { actions.performShiftDoubleTap(path) }
            )
            .allowsHitTesting(!editorSelection)
            .overlay {
                if editorSelection {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { actions.primary(path, LayoutAction(.shift)) }
                        .accessibilityHidden(true)
                }
            }
        } else {
            genericFace
        }
    }

    @ViewBuilder private var deleteFace: some View {
        if (key.longPress ?? []).isEmpty {
            RepeatingDeleteKey(title: authorTitle, subtitle: subtitle) { repeating in
                if let performNativeDelete = actions.performNativeDelete {
                    performNativeDelete(path, repeating)
                } else {
                    actions.primary(path, LayoutAction(.backspace))
                }
            }
        } else {
            genericFace
        }
    }

    /// The native space bar owns its own cursor-pan session; a declared long press replaces it.
    @ViewBuilder private var spaceFace: some View {
        if (key.longPress ?? []).isEmpty {
            CursorSpaceKey(
                title: state.title(for: key), layoutName: actions.spaceLayoutName,
                layoutHintName: actions.spaceHintName, layoutHintToken: actions.spaceHintToken,
                subtitle: subtitle,
                onTap: { actions.primary(path, LayoutAction(.space)) }, moveCursor: actions.moveCursor)
        } else {
            genericFace
        }
    }

    @ViewBuilder private var globeFace: some View {
        let handler = actions.systemKeyboardSwitch ?? editorSelectionHandler
        if (key.longPress ?? []).isEmpty, let handler {
            NativeInputModeKey(
                title: authorTitle, subtitle: subtitle,
                handleEvent: handler,
                accessibilitySwitch: { actions.primary(path, LayoutAction(.globe)) })
        } else {
            genericFace
        }
    }

    /// An editor preview still draws the native globe face, but it must never hand touches to the
    /// system keyboard list. It forwards the real touch stream and selects this key once on lift.
    private var editorSelectionHandler: ((UIView, UIEvent) -> Void)? {
        guard editorSelection else { return nil }
        return { _, event in
            guard event.type == .touches,
                event.allTouches?.contains(where: { $0.phase == .ended }) == true
            else { return }
            actions.primary(path, LayoutAction(.globe))
        }
    }

    @ViewBuilder private var enterFace: some View {
        ReturnKey(
            title: state.title(for: key), isEnabled: state.isReturnEnabled,
            alternates: optionCaps, longPressDelay: 0.35,
            capID: KeyboardPageAuthoredActionTable.capID(path), subtitle: subtitle
        ) { cap in
            perform(cap)
        }
    }

    @ViewBuilder private var genericFace: some View {
        AlternateCharacterKey(
            cap: KeyCap(
                id: KeyboardPageAuthoredActionTable.capID(path), title: displayTitle,
                subtitle: subtitle, action: faceAction(key.action, alternate: false)),
            alternates: faceAlternates, longPressDelay: 0.35,
            layoutPicker: keepsNativeLanguageMenu,
            phoneKey: phoneKeyFace,
            phoneSideKey: phoneSideKeyFace,
            showsKeyPreview: showsKeyPreview,
            visualRole: visualRole,
            accessibilityID: KeyboardPageAuthoredActionTable.capID(path),
            onSelect: { cap in select(cap) }
        )
        .disabled(!state.isEnabled(key) && !editorSelection)
        .opacity((!state.isEnabled(key) && !editorSelection) || shiftDimmed ? 0.4 : 1)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.accessibilityValue(for: key) ?? "")
        .accessibilityHint(accessibilityHint)
    }

    // MARK: Key facts

    private var subtitle: String? {
        guard let label = key.secondaryLabel, !label.isEmpty else { return nil }
        return label
    }

    private var showsKeyPreview: Bool {
        guard let value = key.resolvedLiteralValue(usesASCIIPunctuation: state.usesASCIIPunctuation),
            value.utf8.count == 1
        else { return false }
        // The built-in digit pad never draws the finger callout over its digits; category symbols do.
        if state.isPhoneStyled, case .row = path { return false }
        return true
    }

    /// On an English page a single ASCII letter is a real letter key: its title follows Shift and
    /// its action is an engine code, so caps-lock, word and double-space logic keep working.
    private var displayTitle: String {
        guard state.kind == .english, key.titleMode != .custom, key.action.singleASCIILetter != nil
        else { return state.title(for: key) }
        return state.shiftActive ? key.label.uppercased() : key.label
    }

    /// A keypad page keeps the phone key faces: digits use the pad's larger glyph, rails use the
    /// side-key tone, exactly like the built-in 9-key shell it was copied from.
    private var phoneKeyFace: Bool {
        guard state.isPhoneStyled else { return false }
        if case .row = path { return true }
        return false
    }

    private var phoneSideKeyFace: Bool {
        guard state.isPhoneStyled else { return false }
        switch path {
        case .chrome(.leading, _), .chrome(.trailing, _): return true
        case .row, .chrome(.bottom, _): return false
        }
    }

    /// A generic shift face cannot show the native lock icon, so its selected role carries the state.
    private var visualRole: String? {
        switch key.action.type {
        case .symbolLock: return state.symbolLocked ? "selected" : "control"
        case .shift: return state.shiftActive ? "selected" : "control"
        default: return nil
        }
    }

    private var shiftDimmed: Bool {
        key.action.type == .shift && !state.isEnglishMode
    }

    private var accessibilityLabel: String {
        guard key.titleMode == .automatic else { return key.label }
        switch key.action.type {
        case .pageSwitch:
            if key.action.pageSwitchTarget == .letters { return "返回主键盘" }
            let title = state.title(for: key)
            return "打开\(title)页"
        case .languageSwitch:
            return state.controlPolicy.languageAccessibilityLabel(
                for: key.action.languageSwitchBehavior)
        case .symbolLock: return "锁定符号页"
        case .clearInput: return "重输"
        case .shift: return "上档键"
        default: return state.title(for: key)
        }
    }

    private var accessibilityHint: String {
        guard key.titleMode == .automatic else { return "" }
        switch key.action.type {
        case .clearInput: return state.isComposing ? "清空当前输入" : "当前没有待确认的输入"
        case .symbolLock: return state.symbolLocked ? "输入符号后留在符号页" : "输入一个符号后回到字母页"
        case .shift: return state.isEnglishMode ? "轻点切换一次大写，连续点按两次锁定大写" : "当前为中文输入；使用语言键切换到英文后可用"
        default: return ""
        }
    }

    /// A language key with no authored long press keeps the native keyboard/tools menu.
    private var keepsNativeLanguageMenu: Bool {
        key.action.type == .languageSwitch && (key.longPress ?? []).isEmpty
    }

    private var faceAlternates: [KeyCap] {
        keepsNativeLanguageMenu ? actions.languageMenuAlternates : optionCaps
    }

    private func select(_ cap: KeyCap) {
        if keepsNativeLanguageMenu, cap.id != KeyboardPageAuthoredActionTable.capID(path) {
            actions.handleLanguageMenu?(cap)
            return
        }
        perform(cap)
    }

    private var optionCaps: [KeyCap] {
        (key.longPress ?? []).enumerated().map { index, option in
            KeyCap(
                id: KeyboardPageAuthoredActionTable.optionCapID(path, index), title: option.label,
                action: faceAction(option.action, alternate: true))
        }
    }

    /// A control action has no engine face of its own; the tap is routed through the action table,
    /// so the placeholder only picks the native control tone.
    private func faceAction(_ action: LayoutAction, alternate: Bool) -> KeyAction {
        if state.kind == .english, let letter = action.singleASCIILetter {
            // The engine owns shift/case: a plain tap sends the lowercase code, an explicit
            // long-press variant stays verbatim, as on the legacy English page.
            return alternate ? .letterVariant(letter) : .code(letter.lowercased())
        }
        switch action.type {
        case .literal:
            return .literal(action.literalValue(usesASCIIPunctuation: state.usesASCIIPunctuation) ?? "")
        case .space: return .space
        case .backspace: return .backspace
        case .enter: return .enter
        case .globe: return .switchKeyboard
        case .modeSwitch: return .cycleLayout
        case .code: return .code(action.value ?? "")
        case .shift, .pageSwitch, .languageSwitch, .symbolLock, .clearInput: return .cycleLayout
        }
    }

    private func perform(_ cap: KeyCap) {
        guard let entry = actionTable.entry(for: cap.id) else { return }
        actions.perform(entry.path, entry.action, entry.isAlternate)
    }
}

/// The authored rows of a page. Geometry comes from the one LayoutKit builder, so the live keyboard
/// and the preview cannot drift: standard alphabet rows keep the 26-key columns, anything else uses
/// the declared relative weights, and no Shift/Delete is ever synthesised here.
struct KeyboardAuthoredPageRows: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    /// The page with keys the system cannot use already removed; source indices map a visible key
    /// back to its authored position so selection and action routing stay on the stored address.
    let page: KeyboardPageDefinition
    let split: LayoutSplitConfiguration?
    let metrics: KeyboardAuthoredPageMetrics
    let sourceIndices: [[Int]]
    let state: KeyboardPageAuthoredState
    let actions: KeyboardPageAuthoredActions
    let actionTable: KeyboardPageAuthoredActionTable
    var selectedPath: KeyboardPageKeyPath? = nil
    var editorSelection = false

    var body: some View {
        VStack(spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing)) {
            ForEach(Array(page.rows.enumerated()), id: \.offset) { rowIndex, row in
                GeometryReader { proxy in
                    let geometry = KeyboardPageRowGeometry(
                        width: Double(proxy.size.width), page: page, row: rowIndex, split: split)
                    HStack(spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing)) {
                        ForEach(Array(geometry.keyIndices.enumerated()), id: \.element) { position, source in
                            if position == geometry.splitIndex, geometry.gap > 0 {
                                KeyboardSplitGap()
                                    .frame(
                                        width: max(
                                            0, CGFloat(geometry.gap) - CGFloat(KeyboardAuthoredPageMetrics.spacing)),
                                        height: keyHeight)
                            }
                            keyView(row: rowIndex, key: source, keyValue: row.keys[source])
                                .frame(width: CGFloat(geometry.keyWidths[position]), height: keyHeight)
                        }
                    }
                    .padding(.horizontal, CGFloat(geometry.inset))
                    .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(height: keyHeight)
            }
        }
    }

    private func keyView(row: Int, key: Int, keyValue: LayoutKey) -> KeyboardAuthoredPageKey {
        let path = KeyboardPageKeyPath.row(row, key: sourceIndices[row][key])
        return KeyboardAuthoredPageKey(
            key: keyValue, path: path, state: state, actions: actions, actionTable: actionTable,
            selected: selectedPath == path, editorSelection: editorSelection)
    }
}

/// One authored side rail. Vertical spans come from the author's relative widths through the shared
/// rail geometry; a rail that cannot fit its minimum key heights scrolls instead of compressing.
struct KeyboardAuthoredPageRail: View {
    let keys: [LayoutKey]
    let sourceIndices: [Int]
    let region: KeyboardPageChrome.Region
    let height: CGFloat
    let state: KeyboardPageAuthoredState
    let actions: KeyboardPageAuthoredActions
    let actionTable: KeyboardPageAuthoredActionTable
    var selectedPath: KeyboardPageKeyPath? = nil
    var editorSelection = false

    var body: some View {
        let geometry = KeyboardPageRailGeometry(
            height: Double(height), weights: keys.map(\.widthWeight),
            spacing: KeyboardAuthoredPageMetrics.spacing,
            minimumKeyHeight: KeyboardAuthoredPageMetrics.minimumKeyHeight)
        let content = VStack(spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing)) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                keyView(index: index, keyValue: key)
                    .frame(height: CGFloat(geometry.keyHeights[index]))
            }
        }
        if geometry.contentHeight > Double(height) + 0.5 {
            ScrollView(.vertical, showsIndicators: false) { content }
                .sharpCandidateScrollEdges()
        } else {
            content
        }
    }

    private func keyView(index: Int, keyValue: LayoutKey) -> KeyboardAuthoredPageKey {
        let path = KeyboardPageKeyPath.chrome(region, key: sourceIndices[index])
        return KeyboardAuthoredPageKey(
            key: keyValue, path: path, state: state, actions: actions, actionTable: actionTable,
            selected: selectedPath == path, editorSelection: editorSelection)
    }
}

/// The authored bottom row. Split spaces are duplicated only from one declared space; a second or
/// missing author space stays exactly as authored, and a footer without a space inserts none.
///
/// Widths come from the one LayoutKit footer geometry: a structural default keeps the built-in
/// control-row budget, any real author change falls back to relative weights. A forced split too
/// narrow for two usable spaces scrolls instead of dropping one of them.
struct KeyboardAuthoredPageFooter: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let page: KeyboardPageDefinition
    let keys: [LayoutKey]
    let sourceIndices: [Int]
    let split: LayoutSplitConfiguration?
    let rootWidth: CGFloat
    let state: KeyboardPageAuthoredState
    let actions: KeyboardPageAuthoredActions
    let actionTable: KeyboardPageAuthoredActionTable
    var selectedPath: KeyboardPageKeyPath? = nil
    var editorSelection = false

    private var minimumWidth: Double { KeyboardAuthoredPageMetrics.minimumKeyHeight }
    /// Categorised pages keep browser rows as backup data; the presentation decides the shape.
    private var isCategoryPage: Bool { page.symbolPresentation == .categorized }
    private var isKeypadPage: Bool { page.isKeypad }

    var body: some View {
        GeometryReader { proxy in
            let width = Double(proxy.size.width)
            if let split, !keys.isEmpty {
                splitRow(width: width, split: split)
            } else {
                plainRow(width: width)
            }
        }
    }

    /// The built-in control row's own policy for this page, so the shared footer geometry can tell
    /// a structural default from authored data. The visible keys already dropped an unusable globe.
    private var policy: KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: state.page, isEnglishMode: state.isEnglishMode, hasGlobe: state.hasGlobe,
            isPhoneLayout: state.isPhoneStyled, usesASCIIPunctuation: state.usesASCIIPunctuation,
            includesBottomEnter: !(isCategoryPage || isKeypadPage),
            usesCategorySymbolPage: isCategoryPage)
    }

    /// The one geometry entry shared with the preview: same keys, same policy, same width.
    private func footerGeometry(_ width: Double) -> KeyboardPageFooterGeometry {
        KeyboardPageFooterGeometry(width: max(0, width), keys: keys, policy: policy)
    }

    private var spaceIndex: Int? {
        keys.firstIndex { $0.action.type == .space }
    }

    @ViewBuilder private func plainRow(width: Double) -> some View {
        let geometry = footerGeometry(width)
        let spacing = CGFloat(geometry.spacing)
        if let floored = minimumScrollWidths(geometry) {
            // Generic authored data floors every key to a usable width first; if the floored row is
            // wider than the viewport it scrolls instead of producing untappable slivers.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                        keyView(index: index, keyValue: key)
                            .frame(width: CGFloat(floored[index]), height: keyHeight)
                    }
                }
            }
            .sharpCandidateScrollEdges()
        } else {
            HStack(spacing: spacing) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    keyView(index: index, keyValue: key)
                        .frame(width: CGFloat(max(0, geometry.keyWidths[index])), height: keyHeight)
                }
            }
        }
    }

    /// Generic authored widths only: floor each key to a usable touch width; when a real weight
    /// makes any key narrower than that, the caller scrolls the floored row. The built-in budget
    /// keeps its legacy scaling rules.
    private func minimumScrollWidths(_ geometry: KeyboardPageFooterGeometry) -> [Double]? {
        guard !geometry.usesControlRowBudget, !keys.isEmpty else { return nil }
        guard geometry.keyWidths.contains(where: { $0 < minimumWidth }) else { return nil }
        return geometry.keyWidths.map { max(minimumWidth, $0) }
    }

    @ViewBuilder private func splitRow(width: Double, split: LayoutSplitConfiguration) -> some View {
        let boundary =
            split.breakIndex(row: page.rows.count, keyCount: keys.count, width: Double(rootWidth))
            ?? keys.count
        let left = keys.indices.filter { $0 < boundary }
        let right = keys.indices.filter { $0 >= boundary }
        if let spaceIndex, keys.filter({ $0.action.type == .space }).count == 1 {
            dualSpaceRow(width: width, split: split, left: left, right: right, space: spaceIndex)
        } else {
            authoredSpaceRow(width: width, split: split, left: left, right: right)
        }
    }

    /// Exactly one author space: it becomes the two native cursor spaces (one per half). If the row
    /// cannot hold both, it scrolls horizontally instead of falling back to a single space.
    @ViewBuilder private func dualSpaceRow(
        width: Double, split: LayoutSplitConfiguration, left: [Int], right: [Int], space: Int
    ) -> some View {
        let footer = footerGeometry(width)
        // The built-in split row pins its controls to the 320pt budget and lets the two spaces
        // share the remainder; the structural default keeps that, authored data uses its weights.
        let controlWidths =
            footer.usesControlRowBudget ? footerGeometry(320).keyWidths : footer.keyWidths
        let leftWidths = left.filter { $0 != space }.map { max(minimumWidth, controlWidths[$0]) }
        let rightWidths = right.filter { $0 != space }.map { max(minimumWidth, controlWidths[$0]) }
        // Space prefers three letter widths, exactly the legacy split row.
        let letterWidth = StandardKeyRowGeometry(width: width, split: split).keyWidth
        let preferredSpace = letterWidth * 3 * keys[space].widthWeight / 4
        let requestedGap = split.gap(width: Double(rootWidth), keyCount: keys.count + 1)
        if let geometry = SplitSpaceRowGeometry(
            width: width, requestedGap: requestedGap, leftKeyWidths: leftWidths,
            rightKeyWidths: rightWidths, spacing: footer.spacing,
            minimumSpaceWidth: minimumWidth,
            preferredSpaceWidth: max(minimumWidth, preferredSpace))
        {
            HStack(spacing: 0) {
                HStack(spacing: geometry.spacing) {
                    ForEach(Array(left.filter { $0 != space }.enumerated()), id: \.offset) { position, index in
                        keyView(index: index, keyValue: keys[index])
                            .frame(width: CGFloat(leftWidths[position]), height: keyHeight)
                    }
                    keyView(index: space, keyValue: keys[space])
                        .id("authored-footer-left-space")
                        .frame(width: CGFloat(geometry.leftSpaceWidth), height: keyHeight)
                }
                .frame(width: CGFloat(geometry.leftWidth))
                KeyboardSplitGap().frame(width: CGFloat(geometry.gap + geometry.spacing), height: keyHeight)
                HStack(spacing: geometry.spacing) {
                    keyView(index: space, keyValue: keys[space])
                        .id("authored-footer-right-space")
                        .frame(width: CGFloat(geometry.rightSpaceWidth), height: keyHeight)
                    ForEach(Array(right.filter { $0 != space }.enumerated()), id: \.offset) { position, index in
                        keyView(index: index, keyValue: keys[index])
                            .frame(width: CGFloat(rightWidths[position]), height: keyHeight)
                    }
                }
                .frame(width: CGFloat(geometry.rightWidth))
            }
        } else {
            scrollableDualSpaceRow(
                split: split, left: left, right: right, space: space, widths: footer.keyWidths)
        }
    }

    @ViewBuilder private func scrollableDualSpaceRow(
        split: LayoutSplitConfiguration, left: [Int], right: [Int], space: Int, widths: [Double]
    ) -> some View {
        let spacing = CGFloat(KeyboardAuthoredPageMetrics.spacing)
        let gap = max(CGFloat(split.gap(width: Double(rootWidth), keyCount: keys.count + 1)), spacing)
        let spaceWidth = CGFloat(max(minimumWidth, widths[space]))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(Array(left.filter { $0 != space }.enumerated()), id: \.offset) { _, index in
                    keyView(index: index, keyValue: keys[index])
                        .frame(width: CGFloat(max(minimumWidth, widths[index])), height: keyHeight)
                }
                keyView(index: space, keyValue: keys[space])
                    .id("authored-footer-left-space")
                    .frame(width: spaceWidth, height: keyHeight)
                KeyboardSplitGap().frame(width: max(0, gap - spacing), height: keyHeight)
                keyView(index: space, keyValue: keys[space])
                    .id("authored-footer-right-space")
                    .frame(width: spaceWidth, height: keyHeight)
                ForEach(Array(right.filter { $0 != space }.enumerated()), id: \.offset) { _, index in
                    keyView(index: index, keyValue: keys[index])
                        .frame(width: CGFloat(max(minimumWidth, widths[index])), height: keyHeight)
                }
            }
        }
        .sharpCandidateScrollEdges()
    }

    /// The author declared no space or several: render exactly that data, only adding the split gutter.
    @ViewBuilder private func authoredSpaceRow(
        width: Double, split: LayoutSplitConfiguration, left: [Int], right: [Int]
    ) -> some View {
        let gap = split.gap(width: Double(rootWidth), keyCount: keys.count)
        let footer = footerGeometry(max(0, width - gap))
        let spacing = CGFloat(footer.spacing)
        let floored = minimumScrollWidths(footer)
        let keyWidths = floored ?? footer.keyWidths
        let content = HStack(spacing: spacing) {
            ForEach(Array(left.enumerated()), id: \.offset) { _, index in
                keyView(index: index, keyValue: keys[index])
                    .frame(width: CGFloat(max(0, keyWidths[index])), height: keyHeight)
            }
            if gap > 0 {
                KeyboardSplitGap().frame(width: max(0, CGFloat(gap) - spacing), height: keyHeight)
            }
            ForEach(Array(right.enumerated()), id: \.offset) { _, index in
                keyView(index: index, keyValue: keys[index])
                    .frame(width: CGFloat(max(0, keyWidths[index])), height: keyHeight)
            }
        }
        if floored != nil {
            ScrollView(.horizontal, showsIndicators: false) { content }
                .sharpCandidateScrollEdges()
        } else {
            content
        }
    }

    private func keyView(index: Int, keyValue: LayoutKey) -> KeyboardAuthoredPageKey {
        let path = KeyboardPageKeyPath.chrome(.bottom, key: sourceIndices[index])
        return KeyboardAuthoredPageKey(
            key: keyValue, path: path, state: state, actions: actions, actionTable: actionTable,
            selected: selectedPath == path, editorSelection: editorSelection)
    }
}

/// The one authored page shell: optional leading column (authored rail or category navigation), the
/// page area, the authored trailing rail and the authored footer. Empty regions stay empty: nothing
/// is ever inserted for a deleted Shift, Delete, footer or space.
struct KeyboardAuthoredPageView<CategoryMain: View, CategoryLeading: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let page: KeyboardPageDefinition
    /// The stored split (or inherited one). Activation is resolved against the real key-area width.
    let split: LayoutSplitConfiguration?
    let state: KeyboardPageAuthoredState
    let actions: KeyboardPageAuthoredActions
    var selectedPath: KeyboardPageKeyPath? = nil
    /// Editor preview: every key is selectable, including a control the live state would disable.
    var editorSelection = false
    /// The expanded candidate list takes the main area in place, exactly as the built-in pages do.
    var expandedCandidates: AnyView? = nil
    @ViewBuilder var categoryMain: (KeyboardAuthoredPageMetrics) -> CategoryMain
    @ViewBuilder var categoryLeading: (KeyboardAuthoredPageMetrics) -> CategoryLeading

    private var spacing: CGFloat { CGFloat(KeyboardAuthoredPageMetrics.spacing) }
    /// A categorised page keeps its browser rows as backup data, so this is decided by the
    /// presentation, never by rows.isEmpty.
    private var isCategoryPage: Bool { page.symbolPresentation == .categorized }

    /// The authored data minus keys the system cannot use. With no input-mode switch the globe key
    /// is removed and the remaining keys take its width; it is never left as a dead key.
    private var renderedPage: KeyboardPageDefinition {
        guard !state.hasGlobe, let chrome = page.chrome else { return page }
        var copy = page
        copy.rows = page.rows.map { LayoutRow(keys: $0.keys.filter { $0.action.type != .globe }) }
        var rendered = chrome
        rendered.bottom = chrome.bottom.filter { $0.action.type != .globe }
        rendered.leading = chrome.leading.filter { $0.action.type != .globe }
        rendered.trailing = chrome.trailing.filter { $0.action.type != .globe }
        copy.chrome = rendered
        return copy
    }

    /// Visible index -> authored index. Routing always uses the authored address.
    private func visibleSourceIndices(_ keys: [LayoutKey]) -> [Int] {
        guard !state.hasGlobe else { return Array(keys.indices) }
        return keys.indices.filter { keys[$0].action.type != .globe }
    }

    private var rowSourceIndices: [[Int]] { page.rows.map { visibleSourceIndices($0.keys) } }
    private var leadingSourceIndices: [Int] { visibleSourceIndices(page.chrome?.leading ?? []) }
    private var trailingSourceIndices: [Int] { visibleSourceIndices(page.chrome?.trailing ?? []) }
    private var bottomSourceIndices: [Int] { visibleSourceIndices(page.chrome?.bottom ?? []) }

    private var renderedChrome: KeyboardPageChrome? { renderedPage.chrome }
    /// The fixed viewport: the phone/built-in pages budget three rows, and an authored page with
    /// more rows scrolls inside that same viewport instead of growing past the keyboard.
    private var rowsViewportCount: Int {
        isCategoryPage ? 3 : min(3, max(0, renderedPage.rows.count))
    }
    private var rowCount: Int { isCategoryPage ? 3 : max(0, renderedPage.rows.count) }
    private var hasLeadingRegion: Bool {
        isCategoryPage || !(renderedChrome?.leading.isEmpty ?? true)
    }
    private var hasTrailingRegion: Bool { !(renderedChrome?.trailing.isEmpty ?? true) }
    private var hasBottomRegion: Bool { !(renderedChrome?.bottom.isEmpty ?? true) }

    var body: some View {
        GeometryReader { proxy in
            let rootWidth = Double(proxy.size.width)
            // The whole keyboard width decides the split, and a centred phone shell keeps its
            // built-in unit width; an active split expands it across the surface like the 9-key shell.
            let effectiveSplit = split?.resolvedForRender(rootWidth: rootWidth)
            let layoutWidth = contentLayoutWidth(rootWidth: rootWidth, split: effectiveSplit)
            let metrics = KeyboardAuthoredPageMetrics(
                rootWidth: layoutWidth, keyHeight: Double(keyHeight), rowCount: rowsViewportCount,
                hasLeading: hasLeadingRegion, hasTrailing: hasTrailingRegion, hasBottom: hasBottomRegion,
                hasTrailingSpansBottom: renderedChrome?.trailingSpansBottom == true,
                leadingWidth: renderedChrome?.leadingWidth, trailingWidth: renderedChrome?.trailingWidth)
            let actionTable = KeyboardPageAuthoredActionTable(page: page)
            Group {
                if metrics.trailingRailHeight > metrics.rowsHeight {
                    spansBottomLayout(metrics: metrics, split: effectiveSplit, actionTable: actionTable)
                } else {
                    containedLayout(metrics: metrics, split: effectiveSplit, actionTable: actionTable)
                }
            }
            .frame(width: CGFloat(metrics.rootWidth), height: CGFloat(metrics.totalHeight), alignment: .topLeading)
            .frame(width: proxy.size.width, alignment: .center)
        }
        .frame(height: estimatedHeight)
    }

    /// A keypad/category page keeps the built-in phone shell's 436pt unit and centres it on a wide
    /// surface; normally a row page simply fills the width. An active split expands the unit.
    private func contentLayoutWidth(rootWidth: Double, split: LayoutSplitConfiguration?) -> Double {
        guard split == nil, page.isKeypad || isCategoryPage, rootWidth > PhoneKeypadMetrics.maximumShellWidth
        else { return rootWidth }
        return PhoneKeypadMetrics.maximumShellWidth
    }

    /// Height before the real width is known: the panel and the preview reserve it up front.
    private var estimatedHeight: CGFloat {
        let rows = CGFloat(rowsViewportCount) * (keyHeight + spacing) - spacing
        return rows + (hasBottomRegion ? spacing + keyHeight : 0)
    }

    @ViewBuilder private func spansBottomLayout(
        metrics: KeyboardAuthoredPageMetrics, split: LayoutSplitConfiguration?,
        actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        HStack(alignment: .top, spacing: spacing) {
            VStack(spacing: metrics.bottomHeight > 0 ? spacing : 0) {
                HStack(alignment: .top, spacing: spacing) {
                    leadingColumn(metrics: metrics, actionTable: actionTable)
                    mainArea(metrics: metrics, split: split, actionTable: actionTable)
                }
                .frame(height: CGFloat(metrics.rowsHeight))
                if metrics.bottomHeight > 0 {
                    footer(metrics: metrics, split: split, actionTable: actionTable)
                }
            }
            trailingRail(metrics: metrics, actionTable: actionTable)
        }
    }

    @ViewBuilder private func containedLayout(
        metrics: KeyboardAuthoredPageMetrics, split: LayoutSplitConfiguration?,
        actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        VStack(spacing: metrics.bottomHeight > 0 ? spacing : 0) {
            HStack(alignment: .top, spacing: spacing) {
                leadingColumn(metrics: metrics, actionTable: actionTable)
                mainArea(metrics: metrics, split: split, actionTable: actionTable)
                trailingRail(metrics: metrics, actionTable: actionTable)
            }
            .frame(height: CGFloat(metrics.rowsHeight))
            if metrics.bottomHeight > 0 {
                footer(metrics: metrics, split: split, actionTable: actionTable)
            }
        }
    }

    @ViewBuilder private func footer(
        metrics: KeyboardAuthoredPageMetrics, split: LayoutSplitConfiguration?,
        actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        KeyboardAuthoredPageFooter(
            page: page, keys: renderedChrome?.bottom ?? [], sourceIndices: bottomSourceIndices,
            split: split, rootWidth: CGFloat(metrics.rootWidth), state: state, actions: actions,
            actionTable: actionTable, selectedPath: selectedPath, editorSelection: editorSelection
        )
        .frame(width: CGFloat(metrics.bottomWidth), height: CGFloat(metrics.bottomHeight))
    }

    @ViewBuilder private func leadingColumn(
        metrics: KeyboardAuthoredPageMetrics, actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        if metrics.leadingWidth > 0 {
            Group {
                if isCategoryPage {
                    categoryLeading(metrics)
                } else {
                    KeyboardAuthoredPageRail(
                        keys: renderedChrome?.leading ?? [], sourceIndices: leadingSourceIndices,
                        region: .leading, height: CGFloat(metrics.leadingRailHeight), state: state,
                        actions: actions, actionTable: actionTable, selectedPath: selectedPath,
                        editorSelection: editorSelection)
                }
            }
            .frame(width: CGFloat(metrics.leadingWidth), height: CGFloat(metrics.leadingRailHeight), alignment: .top)
        }
    }

    @ViewBuilder private func trailingRail(
        metrics: KeyboardAuthoredPageMetrics, actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        if metrics.trailingWidth > 0 {
            KeyboardAuthoredPageRail(
                keys: renderedChrome?.trailing ?? [], sourceIndices: trailingSourceIndices,
                region: .trailing, height: CGFloat(metrics.trailingRailHeight), state: state,
                actions: actions, actionTable: actionTable, selectedPath: selectedPath,
                editorSelection: editorSelection
            )
            .frame(width: CGFloat(metrics.trailingWidth), height: CGFloat(metrics.trailingRailHeight), alignment: .top)
        }
    }

    @ViewBuilder private func mainArea(
        metrics: KeyboardAuthoredPageMetrics, split: LayoutSplitConfiguration?,
        actionTable: KeyboardPageAuthoredActionTable
    ) -> some View {
        if let expandedCandidates {
            expandedCandidates
                .frame(width: CGFloat(metrics.mainWidth), height: CGFloat(metrics.rowsHeight), alignment: .top)
        } else if isCategoryPage {
            categoryMain(metrics)
                .frame(width: CGFloat(metrics.mainWidth), height: CGFloat(metrics.rowsHeight), alignment: .top)
        } else {
            let rows = KeyboardAuthoredPageRows(
                page: renderedPage, split: split, metrics: metrics, sourceIndices: rowSourceIndices,
                state: state, actions: actions, actionTable: actionTable, selectedPath: selectedPath,
                editorSelection: editorSelection)
            Group {
                if renderedPage.rows.count > rowsViewportCount {
                    // More authored rows than the fixed three-row viewport: only the rows scroll,
                    // the rails and the footer keep their place.
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .sharpCandidateScrollEdges()
                } else {
                    rows
                }
            }
            .frame(width: CGFloat(metrics.mainWidth), height: CGFloat(metrics.rowsHeight), alignment: .top)
            .clipped()
        }
    }
}

/// Category navigation is metadata, never authored chrome. This one view backs the built-in phone
/// symbol page, a copied categorised page's authored shell and the preview, so the rail never drifts.
struct KeyboardAuthoredCategoryRail: View {
    @Environment(\.keyboardAppearance) private var appearance
    let categories: [SymbolPageTable.PhoneSymbolCategory]
    let open: String
    let mainHeight: CGFloat
    let spacing: CGFloat
    let onSelect: (String) -> Void

    var body: some View {
        let slot = (mainHeight - spacing * 3) / 3.5
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: spacing) {
                    ForEach(categories, id: \.id) { category in
                        let selected = category.id == open
                        Button {
                            onSelect(category.id)
                        } label: {
                            Text(category.title)
                                .font(appearance.font(KeyboardToolsStyle.categoryRailTitleSize))
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .foregroundStyle(
                                    selected
                                        ? appearance.accentForeground
                                        : Color(uiColor: appearance.text(on: "control"))
                                )
                                .frame(maxWidth: .infinity)
                                .frame(height: slot)
                                .background {
                                    if selected {
                                        RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                                            .fill(appearance.color("key"))
                                            .padding(.horizontal, appearance.skin.spacing.visualInsetX + 2)
                                            .padding(.vertical, appearance.skin.spacing.visualInsetY + 2)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(KeyboardPressStyle())
                        .accessibilityLabel("\(category.title)符号")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(category.id)
                    }
                }
            }
            // A tab chosen at the cut-off edge scrolls fully into view; a tab already visible stays put.
            .onChange(of: open) { _, id in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .sharpCandidateScrollEdges()
        .background {
            RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                .fill(appearance.color("control"))
                .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                .padding(.vertical, appearance.skin.spacing.visualInsetY)
        }
    }
}
