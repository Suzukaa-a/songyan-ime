import KeyboardCore
import LayoutKit
import QuickContentKit
import SwiftUI
import UIKit

// Key-area views the live panel and the host previews both draw. Each takes plain values and
// action closures; the panel passes live state, a preview passes its sample state.

/// The rows of a page without authored chrome, with the native Shift and Delete around them.
struct KeyboardPageRows<Key: View, Leading: View, Delete: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let page: KeyboardPageDefinition
    let split: ActiveLayoutSplit?
    var showsGlobe = true
    @ViewBuilder var key: (LayoutKey, Int, Int) -> Key
    /// Shift on the ABC page, the 123/symbol switch on the other pages.
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var delete: () -> Delete

    var body: some View {
        ForEach(page.rows.indices, id: \.self) { row in
            GeometryReader { proxy in
                let geometry = KeyboardPageRowGeometry(
                    width: Double(proxy.size.width), page: page, row: row, split: split, showsGlobe: showsGlobe)
                HStack(spacing: 4) {
                    if geometry.showsLeadingControl {
                        leading().frame(width: geometry.sideWidth, height: keyHeight)
                    }
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

/// One category's symbols in a vertically scrolling grid.
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

/// The built-in 123 rows and the row-shaped #+= page: ten equal columns, and a seven-mark third row
/// between the 123/symbol switch and Delete, the ABC page's Shift-row shape.
struct KeyboardSymbolPageRows<PageSwitch: View, Delete: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let rows: [KeyboardRow]
    let split: ActiveLayoutSplit?
    var alternates: (KeyCap) -> [KeyCap] = { _ in [] }
    let onTap: (KeyCap) -> Void
    /// The 123/symbol switch in the ABC page's Shift position.
    @ViewBuilder var pageSwitch: () -> PageSwitch
    @ViewBuilder var delete: () -> Delete

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            GeometryReader { geometry in
                let metrics = StandardKeyRowGeometry(width: Double(geometry.size.width), split: split)
                HStack(spacing: 4) {
                    if index == 2 {
                        pageSwitch().frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                    }
                    WeightedKeyRow(
                        caps: row.caps, alternates: alternates, showsKeyPreview: true,
                        split: split, rowIndex: index,
                        fixedKeyWidth: CGFloat(metrics.keyWidth), splitGap: CGFloat(metrics.gap),
                        onTap: onTap
                    )
                    if index == 2 {
                        delete().frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                    }
                }
            }.frame(height: keyHeight)
        }
    }
}

/// The standard 26-key shell: three rows on the common ten-column widths, Shift opening and Delete
/// closing the third row.
struct KeyboardStandardQwertyPad<Row: View, Shift: View, Delete: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let split: ActiveLayoutSplit?
    @ViewBuilder var row: (Int, StandardKeyRowGeometry) -> Row
    @ViewBuilder var shift: () -> Shift
    @ViewBuilder var delete: () -> Delete

    var body: some View {
        GeometryReader { geometry in
            let metrics = StandardKeyRowGeometry(width: Double(geometry.size.width), split: split)
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    if index == 2 {
                        HStack(spacing: 4) {
                            shift().frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                            row(index, metrics)
                            delete().frame(width: CGFloat(metrics.thirdRowSideWidth), height: keyHeight)
                        }
                    } else {
                        row(index, metrics)
                    }
                }
            }
        }.frame(height: keyHeight * 3 + 8)
    }
}

