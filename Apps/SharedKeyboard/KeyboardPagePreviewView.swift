import CandidateKit
import KeyboardCore
import LayoutKit
import QuickContentKit
import SkinKit
import SwiftUI

/// Measures the preview's real width so a split preview uses the same whole-surface decision as
/// the running keyboard. Previews are static surfaces, so one settling pass is enough.
struct PreviewWidthProbe: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in width = newWidth }
            }
        }
    }
}

struct KeyboardCategoryGrid<Key: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let keys: [LayoutKey]
    let columns: Int
    let split: ActiveLayoutSplit?
    @ViewBuilder var key: (LayoutKey, Int) -> Key

    var body: some View {
        let rows = stride(from: 0, to: keys.count, by: columns).map { start in
            Array(start..<min(start + columns, keys.count))
        }
        let fullRows = keys.count / columns
        let referenceWeights =
            fullRows > 0
            ? keys[((fullRows - 1) * columns)..<(fullRows * columns)].map(\.widthWeight)
            : keys.map(\.widthWeight)
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row, indices in
                    GeometryReader { proxy in
                        let geometry = KeyboardCategoryRowGeometry(
                            width: Double(proxy.size.width), columns: columns,
                            weights: indices.map { keys[$0].widthWeight }, row: row, split: split,
                            referenceWeights: referenceWeights)
                        let used = geometry.usedWidth
                        HStack(spacing: 0) {
                            HStack(spacing: 4) {
                                ForEach(Array(indices.enumerated()), id: \.element) { local, source in
                                    if local == geometry.splitIndex, geometry.gap > 0 {
                                        KeyboardSplitGap().frame(width: geometry.gap - 4, height: keyHeight)
                                    }
                                    key(keys[source], source)
                                        .frame(
                                            width: geometry.keyWidths[local],
                                            height: keyHeight)
                                }
                            }.frame(width: used)
                            if Double(proxy.size.width) > used {
                                KeyboardSplitGap().frame(width: Double(proxy.size.width) - used, height: keyHeight)
                            }
                        }
                    }.frame(height: keyHeight)
                }
            }
        }.sharpCandidateScrollEdges()
    }
}

public struct KeyboardPagePreviewView: View {
    public let page: KeyboardPageDefinition
    public var inheritedSplit: LayoutSplitConfiguration?
    /// The running main layout is a phone keypad: an automatic page then shows its digit pad
    /// instead of the ten-column row page, exactly as the key area does.
    public var isPhoneLayout: Bool
    private let onSelectKey: ((KeyboardPageKeyPath) -> Void)?
    private let onSelectCategoryKey: ((String, Int) -> Void)?
    private let selectedCategoryKey: (String, Int)?
    private let selectedPageKey: KeyboardPageKeyPath?
    @StateObject private var symbolLibrary = SymbolLibraryModel(onInsert: { _ in false }, loadsImmediately: false)
    @State private var openCategoryID: String?
    @State private var previewWidth: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var keyHeight: CGFloat { verticalSizeClass == .compact ? 44 : 54 }

    public init(
        page: KeyboardPageDefinition, inheritedSplit: LayoutSplitConfiguration? = nil,
        isPhoneLayout: Bool = false, onSelectKey: ((KeyboardPageKeyPath) -> Void)? = nil,
        onSelectCategoryKey: ((String, Int) -> Void)? = nil, selectedCategoryKey: (String, Int)? = nil,
        selectedPageKey: KeyboardPageKeyPath? = nil
    ) {
        self.page = page
        self.inheritedSplit = inheritedSplit
        self.isPhoneLayout = isPhoneLayout
        self.onSelectKey = onSelectKey
        self.onSelectCategoryKey = onSelectCategoryKey
        self.selectedCategoryKey = selectedCategoryKey
        self.selectedPageKey = selectedPageKey
    }

    /// A preview has no session: an explicit page default wins, otherwise an English page shows
    /// the English branch and numeric/symbol pages show Chinese. The same value feeds resolution,
    /// authored state, categories and the footer caption.
    private var previewSymbolMarks: KeyboardNumericMarks {
        page.defaultSymbolMarks ?? (page.kind == .english ? .ascii : .chinese)
    }

    private var previewUsesASCIIPunctuation: Bool { previewSymbolMarks == .ascii }

