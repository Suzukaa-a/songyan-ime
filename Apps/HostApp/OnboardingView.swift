import KeyboardCore
import SwiftUI

/// First-run setup guide (can be re-entered):
///  1. add the keyboard to the system and explain Full Access (the built-in offline pinyin types without any scheme);
///  2. add / start using an input scheme as needed; an applied source that supports management links straight to "User Keyboards";
///  3. finally, try typing.
///
/// Navigation is actionable: with no source enabled it opens the "Input Schemes" page, and custom pinyin does not open the
/// inapplicable user-keyboard management page.
/// Real install/apply state is refreshed on return.
///
/// `Presentation` decides navigation ownership; never nest a second stack inside an existing one:
///  - `.standalone`: owned by first launch (`HostRootView`); this page creates its own `NavigationStack`.
///  - `.pushed`: entered from Settings (which already has an outer stack); this page creates no stack and registers path navigation on the outer one.
///
/// With no usable scheme yet it says so explicitly ("no usable input scheme configured") instead of claiming availability; Release offers no built-in package shortcut.
/// "Skip" only enters the home page and does not mark the guide completed; only finishing the guide does.
struct OnboardingView: View {
    /// Navigation ownership: standalone on first launch (own stack), pushed when reused from Settings (outer stack).
    enum Presentation { case standalone, pushed }

