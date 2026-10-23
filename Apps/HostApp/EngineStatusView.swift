import KeyboardCore
import SwiftUI
import UIKit

/// Engine and integration status (technical detail page under Developer Options): shows the current engine source and adapter layer.
/// Not exposed in the regular UI; reachable only via Settings & About > Developer Options.
struct EngineStatusView: View {
    private var provider: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("RimeBridge（真实 librime）")
                    .font(.headline)
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(.green)
            }

            Text(EngineIntegration.currentEngineDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)

        }
    }

    var body: some View {
        List {
            Section("引擎") {
                provider
            }

            Section("键盘扩展") {
                Text("需在系统「设置」中添加并启用键盘扩展。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("引擎与集成")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings & About: common preferences, privacy, and about. Does not repeat the home page's management navigation
/// (scheme/layout/appearance management is only entered from home). Developer Options is off by default and not shown on the page:
/// tap "Version" 7 times in a row to enable it; once on, a "Developer" group appears at the bottom (where it can be turned off),
/// along with debug info and entry points to diagnostic pages (engine integration, resource check, runtime self-test).
struct SettingsAndAboutView: View {
    @AppStorage(HostAppKeys.developerOptionsEnabled) private var developerOptions = false
    /// Consecutive-tap counter on the "Version" row; reaching the threshold enables Developer Options.
    @State private var versionTapCount = 0
    @State private var showingDeveloperEnabled = false
    @State private var searchText = ""
    private static let developerUnlockTaps = 7

    private var bundleVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "—"
        let b = info?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    private var documentsPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.path ?? "不可用"
    }

    private enum Route: String, CaseIterable, Identifiable {
        case inputOptions, grammarModel, quickContent, keyboardAccess, advanced
        case symbols, userKeyboards, appearance, dictionary, learningBackup
        var id: String { rawValue }
        var visibleByDefault: Bool {
            switch self {
            case .inputOptions, .grammarModel, .quickContent, .keyboardAccess, .advanced: return true
            default: return false
            }
        }
        var title: String {
            switch self {
            case .inputOptions: return "输入选项"
            case .grammarModel: return UserTerminology.grammarModel
            case .quickContent: return "常用语与剪贴板"
            case .keyboardAccess: return "键盘与完全访问"
            case .advanced: return "高级"
            case .symbols: return "符号与颜文字"
            case .userKeyboards: return UserTerminology.userKeyboard
            case .appearance: return UserTerminology.keyboardAppearance
            case .dictionary: return UserTerminology.dictionary
            case .learningBackup: return "学习备份"
            }
        }
        var keywords: String {
            switch self {
            case .inputOptions: return "输入选项 声音 触感 纠错 联想 九键 拼写 高度 紧凑 宽松 双拼 提示 单手 模糊音 弱 适中 强"
            case .grammarModel: return "语法模型 模型"
            case .quickContent: return "常用语 剪贴板 历史 快捷短语"
            case .keyboardAccess: return "键盘 完全访问 权限 添加 引导"
            case .advanced: return "高级 自定义 布局 扩展 诊断 日志"
            case .symbols: return "符号 颜文字 标点 特殊符号"
            case .userKeyboards: return "我的键盘 输入方式 键盘布局 全拼 双拼 九键 26键 14键"
            case .appearance: return "键盘外观 皮肤 颜色 主题"
            case .dictionary: return "词库 词典 词汇"
            case .learningBackup: return "学习备份 词频 备份 换机 恢复"
            }
        }
    }

    private var visibleRoutes: [Route] {
        Route.allCases.filter { route in
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? route.visibleByDefault : matches(route.keywords)
        }
    }

    @ViewBuilder private func destination(_ route: Route) -> some View {
        switch route {
        case .inputOptions: InputOptionsView()
        case .grammarModel: GrammarModelSettingsView()
        case .quickContent: QuickContentManagementView()
        case .keyboardAccess: OnboardingView(presentation: .pushed)
        case .advanced: AdvancedSettingsView()
        case .symbols: SymbolCatalogManagementView()
        case .userKeyboards: UserKeyboardManagementView()
        case .appearance: SkinManagementView()
        case .dictionary: DictionaryImportView()
        case .learningBackup: LearningBackupView()
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(visibleRoutes) { route in
                    NavigationLink {
                        destination(route)
                    } label: {
                        Text(route.title)
                    }
                    .accessibilityIdentifier("settings." + route.rawValue)
                }
            }

            if matches("隐私 网络 完全访问 权限 关于 版本 许可") {
                Section {
                    privacyRow(
                        "键盘不联网", systemImage: "wifi.slash",
                        text: "输入内容只在设备上处理，不会上传。")
                    privacyRow(
                        "允许完全访问", systemImage: "lock.open",
                        text: "不开启也能使用所有输入方案；开启后才能使用按键声音和常用语，并记住你在键盘里做的切换。")
                    privacyRow(
                        "App 何时联网", systemImage: "arrow.down.circle",
                        text: "仅在你下载文件或检查更新时联网。")
                    versionRow
                    NavigationLink("第三方许可") { ThirdPartyLicensesView() }
                        .accessibilityIdentifier("settings.licenses")
                } header: {
                    Text("隐私与关于")
                }
            }

            if developerOptions, matches("开发者 引擎 文档 构建") {
                Section("开发者") {
                    Toggle("开发者选项", isOn: $developerOptions)
                        .accessibilityIdentifier("settings.developerOptions")
                    LabeledRow(label: "引擎来源", value: EngineIntegration.currentEngineDescription)
                    LabeledRow(label: "文档目录", value: documentsPath)
                    LabeledRow(label: "构建配置", value: buildConfigurationName)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索设置")
        .overlay {
            if visibleRoutes.isEmpty && !matches("隐私 网络 完全访问 权限 关于 版本 许可")
                && !(developerOptions && matches("开发者 引擎 文档 构建"))
            {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .alert("已开启开发者选项", isPresented: $showingDeveloperEnabled) {
            Button("好") {}
        } message: {
            Text("可随时在「设置」底部关闭。")
        }
    }

    private func matches(_ keywords: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || keywords.localizedStandardContains(query)
    }

    private func privacyRow(_ title: String, systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.bold())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// "Version" row: 7 consecutive taps enable Developer Options (no prompt once enabled).
    private var versionRow: some View {
        HStack {
            Text("版本")
            Spacer()
            Text(bundleVersion).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !developerOptions else { return }
            versionTapCount += 1
            if versionTapCount >= Self.developerUnlockTaps {
                versionTapCount = 0
                developerOptions = true
                showingDeveloperEnabled = true
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var buildConfigurationName: String {
        #if DEBUG
            "Debug"
        #else
            "Release"
        #endif
    }
}

struct ThirdPartyLicensesView: View {

    var body: some View {
        List {
            Section("Rime 与组件") {
                if let url = Bundle.main.resourceURL?.appendingPathComponent("Legal/ThirdPartyNotices.txt"),
                    FileManager.default.fileExists(atPath: url.path)
                {
                    NavigationLink("Rime 与第三方组件 · 归属及许可全文") {
                        LicenseTextView(title: "Rime 与组件", resource: "Legal/ThirdPartyNotices.txt")
                    }
                }
                NavigationLink("librime-lua · BSD-3-Clause") {
                    LicenseTextView(
                        title: "librime-lua", resource: "EngineResources/licenses/librime-lua-ad1e4a6-LICENSE.txt")
                }
                NavigationLink("librime-lua · MIT") {
                    LicenseTextView(
                        title: "librime-lua",
                        resource: "EngineResources/licenses/librime-lua-ad1e4a6-MIT-NOTICES.txt")
                }
                NavigationLink("Lua · MIT") {
                    LicenseTextView(title: "Lua", resource: "EngineResources/licenses/Lua-5.4.9-LICENSE.txt")
                }
                NavigationLink("librime-octagram · BSD-3-Clause") {
                    LicenseTextView(
                        title: "librime-octagram", resource: "EngineResources/licenses/librime-octagram-LICENSE")
                }
                NavigationLink("librime-predict · BSD-3-Clause") {
                    LicenseTextView(
                        title: "librime-predict", resource: "EngineResources/licenses/librime-predict-LICENSE")
                }
                NavigationLink("ZIPFoundation · MIT") {
                    LicenseTextView(title: "ZIPFoundation", resource: "Legal/licenses/ZIPFoundation-0.9.20-LICENSE.txt")
                }
                NavigationLink("Yams · MIT") {
                    LicenseTextView(title: "Yams", resource: "Legal/licenses/Yams-5.4.0-LICENSE.txt")
                }
                NavigationLink("RapidJSON · MIT") {
                    LicenseTextView(title: "RapidJSON", resource: "Legal/licenses/rapidjson-1.1.0-LICENSE.txt")
                }
                NavigationLink("LibYAML · MIT") {
                    LicenseTextView(title: "LibYAML", resource: "Legal/licenses/libyaml-LICENSE.txt")
                }
                NavigationLink("X11 keysym · MIT") {
                    LicenseTextView(title: "X11 keysym", resource: "Legal/licenses/X11-keysym-NOTICE.txt")
                }
                NavigationLink("UTF8-CPP · BSL-1.0") {
                    LicenseTextView(title: "UTF8-CPP", resource: "Legal/licenses/boost-1.89.0-LICENSE_1_0.txt")
                }
                NavigationLink("rime-prelude · LGPL-3.0") {
                    LicenseTextView(
                        title: "rime-prelude", resource: "PackageManager_PackageManager.bundle/RimePrelude/LICENSE")
                }
                NavigationLink("14 键规则来源 · LGPL-3.0") {
                    LicenseTextView(title: "rime-clover-flypy", resource: "Legal/licenses/LGPL-3.0.txt")
                }
                NavigationLink("项目源码与规则 · GPL-3.0") {
                    LicenseTextView(title: "GPL-3.0", resource: "Legal/licenses/GPL-3.0.txt")
                }
            }
            Section {
                upstreamLicense("librime · RIME Developers · BSD-3-Clause", "rime/librime", "1.17.0", "LICENSE")
                upstreamLicense("glog · Google · BSD-3-Clause", "google/glog", "v0.7.1", "COPYING")
                upstreamLicense("LevelDB · Google · BSD-3-Clause", "google/leveldb", "1.23", "LICENSE")
                upstreamLicense("marisa-trie · Susumu Yata · BSD / LGPL", "s-yata/marisa-trie", "v0.3.1", "COPYING.md")
                upstreamLicense("OpenCC · Carbo Kuo · Apache-2.0", "BYVoid/OpenCC", "ver.1.1.9", "LICENSE")
                upstreamLicense(
                    "yaml-cpp · Jesse Beder · MIT", "jbeder/yaml-cpp", "2f86d13775d119edbb69af52e5f566fd65c6953b",
                    "LICENSE")
                Link(
                    "Boost · Boost Software License 1.0",
                    destination: URL(string: "https://www.boost.org/LICENSE_1_0.txt")!)
                upstreamLicense("darts-clone · Susumu Yata · BSD-2-Clause", "s-yata/darts-clone", "master", "COPYING")
            } header: {
                Text("在线许可全文")
            }
        }
        .navigationTitle("第三方许可")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func upstreamLicense(_ title: String, _ repository: String, _ revision: String, _ file: String) -> some View
    {
        Link(title, destination: URL(string: "https://github.com/\(repository)/blob/\(revision)/\(file)")!)
    }
}

private struct LicenseTextView: View {
    let title: String
    let resource: String
    @State private var content = "正在读取…"

    var body: some View {
        ScrollView {
            Text(content).font(.footnote).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(resource) else {
                content = "无法读取许可文件"
                return
            }
            do {
                content = try await KeyboardResourceReadQueue.async {
                    String(decoding: try Data(contentsOf: url), as: UTF8.self)
                }
            } catch { content = "无法读取许可文件" }
        }
    }
}
