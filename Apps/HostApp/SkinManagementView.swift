import AppearanceKit
import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI
import UniformTypeIdentifiers

/// Appearance project file document (for export/import; one file = skin + candidate-bar layout + display mode).
struct SkinFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Keyboard appearance: **one** appearance project decides both the keyboard skin and the candidate-bar layout.
///
/// Production UI has only this one list, no standalone candidate-bar entry and no standalone candidate-bar "Apply".
struct SkinManagementView: View {
    @StateObject private var manager = AppearanceManager.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var importing = false
    @State private var draft: AppearanceDocument?
    @State private var importError: String?
    @State private var savedDestination: AppearanceDocument?
    @State private var showsSaved = false
    var body: some View {
        List {
            Section {
                // Light/dark is part of the applied appearance: applied immediately on selection, no need to open detail and tap Apply.
                Picker(
                    "深浅色",
                    selection: Binding(
                        get: { manager.editingAppearance },
                        set: { mode in
                            guard mode != manager.editingAppearance else { return }
                            manager.editingAppearance = mode
                            manager.apply(manager.applied, persistDraft: false)
                        })
                ) {
                    Text("跟随系统").tag(SkinAppearance.system)
                    Text("浅色").tag(SkinAppearance.light)
                    Text("深色").tag(SkinAppearance.dark)
                }
                .disabled(manager.isLoading)
                if let message = manager.message { Text(message).font(.footnote) }
                if let error = manager.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if let degraded = manager.appliedSourceNotice {
                    Text(degraded).font(.footnote).foregroundStyle(.orange)
                }
                if manager.error != nil {
                    Button("重试") { manager.reload() }
                }
            } footer: {
                Text("选择外观后，在详情页轻点「应用」。")
            }
            Section("外观") {
                ForEach(manager.projects) { project in
                    NavigationLink {
                        AppearanceDetailView(document: project)
                    } label: {
                        let rowLayout =
                            dynamicTypeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 12))
                        rowLayout {
                            SkinThumbnailBadge(
                                document: project,
                                isDark: manager.editingAppearance == .dark
                                    || (manager.editingAppearance == .system && colorScheme == .dark)
                            )
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .font(.body.weight(.medium))
                                Text(manager.candidateSummary(for: project))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let status = manager.applicationStatus(for: project) {
                                    Label(
                                        status,
                                        systemImage: status == UserTerminology.statusInUse
                                            ? "checkmark.circle.fill" : "circle.dashed"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Button {
                importing = true
            } label: {
                Label("导入外观文件", systemImage: "square.and.arrow.down")
            }
            if let importError { Text(importError).foregroundStyle(.red) }
        }.navigationTitle(UserTerminology.keyboardAppearance)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    draft = try AppearanceImportSupport.decode(documentAt: result.get())
                    importError = nil
                } catch { importError = error.localizedDescription }
            }
            .sheet(item: $draft, onDismiss: { if savedDestination != nil { showsSaved = true } }) {
                SkinEditorView(document: $0) { savedDestination = $0 }
            }
            .navigationDestination(isPresented: $showsSaved) {
                if let savedDestination { AppearanceDetailView(document: savedDestination) }
            }
            .onChange(of: showsSaved) { if !showsSaved { savedDestination = nil } }
    }
}

/// Appearance detail: preview (keyboard + candidate bar shown together), edit, apply, export.
/// The candidate-bar layout and skin belong to this one document, so there is no second "Apply" here.
struct AppearanceDetailView: View {
    private let initialDocument: AppearanceDocument
    init(document: AppearanceDocument) { initialDocument = document }
    @ObservedObject private var manager = AppearanceManager.shared
    private var document: AppearanceDocument {
        manager.projects.first(where: { $0.id == initialDocument.id }) ?? initialDocument
    }
    @State private var layoutID = BuiltinLayouts.merged14.id
    @State private var dark = false
    @State private var showsExpandedCandidates = false
    @State private var draft: AppearanceDocument?
    @State private var exporting = false
    @State private var exportDocument = SkinFileDocument(data: Data())
    @State private var error: String?
    @State private var savedDestination: AppearanceDocument?
    @State private var showsSaved = false
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var layouts: [LayoutDefinition] { LayoutManager.shared.registry.layouts }
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("预览布局", selection: $layoutID) { ForEach(layouts) { Text($0.name).tag($0.id) } }
                Toggle("深色预览", isOn: $dark)
                // One preview shows both the skin and the candidate-bar layout (the same appearance project).
                KeyboardPreviewView(
                    layout: layouts.first(where: { $0.id == layoutID }) ?? BuiltinLayouts.merged14,
                    skin: document.skin, candidateBar: document.candidateBar, previewDark: dark)
                VStack(alignment: .leading, spacing: 6) {
                    Text("候选栏").font(.footnote).foregroundStyle(.secondary)
                    CandidateBarPreviewView(
                        bar: document.candidateBar, skin: document.skin,
                        expanded: showsExpandedCandidates, dark: dark)
                    Button(showsExpandedCandidates ? "预览收起" : "预览展开") {
                        showsExpandedCandidates.toggle()
                    }.buttonStyle(.bordered)
                }
                Button("复制并编辑") { draft = document.copy() }.buttonStyle(.bordered)
                if !document.isBuiltin { Button("编辑外观") { draft = document } }
                if let status = manager.applicationStatus(for: document) { Text(status).font(.footnote) }
                if !document.isBuiltin {
                    Button("删除", role: .destructive) { confirmingDelete = true }
                        .confirmationDialog(
                            "删除外观「\(document.name)」？", isPresented: $confirmingDelete, titleVisibility: .visible
                        ) {
                            Button("删除", role: .destructive) {
                                manager.remove(document.id)
                                dismiss()
                            }
                        } message: {
                            Text(
                                manager.applicationStatus(for: document) != nil
                                    ? "将从列表中删除，键盘会继续使用当前外观。"
                                    : "删除后无法恢复。")
                        }
                }
                Button("导出文件") {
                    do {
                        exportDocument = SkinFileDocument(data: try document.encoded())
                        exporting = true
                    } catch { self.error = error.localizedDescription }
                }
                if let message = manager.message { Text(message).font(.footnote) }
                if let managerError = manager.error { Text(managerError).font(.footnote).foregroundStyle(.red) }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        // The preview follows the system light/dark by default, matching the keyboard's actual behavior under "Follow System".
        .onAppear { dark = colorScheme == .dark }
        .safeAreaInset(edge: .bottom) {
            Button {
                manager.apply(document)
            } label: {
                Label("应用", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("appearance.apply")
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .navigationTitle(document.name)
        .sheet(item: $draft, onDismiss: { if savedDestination != nil { showsSaved = true } }) {
            SkinEditorView(document: $0) { saved in
                if saved.id != document.id { savedDestination = saved }
            }
        }
        .navigationDestination(isPresented: $showsSaved) {
            if let savedDestination { AppearanceDetailView(document: savedDestination) }
        }
        .onChange(of: showsSaved) { if !showsSaved { savedDestination = nil } }
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: "\(document.id)\(AppearanceDocument.fileExtension)"
        ) { result in
            if case .failure(let e) = result { error = e.localizedDescription }
        }
    }
}

/// Appearance thumbnail badge: a miniature keyboard visual of panel background, key color, and accent color.
struct SkinThumbnailBadge: View {
    let document: AppearanceDocument
    var isDark: Bool = false

    var body: some View {
        let appearance = KeyboardAppearance(skin: document.skin, dark: isDark)
        ZStack {
            // Panel background
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.color("panel"))

            // Stacked miniature keys
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(appearance.color("key"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(appearance.color("border").opacity(0.5), lineWidth: 0.5)
                        )
                        .frame(width: 14, height: 11)

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(appearance.color("accent"))
                        .frame(width: 14, height: 11)
                }

                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(appearance.color("key"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(appearance.color("border").opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(width: 22, height: 9)
            }
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}
