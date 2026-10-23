import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

// MARK: - Main key row (letters / numbers / symbols, full width)

private struct KeyboardKeyHeightKey: EnvironmentKey { static let defaultValue: CGFloat = 50 }
private struct KeyboardPopupSurfaceKey: EnvironmentKey { static let defaultValue: UIView? = nil }
extension EnvironmentValues {
    var keyboardKeyHeight: CGFloat {
        get { self[KeyboardKeyHeightKey.self] }
        set { self[KeyboardKeyHeightKey.self] = newValue }
    }
    var keyboardPopupSurface: UIView? {
        get { self[KeyboardPopupSurfaceKey.self] }
        set { self[KeyboardPopupSurfaceKey.self] = newValue }
    }
}

/// The same clipped, panel-local overlay is used in both the app and the extension.
struct KeyboardPopupSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView {
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Value snapshot of the key-area render inputs (see `KeyboardPanelView.keyAreaRenderToken`).
struct KeyAreaRenderToken: Equatable {
    let phoneMetrics: PhoneKeypadMetrics?
    let controller: ObjectIdentifier
    let hostBindingTick: Int
    let keyAreaGeneration: Int
    let page: KeyboardPage
    let keyHeight: CGFloat
    let appearance: KeyboardAppearance
    let preferredLayoutID: String?
    let definitionInputsRevision: UInt64
    let shuangpinHintEnabled: Bool
    let shuangpinHintPresetID: String?
    let shuangpinHintLabels: [String: String]
    let shuangpinHintRevision: UInt64
    let activeDefinition: LayoutDefinition?
    let layout: KeyboardLayoutKind
    let selectedSchemaID: String
    let inputMode: InputMode
    let isEnglishMode: Bool
    let shiftState: ShiftState
    let isComposing: Bool
    let usesASCIIPunctuation: Bool
    let returnKeyTitle: String
    let isReturnKeyEnabled: Bool
    let schemaAlphabet: String
    let publishedKeyboards: [UserKeyboard]
    let quickSymbols: String
    let layoutHintName: String?
    let layoutHintToken: UUID?
    let hasKeyAlternates: Bool
    let hasSystemKeyboardSwitch: Bool
    let allowsCursorMovement: Bool
}

/// `.equatable()` gate: while the token is unchanged SwiftUI skips recomputing `content`, and subviews'
/// environment dependencies (appearance, disabled state) still update as usual.
struct KeyAreaRenderGate<Content: View>: View, Equatable {
    let token: KeyAreaRenderToken
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }

    var body: some View { content() }
}

struct WeightedKeyRow: View {
    @Environment(\.keyboardKeyHeight) private var keyHeight
    let caps: [KeyCap]
    var edgeUnits: CGFloat = 0
    var alternates: (KeyCap) -> [KeyCap] = { _ in [] }
    var isEnabled: (KeyCap) -> Bool = { _ in true }
    var showsKeyPreview = false
    var showsAlternateHint = true
    var visualRole: String? = nil
    let onTap: (KeyCap) -> Void

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let available = max(geometry.size.width - spacing * CGFloat(max(caps.count - 1, 0)), 0)
            let total = max(caps.reduce(CGFloat.zero) { $0 + CGFloat($1.width) } + edgeUnits * 2, 1)
            HStack(spacing: spacing) {
                ForEach(caps) { cap in
                    AlternateCharacterKey(
                        cap: cap, alternates: alternates(cap),
                        showsKeyPreview: showsKeyPreview,
                        showsAlternateHint: showsAlternateHint,
                        visualRole: visualRole, onSelect: onTap
                    )
                    .disabled(!isEnabled(cap))
                    .opacity(isEnabled(cap) ? 1 : 0.45)
                    .frame(width: available * CGFloat(cap.width) / total, height: keyHeight)
                }
            }
            .padding(.horizontal, available * edgeUnits / total)
        }
        .frame(height: keyHeight)
    }
}
