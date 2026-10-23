import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// Common detail skeleton for each install source (`UserTerminology` terms):
///  - Status: in use / not applied (consistent between Host and keyboard);
///  - Input methods: the schemas in the source (dynamic, any number, any naming);
///  - Keyboard layout: 26 / 14 / 9 / custom layouts, combined with the source's capabilities;
///  - Model management belongs to a specific source; expert items such as code verification stay in Settings > Advanced.
/// Details for custom pinyin are adapted here; generic imported-source details (the built-in scheme included)
/// live in SchemePackageDetailView (same structural convention).

// MARK: - Custom pinyin detail (dictionary association here; dictionary management in the home tools)

/// Custom pinyin: detail of a scheme generated from a dictionary. The dictionary in use, entry count and management entry are on this page;
/// starting use is an explicit action; when old dictionary A is in use and new dictionary B is installed, both relations are shown.
struct CustomPinyinDetailView: View {
    @StateObject private var imports = DictionaryImportCenter.shared
    @State private var selectedRevision: String?
    @State private var selectedDictionaryName: String?
    @State private var applied: Bool = false
    /// Immutable snapshot of the shared publish selection (held in `@State`; `body` derives pure values only and never touches disk).
    @State private var selection = AppliedSelectionSnapshot.none
    /// Latest-wins refresh coordinator: `.onChange` only bumps the key and never creates a read Task.
    @State private var refresh = DetailRefreshCoordinator()
    @State private var choices: InputConfigurationChoices?
    @State private var choicesReadError: String?

    var body: some View {
        List {
            statusSection
            dictionarySection
            inputMethodSection
        }
        .navigationTitle("自定义拼音")
        .navigationBarTitleDisplayMode(.inline)
        // Structured: selection reads are driven by refresh.key (once on first frame; the old task is cancelled and rerun on change).
        // `.onChange` only bumps the key and never creates a read Task (structured / latest-wins).
        .task(id: refresh.key) {
            await imports.refresh()
            await reloadSelection()
            await reloadChoices()
        }
        .onChange(of: imports.selectionRevision) { _, _ in refresh.requestRefresh() }
    }

    private var usingInstalledRevision: Bool {
        guard applied, let installed = imports.installed else { return false }
        return selectedRevision == installed.installation.revision
    }

    private var statusSection: some View {
        Section("状态") {
            if applied && !usingInstalledRevision {
                let inUse = selectedDictionaryName.map { "「\($0)」" } ?? "旧版本"
                Text("\(UserTerminology.statusInUse)\(inUse) · 有新版本")
            } else {
                Text(applied ? UserTerminology.statusInUse : UserTerminology.statusNotApplied)
            }
            if let summary = imports.installedSummary {
                LabeledRow(label: "条目数", value: "\(summary.entryCount) 条")
            }
            // 正在使用 already says it all; the action is only offered when it would change something.
            if !usingInstalledRevision {
                Button(applied ? UserTerminology.startUsingNewVersion : UserTerminology.startUsing) {
                    imports.apply()
                }
                .disabled(imports.busy)
            }
        }
    }

    /// Dictionary in use: in-use / installed shown as separate rows or merged into one.
    private var dictionarySection: some View {
        Section("使用的词库") {
            if let summary = imports.installedSummary {
                if usingInstalledRevision {
                    LabeledRow(label: UserTerminology.statusInUse, value: summary.name)
                } else if applied, let name = selectedDictionaryName {
                    LabeledRow(label: UserTerminology.statusInUse, value: name)
                    LabeledRow(label: "已安装", value: "\(summary.name) · \(UserTerminology.statusNotApplied)")
                } else {
                    LabeledRow(label: "已安装", value: summary.name)
                }
                if summary.entryCount > 0 {
                    LabeledRow(label: "条目数", value: "\(summary.entryCount) 条")
                }
            } else {
                Text(imports.installed == nil ? "未安装词库" : "正在读取…")
                    .font(.footnote).foregroundStyle(.secondary)
                if imports.installed == nil {
                    Button("重新读取") { Task { await imports.refresh() } }
                }
            }
            NavigationLink("管理词库") { DictionaryImportView() }
        }
    }

    /// Input methods: schemas actually deployed from the installed dictionary; keyboard layouts come from capability combination.
    private var inputMethodSection: some View {
        Section {
            if let choices {
                ForEach(choices.inputMethods) { method in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(method.name).font(.body)
                            Spacer()
                            if applied, currentSchemaIDs.contains(method.id) {
                                Text(UserTerminology.statusInUse)
                                    .font(.footnote).foregroundStyle(.green)
                            }
                        }
                        Text(
                            UserTerminology.keyboardLayoutLine(
                                method.availableLayouts.map { UserTerminology.layoutName($0) })
                                ?? "\(UserTerminology.keyboardLayout)：—"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(choicesReadError ?? "正在读取…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink("试打") {
                InstalledSourceTryView(
                    name: "自定义拼音", inUse: applied,
                    howToUse: UserTerminology.tryHowToUseViaStartUsing)
            }
        } header: {
            Text(UserTerminology.inputMethod)
        } footer: {
            Text("以下输入方式来自你导入的词库。")
        }
    }

    private var currentSchemaIDs: Set<String> {
        selection.activeSchemaIDs(resourceKind: KeyboardRecipeStore.ResourceKind.userDictionary.rawValue)
    }

    /// Structured async read (latest-wins): an old result never overwrites a newer snapshot; nothing is written after cancellation.
    /// On failure the userDictionary fields this detail cares about are cleared, matching the old "unreadable means applied=false"
    /// behavior.
    private func reloadSelection() async {
        let token = refresh.beginRead()
        let outcome = await AppliedSelectionLoader.load()
        guard !Task.isCancelled, refresh.accepts(token) else { return }
        if let snapshot = outcome.snapshot {
            selection = snapshot
            applied = snapshot.isApplied(
                resourceKind: KeyboardRecipeStore.ResourceKind.userDictionary.rawValue)
            selectedRevision = snapshot.revision
            selectedDictionaryName = snapshot.dictionaryName
        } else {
            selection = .none
            applied = false
            selectedRevision = nil
            selectedDictionaryName = nil
        }
    }

    private func reloadChoices() async {
        guard imports.installed != nil else {
            choices = nil
            choicesReadError = nil
            return
        }
        do {
            choices = (try await imports.tryResources()).map { InputConfigurationChoices(resourceSet: $0) }
            choicesReadError = nil
        } catch {
            choices = nil
            HostLog.append("dictionary choices read failed: \(error.localizedDescription)")
            choicesReadError = "无法读取可用的输入方式与键盘布局，请重试。"
        }
    }
}

/// Trial typing for a source detail: standard text field + system keyboard; states whether the keyboard is using this source.
private struct InstalledSourceTryView: View {
    let name: String
    let inUse: Bool
    let howToUse: String

    var body: some View {
        SystemKeyboardTestView(
            title: "试打",
            context: SystemKeyboardTestView.sourceContext(name: name, inUse: inUse, howToUse: howToUse))
    }
}
