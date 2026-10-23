import CandidateKit
import SwiftUI

/// Unified visual system for the keyboard's tools page (pure styling, no action/state semantics).
///
/// It gives the tool items (panel tools page, schema options, quick insert,
/// composition toggle) into one language:
///  - a stable title bar (provided by `KeyboardPanelView.toolsTitleBar`) above scrollable content;
///  - a uniform section header `KeyboardToolsSectionHeader` + section card `KeyboardToolsCard`;
///  - uniform row height (>= 44), horizontal insets, icon column, text hierarchy, separators and selected/disabled states;
///  - a section has a single background layer and corner radius; rows add no borders/materials of their own.
///
/// All colors come from `KeyboardAppearance` (skin + light/dark) and fonts use semantic sizes, so it
/// adapts to light/dark, skin colors and Dynamic Type; accessibility labels are declared at each call site.
enum KeyboardToolsStyle {
    /// Distance from section cards and headers to the panel's left/right edges.
    static let contentHorizontalInset: CGFloat = 16
    /// Section card corner radius; the row pressed highlight uses the same radius.
    static let cardCornerRadius: CGFloat = 12
    /// Minimum height of any tappable row.
    static let rowMinHeight: CGFloat = 44
    /// Icon column width: rows without an icon keep a same-width placeholder so title left edges align.
    static let iconColumnWidth: CGFloat = 24
    /// Spacing between the icon column and the title.
    static let iconTitleSpacing: CGFloat = 12
    /// Vertical spacing between sections.
    static let sectionTopPadding: CGFloat = 14
    /// Spacing between a section header and its card.
    static let sectionHeaderBottomPadding: CGFloat = 6
    /// Labels of a leading category column (the 9-key symbol page, the quick-content
    /// panel): readable at a glance, and three Chinese characters still fit a 60pt column.
    static let categoryRailTitleSize: Double = 16
}

// MARK: - Panel dismiss button

/// The one way out of a keyboard panel, top-right: 「完成」 in the settings panel,
/// 「返回」 in the quick-content panel. Drawn like the Return key, as the panel's
/// primary action, on a 44pt hit frame.
struct KeyboardToolsDismissButton: View {
    let title: String
    var accessibilityHint: String?
    /// Lets a short title bar keep the frame inside its own height.
    var minHeight: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: 44, minHeight: minHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardToolsKeyButtonStyle(role: "accent"))
        .accessibilityHint(accessibilityHint ?? "")
    }
}

// MARK: - Section header

struct KeyboardToolsSectionHeader: View {
    @Environment(\.keyboardAppearance) private var appearance
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(uiColor: appearance.text(on: "panel", secondary: true)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Section card

/// One uniform background + corner radius holds a whole group of rows; rows are separated by `KeyboardToolsSeparator`.
/// The card is a keycap surface (fill and border as the skin draws letter keys), so the list reads as part of the keyboard.
struct KeyboardToolsCard<Content: View>: View {
    @Environment(\.keyboardAppearance) private var appearance
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: KeyboardToolsStyle.cardCornerRadius, style: .continuous)
                .fill(appearance.color("key"))
                .overlay(
                    RoundedRectangle(cornerRadius: KeyboardToolsStyle.cardCornerRadius, style: .continuous)
                        .strokeBorder(appearance.color("border"), lineWidth: appearance.skin.keycap.borderWidth)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: KeyboardToolsStyle.cardCornerRadius, style: .continuous))
        .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
    }
}

/// Section header + card. All tool sections should render through this.
struct KeyboardToolsSection<Content: View>: View {
    let title: String
    var topPadding: CGFloat = KeyboardToolsStyle.sectionTopPadding
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: KeyboardToolsStyle.sectionHeaderBottomPadding) {
            KeyboardToolsSectionHeader(title: title)
            KeyboardToolsCard { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, topPadding)
    }
}

// MARK: - Separator

struct KeyboardToolsSeparator: View {
    @Environment(\.keyboardAppearance) private var appearance
    var leadingInset: CGFloat = KeyboardToolsStyle.contentHorizontalInset

