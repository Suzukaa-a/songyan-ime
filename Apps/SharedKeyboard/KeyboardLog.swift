import OSLog

/// Every log line from both targets uses one subsystem, so `make sim-log` and
/// `log stream --predicate 'subsystem == "app.songyan.ime"'` see all of it. Packages
/// cannot see app code; their loggers repeat the same subsystem string.
///
/// Interpolate values with an explicit privacy level: technical identifiers (schema
/// IDs, layouts, counts, durations) are `.public`; names the user typed are `.private`.
extension Logger {
    static let songyanSubsystem = "app.songyan.ime"

    // Keyboard (extension and the host's typing area).
    static let keyboardExtension = Logger(subsystem: songyanSubsystem, category: "KeyboardExtension")
    static let keyboardController = Logger(subsystem: songyanSubsystem, category: "KeyboardController")
    static let keyboardPadSession = Logger(subsystem: songyanSubsystem, category: "KeyboardPadSession")
    static let keyboardLifecycle = Logger(subsystem: songyanSubsystem, category: "KeyboardLifecycle")
    static let keyboardStall = Logger(subsystem: songyanSubsystem, category: "KeyboardStall")
    static let keyboardTiming = Logger(subsystem: songyanSubsystem, category: "KeyboardTiming")
    static let keyboardStorage = Logger(subsystem: songyanSubsystem, category: "KeyboardStorage")
    static let debugProbe = Logger(subsystem: songyanSubsystem, category: "DebugProbe")

    // Host app.
    static let keyboardPreparation = Logger(subsystem: songyanSubsystem, category: "KeyboardPreparation")
    static let keyboardSave = Logger(subsystem: songyanSubsystem, category: "KeyboardSave")
}