    public var body: some View {
        // The whole preview surface decides the split once; rows inside never re-apply the
        // automatic width threshold after a rail narrowed them. A nested full preview gets the
        // stored setting and resolves it against the same surface.
        let pageSplit = LayoutSplitConfiguration.resolving(page: page.split, main: inheritedSplit)
        let split = pageSplit?.resolved(forWidth: Double(previewWidth))
        let resolution = KeyboardPageResolver.resolve(
            page: page, kind: page.kind,
            // A preview has no live session: it shows the page's own initial branch (Chinese when
            // nil). The editor picker writes the same field, so opening the copy shows the branch
            // the runtime will start from.
            input: .init(
                usesASCIIPunctuation: previewUsesASCIIPunctuation,
                mainLayoutIsPhoneKeypad: isPhoneLayout))
        Group {
            switch resolution {
            case .authored(let authored):
                if authored.chrome != nil {
                    authoredChromePreview(authored, split: split)
                } else {
                    KeyboardPreviewView(
                        layout: authored.layoutDefinition.settingSplit(pageSplit),
                        pageDefinition: authored, pageUsesPhoneLayout: isPhoneLayout,
                        onSelectKey: authored.usesSymbolBrowser ? nil : legacySelection,
                        onSelectCategoryKey: onSelectCategoryKey, selectedCategoryKey: selectedCategoryKey)
                }
            case .automaticSymbolPage:
                KeyboardPreviewView(
                    layout: page.layoutDefinition.settingSplit(pageSplit),
                    pageDefinition: page, pageUsesPhoneLayout: isPhoneLayout,
                    onSelectCategoryKey: onSelectCategoryKey, selectedCategoryKey: selectedCategoryKey)
            case .automaticNumeric(let form, let marks):
                automaticNumericPreview(form: form, marks: marks, pageSplit: pageSplit)
            case .builtIn:
                EmptyView()
            }
        }
        .modifier(PreviewWidthProbe(width: $previewWidth))
    }

    // MARK: Authored page (chrome != nil)

    /// A page with authored chrome is drawn by the same shell as the live keyboard, so the editor
    /// sees exactly the geometry, rails and footer the keyboard will run.
    private func authoredChromePreview(_ page: KeyboardPageDefinition, split: ActiveLayoutSplit?)
        -> some View
    {
        KeyboardAuthoredPageView(
            page: page, split: split, state: previewChromeState(page), actions: previewChromeActions(),
            selectedPath: selectedPageKey,
            editorSelection: onSelectKey != nil || onSelectCategoryKey != nil,
            categoryMain: { metrics in previewCategoryMain(page, metrics: metrics) },
            categoryLeading: { metrics in previewCategoryLeading(page, metrics: metrics) }
        )
        .environment(\.keyboardKeyHeight, keyHeight)
        .padding(4)
        .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
        .task {
            if page.rows.isEmpty && page.categories == nil { await symbolLibrary.reload().value }
        }
    }

    /// The preview has no session, so it shows the idle state: Chinese columns with the Latin space
    /// label, Return reading 换行 and every control enabled.
    private func previewChromeState(_ page: KeyboardPageDefinition) -> KeyboardPageAuthoredState {
        KeyboardPageAuthoredState(
            page: page.kind == .english ? .letters : (page.kind == .numeric ? .numeric : .symbols),
            kind: page.kind, isEnglishMode: page.kind == .english, shiftState: .off,
            returnTitle: "换行", isReturnEnabled: true, symbolLocked: false, isComposing: false,
            hasGlobe: true, isPhoneStyled: !(page.chrome?.trailing.isEmpty ?? true),
            usesASCIIPunctuation: previewUsesASCIIPunctuation,
            usesCategorySymbolPage: page.symbolPresentation == .categorized)
    }

    private func previewChromeActions() -> KeyboardPageAuthoredActions {
        let select = { (path: KeyboardPageKeyPath) in _ = onSelectKey?(path) }
        return KeyboardPageAuthoredActions(
            perform: { path, _, _ in select(path) },
            performShiftDoubleTap: { path in select(path) },
            moveCursor: nil, systemKeyboardSwitch: nil, spaceLayoutName: nil, spaceHintName: nil,
            spaceHintToken: nil)
    }

