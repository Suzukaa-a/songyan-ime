import KeyboardCore
import LayoutKit
import SwiftUI

/// Home: input schemes / keyboard (my keyboards, appearance, try typing) / tools; settings at top right (including "Keyboard & Full Access").
///
/// User model (`UserTerminology`):
///  - Input scheme: an installable, applicable data unit (source); one source can hold any number of arbitrarily named schemes.
///  - Input method: a way of typing within a scheme (full pinyin, Xiaohe double pinyin, 9-key, shape code, dialect...), derived dynamically from the resource snapshot.
///  - Keyboard layout: 26 / 14 / 9 / custom key positions (DIY management is under Settings > Advanced).
///  - Keyboard appearance: colors / fonts / candidate-bar light and dark, a separate entry.
///  - Dictionary: supplementary vocabulary, under Tools.
struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var schemeLine = "正在读取…"
    @StateObject private var center = KeyboardSelectionCenter.shared
    @StateObject private var imports = DictionaryImportCenter.shared
    @StateObject private var schemeImports = SchemeImportCenter.shared
    /// Observes the appearance manager so the home summary refreshes with the appearance in use.
    @StateObject private var appearance = AppearanceManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section(UserTerminology.inputScheme) {
                    NavigationLink {
                        InputSchemeListView()
                    } label: {
                        HomeRow(title: schemeLine, subtitle: installationSummary, systemImage: "character.book.closed")
                    }
                }

                Section {
                    NavigationLink {
                        // With nothing published the keyboard runs the built-in scheme, so its keyboards are the ones to edit.
                        UserKeyboardManagementView(
                            source: center.usesInstalledScheme
                                ? .active : .package(ProductionInputAvailability.builtinPackageID))
                    } label: {
                        HomeRow(
                            title: UserTerminology.userKeyboard, subtitle: "长按「ABC/中文」键可切换", systemImage: "keyboard")
                    }
                    // One appearance project carries both the keyboard skin and the candidate-bar layout: this is the only entry.
                    NavigationLink {
                        SkinManagementView()
                    } label: {
                        HomeRow(
                            title: UserTerminology.keyboardAppearance, subtitle: appearanceSummary,
                            systemImage: "paintpalette")
                    }
                    NavigationLink {
                        TryInputView()
                    } label: {
                        HomeRow(title: "试打", subtitle: "体验键盘输入与候选上屏", systemImage: "text.cursor")
                    }
                } header: {
                    Text("键盘")
                }

                Section {
                    NavigationLink {
                        DictionaryImportView()
                    } label: {
                        HomeRow(
                            title: UserTerminology.dictionary, subtitle: "管理自定义词库与补充词汇", systemImage: "text.book.closed"
                        )
                    }
                    NavigationLink {
                        PasswordAutoFillView()
                    } label: {
                        HomeRow(title: "密码自动填充", subtitle: "系统设置与临时填写", systemImage: "key")
                    }
                    NavigationLink {
                        SymbolCatalogManagementView()
                    } label: {
                        HomeRow(title: "符号库", subtitle: "标点、特殊符号与颜文字", systemImage: "number")
                    }
                    NavigationLink {
                        LearningBackupView()
                    } label: {
                        HomeRow(title: "学习备份", subtitle: "备份与合并个人词条和词频", systemImage: "tray.and.arrow.up")
                    }
                } header: {
                    Text("工具")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsAndAboutView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .navigationTitle("松烟")
            // Structured: the first frame is read once by .task; refreshTick is incremented on apply/install state changes,
            // cancelling and rerunning the old task; no bare Task is created (the main thread never reads disk).
            .task(id: refreshTick) {
                await center.refresh()
                await imports.refresh()
                await schemeImports.refresh()
                // On launch / foreground, converge a previously interrupted deletion (removes leftover trash inside the lease).
                await schemeImports.recoverInterruptedDeletions()
                await refreshSchemeLine()
                // Typo correction is on by default: converge once for the source in use (one automatic attempt per publish revision),
                // after keyboards saved by an older adapter generator are rebuilt (once per launch).
                // The built-in scheme is installed first so the adapter rebuild sees its current version.
                let builtin = schemeImports.installBuiltinPackage()
                TypoCorrectionCenter.shared.scheduleReconcile(
                    after: Task {
                        await builtin.value
                        await schemeImports.rebuildOutdatedAdapters().value
                        await imports.rebuildOutdatedAdapters()
                    })
                // Commit prediction (on by default once a dictionary is imported) converges after typo correction so the two do not contend for the install transaction.
                PredictionCenter.shared.scheduleReconcile(after: TypoCorrectionCenter.shared.reconcileTask)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshTick &+= 1 }
            }
            .onChange(of: center.applicationPhase) { _, _ in refreshTick &+= 1 }
            .onChange(of: imports.selectionRevision) { _, _ in refreshTick &+= 1 }
            .onChange(of: schemeImports.selectionRevision) { _, _ in refreshTick &+= 1 }
        }
    }

    @State private var refreshTick = 0
    /// Latest-wins token for the home scheme summary: a late old read does not overwrite a newer value.
    @State private var schemeLineGeneration: UInt64 = 0

    /// The input method display name prefers the real name from the publication record; if it cannot be resolved the item is hidden and the internal ID is never exposed.
    ///
    /// The `activation` read completes on the read-only queue (`AppliedSelectionLoader`); the main thread only derives the text.
    private func refreshSchemeLine() async {
        schemeLineGeneration &+= 1
        let token = schemeLineGeneration
        let result = await AppliedSelectionLoader.load()
        guard let snapshot = result.snapshot else {
            guard token == schemeLineGeneration else { return }
            schemeLine =
                result.error == AppliedSelectionLoader.missingGroupMessage
                ? "暂时无法读取设置" : "无法读取当前输入方案"
            return
        }
        guard token == schemeLineGeneration else { return }
        if snapshot.recipeEnabled {
            let inputMethod = UserTerminology.inputMethodName(
                schemaID: snapshot.selectedSchemaID, schemas: snapshot.schemas)
            let layout = snapshot.selectedLayout.map { UserTerminology.layoutName($0) }
            schemeLine = UserTerminology.inUseSummary(
                scheme: snapshot.displayConfigName, inputMethod: inputMethod, layout: layout)
        } else {
            // Nothing published: the keyboard runs the built-in scheme's fallback input method.
            schemeLine = UserTerminology.inUseSummary(
                scheme: ProductionInputAvailability.builtinDisplayName,
                inputMethod: ProductionInputAvailability.fallbackInputMethodName,
                layout: nil)
        }
    }

    /// Number of installed sources (same data set as the input scheme page): **not** called the scheme count.
    private var installationSummary: String {
        let count = (imports.installed != nil ? 1 : 0) + schemeImports.installedPackages.count
        return ProductionInputAvailability.installationSummary(sources: count)
    }

    /// Appearance summary: the name of the appearance in use (candidate-bar details live on the appearance page; the home page does not pile up technical parameters).
    private var appearanceSummary: String {
        "正在使用：\(appearance.applied.name)"
    }
}

/// Generic home row: title + subtitle.
struct HomeRow: View {
    let title: String
    let subtitle: String
    var systemImage: String? = nil

    var body: some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        if let systemImage {
            Label {
                text
            } icon: {
                Image(systemName: systemImage)
            }
        } else {
            text
        }
    }
}
