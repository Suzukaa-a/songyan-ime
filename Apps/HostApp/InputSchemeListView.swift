import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// Input schemes: list of installed sources + the single "add input scheme" entry point.
///
/// Information architecture (`UserTerminology`):
/// - one real install source per row (sources with several input methods are not split); the title opens the source detail;
/// - rows use "input method: ..." and "keyboard layout: ..." to explain what the source contains and which front-end layouts can be configured,
///   counts are always dynamic, never "N input schemes inside the input scheme";
/// - any imported source (ZIP / folder / scheme file / HTTPS link) may contain any number of arbitrarily named
///   input methods (shape-code, dialect, bopomofo, etc.); this page is not designed around any particular source;
/// - expert items such as the grammar model are not on this page: they are under Settings > Advanced;
/// - install, update and trial typing do not equal apply; when an old applied version coexists with a new install, the page shows them separately;
/// - the built-in scheme is an installed scheme like any other and is listed first; with nothing published
///   the keyboard falls back to it, so it reads as in use;
/// - a read failure shows an error on the nearest row plus retry.
struct InputSchemeListView: View {
    @StateObject private var center = KeyboardSelectionCenter.shared
    @StateObject private var imports = DictionaryImportCenter.shared
    @StateObject private var schemeImports = SchemeImportCenter.shared
    @State private var selectedKind: KeyboardRecipeStore.ResourceKind?
    @State private var selectedRevision: String?
    @State private var selectedPackageID: String?
    @State private var selectedSchemaID: String?
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    @State private var selectedRecipeEnabled: Bool?
    @State private var selectionError: String?
    @State private var resourceError: String?
    /// Display for custom pinyin, which needs disk reads to resolve; imported sources use the install manifest directly.
    @State private var presentations: [String: SourcePresentation] = [:]
    @State private var engineCapabilities: EngineCapabilities?

    /// Per-source "input methods / keyboard layouts" display (dynamic, from the resource snapshot).
    private struct SourcePresentation: Equatable {
        var inputMethods: [String] = []
        var layouts: [String] = []
    }

    private struct InstalledSchemeRow: Identifiable {
        let id: String
        let name: String
        let inputMethodNames: [String]
        let layoutNames: [String]
        /// Ordinary language status: in use / not applied / in use (older version)...
        let status: String?
        let isSelected: Bool
        /// When an older version is applied and a newer one is installed, the button reads "start using new version".
        let needsNewVersion: Bool
        let isBusy: Bool
        /// Row-level apply when there is a definitely valid input method; nil means choose in the detail.
        let apply: (() -> Void)?
        let destination: AnyView

        var subtitle: String {
            var parts: [String] = []
            if let line = UserTerminology.inputMethodLine(inputMethodNames) { parts.append(line) }
            if let line = UserTerminology.keyboardLayoutLine(layoutNames) { parts.append(line) }
            if let status { parts.append(status) }
            return parts.joined(separator: " · ")
        }
    }

    var body: some View {
        List {
            installedSection
            importEntrySection
            statusSection
            if developerOptions {
                developerSection
                    .task { if engineCapabilities == nil { engineCapabilities = await EngineCapabilities.load() } }
            }
        }
        .navigationTitle(UserTerminology.inputScheme)
        .navigationBarTitleDisplayMode(.inline)
        // Structured: refreshTick is bumped on apply/install state changes; .task(id:) cancels the old task and reruns.
        // No bare Task is created; the main thread does not read disk (selection goes through AppliedSelectionLoader).
        .task(id: refreshTick) {
            await center.refresh()
            await imports.refresh()
            await schemeImports.refresh()
            await loadSelection()
            await loadPresentations()
        }
        .onChange(of: center.applicationPhase) { _, _ in refreshTick &+= 1 }
        .onChange(of: imports.selectionRevision) { _, _ in refreshTick &+= 1 }
        .onChange(of: schemeImports.selectionRevision) { _, _ in refreshTick &+= 1 }
    }

    @State private var refreshTick = 0
    /// Latest-wins token for selection reads: a late read never overwrites a newer value.
    @State private var selectionGeneration: UInt64 = 0

    // MARK: - Installed sources (one row per source; title opens detail, start-using is a separate button)

    private var installedRows: [InstalledSchemeRow] {
        var rows: [InstalledSchemeRow] = []
        let selectionReadable = selectionError == nil

        // Custom pinyin (generated from a dictionary): the dictionary name is resource info and lives in the detail; this row reports only input method/keyboard layout and status.
        if imports.installedSummary != nil || imports.installed != nil {
            rows.append(customPinyinRow(selectionReadable: selectionReadable))
        }

        // Generic imported source: one row per installed package, the built-in scheme first.
        let builtinID = ProductionInputAvailability.builtinPackageID
        for package in schemeImports.installedPackages.filter({ $0.id == builtinID })
            + schemeImports.installedPackages.filter({ $0.id != builtinID })
        {
            rows.append(packageRow(package, selectionReadable: selectionReadable))
        }
        for package in schemeImports.damagedPackages {
            rows.append(
                InstalledSchemeRow(
                    id: "damaged-\(package.id)", name: package.name,
                    inputMethodNames: [], layoutNames: [], status: "已损坏", isSelected: false,
                    needsNewVersion: false, isBusy: schemeImports.busy, apply: nil,
                    destination: AnyView(SchemePackageDetailView(packageID: package.id))))
        }
        return rows
    }

