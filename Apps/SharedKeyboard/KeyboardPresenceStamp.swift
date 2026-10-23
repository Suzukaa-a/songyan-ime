import Foundation
import os

/// Presence marker for "keyboard added and full access granted".
///
/// A keyboard can write the App Group only with full access, so the marker's existence proves
/// both hold; the host uses it to show the real status in onboarding and on the home page, without
/// relying on private APIs to enumerate system keyboards. Records only a timestamp, never input content.
public enum KeyboardPresenceStamp {
    static let key = "keyboard.fullAccessSeenAt"
    private static let recordedThisProcess = OSAllocatedUnfairLock(initialState: false)

    /// Keyboard side: recorded at least once per process; the write goes to the background so it stays off the key and first-frame paths.
    public static func recordFullAccessSeen() {
        let first = recordedThisProcess.withLock { recorded in
            defer { recorded = true }
            return !recorded
        }
        guard first else { return }
        DispatchQueue.global(qos: .utility).async {
            KeyboardRecipeStore.sharedDefaults()?
                .set(Date().timeIntervalSince1970, forKey: key)
        }
    }

    /// Host side: the most recent time it appeared under full access; nil if never (or full access is off).
    public static func lastFullAccessSeen() -> Date? {
        let value = KeyboardRecipeStore.sharedDefaults()?.double(forKey: key) ?? 0
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}
