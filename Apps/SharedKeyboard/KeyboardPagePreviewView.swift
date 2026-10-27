import CandidateKit
import KeyboardCore
import LayoutKit
import QuickContentKit
import SkinKit
import SwiftUI
import UIKit

// MARK: - Preview support

/// Keyboard settings a preview mirrors. Read off the main thread; the last read seeds the next
/// preview so it does not start from defaults.
///
/// Globe keys: a preview draws them when it is an editor, so they can be selected, or when the
/// keyboard last reported that the system needs its own switch key (unknown counts as needed).
/// Main-layout and page previews both follow this rule.
struct KeyboardPreviewPreferences: Equatable, Sendable {
    var heightPreset = KeyboardHeightPreset.standard
    var prefersCategorySymbolPage = false
    var needsInputModeSwitchKey = true
    var docks: [KeyboardLayoutKind: KeyboardContentDock] = [:]

    @MainActor static var cached = KeyboardPreviewPreferences()

    func keyHeight(compact: Bool) -> CGFloat { CGFloat(heightPreset.keyHeight(compact: compact)) }

    func dock(for layout: KeyboardLayoutKind?) -> KeyboardContentDock {
        layout.flatMap { docks[$0] } ?? .center
    }

    func showsGlobe(editing: Bool) -> Bool { editing || needsInputModeSwitchKey }

    @MainActor static func load() async -> Self {
        let value = await Task.detached(priority: .userInitiated) { read() }.value
        cached = value
        return value
    }

    private static func read() -> Self {
        var docks: [KeyboardLayoutKind: KeyboardContentDock] = [:]
        for layout in KeyboardLayoutKind.allCases { docks[layout] = KeyboardContentDockPreferences.dock(for: layout) }
        return Self(
            heightPreset: KeyboardHeightPreferences.current,
            prefersCategorySymbolPage: KeyboardSymbolPagePreferences.usesCategoryPage,
            needsInputModeSwitchKey: KeyboardSystemRequirements.requiresKeyboardSwitchEntry(),
            docks: docks)
    }
}

/// The widths the keyboard settles its split decisions on, derived from the preview's frame.
struct KeyboardPreviewWidths: Equatable {
    /// The key area width (after the surface's 4pt side padding).
    let content: Double
    /// The width the main layout's split activation is decided on.
    let mainSplit: Double
}

/// Applies the keyboard's own width rules to the preview's frame: a wide surface caps and docks
/// the content like the keyboard, and split decisions read the same widths. Content stays hidden
/// until the real width is known, so a split preview never draws unsplit first.
struct KeyboardPreviewFrame<Content: View>: View {
    let layout: KeyboardLayoutKind?
    let mainSplit: LayoutSplitConfiguration?
    let dock: KeyboardContentDock
    @ViewBuilder var content: (KeyboardPreviewWidths) -> Content
    @State private var width: CGFloat = 0

    var body: some View {
        let raw = Double(width)
        let plan = KeyboardWideContentPolicy.plan(
            panelWidth: raw,
            maximumContentWidth: KeyboardPanelRules.wideMaximumContentWidth(
                rawWidth: raw, mainSplit: mainSplit, layout: layout),
            dock: dock)
        let contentWidth = plan.active ? plan.contentWidth : raw
        content(KeyboardPreviewWidths(content: max(0, contentWidth - 8), mainSplit: max(0, raw - 8)))
            .frame(width: CGFloat(contentWidth))
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(width > 0 ? 1 : 0)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { width = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
                }
            }
    }

    private var alignment: Alignment {
        switch dock {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }
}

/// The panel's language key without the published-keyboard menu a preview has no session for.
struct KeyboardPreviewModeKey: View {
    let policy: KeyboardControlPolicy

    var body: some View {
        AlternateCharacterKey(
            cap: KeyCap(id: "input-mode", title: policy.languageTitle(for: nil), action: .cycleLayout),
            alternates: [], layoutPicker: true
        ) { _ in }
        .accessibilityLabel(policy.languageAccessibilityLabel(for: nil))
    }
}

