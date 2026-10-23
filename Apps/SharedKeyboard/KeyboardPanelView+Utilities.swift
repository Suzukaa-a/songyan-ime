import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

extension KeyboardPanelView {
    /// Keyboard extensions cannot present UIAlertController-backed SwiftUI dialogs.
    /// **utilities-only** "Keyboard Settings" panel (no nested tabs): status hints, "Insert" (symbol library and host-injected
    /// quick fills), host-injected switch groups, and guidance to the host app's matching settings; the list scrolls, rows are >= 44pt.
    ///
    /// There is **no** input-method choice, no 26/14/9 layout choice, no published-keyboard list here:
    /// keyboard switching happens only via the "ABC/中文" long press, and layout combinations come only from the list published by the host app.
    var utilitiesPanel: some View {
        VStack(spacing: 0) {
            toolsTitleBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let statusMessage, onStatusDetails != nil {
                        statusCard(statusMessage)
                    }
                    // Engine options and the key-feedback row both appear via KeyboardPanelHost's
                    // additionalTools (which contains KeyboardOptionsView, always rendered);
                    // not instantiated directly here, to avoid duplicating them in the same panel.
                    utilitiesSection
                    if let additionalTools {
                        additionalTools
                    }
                    // The app owns everything the extension cannot configure: schemes, dictionaries
                    // and the keyboard appearance. One tap goes there instead of a written hint.
                    // Shown only inside the real keyboard extension: the app's own trial area is
                    // already in the app, so a jump to itself would be meaningless.
                    if openHostApp != nil {
                        // The failure is told in this row itself: it sits at the bottom of a
                        // scrolled list, so a row added below it would land out of sight.
                        KeyboardToolsSection(title: "松烟 App") {
                            KeyboardToolsRow(
                                icon: hostAppUnavailable ? "exclamationmark.circle" : "arrow.up.forward.app",
                                iconTint: hostAppUnavailable ? appearance.accentForeground : nil,
                                title: UserTerminology.openHostApp,
                                detail: hostAppUnavailable
                                    ? "没能打开，请回到主屏幕，轻点「松烟」。"
                                    : "输入方案、词库、键盘外观在这里设置",
                                detailLineLimit: 2,
                                accessibilityHint: "打开松烟 App 继续设置",
                                action: openHostAppSetting
                            )
                            .accessibilityIdentifier("keyboard.openHostApp")
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .sharpCandidateScrollEdges()
        }
        // No fill of its own: the list sits on the keyboard surface like the keys do.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Tool list text honours the user's text size; the panel is a bounded
        // ScrollView inside the fixed keyboard height, so no key geometry changes.
        .dynamicTypeSize(.small ... .accessibility3)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { showsUtilitiesMenu = false }
        .onAppear { utilitiesTitleFocused = true }
    }

    /// Stable title bar: does not scroll and, like the candidate bar, draws no rule; the back action is still a pure UI dismiss.
    private var toolsTitleBar: some View {
        KeyboardToolsTitleBar {
            KeyboardToolsTitle(text: "键盘设置")
                .accessibilityFocused($utilitiesTitleFocused)
        } trailing: {
            KeyboardToolsDismissButton(title: "完成", accessibilityHint: "返回键盘", minHeight: 40) {
                showsUtilitiesMenu = false
            }
        }
        .frame(minHeight: 40)
    }

    /// Status error/hint: still a tappable 44pt row that opens details and recovery actions.
    private func statusCard(_ message: String) -> some View {
        KeyboardToolsCard {
            KeyboardToolsRow(
                icon: "exclamationmark.circle",
                iconTint: appearance.accentForeground,
                title: message,
                titleLineLimit: 2,
                detail: "打开详情与恢复操作",
                showsChevron: true,
                accessibilityLabel: message,
                accessibilityHint: "打开详情与恢复操作"
            ) {
                showsUtilitiesMenu = false
                onStatusDetails?()
            }
        }
        .padding(.top, KeyboardToolsStyle.sectionTopPadding)
    }

    /// "Insert": symbol library + quick fills injected by the host via `insertTools` (repeat last input, date/time).
    /// The number/symbol page already has a 123 key in the bottom bar, so there is no duplicate entry here. Switch-type settings are injected by the host via
    /// `additionalTools` (see `KeyboardPanelHost`), grouped apart from the insert actions.
    @ViewBuilder
    private var utilitiesSection: some View {
        // Directly under the title bar unless a status card sits between them.
        KeyboardToolsSection(
            title: "插入",
            topPadding: statusMessage != nil && onStatusDetails != nil ? KeyboardToolsStyle.sectionTopPadding : 4
        ) {
            KeyboardToolsRow(
                icon: "square.grid.3x3",
                title: "快捷内容",
                showsChevron: true,
                accessibilityHint: "符号、颜文字、常用语与剪贴板"
            ) {
                emitSelectionFeedback()
                showsUtilitiesMenu = false
                showsSymbolLibrary = true
            }
            .accessibilityIdentifier("keyboard.quickContent")
            if let insertTools {
                insertTools
            }
        }
    }

    /// Opens the host app for settings the keyboard cannot change itself.
    private func openHostAppSetting() {
        guard let url = HostAppLink.settingsURL else { return }
        emitSelectionFeedback()
        hostAppUnavailable = false
        guard let openHostApp else {
            // No hop is possible (the app is already frontmost): the row only states the fact.
            hostAppUnavailable = true
            return
        }
        openHostApp(url) { accepted in
            hostAppUnavailable = !accepted
        }
    }

    func syncHostPage() {
        page = controller.hostPreferredInput == .numeric ? .numeric : .letters
    }
}