    private func statusText(needsNewVersion: Bool) -> String {
        needsNewVersion
            ? "有新版本"
            : UserTerminology.statusInUse
    }

    private func customPinyinRow(selectionReadable: Bool) -> InstalledSchemeRow {
        let applied = selectionReadable && selectedRecipeEnabled == true && selectedKind == .userDictionary
        let installedRevision = imports.installed?.installation.revision
        let needsNewVersion = applied && installedRevision != nil && selectedRevision != installedRevision
        return InstalledSchemeRow(
            id: "user-dictionary",
            name: "自定义拼音",
            inputMethodNames: presentations["user-dictionary"]?.inputMethods ?? [],
            layoutNames: presentations["user-dictionary"]?.layouts ?? [],
            status: applied ? statusText(needsNewVersion: needsNewVersion) : UserTerminology.statusNotApplied,
            isSelected: applied && !needsNewVersion,
            needsNewVersion: needsNewVersion,
            isBusy: imports.busy || center.isBusy,
            // A dictionary slot has an install-receipt entry, so row-level apply is available; the detail also has explicit apply and dictionary association.
            apply: { imports.apply() },
            destination: AnyView(CustomPinyinDetailView()))
    }

    private func packageRow(
        _ package: SchemeImportCenter.InstalledPackage,
        selectionReadable: Bool
    ) -> InstalledSchemeRow {
        // The built-in scheme is also in use when nothing is published: the keyboard falls back to it.
        let fallback = package.id == ProductionInputAvailability.builtinPackageID && selectedRecipeEnabled != true
        let selected =
            selectionReadable
            && (fallback
                || (selectedRecipeEnabled == true
                    && selectedKind == .userScheme
                    && selectedPackageID == package.id
                    && selectedSchemaID != nil))
        let needsNewVersion = selected && !fallback && selectedRevision != package.active.installation.revision
        return InstalledSchemeRow(
            id: "package-\(package.id)",
            name: package.name,
            inputMethodNames: package.schemas.map { UserTerminology.inputMethodName($0) },
            layoutNames: package.supportedLayouts.map { UserTerminology.layoutName($0) },
            status: selected ? statusText(needsNewVersion: needsNewVersion) : UserTerminology.statusNotApplied,
            isSelected: selected && !needsNewVersion,
            needsNewVersion: needsNewVersion,
            isBusy: schemeImports.busy || center.isBusy,
            // Row-level apply only with a definitely valid entry; otherwise open the detail to view the source status.
            apply: nil,
            destination: AnyView(SchemePackageDetailView(packageID: package.id)))
    }

    private var installedSection: some View {
        Section {
            if installedRows.isEmpty {
                unconfiguredRow
            } else {
                ForEach(installedRows) { row in
                    schemeRow(row)
                }
            }
        } header: {
            Text("已安装")
        }
    }