/// The panel's control row with inert actions.
struct KeyboardPreviewControlRow: View {
    let policy: KeyboardControlPolicy
    var returnTitle = "换行"
    let showsGlobe: Bool
    var columns: KeyboardControlPolicy.PhoneColumns? = nil
    let split: ActiveLayoutSplit?
    let splitRowIndex: Int

    var body: some View {
        ControlRow(
            policy: policy, returnTitle: returnTitle, layoutName: nil, layoutHintName: nil,
            layoutHintToken: nil, modeKey: KeyboardPreviewModeKey(policy: policy),
            systemKeyboardSwitch: showsGlobe ? { _, _ in } : nil, moveCursor: nil,
            onPage: { _ in }, onKey: { _ in }, phoneColumns: columns, split: split,
            splitRowIndex: splitRowIndex)
    }
}

extension KeyboardFixedEditingRail {
    /// The idle editing rail of a preview.
    init(previewMetrics metrics: PhoneKeypadMetrics, returnTitle: String = "换行", isComposing: Bool = false) {
        self.init(
            metrics: metrics, returnTitle: returnTitle, isReturnEnabled: true, isComposing: isComposing,
            onDelete: { _ in }, onReset: {}, onReturn: { _ in })
    }
}

// MARK: - Page preview

/// Draws a page the way the keyboard resolves and draws it, through the same views and rules.
/// A preview has no session: it shows the idle Chinese state, with an explicit page default
/// deciding the symbol branch.
public struct KeyboardPagePreviewView: View {
    public let page: KeyboardPageDefinition
    public var inheritedSplit: LayoutSplitConfiguration?
    /// The running main layout is a phone keypad: an automatic page then shows its digit pad
    /// instead of the ten-column row page, exactly as the key area does.
    public var isPhoneLayout: Bool
    /// The running main layout, for the wide-surface width cap. Nil falls back to the phone
    /// keypad cap when `isPhoneLayout` is set.
    public var mainLayout: KeyboardLayoutKind?
    public var skin: SkinDefinition
    public var previewDark: Bool?
    private let onSelectKey: ((KeyboardPageKeyPath) -> Void)?
    private let onSelectCategoryKey: ((String, Int) -> Void)?
    private let selectedCategoryKey: (String, Int)?
    private let selectedPageKey: KeyboardPageKeyPath?
    @StateObject private var symbolLibrary = SymbolLibraryModel(onInsert: { _ in false }, loadsImmediately: false)
    @State private var openCategoryID: String?
    @State private var preferences = KeyboardPreviewPreferences.cached
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(
        page: KeyboardPageDefinition, inheritedSplit: LayoutSplitConfiguration? = nil,
        isPhoneLayout: Bool = false, mainLayout: KeyboardLayoutKind? = nil,
        skin: SkinDefinition = .systemDefault, previewDark: Bool? = nil,
        onSelectKey: ((KeyboardPageKeyPath) -> Void)? = nil,
        onSelectCategoryKey: ((String, Int) -> Void)? = nil, selectedCategoryKey: (String, Int)? = nil,
        selectedPageKey: KeyboardPageKeyPath? = nil
    ) {
        self.page = page
        self.inheritedSplit = inheritedSplit
        self.isPhoneLayout = isPhoneLayout
        self.mainLayout = mainLayout
        self.skin = skin
        self.previewDark = previewDark
        self.onSelectKey = onSelectKey
        self.onSelectCategoryKey = onSelectCategoryKey
        self.selectedCategoryKey = selectedCategoryKey
        self.selectedPageKey = selectedPageKey
    }

    private var editing: Bool { onSelectKey != nil || onSelectCategoryKey != nil }
    private var showsGlobe: Bool { preferences.showsGlobe(editing: editing) }

    /// An explicit page default wins, otherwise an English page shows the English branch and
    /// numeric/symbol pages show Chinese. The same value feeds resolution, faces and the footer.
    private var usesASCIIPunctuation: Bool {
        (page.defaultSymbolMarks ?? (page.kind == .english ? .ascii : .chinese)) == .ascii
    }

