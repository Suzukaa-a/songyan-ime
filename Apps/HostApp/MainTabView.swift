import KeyboardCore
import LayoutKit
import SwiftUI

/// Home: input schemes and my keyboards / keyboard (appearance, try typing) / tools; settings at top right (including "Keyboard & Full Access").
///
/// The first two rows are the app's only two places to act: 输入方案 (what is installed, and which
/// scheme the keyboard uses) and 我的键盘 (what is on the keyboard, and the keyboard in use).
///
/// User model (`UserTerminology`):
///  - Input scheme: an installable, applicable data unit (source); one source can hold any number of arbitrarily named schemes.
///  - Input method: a way of typing within a scheme (full pinyin, Xiaohe double pinyin, 9-key, shape code, dialect...), derived dynamically from the resource snapshot.
///  - Keyboard layout: 26 / 14 / 9 / custom key positions (DIY management is under Settings > Advanced).
///  - Keyboard appearance: colors / fonts / candidate-bar light and dark, a separate entry.
///  - Dictionary: supplementary vocabulary, under Tools.
struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    /// Scheme in use, for the 输入方案 row; nil until read.
    @State private var inUseSchemeName: String?
    /// The keyboard in use, for the 我的键盘 row.
    @State private var keyboardLine = "正在读取…"
    @StateObject private var center = KeyboardSelectionCenter.shared
    @StateObject private var imports = DictionaryImportCenter.shared
    @StateObject private var schemeImports = SchemeImportCenter.shared
    /// Observes the appearance manager so the home summary refreshes with the appearance in use.
    @StateObject private var appearance = AppearanceManager.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        InputSchemeListView()
                    } label: {
                        HomeRow(
                            title: UserTerminology.inputScheme, subtitle: installationSummary,
                            systemImage: "character.book.closed")
                    }
                    NavigationLink {
                        UserKeyboardManagementView(source: center.userKeyboardSource)
                    } label: {
                        HomeRow(title: UserTerminology.userKeyboard, subtitle: keyboardLine, systemImage: "keyboard")
                    }
                }

                Section {
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
                await refreshInUse()
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
    /// Latest-wins token for the home summaries: a late old read does not overwrite a newer value.
    @State private var inUseGeneration: UInt64 = 0

    /// The input method display name prefers the real name from the publication record; if it cannot be resolved the item is hidden and the internal ID is never exposed.
    ///
    /// The `activation` read completes on the read-only queue (`AppliedSelectionLoader`); the main thread only derives the text.
    private func refreshInUse() async {
        inUseGeneration &+= 1
        let token = inUseGeneration
        let result = await AppliedSelectionLoader.load()
        guard token == inUseGeneration else { return }
        guard let snapshot = result.snapshot else {
            inUseSchemeName = nil
            keyboardLine =
                result.error == AppliedSelectionLoader.missingGroupMessage
                ? "暂时无法读取设置" : "暂时无法读取正在使用的键盘"
            return
        }
        if snapshot.recipeEnabled {
            inUseSchemeName = snapshot.displayConfigName
            keyboardLine =
                UserTerminology.currentKeyboardSummary(
                    inputMethod: UserTerminology.inputMethodName(
                        schemaID: snapshot.selectedSchemaID, schemas: snapshot.schemas),
                    layout: snapshot.selectedLayout) ?? Self.keyboardSwitchHint
        } else {
            // Nothing published: the keyboard runs the built-in scheme's fallback input method.
            inUseSchemeName = ProductionInputAvailability.builtinDisplayName
            keyboardLine =
                UserTerminology.currentKeyboardSummary(
                    inputMethod: ProductionInputAvailability.fallbackInputMethodName, layout: nil)
                ?? Self.keyboardSwitchHint
        }
    }

    private static let keyboardSwitchHint = "长按「ABC/中文」键可切换"

    /// Number of installed sources (same data set as the input scheme page): **not** called the scheme count.
    private var installationSummary: String {
        let count = (imports.installed != nil ? 1 : 0) + schemeImports.installedPackages.count
        return UserTerminology.installedSchemeSummary(count: count, inUse: inUseSchemeName)
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