/// Bundled merged letter pad (14-key, 18-key): the definition's rows at their weighted widths
/// (`MergedKeypadGeometry`), with the separator in the Shift slot and Delete closing the last row.
struct KeyboardMergedPad<Key: View, Separator: View, Delete: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let rows: [LayoutRow]
    let split: ActiveLayoutSplit?
    @ViewBuilder var key: (LayoutKey, Int, Int) -> Key
    @ViewBuilder var separator: () -> Separator
    @ViewBuilder var delete: () -> Delete

    /// Merged letter groups retain their wider editing controls.
    static func sharedDeleteWidth(for width: CGFloat) -> CGFloat {
        max(56, (width - 32) / 10 * 1.8)
    }

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let side = Self.sharedDeleteWidth(for: geometry.size.width)
            let gap = CGFloat(
                split?.gap(
                    width: Double(geometry.size.width), keyCount: (rows.map { $0.keys.count }.max() ?? 1) + 2) ?? 0)
            let metrics = MergedKeypadGeometry.rows(
                weights: rows.map { $0.keys.map(\.widthWeight) },
                width: max(0, geometry.size.width - gap), spacing: spacing,
                sideWidth: side)
            VStack(spacing: spacing) {
                ForEach(Array(zip(rows, metrics).enumerated()), id: \.offset) { index, entry in
                    let isLast = index == rows.count - 1
                    HStack(spacing: spacing) {
                        if isLast {
                            separator().frame(width: side, height: keyHeight)
                        }
                        ForEach(Array(entry.0.keys.enumerated()), id: \.offset) { keyIndex, key in
                            if keyIndex == split?.breakIndex(row: index, keyCount: entry.0.keys.count), gap > 0 {
                                KeyboardSplitGap().frame(width: gap - spacing, height: keyHeight)
                            }
                            self.key(key, index, keyIndex)
                                .frame(width: entry.1.keyWidths[keyIndex], height: keyHeight)
                        }
                        if isLast {
                            delete().frame(width: side, height: keyHeight)
                        }
                    }
                    .frame(width: geometry.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(height: CGFloat(max(1, rows.count)) * (keyHeight + 4) - 4)
    }
}

/// Syllable separator in the merged pad's Shift slot; only a composition uses it.
struct KeyboardMergedSeparatorKey: View {
    @Environment(\.keyboardAppearance) private var appearance
    let isComposing: Bool
    let onTap: () -> Void

    var body: some View {
        AlternateCharacterKey(
            cap: KeyCap(id: "merged-separator", title: "分词", action: .code("'")),
            alternates: [], visualRole: "control",
            titleSize: appearance.controlTextSize
        ) { _ in
            onTap()
        }
        .disabled(!isComposing)
        .accessibilityLabel("分词")
    }
}

/// One definition row at its declared weights. `keys` are the visible keys; `key` receives the
/// visible index. A control row keeps a 44pt minimum per key and may scroll.
struct KeyboardDefinitionRow<Key: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let keys: [LayoutKey]
    var inset: CGFloat = 0
    var spacing: CGFloat = 4
    var split: ActiveLayoutSplit? = nil
    var rowIndex = 0
    var fixedKeyWidth: CGFloat? = nil
    var splitGap: CGFloat? = nil
    var isControls = false
    @ViewBuilder var key: (LayoutKey, Int) -> Key

    var body: some View {
        GeometryReader { geometry in
            let gap = splitGap ?? CGFloat(split?.gap(width: Double(geometry.size.width), keyCount: keys.count) ?? 0)
            let boundary = split?.breakIndex(row: rowIndex, keyCount: keys.count)
            let available = max(0, geometry.size.width - CGFloat(max(0, keys.count - 1)) * spacing - gap)
            let widths = LayoutRowWidthProjection(weights: keys.map(\.widthWeight), inset: Double(inset))
            let minimum: CGFloat = isControls ? 44 : 0
            let remainder = max(0, available - CGFloat(keys.count) * minimum)
            let row = HStack(spacing: spacing) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, value in
                    if index == boundary, gap > 0 {
                        KeyboardSplitGap().frame(width: gap - spacing, height: keyHeight)
                    }
                    key(value, index)
                        .frame(
                            width: fixedKeyWidth
                                ?? (isControls
                                    ? minimum + remainder * CGFloat(widths.keyFractions[index])
                                    : available * CGFloat(widths.keyFractions[index])),
                            height: keyHeight)
                }
            }
            .padding(
                .horizontal,
                fixedKeyWidth.map { max(0, (available - $0 * CGFloat(keys.count)) / 2) }
                    ?? (available * CGFloat(widths.insetFraction)))
            if isControls {
                // Only an authored control row can exceed the width (44pt minimum
                // per key), so only it may scroll.
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .sharpCandidateScrollEdges()
            } else {
                // Letter/digit rows fill the width exactly, so they need no ScrollView:
                // one per row would add gesture arbitration to every key touch and
                // an iOS 26 scroll edge effect along the top of the first row.
                row
            }
        }
        .frame(height: keys.isEmpty ? 0 : keyHeight)
    }
}

/// A declared side column of a row-shaped definition, as tall as its main rows. Return and the
/// like stay where the author declared them.
struct KeyboardAuxiliaryColumn<Key: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let keys: [LayoutKey]
    let rowCount: Int
    @ViewBuilder var key: (LayoutKey, Int) -> Key

    var body: some View {
        if !keys.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { index, value in
                    key(value, index)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 44, height: CGFloat(max(1, rowCount)) * (keyHeight + 4) - 4)
        }
    }
}

/// One slot of the split author control row: a shortcut the bar adds, or a declared key.
enum LayoutFooterItem: Hashable {
    case numericShortcut
    case symbolShortcut
    case globe
    case layoutSwitch
    case key(Int)

