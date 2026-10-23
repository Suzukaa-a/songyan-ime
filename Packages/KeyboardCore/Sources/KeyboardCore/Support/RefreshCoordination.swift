import Foundation

/// Latest-wins token plus change-driven refresh key for the detail page's selection read
/// (pure value).
///
/// The view holds only a key that drives one read via `.task(id: key)`; `.onChange` and the
/// retry button only increment the key and never create a Task (`.task(id:)` cancels the
/// previous task and re-runs when the key changes).
///  - `beginRead()` issues a fresh token per read and `accepts(token:)` accepts only the
///    latest, so a late older read never overwrites a newer snapshot.
///  - When the view disappears `.task` is cancelled, and a `Task.isCancelled` guard after the
///    read keeps it from writing.
///
/// Same idea as `KeyboardAppearanceRefreshGate`, but for reads triggered by arbitrary changes,
/// and it distinguishes the first appearance from later changes.
public struct DetailRefreshCoordinator: Equatable, Sendable {
    /// Change key used as the `.task(id:)` id. Equal: no re-run; different: cancel and re-run.
    public private(set) var key: Int
    /// Latest-wins generation: advanced by every `beginRead()` and checked before a result lands.
    private var generation: UInt64

    public init() {
        self.key = 0
        self.generation = 0
    }

    /// Signals a refresh intent (first entry / state change / user retry): advances the key so
    /// `.task(id:)` cancels the in-flight task and re-runs once. Does not create a Task.
    public mutating func requestRefresh() {
        key &+= 1
    }

    /// Read start: issues this read's token (invalidating all earlier tokens).
    @discardableResult
    public mutating func beginRead() -> UInt64 {
        generation &+= 1
        return generation
    }

    /// Whether the token is still the latest read (safe to write its result). Older tokens are rejected.
    public func accepts(_ token: UInt64) -> Bool { token == generation }
}

/// Resolves "the input method ID a package is currently using" from the shared publication
/// selection (pure value).
///
/// This is pure policy: pass the activation fields in as values and it can be evaluated on
/// any thread or in plain tests, with no disk read.
public enum ActiveSchemaResolver {
    /// - Parameters:
    ///   - activation: value snapshot of the shared publication record; nil = no record.
    ///   - packageID: target package identifier of a generic imported scheme.
    /// - Returns: the schema ID the package currently uses; nil if not enabled or not matching.
    public static func currentSchemaID(
        recipeEnabled: Bool?, resourceKind: String?, packageID: String?,
        selectedSchemaID: String?, requiredSchemaIDs: [String],
        forPackageID target: String
    ) -> String? {
        // With nothing in use the keyboard runs the bundled built-in scheme's first input method.
        if recipeEnabled != true, target == ProductionInputAvailability.builtinPackageID {
            return BuiltinTemplateSchemas.quanpin
        }
        guard recipeEnabled == true, resourceKind == "userScheme", packageID == target else { return nil }
        if let selectedSchemaID { return selectedSchemaID }
        return requiredSchemaIDs.first
    }

    /// What a scheme detail page shows beside one input method: either 正在使用 or a single action.
    public enum InputMethodState: Equatable, Sendable {
        case inUse
        case use
        /// In use, but from an older installed version of the scheme.
        case useNewVersion
    }

    /// - Parameters:
    ///   - currentSchemaID: `currentSchemaID(...)` for the page's package.
    ///   - revisionIsCurrent: the publication carries the package's installed revision (true for the fallback, which publishes nothing).
    public static func state(
        of schemaID: String, currentSchemaID: String?,
        revisionIsCurrent: Bool
    ) -> InputMethodState {
        guard currentSchemaID == schemaID else { return .use }
        return revisionIsCurrent ? .inUse : .useNewVersion
    }
}

/// Two-gate decision for landing a structured refresh result (pure value).
///
/// After an async read returns, the UI may be written only if both hold:
///  1. The enclosing structured task was not cancelled (view disappeared / new intent;
///     `Task.isCancelled`).
///  2. This read is still the owner's latest intent (the latest-wins token is accepted).
///
/// If either fails, do not write: no writes after cancellation, no stale result over a new one.
public enum StructuredRefreshOutcome {
    public static func shouldApply(isCancelled: Bool, accepted: Bool) -> Bool {
        !isCancelled && accepted
    }
}
