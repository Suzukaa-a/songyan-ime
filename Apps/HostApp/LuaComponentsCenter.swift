import Foundation
import KeyboardCore
import PackageManager
import RimeBridge
import SwiftUI

/// Lua components (Settings > Advanced > Lua components): lists, per source and per input method, the
/// lua_processor / lua_segmentor / lua_translator / lua_filter actually mounted by the **compiled** scheme, one toggle each.
///
/// All on by default (nothing is disabled by default). Turning one off writes a standalone Rx-managed block in `<schema>.custom.yaml`;
/// `PackageManager.LuaComponents` computes the list from the recorded baseline, and restoring all leaves only the marker and no pinned
/// list. Within the install transaction, the real engine reads back the component table and compares it with the compiled config before commit (fail closed, the keyboard stays unchanged).
/// Input methods whose user custom already overrides the engine list are shown read-only and never modified.
@MainActor
final class LuaComponentsCenter: ObservableObject {
    static let shared = LuaComponentsCenter()

    struct SchemaRow: Identifiable, Sendable {
        let id: String
        let name: String
        let state: LuaComponents.SchemaState
        let userManaged: Bool
    }

    struct SourceRow: Identifiable, Sendable {
        let packageID: String
        let name: String
        let schemas: [SchemaRow]
        var id: String { packageID }
    }

    @Published private(set) var sources: [SourceRow] = []
    @Published private(set) var loading = false
    @Published private(set) var working = false
    @Published private(set) var notice: String?
    @Published private(set) var failure: String?

    // MARK: - Read

    func refresh() async {
        loading = true
        defer { loading = false }
        var rows: [SourceRow] = []
        let imports = SchemeImportCenter.shared
        await imports.refresh()
        for package in imports.installedPackages {
            if let row = await Self.read(active: package.active, packageID: package.id, name: package.name) {
                rows.append(row)
            }
        }
        sources = rows
    }

    private static func read(active: ActiveRecipe, packageID: String, name: String) async -> SourceRow? {
        let build = active.userDataURL.appendingPathComponent("build")
        let customDirectories = [active.userDataURL, active.resourceURL]
        let task = Task.detached(priority: .userInitiated) { () -> [SchemaRow] in
            var rows: [SchemaRow] = []
            for (id, compiled) in TypoCorrection.enabledCompiledSchemas(
                build: build, include: { !CompactSchemaAdapter.isGeneratedCompanionID($0) })
            {
                guard let state = LuaComponents.state(compiled: compiled, schemaID: id),
                    !state.components.isEmpty
                else { continue }
                let userManaged = customDirectories.contains {
                    LuaComponents.userOwnsSetting(
                        customYAML: try? Data(contentsOf: $0.appendingPathComponent(id + ".custom.yaml")))
                }
                rows.append(SchemaRow(id: id, name: state.name, state: state, userManaged: userManaged))
            }
            return rows
        }
        let schemas = await task.value
        return schemas.isEmpty ? nil : SourceRow(packageID: packageID, name: name, schemas: schemas)
    }

    // MARK: - Apply

    func setEnabled(_ enabled: Bool, component: LuaComponents.Component, schema: SchemaRow, source: SourceRow) {
        guard !working, !schema.userManaged else { return }
        var disabled = schema.state.disabled
        if enabled { disabled.remove(component.prescription) } else { disabled.insert(component.prescription) }
        working = true
        failure = nil
        notice = nil
        Task {
            defer { working = false }
            do {
                let published = try await KeyboardResourceReadQueue.async {
                    PredictionCenter.context(from: try KeyboardRecipeStore.snapshot(selectedOnly: true))
                }
                let imports = SchemeImportCenter.shared
                let outcome = try await imports.applyLuaComponents(
                    packageID: source.packageID, schemaID: schema.id,
                    baseline: schema.state.baseline, disabled: disabled)
                if let published, published.packageID == source.packageID,
                    outcome.previousRevision == published.revision,
                    let keyboard = published.keyboard
                {
                    _ = try await imports.performAddKeyboard(packageID: source.packageID, keyboard: keyboard)
                } else {
                    notice = "已保存，下次使用该方案时生效。"
                }
                HostLog.append(
                    "lua component \(enabled ? "on" : "off") applied: \(schema.id) \(component.prescription)")
            } catch {
                HostLog.append(
                    "lua component apply failed: \(schema.id) \(component.prescription): \(error.localizedDescription)")
                failure = enabled ? "未能开启，请重试。" : "未能关闭，请重试。"
            }
            await refresh()
        }
    }
}

