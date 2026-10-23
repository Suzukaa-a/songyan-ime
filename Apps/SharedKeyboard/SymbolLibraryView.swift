import CandidateKit
import KeyboardCore
import OSLog
import QuickContentKit
import SwiftUI

// MARK: - Standalone symbol library panel (data lives in Packages/QuickContentKit)
//
// ## Host wiring contract
//
// The panel is fully decoupled from the engine: its only outputs are two closures and its input is its own query buffer.
//
//   let model = SymbolLibraryModel(
//       storeDirectory: nil,                    // nil = resolve automatically (see SymbolLibraryStorage)
//       onInsert: { controller.insertLiteral($0) },  // composition confirmation is the controller's job;
//                                                    // the Bool says whether the insert really took effect
//       onInserted: { inserted in /* optional: give feedback only on real success */ })
//   SymbolLibraryView(model: model, onClose: { /* dismiss the overlay, restore the source page */ })
//
//   Enter from a panel search action (optional): model.beginSearch()
//   External query-key injection (optional, e.g. the host app searching with the system keyboard):
//       model.searchKey(.character("j")) / .backspace / .clear
//
// Isolation rules:
//   - The search buffer lives only in SymbolLibraryModel and never calls controller.handle(.code),
//     so a Chinese composition is never polluted by a query; leaving the panel calls onClose and
//     the host restores the source page state.
//   - The internal ASCII query keyboard never raises the system keyboard (no TextField focus) and
//     appears only inside the panel; it is not a new resident bottom key.
//   - Recents persist through RecentSymbolStore into the injected directory; a failed save keeps the old data.
//
// Height budget: the panel replaces the keyboard content area as an overlay above `utilitiesPanel`
// and scrolls internally; the search keyboard takes ~130pt inside the panel and returns it on close.

// MARK: - Panel view (reuses the KeyboardAppearance skin environment)

/// Symbol library panel: category browsing + internal ASCII search + recents.
/// The host presents it as a whole replacement of the keyboard content area (same layer as the layout
/// picker panel); it scrolls itself within the height budget, and closing returns to the source page via `onClose`.
public struct SymbolLibraryView: View {
    @ObservedObject private var model: SymbolLibraryModel
    @StateObject private var local = LocalQuickContentModel()
    @State private var section = "symbols"
    @State private var confirmsClearHistory = false
    @State private var insertionError: String?
    private let onClose: () -> Void
    @Environment(\.keyboardAppearance) private var appearance

    public init(model: SymbolLibraryModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
    }

    /// Symbol-panel keys are chrome, not letter keycaps, so they carry no fixed keycap
    /// geometry to protect; 44pt is the HIG default, and a short panel scales it down rather
    /// than letting the keypad push the results out of the panel.
    private let keypadKeyHeight: CGFloat = 44