    /// Explicit empty state when no product source is available (Release never presents built-in package as a configured source).
    private var unconfiguredRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(ProductionInputAvailability.unconfiguredTitle, systemImage: "square.and.arrow.down")
                .font(.subheadline.bold())
            Text("正在使用\(ProductionInputAvailability.fallbackInputMethodName)。添加输入方案可获取更多词库和输入方式。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The row body opens the detail; the trailing start-using/view-detail control is a separate tap target (outside the NavigationLink).
    private func schemeRow(_ row: InstalledSchemeRow) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                row.destination
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "character.book.closed").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name).font(.body)
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)
            if row.isSelected {
                Text(UserTerminology.statusInUse)
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(row.name) \(UserTerminology.statusInUse)")
            } else if let apply = row.apply {
                Button(row.needsNewVersion ? UserTerminology.startUsingNewVersion : UserTerminology.startUsing) {
                    apply()
                }
                .buttonStyle(.borderless)
                .disabled(row.isBusy)
                .accessibilityLabel("\(UserTerminology.startUsing) \(row.name)")
            } else {
                NavigationLink {
                    row.destination
                } label: {
                    Text("查看详情")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("查看输入方案详情")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Add input scheme (single entry point: any source can be imported)

    private var importEntrySection: some View {
        Section {
            NavigationLink {
                SchemePackageImportView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle").font(.title2).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UserTerminology.addInputScheme).font(.body)
                        Text("从推荐、文件或链接添加")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Status (in-progress and real failures only)

    @ViewBuilder
    private var statusSection: some View {
        let applying = center.applicationPhase == .applying
        if applying || selectionError != nil || resourceError != nil || hasApplicationFailure
            || imports.busy || imports.error != nil || schemeImports.error != nil
        {
            Section {
                if applying { ProgressView("正在切换…") }
                if imports.busy { ProgressView("正在准备导入词库…") }
                if let error = selectionError {
                    failureRow("无法读取当前选择", detail: error)
                    Button("重试") { refreshTick &+= 1 }
                    // A damaged selection is replaced by switching to built-in or applying any scheme.
                    Button("改用\(ProductionInputAvailability.fallbackInputMethodName)") { center.switchToBuiltin() }
                        .disabled(center.isBusy)
                }
                if let resourceError {
                    failureRow("无法读取输入方案", detail: resourceError)
                }
                if case .failed(let message) = center.applicationPhase {
                    failureRow("未能启用", detail: message)
                }
                if let error = imports.error {
                    failureRow("词库操作未完成", detail: error)
                }
                if let error = schemeImports.error {
                    failureRow("输入方案导入未完成", detail: error)
                }
            }
        }
    }

    private var hasApplicationFailure: Bool {
        if case .failed = center.applicationPhase { return true }
        return false
    }

    private func failureRow(_ title: String, detail message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.subheadline.bold())
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    /// Structured selection read (latest-wins): activation and published-resource checks both run on the read queue
    /// (`AppliedSelectionLoader`), the main thread only applies plain values; a late read never overwrites a newer one.
    private func loadSelection() async {
        selectionGeneration &+= 1
        let token = selectionGeneration
        let result = await AppliedSelectionLoader.loadWithResourceValidation()
        guard token == selectionGeneration else { return }
        guard let snapshot = result.snapshot else {
            selectionError = result.selectionError ?? "无法读取状态"
            resourceError = nil
            return
        }
        selectedRecipeEnabled = snapshot.recipeEnabled
        selectedKind =
            snapshot.resourceKind.isEmpty
            ? nil
            : KeyboardRecipeStore.ResourceKind(rawValue: snapshot.resourceKind)
        selectedRevision = snapshot.revision
        selectedPackageID = snapshot.packageID
        selectedSchemaID = snapshot.selectedSchemaID
        selectionError = nil
        resourceError = result.resourceError
    }

    /// Dictionary-generated custom pinyin needs a disk read to resolve its input methods/keyboard layouts;
    /// imported sources take them straight from the install manifest, avoiding duplicate reads.
    private func loadPresentations() async {
        var next: [String: SourcePresentation] = [:]
        if imports.installed != nil, let set = try? await imports.tryResources() {
            next["user-dictionary"] = presentation(for: set)
        }
        presentations = next
    }

    private func presentation(for set: KeyboardResourceSet) -> SourcePresentation {
        let choices = InputConfigurationChoices(resourceSet: set)
        return SourcePresentation(
            inputMethods: choices.inputMethods.map { UserTerminology.inputMethodName($0.schema) },
            layouts: choices.supportedLayouts.map { UserTerminology.layoutName($0) })
    }

    // MARK: - Technical details (developer option; real data, no capability removed)

    @ViewBuilder
    private var developerSection: some View {
        Section("技术详情（开发者）") {
            if let caps = engineCapabilities {
                LabeledRow(label: "已加载组件", value: caps.components.joined(separator: ", "))
                if !caps.unsupported.isEmpty {
                    Text("不支持：\(caps.unsupported.joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(.orange)
                }
                LabeledRow(label: "librime", value: caps.librime?.version ?? "-")
                if let commit = caps.librimeLua?.commit {
                    LabeledRow(label: "librime-lua", value: String(commit.prefix(7)) + "…")
                }
                LabeledRow(label: "Lua", value: caps.lua?.version ?? "-")
            } else {
                Text("未找到 engine-capabilities.json（Resources/EngineResources）")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Simple "label: value" row (shared within the module).
struct LabeledRow: View {
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.footnote.monospaced()).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Bridge/engine capability list bundled as EngineResources/engine-capabilities.json (display only).
struct EngineCapabilities: Codable {
    struct Entry: Codable {
        let version: String?
        let commit: String?
    }
    let librime: Entry?
    let librimeLua: Entry?
    let lua: Entry?
    let opencc: Entry?
    let components: [String]
    let unsupported: [String]

    /// Parses on the resource read queue so the main thread never reads the bundle file.
    static func load() async -> EngineCapabilities? {
        (try? await KeyboardResourceReadQueue.async {
            guard
                let url = Bundle.main.url(
                    forResource: "engine-capabilities", withExtension: "json",
                    subdirectory: "EngineResources"),
                let data = try? Data(contentsOf: url)
            else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(EngineCapabilities.self, from: data)
        }) ?? nil
    }
}
