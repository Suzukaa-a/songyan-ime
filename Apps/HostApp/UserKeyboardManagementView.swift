import KeyboardCore
import LayoutKit
import SwiftUI

/// 我的键盘: the only place to choose what is on the keyboard. Pairs are grouped by input method; the
/// toggles edit a draft published once by "Save", while "Use" on a card publishes the draft plus that
/// pair and switches to it right away. The pair in use is marked 正在使用.
struct UserKeyboardManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var center: UserKeyboardCenter
    private let returnsToSource: Bool
    @State private var selectedIDs: Set<String> = []
    @State private var baselineIDs: Set<String> = []
    @State private var initialized = false
    @State private var hasEditedSelection = false
    @State private var confirmingDiscard = false
    @State private var isSaving = false

    init(
        center: UserKeyboardCenter? = nil, source: UserKeyboardSource = .active,
        returnsToSource: Bool = false
    ) {
        self.returnsToSource = returnsToSource
        _center = StateObject(wrappedValue: center ?? .scoped(to: source))
    }

    var body: some View {
        List {
            statusSection
            if case .ready = center.phase {
                ForEach(groups, id: \.id) { group in
                    Section(group.name) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: 12)], spacing: 12) {
                            ForEach(group.items) { item in
                                keyboardCard(item, inputMethod: group.name)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                if groups.isEmpty {
                    Section { Text(UserTerminology.userKeyboardEmptyHint).foregroundStyle(.secondary) }
                } else {
                    if needsOneKeyboard {
                        Section {
                            Label(UserTerminology.userKeyboardSaveNeedsOne, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Text(UserTerminology.userKeyboardFootnote)
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(UserTerminology.userKeyboard)
        .navigationBarTitleDisplayMode(.inline)
        // With unsaved changes, going back directly (discarding the draft) is not allowed: becomes "Cancel" with a second confirmation.
        .navigationBarBackButtonHidden(hasChanges || isSaving || center.busyKeyboardID != nil)
        .interactiveDismissDisabled(isSaving || center.busyKeyboardID != nil)
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃更改", role: .destructive) {
                guard !isSaving, center.busyKeyboardID == nil else { return }
                resetDraft()
                dismiss()
            }
            .disabled(isSaving || center.busyKeyboardID != nil)
            Button("继续编辑", role: .cancel) {}
        }
        .toolbar {
            if hasChanges, !isSaving, center.busyKeyboardID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        guard !isSaving, center.busyKeyboardID == nil else { return }
                        confirmingDiscard = true
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .accessibilityIdentifier("userKeyboard.save")
                    .disabled(!canSave)
            }
        }
        .task {
            await center.refresh()
            resetDraft()
        }
        .refreshable {
            guard !hasChanges, !isSaving, center.busyKeyboardID == nil else { return }
            await center.refresh()
            resetDraft()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch center.phase {
        case .loading:
            Section { ProgressView("正在读取键盘…") }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Button("重新读取") {
                    Task {
                        await center.refresh()
                        resetDraft()
                    }
                }
            }
        case .readOnly(let message):
            Section {
                Label(message, systemImage: "info.circle").foregroundStyle(.secondary)
                if returnsToSource {
                    Button(UserTerminology.inputScheme) { dismiss() }
                } else {
                    NavigationLink(UserTerminology.inputScheme) { InputSchemeListView() }
                }
            }
        case .needsSource:
            Section {
                Label(UserTerminology.userKeyboardNeedsSourceHint, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                if returnsToSource {
                    Button(UserTerminology.inputScheme) { dismiss() }
                } else {
                    NavigationLink(UserTerminology.inputScheme) { InputSchemeListView() }
                }
            }
        case .ready:
            if center.sourceNeedsUpdate {
                Section {
                    Text("输入方案已更新，轻点「保存」即可使用新版本。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if isSaving || center.busyKeyboardID != nil {
                Section { ProgressView(UserTerminology.userKeyboardSaving) }
            } else if center.resultMessage == nil,
                let current = items.first(where: { $0.id == center.currentKeyboardID })
            {
                Section {
                    LabeledContent(UserTerminology.statusInUse, value: current.keyboard.title)
                }
            }
            if let result = center.resultMessage {
                Section {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.green)
                    NavigationLink("试打当前键盘") { TryInputView() }
                }
            }
            if let error = center.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("知道了") { center.dismissMessages() }
                }
            }
        }
    }

    private struct Item: Identifiable {
        let id: String
        let inputMethodID: String
        let inputMethodName: String
        let layout: KeyboardLayoutKind
        var keyboard: UserKeyboard {
            UserKeyboard(inputMethodID: inputMethodID, inputMethodName: inputMethodName, layout: layout)
        }
    }

    private struct Group {
        let id: String
        let name: String
        let items: [Item]
    }

    private var items: [Item] {
        let published = center.publishedKeyboards.map {
            Item(
                id: $0.id, inputMethodID: $0.inputMethodID,
                inputMethodName: displayName($0.inputMethodName), layout: $0.layout)
        }
        let addable = center.addableKeyboards.map {
            Item(
                id: $0.id, inputMethodID: $0.inputMethodID,
                inputMethodName: displayName($0.inputMethodName), layout: $0.layout)
        }
        var seen = Set<String>()
        return (published + addable).filter { seen.insert($0.id).inserted }
    }

    private var groups: [Group] {
        var order: [String] = []
        var grouped: [String: [Item]] = [:]
        var names: [String: String] = [:]
        for item in items {
            if grouped[item.inputMethodID] == nil { order.append(item.inputMethodID) }
            grouped[item.inputMethodID, default: []].append(item)
            names[item.inputMethodID] = item.inputMethodName
        }
        return order.map { Group(id: $0, name: names[$0] ?? "输入方式", items: grouped[$0] ?? []) }
    }

    private var hasChanges: Bool { initialized && hasEditedSelection && selectedIDs != baselineIDs }

    /// Keyboards turned on in the draft (in page order).
    private var selectedRoster: [UserKeyboard] {
        items.filter { selectedIDs.contains($0.id) }.map(\.keyboard)
    }

    /// No keyboard turned on after the change: cannot save, explained in place.
    private var needsOneKeyboard: Bool { hasChanges && selectedRoster.isEmpty }

    /// The current source must be edited then saved; a non-current source can save its existing list to switch back; an empty list can never be published.
    private var canSave: Bool {
        guard case .ready = center.phase else { return false }
        return initialized && (selectedIDs != baselineIDs || !center.sourceIsCurrent) && !selectedRoster.isEmpty
            && !isSaving && center.busyKeyboardID == nil && center.supportsManagement
    }

    private func displayName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? UserTerminology.inputMethod : name
    }

    private var isBusy: Bool { isSaving || center.busyKeyboardID != nil }

    /// The card body toggles the pair in the draft; the footer is either 正在使用 or a separate "Use" button.
    private func keyboardCard(_ item: Item, inputMethod: String) -> some View {
        let selected = selectedIDs.contains(item.id)
        let inUse = center.currentKeyboardID == item.id
        let name = UserTerminology.userKeyboardToggleLabel(inputMethod: inputMethod, layout: item.layout)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                binding(for: item.id).wrappedValue.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    UserKeyboardMiniature(layout: item.layout)
                        .frame(height: 86)
                        .accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline) {
                        Text(UserTerminology.layoutName(item.layout))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy || !center.supportsManagement)
            .accessibilityIdentifier("userKeyboard.card." + item.id)
            .accessibilityLabel(name)
            .accessibilityValue(
                selected ? UserTerminology.userKeyboardSelected : UserTerminology.userKeyboardNotSelected
            )
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityHint(UserTerminology.userKeyboardDraftHint)
            if inUse {
                Label(UserTerminology.statusInUse, systemImage: "checkmark")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .frame(minHeight: 28)
                    .accessibilityLabel("\(name)，\(UserTerminology.statusInUse)")
            } else {
                Button(UserTerminology.startUsing) { use(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || !center.supportsManagement)
                    .accessibilityIdentifier("userKeyboard.use." + item.id)
                    .accessibilityLabel("\(UserTerminology.startUsing)\(name)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? Color.accentColor.opacity(0.08) : Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
        )
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { enabled in
                if enabled { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
                hasEditedSelection = true
                center.dismissMessages()
            })
    }

    private func resetDraft() {
        let ids = Set(center.publishedKeyboards.map(\.id))
        // Offer one usable starting point without publishing a choice the user has not confirmed.
        let suggested = items.first(where: { $0.layout == .qwerty26 }) ?? items.first
        selectedIDs = ids.isEmpty ? Set(suggested.map { [$0.id] } ?? []) : ids
        baselineIDs = ids
        hasEditedSelection = false
        initialized = true
    }

    @MainActor
    private func save() {
        guard canSave else { return }
        let roster = selectedRoster
        // Block dismissal synchronously before the asynchronous transaction starts.
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            if await center.apply(roster) { resetDraft() }
        }
    }

    /// "Use now": publishes the draft with this pair added and switches the keyboard to it.
    @MainActor
    private func use(_ item: Item) {
        guard case .ready = center.phase, initialized, !isBusy, center.supportsManagement else { return }
        let roster = items.filter { selectedIDs.contains($0.id) || $0.id == item.id }.map(\.keyboard)
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            if await center.apply(roster, selecting: item.keyboard) { resetDraft() }
        }
    }
}

/// Draws the shipped key positions and labels instead of a generic keyboard icon.
private struct UserKeyboardMiniature: View {
    let layout: KeyboardLayoutKind

    var body: some View {
        Canvas { context, size in
            guard let definition = BuiltinLayouts.all.first(where: { $0.id == layout.rawValue }) else { return }
            let rows = definition.rows
            let gap: CGFloat = 2
            let height = (size.height - gap * CGFloat(max(rows.count - 1, 0))) / CGFloat(max(rows.count, 1))
            for (rowIndex, row) in rows.enumerated() {
                let total = row.keys.reduce(0) { $0 + $1.widthWeight }
                let usable = size.width - gap * CGFloat(max(row.keys.count - 1, 0))
                var x: CGFloat = 0
                for key in row.keys {
                    let width = usable * CGFloat(key.widthWeight / max(total, 1))
                    let rect = CGRect(x: x, y: CGFloat(rowIndex) * (height + gap), width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.primary.opacity(0.09)))
                    let label = Text(key.label).font(.system(size: min(9, width * 0.65))).foregroundColor(.primary)
                    context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
                    x += width + gap
                }
            }
        }
    }
}
