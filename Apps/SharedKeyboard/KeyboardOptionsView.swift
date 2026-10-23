import KeyboardCore
import SwiftUI

/// Inline panel content for KeyboardPanelHost/KeyboardPanelView.additionalTools.
/// Compact inline rows: one option per row, title + switch (reflecting the engine's real current state); tap the whole row to toggle.
/// Shows only options the engine really provides (e.g. Simplified/Traditional); nonexistent options are not faked.
/// The key-feedback rows (sound/haptics switches + a strength row per channel)
/// share the same App Group keys (`KeyboardFeedbackPreferences`) as the
/// host app's input options, so a change in one place applies to both.
///
/// Visuals come from `KeyboardToolsStyle`: group title + single-layer card + uniform rows;
/// this view does not build its own header/padding.
public struct KeyboardOptionsView: View {
    @ObservedObject private var controller: KeyboardController
    @Environment(\.keyboardAppearance) private var appearance
    @State private var soundEnabled = KeyboardFeedbackPreferences.soundEnabled
    @State private var hapticEnabled = KeyboardFeedbackPreferences.hapticEnabled
    @State private var soundLevel = KeyboardFeedbackPreferences.soundLevel
    @State private var hapticLevel = KeyboardFeedbackPreferences.hapticLevel

    public init(controller: KeyboardController) { self.controller = controller }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            KeyboardToolsSection(title: "按键反馈") {
                KeyboardToolsRow(
                    icon: "speaker.wave.2",
                    title: "按键声音",
                    mark: .toggle(soundEnabled),
                    accessibilityLabel: "按键声音",
                    accessibilityValue: soundEnabled ? "开启" : "关闭"
                ) {
                    toggleFeedback(sound: true)
                }
                if soundEnabled {
                    KeyboardToolsSeparator()
                    KeyboardToolsRow(
                        icon: "speaker.wave.2",
                        title: "声音强度",
                        trailingText: soundLevel.displayName,
                        accessibilityLabel: "声音强度",
                        accessibilityValue: soundLevel.displayName
                    ) {
                        cycleSoundLevel()
                    }
                }
                KeyboardToolsSeparator()
                KeyboardToolsRow(
                    icon: "iphone.radiowaves.left.and.right",
                    title: "按键触感",
                    mark: .toggle(hapticEnabled),
                    accessibilityLabel: "按键触感",
                    accessibilityValue: hapticEnabled ? "开启" : "关闭"
                ) {
                    toggleFeedback(sound: false)
                }
                if hapticEnabled {
                    KeyboardToolsSeparator()
                    KeyboardToolsRow(
                        icon: "iphone.radiowaves.left.and.right",
                        title: "触感强度",
                        trailingText: hapticLevel.displayName,
                        accessibilityLabel: "触感强度",
                        accessibilityValue: hapticLevel.displayName
                    ) {
                        cycleHapticLevel()
                    }
                }
                if !KeyboardFeedbackService.shared.feedbackAvailableInProcess {
                    KeyboardToolsSeparator()
                    Text("使用按键声音与触感反馈需在系统设置中开启「允许完全访问」。")
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
                        .padding(.vertical, 10)
                }
            }
            if !controller.options.isEmpty {
                KeyboardToolsSection(title: "输入方式选项") {
                    ForEach(Array(controller.options.enumerated()), id: \.element.id) { index, state in
                        if index > 0 { KeyboardToolsSeparator() }
                        optionRow(state)
                    }
                }
            }
            if let error = controller.optionError {
                KeyboardToolsSection(title: "输入方式选项") {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
                        .padding(.vertical, 10)
                    KeyboardToolsSeparator()
                    KeyboardToolsRow(
                        icon: "arrow.clockwise",
                        title: "重新读取"
                    ) {
                        controller.reloadOptions()
                    }
                }
            }
        }
        .onAppear { controller.reloadOptions() }
        .onAppear {
            soundEnabled = KeyboardFeedbackPreferences.soundEnabled
            hapticEnabled = KeyboardFeedbackPreferences.hapticEnabled
            soundLevel = KeyboardFeedbackPreferences.soundLevel
            hapticLevel = KeyboardFeedbackPreferences.hapticLevel
        }
    }

    // MARK: Key feedback (same source as the host app settings; a tap fires one selection feedback via the shared service)

    /// Writes the switch: persists the shared preference first, then updates the local mirror,
    /// and finally fires one selection feedback via the shared service (naturally silent when turned off).
    private func toggleFeedback(sound: Bool) {
        if sound {
            let value = !soundEnabled
            KeyboardFeedbackPreferences.soundEnabled = value
            soundEnabled = value
        } else {
            let value = !hapticEnabled
            KeyboardFeedbackPreferences.hapticEnabled = value
            hapticEnabled = value
        }
        let enabled = sound ? soundEnabled : hapticEnabled
        KeyboardFeedbackService.shared.refreshPreferences()
        if enabled { KeyboardFeedbackService.shared.prepare() }
        KeyboardFeedbackService.shared.selectionChanged()
    }

    /// Strength rows persist through the service (which also updates its cache) and play
    /// one preview at the new level.
    private func cycleSoundLevel() {
        let newLevel = soundLevel.next
        KeyboardFeedbackService.shared.setSoundLevel(newLevel)
        soundLevel = newLevel
        KeyboardFeedbackService.shared.previewKeyFeedback(sound: true, haptic: false, level: newLevel)
    }

    private func cycleHapticLevel() {
        let newLevel = hapticLevel.next
        KeyboardFeedbackService.shared.setHapticLevel(newLevel)
        hapticLevel = newLevel
        KeyboardFeedbackService.shared.previewKeyFeedback(sound: false, haptic: true, level: newLevel)
    }

    private func optionRow(_ state: EngineOptionState) -> some View {
        let currentLabel = state.value ? state.descriptor.enabledLabel : state.descriptor.disabledLabel
        // The switch already expresses on/off; only a current-state name from the schema (e.g. 繁體) that differs from the title is shown as a subtitle.
        let detail = currentLabel == state.descriptor.title ? nil : currentLabel
        return KeyboardToolsRow(
            icon: Self.icon(forOption: state.descriptor.name),
            title: state.descriptor.title,
            detail: detail,
            mark: .toggle(state.value),
            accessibilityLabel: state.descriptor.title,
            accessibilityValue: currentLabel
        ) {
            controller.setOption(state.descriptor.name, value: !state.value)
        }
    }

    /// Icons for common Rime switch names; unknown switches get a generic icon, with no semantic guessing from the title.
    static func icon(forOption name: String) -> String {
        let name = name.lowercased()
        if name.contains("simplif") || name.contains("tradition") || name.contains("zh_hant")
            || name.contains("zh_hans") || name.contains("zh_tw") || name.contains("zh_hk")
        {
            return "character.book.closed"
        }
        if name.contains("emoji") { return "face.smiling" }
        if name.contains("full_shape") { return "textformat.size" }
        if name.contains("ascii_punct") { return "ellipsis.bubble" }
        if name.contains("ascii") { return "textformat.abc" }
        if name.contains("unicode") || name.contains("charset") { return "character" }
        return "switch.2"
    }
}