    public var body: some View {
        GeometryReader { geometry in
            // The panel is drawn inside the keyboard's own height, so every band is measured
            // against that height: the title shrinks and the leading column scrolls instead of
            // overflowing into the content on a short landscape keyboard.
            let layout = QuickContentLayout.resolve(
                height: geometry.size.height,
                railItemCount: railItems.count)
            VStack(spacing: 0) {
                headerBar(layout).frame(height: layout.titleBarHeight)
                bandSeparator(layout)
                if model.searchKeyboardVisible {
                    queryBar.frame(height: layout.titleBarHeight)
                    bandSeparator(layout)
                }
                HStack(spacing: 0) {
                    if !model.searchKeyboardVisible { leadingRail(layout) }
                    // Only the content gives up height: the column keeps its slots, so nothing
                    // overlaps and nothing is cut.
                    Group {
                        if section == "symbols" { content(layout) } else { localContent }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.searchKeyboardVisible {
                    bandSeparator(layout)
                    searchKeypad(
                        keypadKeyHeight: min(
                            keypadKeyHeight,
                            max(30, (layout.contentHeight - 8) / 3.4)))
                }
            }
            // No fill of its own: the panel shows the keyboard surface behind it.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .clipped()
        }
        .tint(appearance.accentForeground)
        .onAppear { local.reload() }
        // Symbol names/browse text honour the user's text size. The grid cells and the
        // search keypad keep their own explicit minimum hit sizes below.
        .dynamicTypeSize(.small ... .accessibility3)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) {
            if model.searchKeyboardVisible { model.endSearch() } else { onClose() }
        }
    }

    // MARK: Leading column

    /// One entry of the leading column: the three sections, plus the open section's categories
    /// while symbols are showing (indented, the way the nine-key symbol page nests its list).
    private struct RailItem: Identifiable {
        enum Kind: Equatable {
            case section(String)
            case category(String?)
        }
        let kind: Kind
        let title: String
        let isSelected: Bool
        /// The first category after the three sections: keeps the two groups visually apart
        /// without indenting one of them (every row shares the same left edge).
        let startsNewGroup: Bool
        var id: String {
            switch kind {
            case .section(let name): return "section:" + name
            case .category(let id): return "category:" + (id ?? "all")
            }
        }
    }

    private var railItems: [RailItem] {
        var items: [RailItem] = [
            RailItem(
                kind: .section("symbols"), title: "符号", isSelected: section == "symbols",
                startsNewGroup: false),
            RailItem(
                kind: .section("phrases"), title: "常用语", isSelected: section == "phrases",
                startsNewGroup: false),
            RailItem(
                kind: .section("clipboard"), title: "剪贴板", isSelected: section == "clipboard",
                startsNewGroup: false),
        ]
        guard section == "symbols" else { return items }
        items.append(
            RailItem(
                kind: .category(nil), title: "全部",
                isSelected: model.selectedCategory == nil, startsNewGroup: true))
        for category in model.visibleCategories {
            items.append(
                RailItem(
                    kind: .category(category.id), title: category.name,
                    isSelected: model.selectedCategory == category.id,
                    startsNewGroup: false))
        }
        return items
    }

    /// The whole column shares one control surface; the open entry is drawn as a key, exactly like
    /// the nine-key symbol page's category rail.
    private func leadingRail(_ layout: QuickContentLayout) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: layout.separatorHeight) {
                ForEach(railItems) { item in
                    railButton(item, layout: layout)
                }
            }
        }
        .sharpCandidateScrollEdges()
        .frame(width: layout.railWidth)
        .background {
            RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                .fill(appearance.color("control"))
                .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                .padding(.vertical, appearance.skin.spacing.visualInsetY)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityLabel("快捷内容分类")
    }

    private func railButton(_ item: RailItem, layout: QuickContentLayout) -> some View {
        Button {
            switch item.kind {
            case .section(let name):
                section = name
                if name == "clipboard" { model.endSearch() }
                if name != "symbols" { local.reload() }
            case .category(let id):
                model.selectCategory(id)
            }
        } label: {
            Text(item.title)
                .font(appearance.font(KeyboardToolsStyle.categoryRailTitleSize))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(
                    item.isSelected
                        ? Color(uiColor: appearance.text(on: "key"))
                        : Color(uiColor: appearance.text(on: "control"))
                )
                .frame(maxWidth: .infinity)
                .frame(height: layout.railSlotHeight)
                .padding(.top, item.startsNewGroup ? 6 : 0)
                .background {
                    if item.isSelected {
                        RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                            .fill(appearance.color("key"))
                            .padding(.horizontal, appearance.skin.spacing.visualInsetX + 2)
                            .padding(.vertical, appearance.skin.spacing.visualInsetY + 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SymbolPanelPressStyle())
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(item.isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("quickContent.rail." + item.id)
    }

    /// Band divider whose height is part of the budget above it, so it never adds to the panel.
    private func bandSeparator(_ layout: QuickContentLayout) -> some View {
        Rectangle()
            .fill(appearance.color("border").opacity(0.7))
            .frame(height: max(0.5, layout.separatorHeight))
            .accessibilityHidden(true)
    }

    private var localContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if local.isBusy { ProgressView("正在读取…") }
                if let insertionError { Text(insertionError).font(.footnote) }
                if let error = local.error {
                    Text(error).font(.footnote)
                    Button("重试") { local.reload() }
                } else if section == "phrases" {
                    let phrases = local.content.phrases.filter { $0.matches(model.query) }
                    if phrases.isEmpty {
                        Text(model.isSearching ? "没有找到常用语" : "在松烟 App 的「常用语与剪贴板」中添加常用语")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(phrases) { phrase in
                        Button {
                            insertLocalText(phrase.text)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(phrase.text).lineLimit(3)
                                if !phrase.shortcut.isEmpty {
                                    Text(phrase.shortcut).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(SkinKeyBackground(role: "key"))
                        }
                        .buttonStyle(SymbolPanelPressStyle())
                        .accessibilityIdentifier("quickContent.phrase.\(phrase.id.uuidString)")
                    }
                } else if !local.content.clipboardEnabled {
                    Text("剪贴板历史未开启").font(.headline)
                    Text("可在松烟 App 的「常用语与剪贴板」中开启。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text("最近粘贴").font(.footnote)
                        Spacer()
                        Button("清空", role: .destructive) { confirmsClearHistory = true }
                            .disabled(local.content.clipboard.isEmpty || local.isBusy)
                            .accessibilityIdentifier("quickContent.clearHistory")
                    }
                    if local.content.clipboard.isEmpty {
                        Text("还没有历史记录。返回键盘后轻点「粘贴」即可保存。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(local.content.clipboard, id: \.self) { text in
                        HStack {
                            Button {
                                insertLocalText(text)
                            } label: {
                                Text(text).lineLimit(3)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            Button {
                                local.deleteClipboard(text)
                            } label: {
                                Image(systemName: "trash").frame(width: 44, height: 44)
                            }
                            .disabled(local.isBusy)
                            .accessibilityLabel("删除这条历史记录")
                        }
                        .buttonStyle(SymbolPanelPressStyle())
                    }
                }
            }
            .padding(8)
            .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
        }
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmsClearHistory, titleVisibility: .visible) {
            Button("清空历史记录", role: .destructive) { local.clearClipboard() }
        }
    }

    private func insertLocalText(_ text: String) {
        insertionError = model.insertQuickText(text) ? nil : "未能输入文字，请返回键盘后重试。"
    }

    // MARK: Header (title / search toggle / back)

    /// Same arrangement as the keyboard settings panel: the title centred, the way
    /// out top-right in the 完成 style, search just left of it.
    private func headerBar(_ layout: QuickContentLayout) -> some View {
        ZStack {
            Text(model.searchKeyboardVisible ? "搜索" : "快捷内容")
                .font(appearance.font(appearance.controlTextSize))
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel")))
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                searchToggle
                KeyboardToolsDismissButton(
                    title: "返回", accessibilityHint: "关闭快捷内容，回到之前的键盘页面",
                    minHeight: min(44, layout.titleBarHeight), action: onClose)
            }
        }
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
    }

    private var searchToggle: some View {
        Button {
            if model.searchKeyboardVisible { model.endSearch() } else { model.beginSearch() }
        } label: {
            Image(systemName: model.searchKeyboardVisible ? "xmark.circle.fill" : "magnifyingglass")
                .font(appearance.font(appearance.controlIconSize))
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SymbolPanelPressStyle())
        .disabled(section == "clipboard")
        .accessibilityIdentifier("quickContent.search")
        .accessibilityLabel(model.searchKeyboardVisible ? "退出搜索" : "搜索")
        .accessibilityHint(model.searchKeyboardVisible ? "清空查询并回到分类浏览" : "打开键盘内查询输入")
    }

    /// Query display row: the panel-private buffer + per-character backspace + clear (no system keyboard focus).
    private var queryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(appearance.font(appearance.skin.typography.secondarySize))
                .foregroundStyle(Color(uiColor: appearance.text(on: "panel", secondary: true)))
            Text(model.query.isEmpty ? (section == "phrases" ? "输入搜索词" : "输入拼音或名称，例如 jiantou") : model.query)
                .font(appearance.font(appearance.controlTextSize))
                .foregroundStyle(
                    Color(
                        uiColor: model.query.isEmpty
                            ? appearance.text(on: "panel", secondary: true)
                            : appearance.text(on: "panel"))
                )
                .lineLimit(1)
                .truncationMode(.head)
            if !model.query.isEmpty {
                Text("▍")
                    .font(appearance.font(appearance.controlTextSize))
                    .foregroundStyle(appearance.accentForeground)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
            if !model.query.isEmpty {
                Button {
                    model.searchKey(.backspace)
                } label: {
                    Image(systemName: "delete.left")
                        .font(appearance.font(appearance.controlIconSize))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SymbolPanelPressStyle())
                .accessibilityLabel("删除最后一个查询字符")
                Button {
                    model.searchKey(.clear)
                } label: {
                    Text("清空").font(appearance.font(appearance.skin.typography.secondarySize + 1))
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SymbolPanelPressStyle())
                .accessibilityLabel("清空查询")
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }

    // MARK: Content (search results / categories + recents)

    private func content(_ layout: QuickContentLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: layout.density == .minimal ? 6 : 8) {
                if model.isLoading && model.catalog.items.isEmpty {
                    ProgressView("正在加载符号…")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                if let error = model.catalogReadError {
                    Text(error)
                        .font(appearance.font(appearance.skin.typography.secondarySize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .accessibilityHint("已恢复内置默认符号目录")
                }
                if model.isSearching {
                    searchSection(layout)
                } else {
                    if layout.showsRecents { recentSection }
                    browseSections(layout)
                }
                if let note = model.persistenceNote {
                    Text(note)
                        .font(appearance.font(appearance.skin.typography.secondarySize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .sharpCandidateScrollEdges()
    }

    @ViewBuilder
    private func searchSection(_ layout: QuickContentLayout) -> some View {
        let results = model.searchResults
        if results.isEmpty {
            Text("未找到与「\(model.query)」匹配的符号")
                .font(appearance.font(appearance.skin.typography.secondarySize + 1))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
        } else {
            symbolGrid(results, layout)
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !model.recents.isEmpty {
            HStack(spacing: 4) {
                Text("最近")
                    .font(appearance.font(appearance.skin.typography.secondarySize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(model.recents) { entry in
                            recentCell(entry)
                        }
                    }
                }
                Button {
                    model.clearRecents()
                } label: {
                    Image(systemName: "trash")
                        .font(appearance.font(appearance.controlIconSize))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SymbolPanelPressStyle())
                .accessibilityLabel("清空最近使用的符号")
            }
        }
    }

    private func recentCell(_ entry: SymbolLibraryModel.RecentEntry) -> some View {
        Button {
            model.insert(entry: entry)
        } label: {
            VStack(spacing: 1) {
                Text(entry.text)
                    .font(appearance.font(appearance.skin.typography.candidateSize + 4))
                if let name = entry.name {
                    Text(name)
                        .font(appearance.font(appearance.skin.typography.secondarySize))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
            .frame(minWidth: 52, minHeight: 52)
            .padding(.horizontal, 2)
            .background(SkinKeyBackground(role: "key"))
        }
        .buttonStyle(SymbolPanelPressStyle())
        .accessibilityLabel("\(entry.name ?? entry.text) \(entry.text)")
        .accessibilityHint("再次插入此符号")
    }

    @ViewBuilder
    private func browseSections(_ layout: QuickContentLayout) -> some View {
        if let selected = model.selectedCategory {
            section(
                title: model.categoryName(selected) ?? selected,
                items: model.catalog.items(in: selected), layout: layout)
        } else {
            ForEach(model.visibleCategories, id: \.id) { category in
                section(title: category.name, items: model.catalog.items(in: category.id), layout: layout)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [SymbolItem], layout: QuickContentLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(appearance.font(appearance.skin.typography.secondarySize))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            symbolGrid(items, layout)
        }
    }

    /// Wide cells are for whole-phrase symbols (kaomoji and friends), narrow ones for a single
    /// glyph: a two-column grid of long phrases reads better than eight cramped columns.
    private func isWide(_ item: SymbolItem) -> Bool {
        item.category == "kaomoji" || item.text.count > 4
    }

    private func symbolGrid(_ items: [SymbolItem], _ layout: QuickContentLayout) -> some View {
        // Kaomoji are whole phrases: a fixed three-column grid keeps each one on a line and shows a
        // leading row instead of two oversized half-width cells. Single glyphs adapt.
        let columns: [GridItem] =
            items.contains(where: isWide)
            ? Array(repeating: GridItem(.flexible(), spacing: 4), count: layout.kaomojiColumnCount)
            : [GridItem(.adaptive(minimum: layout.symbolColumnMinWidth), spacing: 4)]
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(items) { item in
                symbolCell(item, layout)
            }
        }
    }

    private func symbolCell(_ item: SymbolItem, _ layout: QuickContentLayout) -> some View {
        let size =
            isWide(item)
            ? min(appearance.skin.typography.candidateSize + 2, layout.density == .minimal ? 18 : 26)
            : min(30, appearance.skin.typography.candidateSize + 6)
        return Button {
            model.insert(item)
        } label: {
            VStack(spacing: 2) {
                Text(item.text)
                    .font(appearance.font(size))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(item.name)
                    .font(appearance.font(appearance.skin.typography.secondarySize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(Color(uiColor: appearance.text(on: "key")))
            .frame(maxWidth: .infinity, minHeight: layout.symbolCellMinHeight)
            .padding(.horizontal, 4)
            .background(SkinKeyBackground(role: "key"))
            .contentShape(Rectangle())
        }
        .buttonStyle(SymbolPanelPressStyle())
        .accessibilityLabel("\(item.name) \(item.text)")
        .accessibilityHint("轻点插入")
    }

    // MARK: Internal ASCII query keyboard (appears inside the panel, not a resident bottom key)

    private static let keypadRows: [[String]] = [
        ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
        ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
        ["z", "x", "c", "v", "b", "n", "m"],
    ]

    private func searchKeypad(keypadKeyHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.keypadRows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 4) {
                    if index == 2 {
                        keypadKey(title: nil, symbol: "trash", width: 52, height: keypadKeyHeight) {
                            model.searchKey(.clear)
                        }
                        .accessibilityLabel("清空查询")
                    }
                    ForEach(row, id: \.self) { letter in
                        keypadKey(title: letter, symbol: nil, width: nil, height: keypadKeyHeight) {
                            model.searchKey(.character(letter))
                        }
                    }
                    if index == 2 {
                        keypadKey(title: nil, symbol: "delete.left", width: 52, height: keypadKeyHeight) {
                            model.searchKey(.backspace)
                        }
                        .accessibilityLabel("删除最后一个查询字符")
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func keypadKey(
        title: String?, symbol: String?, width: CGFloat?, height: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(appearance.font(appearance.controlIconSize))
                } else if let title {
                    Text(title)
                        .font(appearance.font(appearance.skin.typography.keySize))
                }
            }
            .frame(
                minWidth: width,
                maxWidth: width == nil ? .infinity : nil
            )
            .frame(height: height)
            .background(SkinKeyBackground(role: width == nil ? "key" : "control"))
            .foregroundStyle(Color(uiColor: appearance.text(on: width == nil ? "key" : "control")))
            .contentShape(Rectangle())
        }
        .buttonStyle(SymbolPanelKeyStyle())
    }

}

// MARK: - In-panel button style (skin injected through the environment; local implementation, KeyboardPanelView is untouched)

// A press shares only timing and press amount: corner radius and color keep the local skin roles, and
// the shared layer draws no square overlay, so rounded cards are not covered and the whole label is no
// longer faded with opacity. The query keyboard keeps its keycap-shaped highlight (inset + keycap
// radius), with color/duration from the same KeyboardPressPhysics / KeyboardMotion.
private struct SymbolPanelPressStyle: ButtonStyle {
    @Environment(\.keyboardAppearance) private var appearance
    /// Corner radius: defaults to the keycap radius; category chips pass their own 16 to match their shape.
    var cornerRadius: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .keyboardPressHighlight(
                isPressed: configuration.isPressed,
                cornerRadius: cornerRadius ?? appearance.skin.keycap.cornerRadius,
                style: appearance.color("pressed")
            )
            .keyboardChromePressTiming(isPressed: configuration.isPressed)
    }
}

private struct SymbolPanelKeyStyle: ButtonStyle {
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
                    .fill(
                        appearance.color("pressed").opacity(
                            configuration.isPressed ? KeyboardPressPhysics.overlayOpacity : 0)
                    )
                    .padding(.horizontal, appearance.skin.spacing.visualInsetX)
                    .padding(.vertical, appearance.skin.spacing.visualInsetY)
                    .allowsHitTesting(false)
            }
            .animation(
                configuration.isPressed
                    ? KeyboardPressPhysics.pressInAnimation
                    : KeyboardMotion.release(reduceMotion: reduceMotion),
                value: configuration.isPressed)
    }
}

// MARK: - Symbol library panel host (data/views in SymbolLibraryView.swift + QuickContentKit)

/// StateObject host: the model's lifecycle matches the panel; the parent wraps it in `.id(ObjectIdentifier(controller))`,
/// so a controller identity change rebuilds it wholesale and the onInsert closure always points at the current controller.
/// The sole insert exit = controller.insertLiteral (composition-confirm semantics come from the existing insertLiteral).
/// Recent-use is recorded and one selection feedback emitted only when this literal was really dispatched to a valid host exit
/// (insertLiteral returned true); success is not guessed from counts/snapshots: a partial composition commit,
/// no host exit, and input disabled all return false, and the public proxy does not guarantee the document actually accepted it.
struct SymbolLibraryPanel: View {
    @ObservedObject private var controller: KeyboardController
    private let onClose: () -> Void
    @StateObject private var model: SymbolLibraryModel

    init(controller: KeyboardController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        // onInsert/onInserted hold only a weak reference to the controller; when it is nil (released),
        // onInsert returns false: no valid host exit, so no recent-use record and no feedback.
        _model = StateObject(
            wrappedValue: SymbolLibraryModel(
                storeDirectory: nil,
                onInsert: { [weak controller] text in
                    guard let controller else { return false }
                    return controller.insertLiteral(text)
                },
                onInserted: { inserted in
                    // Feedback only when this literal was really dispatched to a valid host exit; none on a failed confirm or with no host.
                    if inserted { KeyboardFeedbackService.shared.selectionChanged() }
                }))
    }

    var body: some View {
        SymbolLibraryView(model: model, onClose: onClose)
    }
}
