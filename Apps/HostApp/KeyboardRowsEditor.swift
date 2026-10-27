import LayoutKit
import SwiftUI

/// Shared structural editor for main layouts and direct-input pages: rows and their keys. The
/// selected key's own actions live in `SelectedRowKeyActions`, next to its fields.
struct KeyboardRowsEditor: View {
    @Binding var rows: [LayoutRow]
    @Binding var selected: LayoutKeyPath
    @State private var pendingRowRemoval: Int?
    private let rowKeyLimit = LayoutResourceBudget.keysPerRegion

    var body: some View {
        Section("行与按键") {
            ForEach(rows.indices, id: \.self) { row in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("第 \(row + 1) 行").font(.headline)
                        Spacer()
                        Button {
                            moveRow(row, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .disabled(row == 0).accessibilityLabel("上移这一行")
                        Button {
                            moveRow(row, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .disabled(row == rows.count - 1).accessibilityLabel("下移这一行")
                        Button(role: .destructive) {
                            pendingRowRemoval = row
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(rows.count == 1).accessibilityLabel("删除这一行")
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(rows[row].keys.indices, id: \.self) { index in
                                KeyChip(
                                    label: rows[row].keys[index].label,
                                    isSelected: selected == .row(row, key: index)
                                ) { selected = .row(row, key: index) }
                            }
                            Button {
                                appendKey(row)
                            } label: {
                                Image(systemName: "plus")
                            }
                            .disabled(rows[row].keys.count >= rowKeyLimit)
                            .accessibilityLabel("添加按键")
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Button("添加一行", systemImage: "plus") {
                rows.append(LayoutRow(keys: [newKey]))
                selected = .row(rows.count - 1, key: 0)
            }
            .disabled(rows.count >= LayoutResourceBudget.rows)
        }
        .buttonStyle(.borderless)
        .confirmationDialog(
            pendingRowRemoval.map { "删除第 \($0 + 1) 行？" } ?? "",
            isPresented: Binding(get: { pendingRowRemoval != nil }, set: { if !$0 { pendingRowRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除这一行", role: .destructive) {
                guard let row = pendingRowRemoval, rows.indices.contains(row), rows.count > 1 else { return }
                pendingRowRemoval = nil
                rows.remove(at: row)
                selected = .row(0, key: 0)
            }
        } message: {
            if let row = pendingRowRemoval, rows.indices.contains(row) {
                Text("这一行的 \(rows[row].keys.count) 个按键会一起删除。")
            }
        }
    }

    private var newKey: LayoutKey { LayoutKey(label: "新键", action: .init(.literal, value: "。"), titleMode: nil) }

    private func appendKey(_ row: Int) {
        var keys = rows[row].keys
        keys.append(newKey)
        rows[row] = LayoutRow(keys: keys)
        selected = .row(row, key: keys.count - 1)
    }

    private func moveRow(_ row: Int, by offset: Int) {
        rows.swapAt(row, row + offset)
        selected = .row(row + offset, key: 0)
    }
}

/// Order, copy and delete for the selected row key. Sits right under the key's fields.
struct SelectedRowKeyActions: View {
    @Binding var rows: [LayoutRow]
    @Binding var selected: LayoutKeyPath
    private let rowKeyLimit = LayoutResourceBudget.keysPerRegion

    var body: some View {
        if case .row(let row, let index) = selected,
            rows.indices.contains(row), rows[row].keys.indices.contains(index)
        {
            Section("移动选中按键") {
                HStack {
                    Button("左移") { moveKey(row, index, by: -1) }.disabled(index == 0)
                    Spacer()
                    Button("右移") { moveKey(row, index, by: 1) }.disabled(index == rows[row].keys.count - 1)
                }
                HStack {
                    Button("移到上一行") { transferKey(row, index, to: row - 1) }
                        .disabled(
                            row == 0 || rows[row].keys.count == 1
                                || (row > 0 && rows[row - 1].keys.count >= rowKeyLimit))
                    Spacer()
                    Button("移到下一行") { transferKey(row, index, to: row + 1) }
                        .disabled(
                            row == rows.count - 1 || rows[row].keys.count == 1
                                || (row < rows.count - 1 && rows[row + 1].keys.count >= rowKeyLimit)
                        )
                }
                Button("复制按键") {
                    var keys = rows[row].keys
                    keys.insert(keys[index], at: index + 1)
                    rows[row] = LayoutRow(keys: keys)
                    selected = .row(row, key: index + 1)
                }
                .disabled(rows[row].keys.count >= rowKeyLimit)
                Button("删除按键", role: .destructive) {
                    var keys = rows[row].keys
                    keys.remove(at: index)
                    rows[row] = LayoutRow(keys: keys)
                    selected = .row(row, key: min(index, keys.count - 1))
                }
                .disabled(rows[row].keys.count == 1)
            }
            .buttonStyle(.borderless)
        }
    }

    private func moveKey(_ row: Int, _ index: Int, by offset: Int) {
        var keys = rows[row].keys
        keys.swapAt(index, index + offset)
        rows[row] = LayoutRow(keys: keys)
        selected = .row(row, key: index + offset)
    }

    private func transferKey(_ row: Int, _ index: Int, to target: Int) {
        var source = rows[row].keys
        let key = source.remove(at: index)
        var destination = rows[target].keys
        destination.append(key)
        rows[row] = LayoutRow(keys: source)
        rows[target] = LayoutRow(keys: destination)
        selected = .row(target, key: destination.count - 1)
    }
}

/// One selectable key in a structural list.
struct KeyChip: View {
    let label: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(label, action: select)
            .buttonStyle(.bordered)
            .tint(isSelected ? .accentColor : .secondary)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct KeyboardSplitEditor: View {
    let rows: [LayoutRow]
    /// Optional row names; the page editor names its authored footer row.
    var rowTitles: [String] = []
    @Binding var split: LayoutSplitConfiguration?
    var allowsInheritance = false
    var inheritanceTitle = "和主键盘一样拆分"
    /// No stored split means the split is off, never the initializer's default-on value.
    private var configuration: LayoutSplitConfiguration { split ?? LayoutSplitConfiguration(activation: .off) }

    /// The stored cut, or the same middle default the keyboard uses before a cut is saved.
    private var breaks: [Int] {
        rows.indices.map { index in
            configuration.breakIndex(row: index, keyCount: rows[index].keys.count)
        }
    }

    var body: some View {
        Section("拆分") {
            if allowsInheritance {
                Toggle(
                    inheritanceTitle,
                    isOn: Binding(
                        get: { split == nil },
                        set: { follows in split = follows ? nil : LayoutSplitConfiguration(activation: .off) }))
            }
            if !allowsInheritance || split != nil {
                Toggle(
                    "拆分键盘",
                    isOn: Binding(
                        get: { configuration.activation != .off },
                        set: { enabled in update { $0.activation = enabled ? .automatic : .off } }))
                if configuration.activation != .off {
                    Picker(
                        "拆分时机",
                        selection: Binding(
                            get: { configuration.activation },
                            set: { activation in update { $0.activation = activation } })
                    ) {
                        Text("宽屏时").tag(LayoutSplitConfiguration.Activation.automatic)
                        Text("始终").tag(LayoutSplitConfiguration.Activation.always)
                    }
                    Toggle(
                        "自动间距",
                        isOn: Binding(
                            get: { configuration.automaticGap },
                            set: { automatic in update { $0.automaticGap = automatic } }))
                    if !configuration.automaticGap {
                        Slider(
                            value: Binding(
                                get: { configuration.gapFraction },
                                set: { fraction in update { $0.gapFraction = fraction } }), in: 0.05...0.85
                        ) { Text("中间间距") }
                    }
                    ForEach(rows.indices, id: \.self) { row in
                        Stepper(
                            "\(rowTitle(row))：左侧 \(breaks[row]) 个键",
                            value: Binding(
                                get: { breaks[row] },
                                set: { value in
                                    var updated = configuration
                                    updated.rowBreaks = breaks
                                    updated.rowBreaks[row] = value
                                    split = updated
                                }), in: rows[row].keys.count > 1 ? 1...(rows[row].keys.count - 1) : 1...1
                        )
                        .disabled(rows[row].keys.count <= 1)
                    }
                }
            }
        }
    }

    private func rowTitle(_ row: Int) -> String {
        rowTitles.indices.contains(row) ? rowTitles[row] : "第 \(row + 1) 行"
    }

    private func update(_ change: (inout LayoutSplitConfiguration) -> Void) {
        var value = configuration
        value.rowBreaks = breaks
        change(&value)
        split = value
    }

    static func adjusted(_ split: LayoutSplitConfiguration?, rows: [LayoutRow]) -> LayoutSplitConfiguration? {
        split?.adjusted(to: rows)
    }
}

/// Lists and adds the authored function keys. Empty arrays are deliberate: a deleted key stays
/// deleted. Ordering, copying and deleting the selected key live in the page editor's
/// "按键位置" section, next to the key's fields.
struct KeyboardChromeKeysEditor: View {
    @Binding var chrome: KeyboardPageChrome
    @Binding var selected: KeyboardPageKeyPath
    /// A categorized page's left rail is category navigation, so it has no authored keys.
    var allowsLeading = true

    var body: some View {
        Section("底行按键") {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    chips(region: .bottom)
                    addButton(.bottom, label: "添加底行按键")
                }
            }
        }
        Section("右侧栏") {
            chips(region: .trailing)
            addButton(.trailing, label: "添加按键")
        }
        if allowsLeading {
            Section("左侧栏") {
                chips(region: .leading)
                addButton(.leading, label: "添加按键")
            }
        }
        if !chrome.trailing.isEmpty || (allowsLeading && !chrome.leading.isEmpty) {
            Section {
                if !chrome.trailing.isEmpty {
                    Toggle("右侧栏延伸到底行", isOn: $chrome.trailingSpansBottom)
                    OptionalWidthField(title: "右侧栏宽度", placeholder: "跟随键盘", value: $chrome.trailingWidth)
                }
                if allowsLeading && !chrome.leading.isEmpty {
                    OptionalWidthField(title: "左侧栏宽度", placeholder: "跟随键盘", value: $chrome.leadingWidth)
                }
            } header: {
                Text("栏宽")
            } footer: {
                Text("留空时跟随键盘。")
            }
        }
    }

    private func chips(region: KeyboardPageChrome.Region) -> some View {
        let keys = chrome.keys(in: region)
        return ForEach(keys.indices, id: \.self) { index in
            KeyChip(label: keys[index].label, isSelected: selected == .chrome(region, key: index)) {
                selected = .chrome(region, key: index)
            }
        }
    }

    @ViewBuilder
    private func addButton(_ region: KeyboardPageChrome.Region, label: String) -> some View {
        let full = chrome.keys(in: region).count >= LayoutResourceBudget.keysPerRegion
        if region == .bottom {
            Button {
                append(region)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(full)
            .accessibilityLabel(label)
        } else {
            Button(label, systemImage: "plus") { append(region) }
                .buttonStyle(.borderless)
                .disabled(full)
        }
    }

    /// Rail keys size by relative height; the footer sizes by relative width.
    private func newKey(_ region: KeyboardPageChrome.Region) -> LayoutKey {
        switch region {
        case .bottom:
            return LayoutKey(label: "空格", action: LayoutAction(.space), titleMode: .automatic)
        case .leading, .trailing:
            return LayoutKey(label: "⌫", action: LayoutAction(.backspace), titleMode: .automatic)
        }
    }

    private func append(_ region: KeyboardPageChrome.Region) {
        let keys = chrome.keys(in: region) + [newKey(region)]
        guard keys.count <= LayoutResourceBudget.keysPerRegion else { return }
        chrome = chrome.settingKeys(keys, in: region)
        selected = .chrome(region, key: keys.count - 1)
    }
}

/// Width text that is currently not a positive number. A form holding one must not save: the
/// field keeps its old value while invalid, so saving would silently write what is not shown.
@MainActor
final class WidthFieldValidity: ObservableObject {
    @Published private(set) var invalidCount = 0
    private var fields: Set<UUID> = []

    nonisolated init() {}

    var isInvalid: Bool { invalidCount > 0 }

    func setInvalid(_ invalid: Bool, for field: UUID) {
        let changed: Bool
        if invalid {
            changed = fields.insert(field).inserted
        } else {
            changed = fields.remove(field) != nil
        }
        if changed { invalidCount = fields.count }
    }
}

private struct WidthFieldValidityKey: EnvironmentKey {
    static var defaultValue: WidthFieldValidity { WidthFieldValidity() }
}

extension EnvironmentValues {
    var widthFieldValidity: WidthFieldValidity {
        get { self[WidthFieldValidityKey.self] }
        set { self[WidthFieldValidityKey.self] = newValue }
    }
}

/// Optional point or relative size: empty means the running keyboard decides. Reads and writes
/// numbers in the user's locale, so a comma decimal separator works where the keypad offers one.
struct OptionalWidthField: View {
    let title: String
    var placeholder = "自动"
    @Binding var value: Double?
    @Environment(\.widthFieldValidity) private var validity: WidthFieldValidity
    @Environment(\.locale) private var locale
    @State private var fieldID = UUID()
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField(placeholder, text: $text)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onChange(of: text) { _, newValue in
                        apply(newValue)
                    }
            }
            if invalid {
                Text("请填写大于 0 的数字，或者留空。").font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear { text = value.map(format) ?? "" }
        .onChange(of: focused) { _, isFocused in
            // Leaving the field drops text that was never accepted, instead of showing an error
            // next to a value the draft does not have.
            if !isFocused { revertInvalidText() }
        }
        .onDisappear { validity.setInvalid(false, for: fieldID) }
    }

    private func format(_ number: Double) -> String {
        if number == number.rounded(), number.magnitude < 1e15 { return String(Int(number)) }
        return String(number).replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    /// Widths never carry grouping, so either decimal mark is read as the decimal point: the
    /// locale's keypad may offer "," and a hardware keyboard may type ".".
    private func parse(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func apply(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
            mark(false)
            return
        }
        if let number = parse(trimmed), number.isFinite, number > 0 {
            value = number
            mark(false)
        } else {
            mark(true)
        }
    }

    private func mark(_ isInvalid: Bool) {
        invalid = isInvalid
        validity.setInvalid(isInvalid, for: fieldID)
    }

    private func revertInvalidText() {
        guard invalid else { return }
        text = value.map(format) ?? ""
        mark(false)
    }
}