extension SchemeImportCenter {
    /// One transactional update of one input method's Lua component switches. The live
    /// engine must show exactly the intended components before the installation commits.
    func applyLuaComponents(
        packageID: String, schemaID: String, baseline: [String: [String]],
        disabled: Set<String>
    ) async throws -> PredictionOutcome {
        let result = try await applyManagedPatch(
            packageID: packageID, message: "正在保存…",
            plan: { context in
                guard !LuaComponents.userOwnsSetting(customYAML: context.snapshot.files[schemaID + ".custom.yaml"])
                else {
                    throw RecipeInstallError.invalidResource("此输入方式的扩展功能由方案配置决定")
                }
                let recipe = try LuaComponents.make(schemaID: schemaID, baseline: baseline, disabled: disabled)
                return ManagedPatchPlan(recipe: recipe, change: ())
            },
            verify: { engine, enabledIDs, deployment, _ in
                guard enabledIDs.contains(schemaID) else {
                    throw RecipeInstallError.deployment("扩展功能：输入方式「\(schemaID)」未启用")
                }
                let build = deployment.userDataURL.appendingPathComponent("build")
                let components = Set(engine.schemaComponents(schemaID))
                let lua = baseline.values.flatMap { $0 }.filter(LuaComponents.isLua)
                guard lua.allSatisfy({ components.contains($0) != disabled.contains($0) }),
                    let compiled = try? Data(
                        contentsOf: InstalledPackageLayout.compiledSchemaURL(build: build, id: schemaID)),
                    LuaComponents.matches(
                        compiled: compiled, schemaID: schemaID,
                        baseline: baseline, disabled: disabled)
                else {
                    throw RecipeInstallError.deployment("扩展功能配置读取不一致：输入方式「\(schemaID)」")
                }
            })
        return PredictionOutcome(changed: true, previousRevision: result.previousRevision)
    }
}

/// Settings > Advanced > Extensions (Lua components).
struct LuaComponentsView: View {
    @StateObject private var center = LuaComponentsCenter.shared

    var body: some View {
        List {
            if center.sources.isEmpty {
                Text(center.loading ? "正在读取…" : "已安装的输入方案未包含扩展功能。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if center.working {
                ProgressView("正在保存…").font(.footnote)
            } else if let failure = center.failure {
                Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            } else if let notice = center.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(center.sources) { source in
                ForEach(source.schemas) { schema in
                    Section {
                        ForEach(schema.state.components) { component in
                            Toggle(
                                isOn: Binding(
                                    get: { component.enabled },
                                    set: { center.setEnabled($0, component: component, schema: schema, source: source) }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(component.displayName).font(.body.monospaced())
                                    Text(Self.kind(component.list)).font(.caption).foregroundStyle(.secondary)
                                    if component.mayAffectBasicInput {
                                        Text("可能影响基本输入").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            .disabled(center.working || schema.userManaged)
                        }
                    } header: {
                        Text(source.name == schema.name ? schema.name : source.name + " · " + schema.name)
                    } footer: {
                        if schema.userManaged { Text("由输入方案决定") }
                    }
                }
            }
        }
        .navigationTitle("扩展功能")
        .navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
    }

    private static func kind(_ list: String) -> String {
        switch list {
        case "processors": return "按键处理"
        case "segmentors": return "分词"
        case "translators": return "候选生成"
        default: return "候选整理"
        }
    }
}
