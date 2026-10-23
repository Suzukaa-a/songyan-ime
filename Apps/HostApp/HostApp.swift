import CandidateKit
import KeyboardCore
import SwiftUI

/// Host app preference keys (shared via AppStorage), persisted in the HostApp sandbox UserDefaults.
enum HostAppKeys {
    /// Developer Options switch: off by default. When on, shows diagnostic entry points and technical details
    /// (version/commit/paths/component probes/engine self-test). The regular UI stays simple.
    static let developerOptionsEnabled = "app.songyan.settings.developerOptions"
}

@main
struct HostApp: App {

    init() {
        // Candidate renderer registration (source-level extension point; the default renderer is the production rendering path).
        CandidateRenders.installDefault()
        #if DEBUG
            DebugProbe.reportEnvironment(role: "hostApp")
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // First-launch routing (strict probing + the first-run onboarding's own navigation) is in HostRootView:
            // existing users with a real configuration go straight to home; unconfigured new users enter the actionable onboarding.
            HostRootView()
                // `songyan://` exists only so the keyboard's settings panel can come back here
                // (an extension cannot open another app any other way). Landing on the home
                // screen is right: every setting starts from there, so no route is pending.
                .onOpenURL { _ in }
        }
    }
}
