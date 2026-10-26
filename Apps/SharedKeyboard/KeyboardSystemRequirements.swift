import Foundation

/// The last known system requirement for a keyboard-switch entry.
///
/// The extension reads the input controller's real needsInputModeSwitchKey on every appearance and
/// records it here; the app validates a layout against that value before it saves or imports one.
/// The value can change while the process lives (another host, a folded cover screen), so it is not
/// treated as a device constant. Unknown means required: a missing record must never let an
/// unreachable switch through.
public enum KeyboardSystemRequirements {
    static let needsInputModeSwitchKeyKey = "keyboard.needsInputModeSwitchKey"
    /// Serial so two appearance writes can never land out of order.
    private static let writeQueue = DispatchQueue(
        label: "app.songyan.keyboard.systemRequirements", qos: .utility)

    /// The value this process last wrote; repeated appearances with the same answer write nothing.
    @MainActor private static var lastRecorded: Bool?

    /// Keyboard side: called on the appearance path only; the write leaves the key and first-frame
    /// paths because it runs on the serial background queue.
    @MainActor
    public static func recordNeedsInputModeSwitchKey(_ needed: Bool) {
        guard lastRecorded != needed else { return }
        lastRecorded = needed
        let key = needsInputModeSwitchKeyKey
        writeQueue.async {
            KeyboardRecipeStore.sharedDefaults()?.set(needed, forKey: key)
        }
    }

    /// Host side: the last recorded value, or nil until a keyboard has appeared. Read it on the
    /// caller's own configuration queue, never on the main thread.
    public static func lastKnownNeedsInputModeSwitchKey() -> Bool? {
        guard let defaults = KeyboardRecipeStore.sharedDefaults(),
            defaults.object(forKey: needsInputModeSwitchKeyKey) != nil
        else { return nil }
        return defaults.bool(forKey: needsInputModeSwitchKeyKey)
    }

    /// The requirement to validate against. Unknown counts as required.
    public static func requiresKeyboardSwitchEntry() -> Bool {
        lastKnownNeedsInputModeSwitchKey() ?? true
    }
}