    /// Legacy pages (chrome == nil) keep the old row selection path; the editor materialises a page
    /// before editing, so only read-only previews reach here with row callbacks nil.
    private var legacySelection: ((LayoutKeyPath) -> Void)? {
        guard let onSelectKey else { return nil }
        return { path in
            if case .row(let row, let key) = path { onSelectKey(.row(row, key: key)) }
        }
    }

    private func previewCategories(_ page: KeyboardPageDefinition) -> [SymbolPageTable.PhoneSymbolCategory] {
        if let categories = page.categories {
            return SymbolPageTable.authoredCategories(categories, recents: symbolLibrary.recents.map(\.text))
        }
        let catalog = symbolLibrary.catalog
        return SymbolPageTable.phoneSymbolCategories(
            ascii: previewUsesASCIIPunctuation, recents: symbolLibrary.recents.map(\.text),
            library: catalog.orderedCategories.map {
                .init(id: $0.id, title: $0.name, symbols: catalog.items(in: $0.id).map(\.text))
            })
    }

    @ViewBuilder
    private func previewCategoryMain(
        _ page: KeyboardPageDefinition, metrics: KeyboardAuthoredPageMetrics
    ) -> some View {
        let categories = previewCategories(page)
        if let open = categories.first(where: { $0.id == openCategoryID }) ?? categories.first {
            // Same order as the runtime: category split overrides the page's split, which
            // overrides the main layout's; activation is settled on the whole preview width once.
            let pageSplit = LayoutSplitConfiguration.resolving(page: page.split, main: inheritedSplit)
            let active =
                LayoutSplitConfiguration
                .resolving(page: open.split, main: pageSplit)?
                .resolved(forWidth: Double(previewWidth))
            KeyboardCategoryGrid(keys: open.keys, columns: open.columns, split: active) { key, index in
                previewCategoryKey(page: page, open: open, key: key, index: index)
            }
            .id(open.id)
        }
    }

    @ViewBuilder
    private func previewCategoryLeading(
        _ page: KeyboardPageDefinition, metrics: KeyboardAuthoredPageMetrics
    ) -> some View {
        let categories = previewCategories(page)
        if let open = categories.first(where: { $0.id == openCategoryID }) ?? categories.first {
            KeyboardAuthoredCategoryRail(
                categories: categories, open: open.id, mainHeight: CGFloat(metrics.rowsHeight),
                spacing: CGFloat(KeyboardAuthoredPageMetrics.spacing),
                onSelect: { openCategoryID = $0 })
        }
    }

    /// A category's authored content key uses the same faces and titleMode semantics as the live
    /// keyboard; the editor keeps its own selection callback for category content.
    private func previewCategoryKey(
        page: KeyboardPageDefinition, open: SymbolPageTable.PhoneSymbolCategory, key: LayoutKey, index: Int
    ) -> some View {
        // Category content keys are edited through the category editor's own callback. The page
        // editor's top preview does not pass it, so tapping one there selects nothing.
        let path = KeyboardPageKeyPath.chrome(.bottom, key: 0)
        let select = { (categoryID: String, item: Int, pagePath: KeyboardPageKeyPath) in
            if let onSelectCategoryKey {
                onSelectCategoryKey(categoryID, item)
            }
        }
        return KeyboardAuthoredPageKey(
            key: key, path: path, state: previewChromeState(page),
            actions: KeyboardPageAuthoredActions(
                perform: { pagePath, _, _ in select(open.id, index, pagePath) },
                performShiftDoubleTap: { pagePath in select(open.id, index, pagePath) },
                moveCursor: nil, systemKeyboardSwitch: nil, spaceLayoutName: nil,
                spaceHintName: nil, spaceHintToken: nil),
            actionTable: KeyboardPageAuthoredActionTable(singleKey: key, path: path),
            selected: selectedCategoryKey?.0 == open.id && selectedCategoryKey?.1 == index,
            editorSelection: onSelectCategoryKey != nil || onSelectKey != nil)
    }

    @ViewBuilder
    private func automaticNumericPreview(
        form: KeyboardNumericForm, marks: KeyboardNumericMarks, pageSplit: LayoutSplitConfiguration?
    ) -> some View {
        switch form {
        case .rows:
            automaticNumericRowsPreview(marks: marks, pageSplit: pageSplit)
        case .phoneDigitPad:
            KeyboardPhoneNumericPagePreview(marks: marks, split: pageSplit?.resolved(forWidth: Double(previewWidth)))
        }
    }

