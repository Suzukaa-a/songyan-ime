import KeyboardCore
import SwiftUI
import UniformTypeIdentifiers

/// Dictionary management page: installed dictionary name, entry count, status, plus dictionary import.
/// A dictionary is an independent resource: its file name is never used as an input-scheme title;
/// "view input scheme" goes to the custom-pinyin detail. The apply button shares the explicit apply path with the scheme list.
struct DictionaryImportView: View {
    @StateObject private var center = DictionaryImportCenter.shared
    @State private var choosingFile = false
    @State private var confirmingReplace = false
    @State private var enteringURL = false
    @State private var dependencyPath: String?
    @State private var address = ""
    @State private var addressError: String?
    /// Value snapshot of the shared publication selection (read on the read queue; body only derives, never touches disk).
    @State private var appliedRecipeEnabled = false
    @State private var appliedKind: KeyboardRecipeStore.ResourceKind?
    @State private var appliedDictionaryRevision: String?
    @State private var appliedDictionaryNameValue: String?
    @State private var refreshTick = 0

    var body: some View {
        List {
            installedSection

            Section {
                Button("从文件导入") {
                    dependencyPath = nil
                    choosingFile = true
                }
                Button("从链接导入") { openURL(nil) }
            } header: {
                Text("导入词库")
            } footer: {
                Text("支持带拼音的 RIME 词库文件（.dict.yaml）。安装后，在本页轻点「使用」即可打字。")
            }
            .disabled(center.busy)

            if !center.inspections.isEmpty {
                Section("读取结果") {
                    ForEach(center.inspections, id: \.path) { source in
                        VStack(alignment: .leading) {
                            Text(source.name).font(.headline)
                            Text("\(source.entryCount) 条 · \(source.path)").font(.caption)
                            if source.normalizesToneMarks {
                                Text("会自动去除声调（ü 记作 v）").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !center.missing.isEmpty {
                Section("还缺少以下词库文件") {
                    ForEach(center.missing, id: \.self) { path in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(path).font(.subheadline).textSelection(.enabled)
                            HStack {
                                Button("选择文件") {
                                    dependencyPath = path
                                    choosingFile = true
                                }
                                Button("从链接下载") { openURL(path) }
                            }.buttonStyle(.borderless)
                        }
                    }
                }.disabled(center.busy)
            }
            if center.canPrepare || center.prepared != nil || center.busy || center.message != nil
                || center.error != nil
            {
                Section {
                    if center.canPrepare {
                        Button("下一步") { center.prepare() }.disabled(center.busy)
                    }
                    if let prepared = center.prepared {
                        Text("共 \(prepared.entryCount) 条词条")
                            .font(.footnote)
                        Button(center.installed == nil ? "安装" : "安装并替换当前词库") {
                            if center.installed == nil { center.install() } else { confirmingReplace = true }
                        }
                        .disabled(center.busy)
                        .confirmationDialog("替换当前词库？", isPresented: $confirmingReplace, titleVisibility: .visible) {
                            Button("替换", role: .destructive) { center.install() }
                        } message: {
                            Text("新词库将替换已安装的词库，原词库无法恢复。")
                        }
                    }
                    if center.busy { ProgressView() }
                    if let message = center.message { Text(message).font(.footnote) }
                    if let error = center.error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote)
                    }
                } header: {
                    Text("安装")
                }
            }
        }
        .navigationTitle("词库")
        .navigationBarTitleDisplayMode(.inline)
        // Structured: the selection snapshot is read via refreshTick on the read queue; body does not touch disk.
        .task(id: refreshTick) {
            await center.refresh()
            await loadAppliedSelection()
        }
        .onChange(of: center.selectionRevision) { _, _ in refreshTick &+= 1 }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): center.accept(url, dependencyPath: dependencyPath)
            case .failure(let error): center.report(error)
            }
        }
        .sheet(isPresented: $enteringURL) {
            NavigationStack {
                Form {
                    Section(dependencyPath.map { "还需要：\($0)" } ?? "链接") {
                        TextField("https://", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if let addressError { Text(addressError).foregroundStyle(.red).font(.footnote) }
                        Text("请输入 .dict.yaml 文件的链接。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("从链接导入")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { enteringURL = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("读取") {
                            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                                url.scheme?.lowercased() == "https", url.host != nil
                            else {
                                addressError = "请输入以 https:// 开头的链接。"
                                return
                            }
                            center.accept(url, dependencyPath: dependencyPath)
                            enteringURL = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Installed slot: in use vs. pending apply, reported accurately

    /// The dictionary name is a user resource name and is shown verbatim (not translated); in-use state comes from
    /// a revision comparison and never hides an older version that is still in use.
    private var installedSection: some View {
        Group {
            if let summary = center.installedSummary {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "character.book.closed").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.name).font(.body)
                            Text(slotStatusLine)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                    }
                    .padding(.vertical, 2)
                    if !usingInstalledRevision {
                        Button(UserTerminology.startUsing) { center.apply() }
                            .disabled(center.busy)
                    }
                    NavigationLink("查看输入方案") { CustomPinyinDetailView() }
                } header: {
                    Text("已安装词库")
                }
            }
        }
    }

    private var slotStatusLine: String {
        let entryNote = "\(summaryCount) 条"
        if usingInstalledRevision {
            return "\(entryNote) · \(UserTerminology.statusInUse)"
        }
        if appliedDictionaryName != nil {
            return
                "\(entryNote) · \(UserTerminology.statusNotApplied)（\(UserTerminology.statusInUse)「\(appliedDictionaryName!)」）"
        }
        return "\(entryNote) · \(UserTerminology.statusNotApplied)"
    }

    private var summaryCount: Int {
        center.installedSummary?.entryCount ?? 0
    }

    /// Whether the currently applied revision equals this slot's revision (same version in use).
    private var usingInstalledRevision: Bool {
        guard appliedRecipeEnabled, appliedKind == .userDictionary,
            let installed = center.installed
        else { return false }
        return appliedDictionaryRevision == installed.installation.revision
    }

    /// When the applied revision differs, the dictionary name saved at that time; nil if it had none.
    private var appliedDictionaryName: String? {
        guard appliedRecipeEnabled, appliedKind == .userDictionary, !usingInstalledRevision else { return nil }
        return appliedDictionaryNameValue
    }

    /// Structured read of the shared publication selection (read queue); the main thread only applies the value snapshot.
    private func loadAppliedSelection() async {
        let snapshot = await AppliedSelectionLoader.loadSnapshot() ?? .none
        appliedRecipeEnabled = snapshot.recipeEnabled
        appliedKind =
            snapshot.resourceKind.isEmpty
            ? nil
            : KeyboardRecipeStore.ResourceKind(rawValue: snapshot.resourceKind)
        appliedDictionaryRevision = snapshot.revision
        appliedDictionaryNameValue = snapshot.dictionaryName
    }

    private func openURL(_ path: String?) {
        dependencyPath = path
        address = ""
        addressError = nil
        enteringURL = true
    }
}
