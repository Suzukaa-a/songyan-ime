import Foundation

/// Boot kind of one keyboard appearance, logged to tell warm resumes from cold starts.
public enum KeyboardBootClassification: String, Equatable, Sendable {
    /// A ready engine already in the process was reused.
    case warmReuse
    /// The process was ready before but has no ready engine now.
    case coldRebootInProcess
    /// First ready engine in this process.
    case coldFirstBoot

    public var isCold: Bool { self != .warmReuse }

    public init(hadReadyEngineAtEntry: Bool, processHasEverBeenReady: Bool) {
        if hadReadyEngineAtEntry {
            self = .warmReuse
        } else {
            self = processHasEverBeenReady ? .coldRebootInProcess : .coldFirstBoot
        }
    }
}
