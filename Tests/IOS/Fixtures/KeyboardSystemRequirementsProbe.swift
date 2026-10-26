import Foundation

/// Test seam for the host's last known system requirement.
///
/// Production reads the value through `KeyboardSystemRequirements`, which stores it in the shared
/// recipe defaults. Probes cannot touch the real app group, so this thread-safe double keeps the
/// same two lookups and lets a probe switch between unknown / required / not required. LayoutManager
/// reads it on the configuration queue while the probe writes it from the main actor, hence the lock.
enum KeyboardSystemRequirementsProbe {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var required: Bool?

        func read() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return required
        }

        func write(_ value: Bool?) {
            lock.lock()
            required = value
            lock.unlock()
        }
    }

    private static let state = State()

    /// `nil` means the keyboard never appeared yet (unknown).
    static func setRequired(_ value: Bool?) { state.write(value) }
    static var required: Bool? { state.read() }
}

enum KeyboardSystemRequirements {
    static func lastKnownNeedsInputModeSwitchKey() -> Bool? {
        KeyboardSystemRequirementsProbe.required
    }

    /// Unknown counts as required, exactly like the production helper.
    static func requiresKeyboardSwitchEntry() -> Bool {
        KeyboardSystemRequirementsProbe.required ?? true
    }
}
