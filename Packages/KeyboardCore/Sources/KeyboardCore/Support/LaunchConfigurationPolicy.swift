import Foundation

/// First-launch routing (pure function).
///
/// Only a strictly decodable and usable real publication record or install receipt counts as
/// "already configured": an empty directory, leftover staging/log, or corrupt JSON does not,
/// so none of them can skip first-run onboarding.
public enum LaunchConfigurationPolicy: Sendable {

    /// First-launch route result.
    public enum Route: Equatable, Sendable {
        /// Render the home page directly (completed users; the first frame must not go through probing).
        case main
        /// Needs an async strict probe (users who have not finished first-time setup).
        case probe
        /// Enter first-time setup onboarding.
        case onboarding
    }

    /// First-frame route: when the persisted completion flag is true go straight to home with no
    /// probe/loading state; only incomplete users need the async probe. This avoids flashing a
    /// full-screen `ProgressView` on every launch for existing users.
    public static func initialRoute(onboardingCompleted: Bool) -> Route {
        onboardingCompleted ? .main : .probe
    }

    /// Destination after the strict probe.
    public static func routeAfterProbe(hasUsableConfiguration: Bool) -> Route {
        hasUsableConfiguration ? .main : .onboarding
    }

    /// - Parameters:
    ///   - hasUsableRealPublication: the App Group publication record decodes strictly, validates, and is not built-in package.
    ///   - hasStrictlyDecodedInstallation: at least one install receipt decodes strictly and is valid.
    public static func shouldSkipOnboarding(
        hasUsableRealPublication: Bool,
        hasStrictlyDecodedInstallation: Bool
    ) -> Bool {
        hasUsableRealPublication || hasStrictlyDecodedInstallation
    }
}
