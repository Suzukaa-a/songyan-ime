import XCTest

@testable import SkinKit

/// `KeyboardAppearancePolicy` decision matrix: the system default skin follows the host field, custom skins follow the user's choice.
final class KeyboardAppearancePolicyTests: XCTestCase {
    private func dark(
        systemDefault: Bool, skin: SkinAppearance,
        host: HostKeyboardAppearance, systemDark: Bool
    ) -> Bool {
        KeyboardAppearancePolicy.resolvedDark(
            skinIsSystemDefault: systemDefault,
            skinAppearance: skin,
            hostAppearance: host,
            systemDark: systemDark)
    }

    /// System default skin: a forced light/dark field wins; `.unspecified` falls back to the SwiftUI system environment.
    func testSystemDefaultSkinFollowsHostField() {
        for systemDark in [false, true] {
            XCTAssertFalse(dark(systemDefault: true, skin: .system, host: .light, systemDark: systemDark))
            XCTAssertTrue(dark(systemDefault: true, skin: .system, host: .dark, systemDark: systemDark))
            XCTAssertEqual(
                dark(systemDefault: true, skin: .system, host: .unspecified, systemDark: systemDark),
                systemDark)
        }
        // The field still wins on the system default skin even if the document preference is light/dark (matches the read-only default).
        XCTAssertFalse(dark(systemDefault: true, skin: .dark, host: .light, systemDark: true))
        XCTAssertTrue(dark(systemDefault: true, skin: .light, host: .dark, systemDark: false))
    }

    func testResolvedKeyboardSurfaceWinsOverStaleHostProxy() {
        // UIKit has already resolved the keyboard surface; a proxy value can
        // briefly disagree with its actual light/dark trait during a live
        // system change. An explicit field-specific surface is also reflected
        // in that same trait and follows this path.
        XCTAssertTrue(
            KeyboardAppearancePolicy.resolvedDark(
                skinIsSystemDefault: true, skinAppearance: .system,
                hostAppearance: .light, systemDark: true, systemTraitKnown: true))
        XCTAssertFalse(
            KeyboardAppearancePolicy.resolvedDark(
                skinIsSystemDefault: true, skinAppearance: .system,
                hostAppearance: .dark, systemDark: false, systemTraitKnown: true))
    }

    /// Custom skins: the user's choice is not overridden by the field.
    func testCustomSkinKeepsUserChoice() {
        for host in HostKeyboardAppearance.allCases {
            XCTAssertFalse(dark(systemDefault: false, skin: .light, host: host, systemDark: true))
            XCTAssertTrue(dark(systemDefault: false, skin: .dark, host: host, systemDark: false))
        }
        XCTAssertTrue(dark(systemDefault: false, skin: .system, host: .light, systemDark: true))
        XCTAssertFalse(dark(systemDefault: false, skin: .system, host: .dark, systemDark: false))
        XCTAssertFalse(
            KeyboardAppearancePolicy.resolvedDark(
                skinIsSystemDefault: false, skinAppearance: .light,
                hostAppearance: .dark, systemDark: true, systemTraitKnown: true))
    }
}