    var body: some View {
        Rectangle()
            .fill(appearance.color("border").opacity(0.6))
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

// MARK: - Trailing mark

enum KeyboardToolsMark: Equatable {
    /// No mark.
    case none
    /// Toggle: a drawn capsule switch (same shape as the system `Toggle`); the whole row is still one button.
    case toggle(Bool)
    /// Selection: a checkmark only (shown when selected).
    case check(Bool)
}

// MARK: - Generic row

/// Uniform tools-page row: icon column (fixed width, may be an empty placeholder) + title/subtitle + trailing text/mark/chevron.
/// Always a single Button (`.disabled` when not tappable), with a hit height >= 44.
struct KeyboardToolsRow: View {
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled

    var icon: String? = nil
    var iconTint: Color? = nil
    var title: String
    var titleLineLimit: Int = 1
    var detail: String? = nil
    var detailLineLimit: Int = 1
    var trailingText: String? = nil
    var mark: KeyboardToolsMark = .none
    var showsChevron: Bool = false
    var isExpanded: Bool = false
    var isSelected: Bool = false
    var accessibilityLabel: String? = nil
    var accessibilityValue: String? = nil
    var accessibilityHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: KeyboardToolsStyle.iconTitleSpacing) {
                iconColumn
                textColumn
                Spacer(minLength: 8)
                if let trailingText, !trailingText.isEmpty {
                    Text(trailingText)
                        .font(.footnote)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .minimumScaleFactor(0.8)
                }
                markView
                if showsChevron { chevron }
            }
            .padding(.horizontal, KeyboardToolsStyle.contentHorizontalInset)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: KeyboardToolsStyle.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(KeyboardToolsRowButtonStyle())
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Internals

    @ViewBuilder
    private var iconColumn: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconTint ?? (isSelected ? appearance.accentForeground : secondaryColor))
                .frame(width: KeyboardToolsStyle.iconColumnWidth)
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: KeyboardToolsStyle.iconColumnWidth, height: 1)
        }
    }

    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .foregroundStyle(primaryColor)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: titleLineLimit > 1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(detailLineLimit)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: detailLineLimit > 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .none:
            EmptyView()
        case .toggle(let isOn):
            KeyboardToolsSwitch(isOn: isOn)
        case .check(let isOn):
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.accentForeground)
                    .frame(width: 20)
                    .accessibilityHidden(true)
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(secondaryColor)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }

    // Rows sit on the keycap-coloured card.
    private var primaryColor: Color { Color(uiColor: appearance.text(on: "key")) }
    private var secondaryColor: Color { Color(uiColor: appearance.text(on: "key", secondary: true)) }
}

/// Read-only switch look: a 47x28 capsule, accent color when on and separator color when off; the knob slides with state.
/// It has no gesture of its own: hit testing and the action belong to the row, avoiding two touch owners (row and switch).
struct KeyboardToolsSwitch: View {
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isOn: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(isOn ? appearance.accentForeground : appearance.color("border").opacity(0.9))
            .frame(width: 47, height: 28)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                    .padding(2)
            }
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: isOn)
            .accessibilityHidden(true)
    }
}

/// Row pressed state: local corner radius + the skin's `pressed` color; only the timing is shared
/// (instant color change + critically damped spring, immediate under Reduce Motion). The shared layer draws no
/// rectangular overlay, so rounded cards are not covered by a square highlight.
struct KeyboardToolsRowButtonStyle: ButtonStyle {
    @Environment(\.keyboardAppearance) private var appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: KeyboardToolsStyle.cardCornerRadius, style: .continuous)
                    .fill(appearance.color("pressed"))
                    .opacity(configuration.isPressed ? 1 : 0)
            )
            .keyboardChromePressTiming(isPressed: configuration.isPressed)
    }
}

/// Capsule button painted with a keycap role (`control` for chips, `accent` for "Done", as the
/// Return key): fill, text and pressed colour come from the skin like real keys. The label
/// keeps its 44pt hit frame; only the `height`-tall capsule is drawn.
struct KeyboardToolsKeyButtonStyle: ButtonStyle {
    @Environment(\.keyboardAppearance) private var appearance
    var role = "control"
    var height: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.isPressed ? "pressed" : role
        configuration.label
            .foregroundStyle(Color(uiColor: appearance.text(on: fill)))
            .background(
                Capsule(style: .continuous)
                    .fill(appearance.color(fill))
                    .frame(height: height)
            )
            .keyboardChromePressTiming(isPressed: configuration.isPressed)
    }
}
