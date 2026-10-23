import KeyboardCore
import SwiftUI

/// Quick-insert tools (content of the keyboard's "Keyboard settings · Insert" card, injected via
/// `insertTools`; adds no top key and changes no layout/scheme/schema).
///
/// - Repeat last commit: shows a short preview row only when this input session has a recent non-empty
///   commit; a tap first completes the current composition with the existing confirm semantics, then
///   inserts once, and can be repeated. The outer `resetContext()` clears it on focus loss / host switch; user input is never persisted.
/// - Insert date and time: a few fixed formats, shown as the text that will be inserted; a tap generates it in the device time zone and inserts it.
///
/// Visuals come from `KeyboardToolsStyle` (section header + single-layer card + uniform rows).
public struct QuickInsertView: View {
    @ObservedObject private var state: QuickInsertState
    @Environment(\.keyboardAppearance) private var appearance

    public init(state: QuickInsertState) {
        self.state = state
    }

    /// Emits rows only, no section: the panel merges them into the "Insert" card (the first row is the symbol library, so each row is preceded by a separator).
    public var body: some View {
        if state.hasRepeatableText {
            KeyboardToolsSeparator(leadingInset: separatorInset)
            KeyboardToolsRow(
                icon: "arrow.uturn.backward",
                title: "重复上次输入",
                trailingText: state.repeatPreview.map { "“\($0)”" },
                accessibilityLabel: "重复上次输入",
                accessibilityValue: state.repeatPreview ?? "",
                accessibilityHint: "再次输入最近一次上屏的文字"
            ) {
                state.performRepeat()
            }
        }
        KeyboardToolsSeparator(leadingInset: separatorInset)
        dateChips
    }

    /// Date/time rows show the text that will be inserted: what you see is what a tap inserts, with no format to pick first.
    private var dateChips: some View {
        HStack(spacing: KeyboardToolsStyle.iconTitleSpacing) {
            Image(systemName: "calendar")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(uiColor: appearance.text(on: "key", secondary: true)))
                .frame(width: KeyboardToolsStyle.iconColumnWidth)
                .accessibilityHidden(true)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuickInsertDateFormat.allCases) { format in
                        chip(format)
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.leading, KeyboardToolsStyle.contentHorizontalInset)
        .frame(maxWidth: .infinity, minHeight: KeyboardToolsStyle.rowMinHeight, alignment: .leading)
    }

    private func chip(_ format: QuickInsertDateFormat) -> some View {
        let text = state.formattedText(format)
        return Button {
            state.insertDateFormat(format)
        } label: {
            Text(text)
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: KeyboardToolsStyle.rowMinHeight)
                .contentShape(Rectangle())
        }
        // Function-key tone on the key-coloured card, like Shift/Delete beside letters.
        .buttonStyle(KeyboardToolsKeyButtonStyle(role: "control"))
        .accessibilityLabel("插入\(format.title)")
        .accessibilityValue(text)
    }

    private var separatorInset: CGFloat {
        KeyboardToolsStyle.contentHorizontalInset + KeyboardToolsStyle.iconColumnWidth
            + KeyboardToolsStyle.iconTitleSpacing
    }
}
