import LayoutKit
import SwiftUI

/// Shared structural editor for main layouts and direct-input pages.
struct KeyboardRowsEditor: View {
    @Binding var rows: [LayoutRow]
    @Binding var selected: LayoutKeyPath
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
                            rows.remove(at: row)
                            selected = .row(0, key: 0)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(rows.count == 1).accessibilityLabel("删除这一行")
                    }
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(rows[row].keys.indices, id: \.self) { index in
                                Button(rows[row].keys[index].label) { selected = .row(row, key: index) }
                                    .buttonStyle(.bordered)
                                    .tint(selected == .row(row, key: index) ? .accentColor : .secondary)
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

struct KeyboardSplitEditor: View {
    let rows: [LayoutRow]
    /// Optional row names; the page editor labels its authored footer row "页底".
    var rowTitles: [String] = []
    @Binding var split: LayoutSplitConfiguration?
    var allowsInheritance = false
    var inheritanceTitle = "跟随主布局开关与间距"
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
        guard var split else { return nil }
        split.rowBreaks = rows.indices.map { row in
            split.breakIndex(row: row, keyCount: rows[row].keys.count)
        }
        return split
    }
}

/// One authored function-key region. Empty arrays are deliberate: a deleted key stays deleted.
struct KeyboardChromeKeysEditor: View {
    @Binding var chrome: KeyboardPageChrome
    @Binding var selected: KeyboardPageKeyPath
    /// A categorized page's left rail is category navigation, so it has no authored keys.
    var allowsLeading = true

    var body: some View {
        Section("页底按键") {
            chips(region: .bottom)
        }
        Section("右侧栏") {
            rail(region: .trailing)
        }
        if allowsLeading {
            Section("左侧栏") {
                rail(region: .leading)
            }
        }
        if !chrome.trailing.isEmpty || (allowsLeading && !chrome.leading.isEmpty) {
            Section {
                if !chrome.trailing.isEmpty {
                    Toggle("右侧栏延伸到页底", isOn: $chrome.trailingSpansBottom)
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

    @ViewBuilder
    private func chips(region: KeyboardPageChrome.Region) -> some View {
        let keys = chrome.keys(in: region)
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(keys.indices, id: \.self) { index in
                    Button(keys[index].label) { selected = .chrome(region, key: index) }
                        .buttonStyle(.bordered)
                        .tint(selected == .chrome(region, key: index) ? .accentColor : .secondary)
                }
                Button {
                    append(region)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(keys.count >= LayoutResourceBudget.keysPerRegion)
                .accessibilityLabel("添加页底按键")
            }
        }
        if case .chrome(let selectedRegion, let index) = selected,
            selectedRegion == region, keys.indices.contains(index)
        {
            Button("删除选中按键", role: .destructive) { remove(region, index) }
        }
    }

    @ViewBuilder
    private func rail(region: KeyboardPageChrome.Region) -> some View {
        let keys = chrome.keys(in: region)
        ForEach(keys.indices, id: \.self) { index in
            HStack {
                Button(keys[index].label) { selected = .chrome(region, key: index) }
                    .buttonStyle(.bordered)
                    .tint(selected == .chrome(region, key: index) ? .accentColor : .secondary)
                Spacer()
                Button {
                    move(region, index, by: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(index == 0).accessibilityLabel("上移这个按键")
                Button {
                    move(region, index, by: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .disabled(index == keys.count - 1).accessibilityLabel("下移这个按键")
                Button(role: .destructive) {
                    remove(region, index)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除这个按键")
            }
        }
        Button("添加按键", systemImage: "plus") { append(region) }
            .disabled(keys.count >= LayoutResourceBudget.keysPerRegion)
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
        var keys = chrome.keys(in: region)
        guard keys.count < LayoutResourceBudget.keysPerRegion else { return }
        keys.append(newKey(region))
        setKeys(keys, in: region)
        selected = .chrome(region, key: keys.count - 1)
    }

    private func remove(_ region: KeyboardPageChrome.Region, _ index: Int) {
        var keys = chrome.keys(in: region)
        guard keys.indices.contains(index) else { return }
        keys.remove(at: index)
        setKeys(keys, in: region)
        if keys.isEmpty {
            if !chrome.bottom.isEmpty {
                selected = .chrome(.bottom, key: chrome.bottom.count - 1)
            } else if !chrome.trailing.isEmpty {
                selected = .chrome(.trailing, key: chrome.trailing.count - 1)
            } else if !chrome.leading.isEmpty {
                selected = .chrome(.leading, key: chrome.leading.count - 1)
            }
        } else {
            selected = .chrome(region, key: min(index, keys.count - 1))
        }
    }

    private func move(_ region: KeyboardPageChrome.Region, _ index: Int, by offset: Int) {
        var keys = chrome.keys(in: region)
        let target = index + offset
        guard keys.indices.contains(index), keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        setKeys(keys, in: region)
        selected = .chrome(region, key: target)
    }

    private func setKeys(_ keys: [LayoutKey], in region: KeyboardPageChrome.Region) {
        switch region {
        case .bottom: chrome.bottom = keys
        case .leading: chrome.leading = keys
        case .trailing: chrome.trailing = keys
        }
    }
}

/// Width text that is currently not a positive number. A form holding one must not save: the
/// field keeps its old value while invalid, so saving would silently write what is not shown.
final class WidthFieldValidity: ObservableObject, @unchecked Sendable {
    @Published private(set) var invalidCount = 0
    private var fields: Set<UUID> = []

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

/// Optional point or relative size: empty means the running keyboard decides.
struct OptionalWidthField: View {
    let title: String
    var placeholder = "自动"
    @Binding var value: Double?
    @Environment(\.widthFieldValidity) private var validity: WidthFieldValidity
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
                Text("请填写大于 0 的数字，留空则自动。").font(.footnote).foregroundStyle(.red)
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
        return String(number)
    }

    private func apply(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
            mark(false)
            return
        }
        if let number = Double(trimmed), number.isFinite, number > 0 {
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
