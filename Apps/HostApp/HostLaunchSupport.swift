import Foundation
import KeyboardCore
import PackageManager
import SwiftUI

/// First-launch routing: strict, asynchronous, and never scans directories in `App.init`.
///
/// Only a strictly decodable, usable publication record or install receipt counts as
/// "already configured". Empty directories, leftover staging/log files and corrupt JSON do not,
/// so upgrading users are not misrouted and new users are not skipped past onboarding.
@MainActor
enum HostLaunchRouter {

    /// - Parameter activationRoot: test injection only (App Group root); nil in production.
    static func hasUsableConfiguration(
        activationRoot: URL? = nil,
        includeStores: Bool = true
    ) async -> Bool {
        // 1) App Group publication record: `snapshot(selectedOnly:)` strictly validates the generation,
        //    enabled manifest and compiled schemes; any failure throws, meaning no usable publication.
        //    Disk reads go through the resource read queue, off the main thread.
        if let snapshot = try? await KeyboardResourceReadQueue.async({
            try KeyboardRecipeStore.snapshot(rootURL: activationRoot, selectedOnly: true)
        }),
            !ProductionInputAvailability.isBuiltin(resourceID: snapshot.activation.resourceID)
        {
            return true
        }
        guard includeStores else { return false }
        // 2) Strictly decoded install receipts (generic import source / dictionary build).
        if await InstalledConfigurationProbe.hasAnyActiveInstallation(inPackageStoreRoot: SchemeImportCenter.storeRoot)
        {
            return true
        }
        if await InstalledConfigurationProbe.hasActiveInstallation(inStoreRoot: DictionaryImportCenter.storeRoot) {
            return true
        }
        return false
    }
}

/// Host root view: checks the persisted completion flag first, then decides whether to probe asynchronously.
///
///  - First frame: `onboardingCompleted == true` renders the home screen directly, with no probe
///    or loading state and no full-screen `ProgressView` flash; only incomplete users are probed.
///  - The probe runs in `task`, not by enumerating directories synchronously in `App.init`.
///  - Only strictly decoded real records are trusted; leftover files cannot cause a false positive.
///  - "Skip onboarding" enters the home screen without writing the completion flag.
struct HostRootView: View {
    @AppStorage(AppSettings.onboardingCompletedKey) private var onboardingCompleted = false
    @State private var probeRoute: LaunchConfigurationPolicy.Route?

    var body: some View {
        Group {
            switch LaunchConfigurationPolicy.initialRoute(onboardingCompleted: onboardingCompleted) {
            case .main:
                // Completed: home screen on the first frame, no probe or loading state.
                MainTabView()
            case .probe, .onboarding:
                switch probeRoute {
                case .none:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .some(.main), .some(.probe):
                    MainTabView()
                case .some(.onboarding):
                    OnboardingView(
                        presentation: .standalone,
                        onFinish: { finishOnboarding() },
                        onSkip: { skipOnboarding() })
                }
            }
        }
        .task {
            // Completed users must never trigger the probe.
            guard LaunchConfigurationPolicy.initialRoute(onboardingCompleted: onboardingCompleted) == .probe,
                probeRoute == nil
            else { return }
            let route = LaunchConfigurationPolicy.routeAfterProbe(
                hasUsableConfiguration: await HostLaunchRouter.hasUsableConfiguration())
            // A usable configuration counts as completed onboarding, so later cold starts go straight home.
            if route == .main { onboardingCompleted = true }
            probeRoute = route
        }
    }

    /// Onboarding finished: write the completion flag and enter the home screen.
    private func finishOnboarding() {
        onboardingCompleted = true
        probeRoute = .main
    }

    /// Skipped: enter the home screen this time without writing the flag (the next launch re-decides from the real configuration).
    private func skipOnboarding() {
        probeRoute = .main
    }
}
