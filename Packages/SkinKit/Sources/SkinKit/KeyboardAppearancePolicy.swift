import Foundation

/// The host text field's requested keyboard appearance
/// (`UITextInputTraits.keyboardAppearance`), reduced to a UIKit-free value so the
/// resolution policy is unit-testable off-device. The app layer maps
/// `UIKeyboardAppearance` onto this type.
public enum HostKeyboardAppearance: String, CaseIterable, Sendable {
    /// The field does not request an appearance (`UIKeyboardAppearance.default`).
    case unspecified
    case light
    case dark
}

/// Decides which variant (light/dark) of the active skin to render.
///
/// Rules (single source of truth; consumed by `KeyboardPanelHost`):
///  - The **system default** skin follows the actual keyboard surface trait once
///    UIKit has resolved it, including a field-specific light/dark surface.
///    A proxy field's keyboardAppearance can lag behind a live style transition,
///    so it is only a fallback before the surface trait is known.
///  - A **custom** skin keeps the user's own `SkinAppearance`; the host field never
///    repaints a user-authored skin.
///
/// `systemDark` is the SwiftUI environment's colour scheme (`colorScheme == .dark`).
public enum KeyboardAppearancePolicy {
    public static func resolvedDark(
        skinIsSystemDefault: Bool,
        skinAppearance: SkinAppearance,
        hostAppearance: HostKeyboardAppearance,
        systemDark: Bool,
        systemTraitKnown: Bool = false
    ) -> Bool {
        if skinIsSystemDefault {
            if systemTraitKnown { return systemDark }
            switch hostAppearance {
            case .light: return false
            case .dark: return true
            case .unspecified: return systemDark
            }
        }
        switch skinAppearance {
        case .light: return false
        case .dark: return true
        case .system: return systemDark
        }
    }
}
