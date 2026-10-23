import AppearanceKit
import CandidateKit
import KeyboardCore
import PackageManager
import SwiftUI

/// Advanced (Settings > Advanced): DIY keyboard layouts, input-code verification, resource diagnostics (the grammar model lives in Input Options).
///
/// These are expert items: the normal path (the four home groups and the main path of each detail page) does not surface them, but the features are fully kept.
/// Terminology matches the normal path (input method / keyboard layout).
///
/// **Diagnostics/self-test policy**: resource diagnostics and self-tests only appear once Developer Options is on;
/// the built-in resource check additionally requires that Release shows no built-in package (`ProductionInputAvailability`).
/// A regular Release build's Advanced page has no built-in package wording or debug entry points.
struct AdvancedSettingsView: View {
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    @AppStorage(
        KeyboardLifecycleDiagnostics.lifecycleKey,
        store: UserDefaults(suiteName: KeyboardRecipeStore.groupID))
    private var lifecycleDiagnostics = false

    var body: some View {
        List {
            Section {
                NavigationLink("自定义键盘布局") { LayoutManagementView() }
                    .accessibilityIdentifier("advanced.customLayouts")
            }

            Section {
                NavigationLink("扩展功能") { LuaComponentsView() }
                    .accessibilityIdentifier("advanced.extensions")
            }

            Section {
                NavigationLink("诊断日志") { InstallationLogView() }
                    .accessibilityIdentifier("advanced.logs")
            }

            // Expert items (input-code verification) and diagnostics only appear once
            // Developer Options is on, so regular users never land on an empty page or see author-facing terms.
            if developerOptions {
                Section {
                    NavigationLink("输入码验证") { InputBindingValidationView() }
                } header: {
                    Text("专家工具")
                }
            }

            // Diagnostics and self-tests follow the Developer Options policy: hidden entirely while it is off.
            if developerOptions {
                Section {
                    NavigationLink("引擎与集成状态") { EngineStatusView() }
                    NavigationLink("内置资源检查（开发）") { ResourceCheckView() }
                    Toggle("记录键盘生命周期", isOn: $lifecycleDiagnostics)
                        .accessibilityIdentifier("advanced.lifecycleDiagnostics")
                        .accessibilityHint("记录进程、切换与启动耗时，便于排查问题")
                } header: {
                    Text("资源诊断（开发者）")
                }
            }
        }
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InstallationLogView: View {
    @State private var content = "正在读取…"
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            Text(content)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: content) { Label("分享", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("清空日志", systemImage: "trash")
            }
        }
        .confirmationDialog("清空诊断日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    content = await HostLog.clear() ? "日志已清空" : "无法清空日志"
                }
            }
        }
        .task { content = await HostLog.recent() ?? "暂无日志" }
    }
}

// MARK: - Input-code verification (choose the owning source)

/// Source picker for input-code verification; each source opens its own verification form.
struct InputBindingValidationView: View {
    @ObservedObject private var center = SchemeImportCenter.shared

    var body: some View {
        List {
            if center.installedPackages.isEmpty {
                Text("请先导入输入方案，再验证输入码与候选词。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(center.installedPackages) { package in
                NavigationLink(package.name) {
                    List { InputBindingValidationForm(packageID: package.id) }
                        .navigationTitle(package.name)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .navigationTitle("输入码验证")
        .navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
    }
}

/// Input-code verification form (expert item): verifies "input code -> expected candidate" on the real engine,
/// and only saves it as the association for this keyboard layout and input method on success; re-verify after resources update.
struct InputBindingValidationForm: View {
    let packageID: String
    @ObservedObject private var center = SchemeImportCenter.shared
    @State private var schemaID = ""
    @State private var layout: KeyboardLayoutKind?
    @State private var code = ""
    @State private var candidate = ""
    @State private var error: String?
    @State private var saved = false

    private var item: SchemeImportCenter.InstalledPackage? {
        center.installedPackages.first { $0.id == packageID }
    }

    var body: some View {
        Group {
            if let item {
                Menu {
                    ForEach(item.schemas) { schema in
                        Button(schema.name.isEmpty ? schema.id : schema.name) {
                            schemaID = schema.id
                            reset()
                            layout = defaultLayout(for: schema.id)
                        }
                    }
                } label: {
                    HStack {
                        Text(UserTerminology.inputMethod)
                        Spacer()
                        Text(currentSchemaName(item)).foregroundStyle(.secondary)
                    }
                }
                Menu {
                    ForEach(KeyboardLayoutKind.allCases) { kind in
                        Button(UserTerminology.layoutName(kind)) {
                            layout = kind
                            reset()
                        }
                    }
                } label: {
                    HStack {
                        Text(UserTerminology.keyboardLayout)
                        Spacer()
                        Text(layout.map { UserTerminology.layoutName($0) } ?? "未设置").foregroundStyle(.secondary)
                    }
                }
                TextField("输入码（此键盘布局实际发送的逻辑键，如 ni）", text: $code)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("输入这些键后期望出现的完整词（如 你）", text: $candidate)
                Button {
                    guard let resolved = resolvedSchemaID(item), let layout else { return }
                    error = nil
                    saved = false
                    let binding = SchemeInputBinding(
                        layout: layout.rawValue, schemaID: resolved,
                        code: code, candidate: candidate)
                    Task {
                        do {
                            try await center.validateBinding(binding, packageID: packageID)
                            saved = true
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("验证并保存关联", systemImage: "checkmark.seal")
                }
                .disabled(center.busy || code.isEmpty || candidate.isEmpty || layout == nil)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                if saved { Label("已验证并保存关联", systemImage: "checkmark.circle").font(.footnote) }
                Text("测试通过后保存。更新输入方案后需要重新验证。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("未找到此方案，可能已被移除。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .task {
            await center.refresh()
            guard schemaID.isEmpty, let item else { return }
            let resolved = resolvedSchemaID(item) ?? ""
            schemaID = resolved
            layout = defaultLayout(for: resolved)
        }
    }

    private func currentSchemaName(_ item: SchemeImportCenter.InstalledPackage) -> String {
        let resolved = resolvedSchemaID(item)
        return item.schemas.first { $0.id == resolved }
            .map { UserTerminology.inputMethodName($0) } ?? "未设置"
    }

    private func resolvedSchemaID(_ item: SchemeImportCenter.InstalledPackage) -> String? {
        if !schemaID.isEmpty, item.schemas.contains(where: { $0.id == schemaID }) { return schemaID }
        return item.schemas.first?.id
    }

    /// Capability-first default layout: the first really usable keyboard layout for the input method; nothing is invented when there is no information.
    private func defaultLayout(for schemaID: String) -> KeyboardLayoutKind? {
        center.inputConfiguration(packageID: packageID)?.firstAvailableLayout(for: schemaID)
            ?? KeyboardLayoutKind.allCases.first
    }

    private func reset() {
        saved = false
        error = nil
    }
}
