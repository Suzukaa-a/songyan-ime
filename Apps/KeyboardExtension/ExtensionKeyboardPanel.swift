import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import OSLog
import SwiftUI
import UIKit

final class ExtensionPresentationStatus: ObservableObject {
    @Published var budget: KeyboardPanelPresentationBudget
    @Published var presentedHeight: CGFloat?

    init(budget: KeyboardPanelPresentationBudget) {
        self.budget = budget
    }
}

final class ExtensionRouteStatus: ObservableObject {
    enum Recovery {
        case reloadConfiguration, saveBuiltin, applyRecipe

        var title: String {
            switch self {
            case .reloadConfiguration: return "重新载入设置"
            case .saveBuiltin: return "重新保存选择"
            case .applyRecipe: return "重新使用输入方案"
            }
        }
    }
    @Published var message = "正在读取键盘配置"
    @Published var schemeName = ProductionInputAvailability.runtimeUnconfiguredSchemeName
    @Published var notice: String?
    @Published var recovery: Recovery?
    @Published var needsInputModeSwitchKey = false
    @Published var layoutRegistry: LayoutRegistry?
    @Published var selectedLayoutID: String?
    @Published var layoutNotice: String?
    @Published var layoutMessage = ""
    /// Whether the layout registry read has settled (success, unavailable, failure, or no Full Access). The
    /// pinyin-row grant trusts only the eligibility report from a settled read.
    @Published var layoutReadSettled = false
    /// Host-binding counter: incremented once per `viewWillAppear` by the extension controller, an explicit trigger
    /// for the panel to re-read appearance/layout (replaces the app-active notification that never fires in an extension).
    @Published var hostBindingTick = 0
    /// Explicit UIKit trait bridge: changes even while this keyboard stays open.
    @Published var systemColorScheme: ColorScheme = .light
    @Published var hasResolvedSystemColorScheme = false
    var explainRecipeAvailability = false
    var selectionError: String?

    /// Every `@Published` assignment sends `objectWillChange` even for an equal value, recomputing the whole panel;
    /// lifecycle refreshes write only when the value actually changes.
    func assignIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ExtensionRouteStatus, Value>,
        _ value: Value
    ) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

struct ExtensionKeyboardPanel: View {
    @ObservedObject var session: KeyboardPadSession
    @ObservedObject var route: ExtensionRouteStatus
    let panelHostLifetime: KeyboardPanelHostLifetime
    let selectBuiltin: (Bool) -> Void
    let systemKeyboardSwitch: (UIView, UIEvent) -> Void
    let retryRoute: (ExtensionRouteStatus.Recovery) -> Void
    let restoreBuiltin: () -> Void
    let reloadLayouts: () -> Void
    let selectDefinition: (LayoutDefinition) -> Void
    let initialPresentation: KeyboardInitialPresentation
    @ObservedObject var presentation: ExtensionPresentationStatus
    let onAppearanceChange: (KeyboardAppearance) -> Void
    /// Opens the host app; the extension itself has no application object to send a URL to.
    let openHostApp: (URL, @escaping @MainActor (Bool) -> Void) -> Void
    let dismissKeyboard: () -> Void
    @State private var showsRouteDetails = false