    /// The ten-column form a non-keypad layout shows; the preview shows the Chinese marks (the
    /// running keyboard switches to the ASCII marks for English and ASCII fields).
    private func automaticNumericRowsPreview(
        marks: KeyboardNumericMarks, pageSplit: LayoutSplitConfiguration?
    ) -> some View {
        let resolved = marks == .ascii ? KeyboardPagePresets.numericEnglish : KeyboardPagePresets.numericChinese
        return KeyboardPreviewView(layout: resolved.layoutDefinition.settingSplit(pageSplit), pageDefinition: resolved)
    }
}

/// The phone keypad's 123 page: the digit grid, the punctuation rail, the editing rail and the
/// bottom row that carries 0. An automatic 123 page shows this form on a phone main layout.
struct KeyboardPhoneNumericPagePreview: View {
    let marks: KeyboardNumericMarks
    let split: ActiveLayoutSplit?

    private var ascii: Bool { marks == .ascii }
    private var digitRows: [[KeyCap]] {
        let digits = SymbolPageTable.numericRows(ascii: ascii).first?.caps ?? []
        return (0..<3).map { row in Array(digits.dropFirst(row * 3).prefix(3)) }
    }
    private var railCaps: [KeyCap] { SymbolPageTable.phoneNumericRail(ascii: ascii) }

    var body: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: true,
            expandsForSplit: split != nil,
            leading: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    ForEach(Array(railCaps.prefix(3).enumerated()), id: \.element.id) { _, cap in
                        AlternateCharacterKey(
                            cap: cap, alternates: [], phoneKey: true, phoneSideKey: true,
                            titleSize: 19
                        ) { _ in }
                        .frame(height: CGFloat(metrics.rowHeight))
                    }
                }
            },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    ForEach(Array(digitRows.enumerated()), id: \.offset) { index, caps in
                        WeightedKeyRow(caps: caps, split: split, rowIndex: index) { _ in }
                            .frame(height: CGFloat(metrics.rowHeight))
                    }
                }
            },
            trailing: { metrics in
                let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
                VStack(spacing: CGFloat(metrics.spacing)) {
                    RepeatingDeleteKey {}
                        .frame(height: CGFloat(slots[0].height))
                    ControlKeyFace(text: "重输")
                        .opacity(0.45)
                        .frame(height: CGFloat(slots[1].height))
                    ReturnKey(title: "换行") { _ in }
                        .frame(height: CGFloat(slots[2].height))
                }
            },
            bottom: { metrics in controlRow(metrics) }
        )
        .padding(4)
        .background(Color(uiColor: .systemGray5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func controlRow(_ metrics: PhoneKeypadMetrics) -> some View {
        let policy = KeyboardControlPolicy(
            page: .numeric, isEnglishMode: ascii, hasGlobe: false, isPhoneLayout: true,
            usesASCIIPunctuation: ascii, includesBottomEnter: false)
        return ControlRow(
            policy: policy, returnTitle: "换行", layoutName: nil, layoutHintName: nil, layoutHintToken: nil,
            modeKey: AlternateCharacterKey(
                cap: KeyCap(id: "preview-digit-mode", title: policy.languageTitle, action: .cycleLayout),
                alternates: [], layoutPicker: true
            ) { _ in },
            systemKeyboardSwitch: nil, moveCursor: nil, onPage: { _ in }, onKey: { _ in },
            phoneColumns: .init(rail: metrics.railWidth, digit: metrics.digitWidth),
            split: split, splitRowIndex: PhoneKeypadMetrics.mainRowCount)
    }
}

struct KeyboardCategoryPagePreview<Key: View, Footer: View>: View {
    @Environment(\.keyboardAppearance) private var appearance
    @StateObject private var library = SymbolLibraryModel(onInsert: { _ in false }, loadsImmediately: false)
    @State private var selected: String?
    @State private var previewWidth: CGFloat = 0
    let page: KeyboardPageDefinition
    let split: ActiveLayoutSplit?
    @ViewBuilder var key: (LayoutKey, String, Int) -> Key
    @ViewBuilder var footer: (PhoneKeypadMetrics, ActiveLayoutSplit?) -> Footer

    private var categories: [SymbolPageTable.PhoneSymbolCategory] {
        if let categories = page.categories {
            return SymbolPageTable.authoredCategories(categories, recents: library.recents.map(\.text))
        }
        let catalog = library.catalog
        return SymbolPageTable.phoneSymbolCategories(
            ascii: false, recents: library.recents.map(\.text),
            library: catalog.orderedCategories.map {
                .init(id: $0.id, title: $0.name, symbols: catalog.items(in: $0.id).map(\.text))
            })
    }

    var body: some View {
        let categories = categories
        let open = categories.first { $0.id == selected } ?? categories[0]
        let active = ActiveLayoutSplit.resolving(nested: open.split, parent: split, width: Double(previewWidth))
        return StablePhoneKeypadShell(
            trailingSpansControlRow: true, expandsForSplit: active != nil,
            leading: { metrics in
                let height = (CGFloat(metrics.mainHeight) - 12) / 3.5
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(categories, id: \.id) { category in
                            Button {
                                selected = category.id
                            } label: {
                                Text(category.title).font(appearance.font(KeyboardToolsStyle.categoryRailTitleSize))
                                    .lineLimit(1).minimumScaleFactor(0.75)
                                    .foregroundStyle(
                                        category.id == open.id
                                            ? appearance.accentForeground
                                            : Color(uiColor: appearance.text(on: "control"))
                                    )
                                    .frame(maxWidth: .infinity).frame(height: height)
                                    .background {
                                        if category.id == open.id {
                                            RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                                                .fill(appearance.color("key"))
                                                .padding(.horizontal, appearance.skin.spacing.visualInsetX + 2)
                                                .padding(.vertical, appearance.skin.spacing.visualInsetY + 2)
                                        }
                                    }
                            }.buttonStyle(KeyboardPressStyle())
                        }
                    }
                }.sharpCandidateScrollEdges().background(appearance.color("control"))
            },
            main: { _ in
                if open.keys.isEmpty {
                    Text("还没有符号。").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    KeyboardCategoryGrid(keys: open.keys, columns: open.columns, split: active) { item, index in
                        key(item, open.id, index)
                    }.id(open.id)
                }
            },
            trailing: { metrics in
                let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
                VStack(spacing: CGFloat(metrics.spacing)) {
                    RepeatingDeleteKey {}.frame(height: CGFloat(slots[0].height))
                    ControlKeyFace(text: "重输").opacity(0.45).frame(height: CGFloat(slots[1].height))
                    ReturnKey(title: "换行") { _ in }.frame(height: CGFloat(slots[2].height))
                }
            }, bottom: { metrics in footer(metrics, active?.withoutRowBreaks) }
        )
        .modifier(PreviewWidthProbe(width: $previewWidth))
        .task { await library.reload().value }
    }
}