    func width(keys: [LayoutKey]) -> Double {
        guard case .key(let index) = self else { return 44 }
        return max(44, keys[index].widthWeight * 44)
    }
}

/// The author layout bar: the declared control row with its actions, order, widths and long-press
/// menus. 123, #+=, globe and layout shortcuts are added only when the author did not declare the
/// same entry. `key` receives the key, its cap id and its declared index.
struct KeyboardLayoutUtilityBar<Key: View, Globe: View, ModeSwitch: View>: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let controlRow: LayoutRow?
    /// The row index the split cut list uses for the control row.
    let rowIndex: Int
    let split: ActiveLayoutSplit?
    /// Whether globe keys can run (a system switcher exists).
    let showsGlobe: Bool
    /// Whether the definition already declares a globe anywhere.
    let definitionHasGlobe: Bool
    let onPage: (KeyboardPage) -> Void
    @ViewBuilder var key: (LayoutKey, String, Int) -> Key
    @ViewBuilder var globe: () -> Globe
    @ViewBuilder var modeSwitch: () -> ModeSwitch

    private var keys: [LayoutKey] { controlRow?.keys ?? [] }

    /// Shortcuts the bar adds only when the authored control row does not already declare them.
    private var dedupe: (numeric: Bool, symbols: Bool, layout: Bool) {
        (
            numeric: keys.contains { $0.action.pageSwitchTarget == .numeric },
            symbols: keys.contains { $0.action.pageSwitchTarget == .symbols },
            layout: keys.contains { $0.action.type == .modeSwitch }
        )
    }

    var body: some View {
        if let split {
            let keys = keys
            let boundary = split.breakIndex(row: rowIndex, keyCount: keys.count)
            let visible = keys.indices.filter {
                keys[$0].action.type != .space && (keys[$0].action.type != .globe || showsGlobe)
            }
            let dedupe = dedupe
            let shortcuts: [LayoutFooterItem] =
                (dedupe.numeric ? [] : [.numericShortcut]) + (dedupe.symbols ? [] : [.symbolShortcut])
                + (!definitionHasGlobe && showsGlobe ? [.globe] : [])
            let left = shortcuts + visible.filter { $0 < boundary }.map(LayoutFooterItem.key)
            let right =
                visible.filter { $0 >= boundary }.map(LayoutFooterItem.key)
                + (dedupe.layout ? [] : [LayoutFooterItem.layoutSwitch])
            let spaceIndex = keys.firstIndex { $0.action.type == .space }
            let space = spaceIndex.map { keys[$0] } ?? LayoutKey(label: "空格", width: 4, action: .init(.space))
            SplitSpaceKeyboardRow(
                leftKeys: left, rightKeys: right,
                leftWidths: left.map { $0.width(keys: keys) },
                rightWidths: right.map { $0.width(keys: keys) }, split: split,
                spaceWidthMultiplier: 3 * space.widthWeight / 4,
                key: { footerKey($0, keys: keys) },
                space: { key(space, "controls-space", spaceIndex ?? -1) },
                fallback: { singleSpaceBar })
        } else {
            singleSpaceBar
        }
    }

    @ViewBuilder
    private func footerKey(_ item: LayoutFooterItem, keys: [LayoutKey]) -> some View {
        switch item {
        case .numericShortcut: pageShortcut("123", target: .numeric)
        case .symbolShortcut: pageShortcut(KeyboardControlPolicy.symbolPageTitle, target: .symbols)
        case .globe: globe()
        case .layoutSwitch: modeSwitch()
        case .key(let index): key(keys[index], "controls-\(index)", index)
        }
    }

    private var singleSpaceBar: some View {
        let dedupe = dedupe
        return HStack(spacing: 4) {
            if !dedupe.numeric { pageShortcut("123", target: .numeric) }
            if !dedupe.symbols {
                pageShortcut(KeyboardControlPolicy.symbolPageTitle, target: .symbols)
            }
            if let row = controlRow {
                let sources = row.keys.indices.filter { showsGlobe || row.keys[$0].action.type != .globe }
                KeyboardDefinitionRow(keys: sources.map { row.keys[$0] }, isControls: true) { value, index in
                    key(value, "controls-\(index)", sources[index])
                }
            } else {
                Spacer(minLength: 0)
            }
            if !definitionHasGlobe, showsGlobe {
                globe().frame(width: 44, height: keyHeight)
            }
            if !dedupe.layout {
                modeSwitch().frame(width: 44, height: keyHeight)
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(KeyboardPressStyle())
    }

    private func pageShortcut(_ title: String, target: KeyboardPage) -> some View {
        AlternateCharacterKey(
            cap: KeyCap(id: "layout-page-\(title)", title: title, action: .cycleLayout), alternates: []
        ) { _ in
            onPage(target)
        }
        .frame(width: 44, height: keyHeight)
        .accessibilityLabel(target == .numeric ? "打开数字符号页" : "打开符号页")
    }
}

/// The bundled T9's trailing column, as on the system / mainstream pinyin 9-key pads: Delete
/// (row 0), 重输 (row 1) and Return/Confirm across row 2 and the control row, in the bottom-right
/// corner. Confirm appears only here: the bottom row of these pads has no Return.
struct KeyboardFixedEditingRail: View {
    @Environment(\.keyboardAppearance) private var appearance
    let metrics: PhoneKeypadMetrics
    let returnTitle: String
    let isReturnEnabled: Bool
    let isComposing: Bool
    /// Receives whether this call is a repeat of a held Delete.
    let onDelete: (Bool) -> Void
    let onReset: () -> Void
    let onReturn: (KeyCap) -> Void

    var body: some View {
        let slots = metrics.railSlots(.trailing, spans: PhoneKeypadRailPolicy.bundledTrailingSpans)
        VStack(spacing: CGFloat(metrics.spacing)) {
            RepeatingDeleteKey(action: onDelete)
                .frame(height: CGFloat(slots[0].height))
                .accessibilityLabel("删除")
            AlternateCharacterKey(
                cap: KeyCap(id: "t9-reset", title: "重输", action: .backspace),
                alternates: [], visualRole: "control",
                titleSize: appearance.controlTextSize
            ) { _ in
                onReset()
            }
            .disabled(!isComposing)
            .frame(height: CGFloat(slots[1].height))
            .accessibilityLabel("重输")
            .accessibilityHint("清空当前输入")
            ReturnKey(title: returnTitle, isEnabled: isReturnEnabled, onSelect: onReturn)
                .frame(height: CGFloat(slots[2].height))
        }
    }
}

/// The three fixed symbol slots of a phone keypad's leading rail.
///
/// `firstKeyAlternates` is for callers whose only path to further symbols is long press (the 123
/// page's punctuation rail). The 9-key letter page cycles the rest on its first key instead, so it
/// passes none: no redundant menu and no hint for an unreachable one.
struct KeyboardPhoneSymbolRail: View {
    static let titleSize: Double = 19
    let caps: [KeyCap]
    let metrics: PhoneKeypadMetrics
    var firstKeyAlternates: [KeyCap] = []
    let onSelect: (KeyCap) -> Void

    var body: some View {
        VStack(spacing: CGFloat(metrics.spacing)) {
            ForEach(Array(caps.prefix(3).enumerated()), id: \.element.id) { index, cap in
                AlternateCharacterKey(
                    cap: cap,
                    alternates: index == 0 ? firstKeyAlternates : [],
                    phoneKey: true, phoneSideKey: true,
                    titleSize: Self.titleSize,
                    onSelect: onSelect
                )
                // One rail slot equals one number row, so the rail and the 3×3 grid share lines.
                .frame(height: CGFloat(metrics.rowHeight))
                .accessibilityHint(
                    index == 0 && !firstKeyAlternates.isEmpty
                        ? "长按输入更多符号" : "")
            }
        }
        .buttonStyle(KeyboardPressStyle())
    }
}

/// An imported phone keypad's declared rail keys in deterministic row slots
/// (`PhoneKeypadMetrics.slotSpans`), below any reading choices in the same scroller.
struct KeyboardPhoneDeclaredRail<Readings: View, Key: View>: View {
    let keys: [LayoutKey]
    let position: LayoutAuxiliaryArea.Position
    let metrics: PhoneKeypadMetrics
    @ViewBuilder var readings: () -> Readings
    @ViewBuilder var key: (LayoutKey, Int) -> Key

    var body: some View {
        let spans = PhoneKeypadMetrics.slotSpans(
            keyCount: keys.count,
            rowCount: PhoneKeypadMetrics.mainRowCount)
        let slots = metrics.railSlots(position == .leading ? .leading : .trailing, spans: spans)
        ScrollView(.vertical) {
            LazyVStack(spacing: CGFloat(metrics.spacing)) {
                if position == .leading { readings() }
                ForEach(Array(keys.enumerated()), id: \.offset) { index, value in
                    key(value, index)
                        .frame(height: CGFloat(slots[index].height))
                }
            }
            .buttonStyle(KeyboardPressStyle())
        }
        .sharpCandidateScrollEdges()
    }
}

/// A phone keypad's 123 page: 1–9 in the 3×3 grid, 0 in the bottom row, the page's punctuation in
/// the leading rail. This page has no first-key cycling, so extra punctuation stays on the first
/// rail key's long press.
struct KeyboardPhoneDigitPad<Expanded: View, Trailing: View, Bottom: View>: View {
    let usesASCIIPunctuation: Bool
    let split: ActiveLayoutSplit?
    let trailingSpansControlRow: Bool
    var showsExpanded = false
    var alternates: (KeyCap) -> [KeyCap] = { _ in [] }
    let onKey: (KeyCap) -> Void
    @ViewBuilder var expanded: () -> Expanded
    @ViewBuilder var trailing: (PhoneKeypadMetrics) -> Trailing
    @ViewBuilder var bottom: (PhoneKeypadMetrics) -> Bottom

    var body: some View {
        let railCaps = SymbolPageTable.phoneNumericRail(ascii: usesASCIIPunctuation)
        let digitRows = SymbolPageTable.phoneDigitRows(ascii: usesASCIIPunctuation)
        StablePhoneKeypadShell(
            trailingSpansControlRow: trailingSpansControlRow,
            expandsForSplit: split != nil,
            leading: { metrics in
                KeyboardPhoneSymbolRail(
                    caps: railCaps, metrics: metrics, firstKeyAlternates: Array(railCaps.dropFirst(3)),
                    onSelect: onKey)
            },
            main: { metrics in
                VStack(spacing: CGFloat(metrics.spacing)) {
                    if showsExpanded {
                        expanded()
                    } else {
                        ForEach(Array(digitRows.enumerated()), id: \.offset) { index, caps in
                            WeightedKeyRow(
                                caps: caps, alternates: alternates, split: split, rowIndex: index, onTap: onKey
                            )
                            .frame(height: CGFloat(metrics.rowHeight))
                        }
                    }
                }
            },
            trailing: trailing,
            bottom: bottom)
    }
}

/// The categorised symbol page of every layout (#+= on 26/14/18-key, 符号 on 9-key): categories in
/// the leading rail, the open category's symbols in a grid of digit-pad-height keys that scrolls
/// vertically, then the trailing column and the phone-pad control row.
struct KeyboardCategorySymbolPad<Key: View, Trailing: View, Bottom: View>: View {
    let categories: [SymbolPageTable.PhoneSymbolCategory]
    let open: SymbolPageTable.PhoneSymbolCategory
    /// The open category's split, already resolved against the keyboard width.
    let split: ActiveLayoutSplit?
    let trailingSpansControlRow: Bool
    let onSelectCategory: (String) -> Void
    @ViewBuilder var key: (LayoutKey, Int) -> Key
    @ViewBuilder var trailing: (PhoneKeypadMetrics) -> Trailing
    @ViewBuilder var bottom: (PhoneKeypadMetrics) -> Bottom

    var body: some View {
        StablePhoneKeypadShell(
            trailingSpansControlRow: trailingSpansControlRow,
            expandsForSplit: split != nil,
            leading: { metrics in
                KeyboardAuthoredCategoryRail(
                    categories: categories, open: open.id, mainHeight: CGFloat(metrics.mainHeight),
                    spacing: CGFloat(metrics.spacing), onSelect: onSelectCategory)
            },
            main: { metrics in
                let keys = open.keys
                if keys.isEmpty {
                    Text("还没有符号。").font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    KeyboardCategoryGrid(keys: keys, columns: open.columns, split: split, key: key)
                        .id(open.id)
                        .environment(\.keyboardKeyHeight, CGFloat(metrics.rowHeight))
                }
            },
            trailing: trailing,
            bottom: bottom)
    }
}

extension SymbolLibraryModel {
    /// The categories a symbol page shows: the page's own categories when it has them, otherwise
    /// the built-in tabs followed by the library's sets. `ascii` follows the real input language;
    /// an explicit symbol toggle only changes explicitly paired keys.
    func pageCategories(
        authored: [KeyboardPageCategory]?, ascii: Bool, showsGlobe: Bool
    ) -> [SymbolPageTable.PhoneSymbolCategory] {
        if let authored {
            return SymbolPageTable.authoredCategories(
                authored, recents: recents.map(\.text), showsGlobe: showsGlobe)
        }
        let catalog = catalog
        return SymbolPageTable.phoneSymbolCategories(
            ascii: ascii,
            recents: recents.map(\.text),
            library: catalog.orderedCategories.map { category in
                SymbolPageTable.LibraryCategory(
                    id: category.id, title: category.name,
                    symbols: catalog.items(in: category.id).map(\.text))
            })
    }
}
