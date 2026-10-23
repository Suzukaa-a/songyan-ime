import Foundation
import KeyboardCore
import PackageManager
import SwiftUI
import UniformTypeIdentifiers

/// A real source-order entry, sharing the installer's bounded acquisition and transaction.
struct RimeSourceInstallView: View {
    @ObservedObject private var center = SchemeImportCenter.shared
    /// Expert page: Rime source expressions and raw schema IDs are reachable only under developer options.
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    var updatingPackageID: String?
    @State private var target = ""
    @State private var importer = false
    @State private var resourcePath: String?
    @State private var entrySchemaID = ""
    private var schemaIDs: [String] {
        Set(
            center.acquiredSources.flatMap { $0.files.keys }.filter {
                $0.hasSuffix(".schema.yaml") && !$0.contains("/")
            }
            .map { String($0.dropLast(12)) }
        ).sorted()
    }

    private var requirements: [RecipeExternalResource] {
        var seen = Set<String>()
        return center.acquiredSources.flatMap(\.externalResources).filter { seen.insert($0.path).inserted }
    }
    var body: some View {
        Group {
            if developerOptions {
                rimeSourceList
            } else {
                // Defensive: this page is normally reachable only under developer options; if linked from elsewhere it still does not expose internal source expressions.
                Text("此页仅在开发者选项中可用。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("从 Rime 来源安装")
        .onChange(of: entrySchemaID) { _, _ in center.invalidateSourcePlan() }
        .task {
            if let id = updatingPackageID { target = SchemeImportCenter.recordedSourceTarget(packageID: id) ?? "" }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                if let resourcePath {
                    center.provideExternalResource(url, requirementPath: resourcePath)
                } else {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 256 * 1024 else { throw RecipeInstallError.invalidResource("配置文件超过256 KiB") }
                    target = try RimeSourceOrder.parseConfiguration(String(contentsOf: url, encoding: .utf8)).map(
                        \.expression
                    ).joined(separator: "\n")
                }
            } catch { center.report(error) }
        }
    }

    @ViewBuilder
    private var rimeSourceList: some View {
        List {
            Section("Rime 来源（rime-install）") {
                TextEditor(text: $target).frame(minHeight: 85).autocorrectionDisabled().textInputAutocapitalization(
                    .never)
                Text("格式示例：owner/repo@分支:目标配置:参数=值；也可填写 :preset、HTTPS .conf 链接，或分行填写多个来源。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("缺少的官方依赖会自动补齐。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("读取配置文件（.conf）") {
                    resourcePath = nil
                    importer = true
                }
                Button("获取来源 / 检查更新") { center.acquireSource(target, updatingPackageID: updatingPackageID) }
                    .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(center.busy)
            if center.busy {
                Section {
                    ProgressView(center.message ?? "正在处理…")
                    Button("取消") { center.cancelSourceOperation() }
                }
            }
            ForEach(Array(center.acquiredSources.enumerated()), id: \.offset) { index, source in
                Section("步骤 \(index + 1)") {
                    Text(source.order.expression).textSelection(.enabled)
                    Text("固定修订 \(source.revision)").font(.caption.monospaced()).textSelection(.enabled)
                    Text(source.recipe.displayDescription ?? source.recipe.path).font(.footnote)
                    Text("\(source.files.count) 个源码文件，\(source.models.count) 个模型文件").font(.caption)
                }
            }
            ForEach(requirements, id: \.path) { requirement in
                Section("所需资源：\(requirement.path)") {
                    Text(requirement.url.absoluteString).font(.caption).textSelection(.enabled)
                    if let model = center.providedDownloadFiles[requirement.path] {
                        Text(
                            "已提供 \(ByteCountFormatter.string(fromByteCount: Int64(model.size), countStyle: .file)) · SHA256 \(model.sha256)"
                        ).font(.caption)
                    } else if let file = center.providedOrdinaryResources[requirement.path] {
                        Text("已提供 \(file.size) 字节").font(.caption)
                    }
                    Button("下载 / 更新此资源") { center.downloadExternalResource(requirement) }
                    Button("从文件提供") {
                        resourcePath = requirement.path
                        importer = true
                    }
                }.disabled(center.busy)
            }
            if !center.acquiredSources.isEmpty {
                Section {
                    Picker("启用的输入方式", selection: $entrySchemaID) {
                        Text("保持来源配置").tag("")
                        ForEach(schemaIDs, id: \.self) { Text($0).tag($0) }
                    }.disabled(center.busy)
                    Text("选择默认使用的输入方式；不选时沿用方案自带的设置。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("检查安装计划") { center.checkSourcePlan(entrySchemaID: entrySchemaID) }
                        .disabled(center.busy || target != center.sourceTarget)
                    if let plan = center.sourcePlan {
                        Text("按序执行 \(plan.stageReceipts.count) 步，修改 \(plan.changedPaths.count) 个文件。")
                        DisclosureGroup("将安装或修改的文件") {
                            ForEach(plan.changedPaths, id: \.self) { Text($0).font(.caption) }
                        }
                        Button("安装并验证") { center.installSourcePlan() }
                            .disabled(center.busy || target != center.sourceTarget)
                    }
                }
            }
            if let id = center.lastInstalledPackageID, center.acquiredSources.isEmpty {
                Section {
                    Label("安装完成 · \(UserTerminology.statusNotApplied)", systemImage: "checkmark.circle")
                    NavigationLink("\(UserTerminology.startUsing)输入方案") { SchemePackageDetailView(packageID: id) }
                }
            }
            if let error = center.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            Section {
            }
        }
    }
}