struct KeyboardPageRows<Key: View, Shift: View, Delete: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let page: KeyboardPageDefinition
    let split: ActiveLayoutSplit?
    var showsGlobe = true
    @ViewBuilder var key: (LayoutKey, Int, Int) -> Key
    @ViewBuilder var shift: () -> Shift
    @ViewBuilder var delete: () -> Delete

    var body: some View {
        ForEach(page.rows.indices, id: \.self) { row in
            GeometryReader { proxy in
                let geometry = KeyboardPageRowGeometry(
                    width: Double(proxy.size.width), page: page, row: row, split: split, showsGlobe: showsGlobe)
                HStack(spacing: 4) {
                    if geometry.showsShift { shift().frame(width: geometry.sideWidth, height: keyHeight) }
                    HStack(spacing: 4) {
                        ForEach(Array(geometry.keyIndices.enumerated()), id: \.element) { index, source in
                            if index == geometry.splitIndex, geometry.gap > 0 {
                                KeyboardSplitGap().frame(width: geometry.gap - 4, height: keyHeight)
                            }
                            key(page.rows[row].keys[source], row, source)
                                .frame(width: geometry.keyWidths[index], height: keyHeight)
                        }
                    }.padding(.horizontal, geometry.inset).frame(width: geometry.rowWidth)
                    if geometry.showsDelete { delete().frame(width: geometry.sideWidth, height: keyHeight) }
                }
            }.frame(height: keyHeight)
        }
    }
}