    private var resolution: KeyboardPageResolution {
        KeyboardPageResolver.resolve(
            page: page, kind: page.kind,
            input: .init(usesASCIIPunctuation: usesASCIIPunctuation, mainLayoutIsPhoneKeypad: isPhoneLayout))
    }

    public var body: some View {
        let resolution = resolution
        let appearance = KeyboardAppearance(skin: skin, dark: previewDark ?? (colorScheme == .dark))
        let layout = mainLayout ?? (isPhoneLayout ? .phone9 : nil)
        KeyboardPreviewFrame(layout: layout, mainSplit: inheritedSplit, dock: preferences.dock(for: layout)) {
            widths in
            content(resolution, widths: widths)
                .padding(4)
                .background(appearance.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .environment(\.keyboardAppearance, appearance)
        .environment(\.keyboardKeyHeight, preferences.keyHeight(compact: verticalSizeClass == .compact))
        .task { preferences = await KeyboardPreviewPreferences.load() }
        // Category pages read recents and the library's sets.
        .task(id: showsCategories(resolution)) {
            if showsCategories(resolution) { await symbolLibrary.reload().value }
        }
    }

    private func showsCategories(_ resolution: KeyboardPageResolution) -> Bool {
        switch resolution {
        case .authored(let authored): return authored.symbolPresentation == .categorized
        case .automaticSymbolPage: return isPhoneLayout || preferences.prefersCategorySymbolPage
        case .automaticNumeric, .builtIn: return false
        }
    }

    /// The resolver answers `.builtIn` only for a missing page or another kind, which a page
    /// preview never asks for; every other case is drawn like the key area draws it.
    @ViewBuilder
    private func content(_ resolution: KeyboardPageResolution, widths: KeyboardPreviewWidths) -> some View {
        if let authored = resolution.page {
            let split = pageSplit(authored.split, widths: widths)
            if authored.chrome != nil {
                authoredChromePreview(authored, split: split, widths: widths)
            } else if authored.kind == .symbols && authored.symbolPresentation == .categorized {
                categoryPad(authored, split: split, widths: widths)
            } else {
                rowsPage(authored, split: split)
            }
        } else if case .automaticNumeric(let form, let marks) = resolution {
            let split = pageSplit(nil, widths: widths)
            if form == .phoneDigitPad {
                phoneDigitPad(usesASCIIPunctuation: marks == .ascii, split: split)
            } else {
                builtInRows(
                    SymbolPageTable.numericRows(ascii: marks == .ascii), page: .numeric,
                    usesASCIIPunctuation: marks == .ascii, split: split)
            }
        } else if isPhoneLayout || preferences.prefersCategorySymbolPage {
            categoryPad(nil, split: pageSplit(nil, widths: widths), widths: widths)
        } else {
            builtInRows(
                SymbolPageTable.symbolRows(ascii: usesASCIIPunctuation), page: .symbols,
                usesASCIIPunctuation: usesASCIIPunctuation, split: pageSplit(nil, widths: widths))
        }
    }

    /// An automatic page draws no page object, so only an authored page's own split applies.
    private func pageSplit(_ split: LayoutSplitConfiguration?, widths: KeyboardPreviewWidths) -> ActiveLayoutSplit? {
        KeyboardPanelRules.activeSplit(
            main: inheritedSplit, mainWidth: widths.mainSplit, showsMainLetters: false,
            pageSplit: split, contentWidth: widths.content)
    }

    private var mainAreaHeight: CGFloat {
        let keyHeight = preferences.keyHeight(compact: verticalSizeClass == .compact)
        return 3 * (keyHeight + 4) - 4
    }

    private func panelPage(_ kind: KeyboardPageKind) -> KeyboardPage {
        switch kind {
        case .english: return .letters
        case .numeric: return .numeric
        case .symbols: return .symbols
        }
    }

    private func rowPolicy(_ page: KeyboardPage, usesASCIIPunctuation: Bool) -> KeyboardControlPolicy {
        KeyboardPanelRules.controlPolicy(
            page: page, isEnglishMode: self.page.kind == .english, hasGlobe: showsGlobe,
            usesASCIIPunctuation: usesASCIIPunctuation, phoneShellVisible: false,
            usesFixedEditingRail: false, declaredTrailingReturn: false, showsCategorySymbolPage: false)
    }

    private func state(_ page: KeyboardPageDefinition) -> KeyboardPageAuthoredState {
        KeyboardPageAuthoredState(
            page: panelPage(page.kind), kind: page.kind, isEnglishMode: page.kind == .english,
            shiftState: .off, returnTitle: "换行", isReturnEnabled: true, symbolLocked: false,
            isComposing: false, hasGlobe: showsGlobe,
            isPhoneStyled: !(page.chrome?.trailing.isEmpty ?? true),
            usesASCIIPunctuation: usesASCIIPunctuation,
            usesCategorySymbolPage: page.symbolPresentation == .categorized)
    }

    private func actions(select: @escaping (KeyboardPageKeyPath) -> Void) -> KeyboardPageAuthoredActions {
        KeyboardPageAuthoredActions(
            perform: { path, _, _ in select(path) },
            performShiftDoubleTap: { path in select(path) },
            moveCursor: nil, systemKeyboardSwitch: showsGlobe && !editing ? { _, _ in } : nil,
            spaceLayoutName: nil, spaceHintName: nil, spaceHintToken: nil)
    }

    // MARK: Authored chrome

    /// A page with authored chrome is drawn by the same shell as the live keyboard, so the editor
    /// sees exactly the geometry, rails and footer the keyboard will run.
    private func authoredChromePreview(
        _ page: KeyboardPageDefinition, split: ActiveLayoutSplit?, widths: KeyboardPreviewWidths
    ) -> some View {
        KeyboardAuthoredPageView(
            page: page, split: split, state: state(page),
            actions: actions { onSelectKey?($0) },
            selectedPath: selectedPageKey, editorSelection: editing,
            categoryMain: { _ in chromeCategoryMain(page, split: split, widths: widths) },
            categoryLeading: { metrics in chromeCategoryLeading(page, metrics: metrics) })
    }

    private func categories(_ page: KeyboardPageDefinition?) -> [SymbolPageTable.PhoneSymbolCategory] {
        // Category content follows the input language; a preview shows Chinese input.
        symbolLibrary.pageCategories(authored: page?.categories, ascii: false, showsGlobe: showsGlobe)
    }

    @ViewBuilder
    private func chromeCategoryMain(
        _ page: KeyboardPageDefinition, split: ActiveLayoutSplit?, widths: KeyboardPreviewWidths
    ) -> some View {
        let categories = categories(page)
        if let open = categories.first(where: { $0.id == openCategoryID }) ?? categories.first {
            KeyboardCategoryGrid(
                keys: open.keys, columns: open.columns,
                split: ActiveLayoutSplit.resolving(nested: open.split, parent: split, width: widths.content)
            ) { key, index in
                chromeCategoryKey(page, open: open, key: key, index: index)
            }
            .id(open.id)
        }
    }

    @ViewBuilder
    private func chromeCategoryLeading(
        _ page: KeyboardPageDefinition, metrics: KeyboardAuthoredPageMetrics
    ) -> some View {
        let categories = categories(page)
        if let open = categories.first(where: { $0.id == openCategoryID }) ?? categories.first {
            KeyboardAuthoredCategoryRail(
                categories: categories, open: open.id, mainHeight: CGFloat(metrics.rowsHeight),
                spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing),
                onSelect: { openCategoryID = $0 })
        }
    }

    /// The live page draws category content through the authored key face too; tapping one selects
    /// it in the category editor and does nothing elsewhere.
    private func chromeCategoryKey(
        _ page: KeyboardPageDefinition, open: SymbolPageTable.PhoneSymbolCategory, key: LayoutKey, index: Int
    ) -> some View {
        let path = KeyboardPageKeyPath.chrome(.bottom, key: 0)
        return KeyboardAuthoredPageKey(
            key: key, path: path, state: state(page),
            actions: actions { _ in onSelectCategoryKey?(open.id, index) },
            actionTable: KeyboardPageAuthoredActionTable(singleKey: key, path: path),
            selected: isSelectedCategoryKey(open.id, index), editorSelection: editing)
    }

    private func isSelectedCategoryKey(_ category: String, _ index: Int) -> Bool {
        selectedCategoryKey?.0 == category && selectedCategoryKey?.1 == index
    }

    // MARK: Pages without authored chrome

    /// A literal keeps the page key face (the long-press corner hint included); other actions use
    /// the authored face, which draws the same native controls.
    @ViewBuilder
    private func pageKey(
        _ key: LayoutKey, page: KeyboardPageDefinition, id: String,
        select: @escaping () -> Void
    ) -> some View {
        if key.action.type == .literal {
            AlternateCharacterKey(
                cap: KeyboardPanelRules.pageCap(
                    key, id: id, kind: page.kind, alternate: false,
                    usesASCIIPunctuation: usesASCIIPunctuation, shiftActive: false),
                alternates: (key.longPress ?? []).enumerated().map { index, option in
                    KeyboardPanelRules.pageCap(
                        LayoutKey(label: option.label, action: option.action), id: "\(id)-option-\(index)",
                        kind: page.kind, alternate: true, usesASCIIPunctuation: usesASCIIPunctuation,
                        shiftActive: false)
                },
                showsKeyPreview: true
            ) { _ in select() }
        } else {
            let path = KeyboardPageKeyPath.chrome(.bottom, key: 0)
            KeyboardAuthoredPageKey(
                key: key, path: path, state: state(page),
                actions: actions { _ in select() },
                actionTable: KeyboardPageAuthoredActionTable(singleKey: key, path: path),
                editorSelection: editing)
        }
    }

    private func rowsPage(_ page: KeyboardPageDefinition, split: ActiveLayoutSplit?) -> some View {
        let keyHeight = preferences.keyHeight(compact: verticalSizeClass == .compact)
        let overflows = CGFloat(page.rows.count) * (keyHeight + 4) - 4 > mainAreaHeight + 1
        let rows = KeyboardPageRows(
            page: page, split: split, showsGlobe: showsGlobe,
            key: { key, row, index in
                pageKey(key, page: page, id: "page-\(page.id)-\(row)-\(index)") {}
            },
            shift: { ShiftKey(state: .off, isEnglishMode: true, tap: {}, doubleTap: {}) },
            delete: { RepeatingDeleteKey {} })
        return VStack(spacing: 4) {
            Group {
                if overflows {
                    ScrollView { VStack(spacing: 4) { rows } }.sharpCandidateScrollEdges()
                } else {
                    VStack(spacing: 4) { rows }
                }
            }
            .frame(height: mainAreaHeight, alignment: .top)
            KeyboardPreviewControlRow(
                policy: rowPolicy(panelPage(page.kind), usesASCIIPunctuation: usesASCIIPunctuation),
                showsGlobe: showsGlobe, split: split, splitRowIndex: page.rows.count)
        }
    }

    // MARK: Built-in pages

    private func builtInRows(
        _ rows: [KeyboardRow], page: KeyboardPage, usesASCIIPunctuation: Bool, split: ActiveLayoutSplit?
    ) -> some View {
        VStack(spacing: 4) {
            VStack(spacing: 4) {
                KeyboardSymbolPageRows(rows: rows, split: split, onTap: { _ in }, delete: { RepeatingDeleteKey {} })
            }
            .frame(height: mainAreaHeight, alignment: .top)
            KeyboardPreviewControlRow(
                policy: rowPolicy(page, usesASCIIPunctuation: usesASCIIPunctuation),
                showsGlobe: showsGlobe, split: split, splitRowIndex: rows.count)
        }
    }

    /// A phone main layout is drawn as the bundled 9-key, whose editing rail spans the bottom row.
    private func phoneDigitPad(usesASCIIPunctuation: Bool, split: ActiveLayoutSplit?) -> some View {
        let policy = KeyboardPanelRules.controlPolicy(
            page: .numeric, isEnglishMode: false, hasGlobe: showsGlobe,
            usesASCIIPunctuation: usesASCIIPunctuation, phoneShellVisible: true, usesFixedEditingRail: true,
            declaredTrailingReturn: false, showsCategorySymbolPage: false)
        return KeyboardPhoneDigitPad(
            usesASCIIPunctuation: usesASCIIPunctuation, split: split, trailingSpansControlRow: true,
            onKey: { _ in }, expanded: { EmptyView() },
            trailing: { metrics in KeyboardFixedEditingRail(previewMetrics: metrics) },
            bottom: { metrics in
                KeyboardPreviewControlRow(
                    policy: policy, showsGlobe: showsGlobe,
                    columns: .init(rail: metrics.railWidth, digit: metrics.digitWidth), split: split,
                    splitRowIndex: PhoneKeypadMetrics.mainRowCount)
            })
    }

    @ViewBuilder
    private func categoryPad(
        _ page: KeyboardPageDefinition?, split: ActiveLayoutSplit?, widths: KeyboardPreviewWidths
    ) -> some View {
        let categories = categories(page)
        if let open = categories.first(where: { $0.id == openCategoryID }) ?? categories.first {
            let categorySplit = ActiveLayoutSplit.resolving(nested: open.split, parent: split, width: widths.content)
            // A phone main layout is drawn as the bundled 9-key; an imported keypad's own rails
            // are not known to a page preview.
            let fixedRail = KeyboardPanelRules.usesFixedEditingRail(
                showsCategorySymbolPage: true, hasAuthoredPage: page != nil,
                mainIsPhoneKeypad: isPhoneLayout, mainIsBuiltinPhonePad: isPhoneLayout)
            let policy = KeyboardPanelRules.controlPolicy(
                page: .symbols, isEnglishMode: false, hasGlobe: showsGlobe,
                usesASCIIPunctuation: usesASCIIPunctuation, phoneShellVisible: true,
                usesFixedEditingRail: fixedRail, declaredTrailingReturn: false, showsCategorySymbolPage: true)
            KeyboardCategorySymbolPad(
                categories: categories, open: open, split: categorySplit, trailingSpansControlRow: fixedRail,
                onSelectCategory: { openCategoryID = $0 },
                key: { key, index in
                    categoryKey(page, open: open, key: key, index: index)
                        .overlay {
                            if isSelectedCategoryKey(open.id, index) {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor, lineWidth: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                },
                trailing: { metrics in
                    if fixedRail { KeyboardFixedEditingRail(previewMetrics: metrics) }
                },
                bottom: { metrics in
                    KeyboardPreviewControlRow(
                        policy: policy, showsGlobe: showsGlobe,
                        columns: fixedRail ? .init(rail: metrics.railWidth, digit: metrics.digitWidth) : nil,
                        split: categorySplit?.withoutRowBreaks ?? split,
                        splitRowIndex: page?.rows.count ?? PhoneKeypadMetrics.mainRowCount)
                })
        }
    }

    @ViewBuilder
    private func categoryKey(
        _ page: KeyboardPageDefinition?, open: SymbolPageTable.PhoneSymbolCategory, key: LayoutKey, index: Int
    ) -> some View {
        let select: () -> Void = { onSelectCategoryKey?(open.id, index) }
        if let page, open.authoredKeys != nil {
            pageKey(key, page: page, id: "category-\(open.id)-\(index)", select: select)
        } else {
            AlternateCharacterKey(cap: open.caps[index], alternates: [], showsKeyPreview: true) { _ in select() }
        }
    }
}