    var body: some View {
        KeyboardPanelHost(
            session: session, onRestoreBuiltin: restoreBuiltin,
            systemKeyboardSwitch: route.needsInputModeSwitchKey ? systemKeyboardSwitch : nil,
            layoutRegistry: route.layoutRegistry, selectedLayoutID: route.selectedLayoutID,
            loadsStoredLayouts: false,
            additionalTools: AnyView(routeTools), statusMessage: noticeSummary,
            onStatusDetails: { showsRouteDetails = true },
            initialPresentation: initialPresentation,
            onAppearanceChange: onAppearanceChange,
            systemTraitKnown: route.hasResolvedSystemColorScheme,
            hostBindingTick: route.hostBindingTick,
            layoutSourceSettled: route.layoutReadSettled,
            presentedHeight: presentation.presentedHeight,
            presentationBudget: presentation.budget,
            openHostApp: openHostApp,
            dismissKeyboard: dismissKeyboard
        )
        .environment(\.colorScheme, route.systemColorScheme)
        .environment(\.keyboardPanelHostLifetime, panelHostLifetime)
        .disabled(showsRouteDetails)
        .accessibilityHidden(showsRouteDetails)
        .overlay { if showsRouteDetails { routeDetails } }
        // Covers the route-details scroller too; the panel host covers its own.
        .sharpCandidateScrollEdges()
        // Neutral transition: when the pinyin-row grant changes, the host height and the UIKit shell height are not
        // in the same commit. Bottom anchoring makes the transient difference only crop/reveal an empty top band,
        // so the key area and candidate row do not move on screen (the hosting view is bottom-anchored and clipsToBounds).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Recovery actions appear only when something is actually wrong (`noticeSummary`); when all is well, keyboard
    /// settings do not show a set of incomprehensible, useless reload/rollback buttons.
    @ViewBuilder
    private var routeTools: some View {
        KeyboardToolsSection(title: "键盘") {
            KeyboardToolsRow(icon: "keyboard.chevron.compact.down", title: "收起键盘", action: dismissKeyboard)
        }
        if noticeSummary != nil {
            KeyboardToolsSection(title: "遇到问题") {
                KeyboardToolsRow(icon: "arrow.uturn.backward", title: "使用已选的输入方案") {
                    selectBuiltin(false)
                }
                KeyboardToolsSeparator()
                KeyboardToolsRow(title: "改用\(ProductionInputAvailability.fallbackInputMethodName)") {
                    selectBuiltin(true)
                }
                KeyboardToolsSeparator()
                KeyboardToolsRow(
                    title: "暂时改用\(ProductionInputAvailability.fallbackInputMethodName)", action: restoreBuiltin)
                KeyboardToolsSeparator()
                KeyboardToolsRow(icon: "arrow.clockwise", title: "重新载入设置") {
                    retryRoute(.reloadConfiguration)
                }
                KeyboardToolsSeparator()
                KeyboardToolsRow(title: "重新载入布局", action: reloadLayouts)
                KeyboardToolsSeparator()
                KeyboardToolsRow(icon: "info.circle", title: "查看详情") {
                    showsRouteDetails = true
                }
            }
        }
    }

    private var routeDetails: some View {
        VStack(spacing: 4) {
            HStack {
                if route.needsInputModeSwitchKey {
                    NativeInputModeKey(
                        handleEvent: systemKeyboardSwitch,
                        accessibilitySwitch: { session.onSwitchKeyboard?() }
                    )
                    .frame(width: 44, height: 44)
                }
                Button("返回键盘") { showsRouteDetails = false }.frame(minHeight: 44)
                Spacer()
                if let recovery = route.recovery {
                    Button(recovery.title) { retryRoute(recovery) }.frame(minHeight: 44)
                } else {
                    Button("重新载入布局", action: reloadLayouts).frame(minHeight: 44)
                }
            }
            ScrollView {
                Text(
                    [
                        route.notice, route.layoutNotice,
                        route.notice == nil ? nil : route.message,
                        route.layoutNotice == nil ? nil : route.layoutMessage,
                        noticeSummary == nil ? "一切正常，可以返回键盘继续输入。" : nil,
                    ]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                )
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Button("暂时改用\(ProductionInputAvailability.fallbackInputMethodName)") {
                restoreBuiltin()
                showsRouteDetails = false
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityAction(.escape) { showsRouteDetails = false }
    }

    private var noticeSummary: String? {
        switch (route.notice != nil, route.layoutNotice != nil) {
        case (true, true): return "方案未能生效 · 布局暂用内置"
        case (true, false): return route.selectionError == nil ? route.notice : "方案保存失败 · 已保留原选择"
        case (false, true): return "自定义布局不可用 · 暂用内置"
        case (false, false): return nil
        }
    }
}