    let presentation: Presentation
    /// Finish the guide (host writes the completion mark and enters home); when nil this page marks completion and dismisses itself (Settings reuse).
    var onFinish: (() -> Void)? = nil
    /// Skip (host enters home without marking completion); when nil, only dismisses.
    var onSkip: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppSettings.onboardingCompletedKey) private var onboardingCompleted = false
    @StateObject private var center = KeyboardSelectionCenter.shared
    @StateObject private var imports = DictionaryImportCenter.shared
    @StateObject private var schemeImports = SchemeImportCenter.shared

    @State private var step = 0
    @State private var verificationText = ""
    @FocusState private var verificationFocused: Bool
    @State private var statusLine = "读取中…"
    @State private var hasRealScheme = false
    @State private var activeSupportsUserKeyboards = false
    /// Structured refresh tick: bumped on return to foreground / install-apply state changes, rerunning `.task(id:)`.
    @State private var refreshTick = 0
    /// Whether the keyboard has ever appeared with Full Access (judged by a presence marker the keyboard writes; refreshed on return to foreground).
    @State private var keyboardSeenWithFullAccess = false

    init(
        presentation: Presentation = .pushed,
        initialStep: Int = 0,
        onFinish: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
        self.onSkip = onSkip
    }

    /// Pages reachable from the guide (all generic, not tied to any source).
    private enum Destination: Hashable {
        case schemeList
        case addScheme
        case userKeyboard
    }

    var body: some View {
        switch presentation {
        case .standalone:
            // First launch: this page owns the navigation stack.
            NavigationStack { content }
        case .pushed:
            // Settings reuse: no stack is created; destinations register on the outer stack; NavigationStack is not nested.
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, item in
                    stepCard(i, item)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Native page dots overlay the scroll view and obscure large text.
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("引导进度")
            .accessibilityValue("第 \(step + 1) 步，共 \(steps.count) 步")
            .accessibilityAdjustableAction { direction in
                withAnimation {
                    switch direction {
                    case .increment: step = min(step + 1, steps.count - 1)
                    case .decrement: step = max(step - 1, 0)
                    @unknown default: break
                    }
                }
            }

            let navigationLayout =
                dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout())
            navigationLayout {
                if step > 0 {
                    Button {
                        withAnimation { step -= 1 }
                    } label: {
                        Text("上一步")
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                    }
                    .buttonStyle(.bordered)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                Button {
                    if step < steps.count - 1 { withAnimation { step += 1 } } else { finish() }
                } label: {
                    Text(step < steps.count - 1 ? "下一步" : "完成")
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(presentation == .standalone ? "欢迎使用松烟" : "键盘与完全访问")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if presentation == .standalone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("跳过") { skip() }
                }
            }
        }
        // Destinations use view-based NavigationLink: pushing this page from the home page (a view-based link) and then appending a
        // value-based path makes SwiftUI rebuild the stack and reset this page to the first step.
        // Refresh exactly once on the first frame: `.task(id:)` runs once on first appearance and reruns when the refresh key
        // changes, which only reacts to return-to-foreground and real install/apply changes; paging does not reread the scheme list.
        // Not `.onAppear { Task { ... } }`: that would run the first frame twice, and a bare `Task` is not cancelled when the view
        // disappears, leaving a late-write race on `statusLine`.
        .task(id: refreshKey) { await refreshStatus() }
        .onChange(of: step) { _, value in
            if value != 2 { verificationFocused = false }
        }
        .onDisappear { verificationFocused = false }
        .onChange(of: scenePhase) { _, value in if value == .active { refreshTick &+= 1 } }
        // Structured replacement for "refresh in onAppear on return to this page": reruns only on real install/apply state changes,
        // not on every redraw, and does not race the first-frame `.task` (`onChange` ignores the initial value).
        .onChange(of: center.applicationPhase) { _, _ in refreshTick &+= 1 }
        .onChange(of: imports.selectionRevision) { _, _ in refreshTick &+= 1 }
        .onChange(of: schemeImports.selectionRevision) { _, _ in refreshTick &+= 1 }
    }

    /// Status refresh key: reruns on appear, return to foreground and real install/apply changes, not on step changes.
    private var refreshKey: OnboardingRefreshKey {
        OnboardingRefreshKey(refreshTick: refreshTick)
    }

    @ViewBuilder
    private func destinationView(_ destination: Destination) -> some View {
        switch destination {
        case .schemeList:
            InputSchemeListView()
        case .addScheme:
            SchemePackageImportView()
        case .userKeyboard:
            UserKeyboardManagementView()
        }
    }

    /// Steps: add the keyboard to the system first (the built-in scheme can type), then add an input scheme as needed, and finally try typing.
    private var steps: [(title: String, body: String)] {
        [
            (
                "添加键盘",
                """
                前往系统「设置」，轻点「键盘」并添加「松烟」。

                键盘不会连接网络，输入内容仅在设备端处理。开启「允许完全访问」后，才能使用按键声音和常用语，并记住你在键盘里做的切换。
                """
            ),
            (
                "选择输入方案",
                """
                \(statusLine)

                内置输入方案的词库较小。日常使用建议添加完整的输入方案。
                """
            ),
            (
                "试一试",
                """
                轻点下方输入框，长按 🌐 键并选择「松烟」。
                """
            ),
        ]
    }

    private func stepIcon(_ index: Int) -> String {
        switch index {
        case 0: return "keyboard"
        case 1: return "character.book.closed"
        case 2: return "text.cursor"
        default: return "star"
        }
    }

    private func stepCard(_ index: Int, _ item: (title: String, body: String)) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header icon and step progress
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: stepIcon(index))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("第 \(index + 1) 步 / 共 \(steps.count) 步")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(item.title)
                            .font(.title2.bold())
                    }
                }
                .padding(.top, 4)

                Text(item.body)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(.primary)

                if index == 0 {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: keyboardSeenWithFullAccess ? "clock" : "circle.dashed")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                if keyboardSeenWithFullAccess {
                                    Text("曾检测到已开启完全访问。若更改了系统设置，请重新确认。")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("尚未检测到键盘状态")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("添加键盘并开启完全访问后，在任意输入框调出一次键盘即可确认。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(uiColor: .secondarySystemBackground))
                        )

                        Link("前往设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                            .accessibilityIdentifier("onboarding.openSettings")
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                        Text("打开后轻点「键盘」；也可以在「通用」→「键盘」→「键盘」中添加。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if index == 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink {
                            destinationView(.addScheme)
                        } label: {
                            Label(UserTerminology.addInputScheme, systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        NavigationLink {
                            destinationView(selectionDestination)
                        } label: {
                            HStack {
                                if activeSupportsUserKeyboards {
                                    Label(UserTerminology.userKeyboard, systemImage: "keyboard")
                                } else {
                                    Label("已安装的\(UserTerminology.inputScheme)", systemImage: "list.bullet")
                                }
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                if index == 2 {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("试打区域")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("轻点此处输入", text: $verificationText, axis: .vertical)
                                .focused($verificationFocused)
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }

                        Label("成功调出「松烟」键盘即表示设置完成。", systemImage: "hand.tap")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .padding(.bottom, 32)
        }
    }

    /// Step 2 goes straight to the management page only when the applied source supports user keyboards; first-time enablement or custom
    /// pinyin opens the scheme list first.
    private var selectionDestination: Destination {
        activeSupportsUserKeyboards ? .userKeyboard : .schemeList
    }

    private func finish() {
        verificationFocused = false
        onboardingCompleted = true
        if let onFinish { onFinish() } else { dismiss() }
    }

    /// Skip: enters home without marking completion (does not pretend it is done).
    private func skip() {
        verificationFocused = false
        if let onSkip { onSkip() } else { dismiss() }
    }

    /// The status line reports only real records: with no real applied scheme it says not configured (does not claim availability).
    /// Driven by structured `.task(id:)`; once the task is cancelled (view disappears / key changes and reruns),
    /// nothing is written after a mid-way await, avoiding late writes.
    ///
    /// The `activation` read (`Data(contentsOf:)`) runs on `KeyboardResourceReadQueue` and never stays on the MainActor;
    /// only plain display inputs return to the main thread to derive text.
    private func refreshStatus() async {
        keyboardSeenWithFullAccess = KeyboardPresenceStamp.lastFullAccessSeen() != nil
        await center.refresh()
        await schemeImports.refresh()
        await imports.refresh()
        guard !Task.isCancelled else { return }
        let inputs = await AppliedSelectionDisplayLoader.load()
        guard !Task.isCancelled else { return }
        let summary = AppliedSelectionDisplaySummary.make(from: inputs)
        statusLine = summary.statusLine
        hasRealScheme = summary.hasRealScheme
        activeSupportsUserKeyboards =
            summary.hasRealScheme
            && inputs?.resourceKind != KeyboardRecipeStore.ResourceKind.userDictionary.rawValue
    }
}
