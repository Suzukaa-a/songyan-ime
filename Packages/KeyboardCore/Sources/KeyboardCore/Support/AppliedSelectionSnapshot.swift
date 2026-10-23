import Foundation

/// Immutable value snapshot of the currently applied input selection (pure value).
///
/// Host views must not read the publication record from disk in SwiftUI computed properties
/// or `body` (file I/O on every redraw). Instead one structured async read produces this
/// snapshot, `@State` holds it, and `body` only derives pure values from it (in use / current
/// input method / revision / dictionary name). Refresh triggers are entering the page and
/// apply/install state changes.
///
/// It depends only on `String` and basic collections, not the app-layer
/// `KeyboardRecipeStore.ResourceKind`, so KeyboardCore tests can cover it; callers pass
/// `ResourceKind.rawValue` as `resourceKind`.
public struct AppliedSelectionSnapshot: Equatable, Sendable {
    /// Whether the publication record is enabled (in use).
    public let recipeEnabled: Bool
    /// Source kind (same value as `KeyboardRecipeStore.ResourceKind.rawValue`).
    public let resourceKind: String
    /// Input method (schema) ID explicitly selected in the publication record; nil = not explicit.
    public let selectedSchemaID: String?
    /// All input method IDs in the publication's enabled list (fallback when none is explicitly selected).
    public let requiredSchemaIDs: [String]
    /// Publication revision (for the "new version installed, not applied" check); nil = unknown.
    public let revision: String?
    /// Dictionary display name (for the custom-pinyin detail); nil = not applicable/unknown.
    public let dictionaryName: String?
    /// Package identifier of an installed scheme (`userScheme`); nil = not applicable.
    public let packageID: String?
    /// Whether an enabled real shared publication record exists (not built-in, not an empty
    /// generation). Lets views such as `RecipeView` derive the shared-container status line without another read.
    public let hasRealPublication: Bool
    /// Publication record name (`Activation.name`, source identity); used to derive the status line.
    public let publicationName: String?
    /// Display config name the publication record uses for the home scheme summary
    /// (`Activation.displayConfigName`). Separate from `publicationName`: this is the user's
    /// current configuration name, that is the publication's source identity.
    public let displayConfigName: String
    /// Full description of the publication's enabled list (for resolving input method display names); may be empty.
    public let schemas: [KeyboardSchemaDescriptor]
    /// Physical layout of the publication selection; nil = not explicit.
    public let selectedLayout: KeyboardLayoutKind?

    public init(
        recipeEnabled: Bool, resourceKind: String,
        selectedSchemaID: String?, requiredSchemaIDs: [String],
        revision: String? = nil, dictionaryName: String? = nil,
        packageID: String? = nil, hasRealPublication: Bool = false,
        publicationName: String? = nil, displayConfigName: String = "",
        schemas: [KeyboardSchemaDescriptor] = [],
        selectedLayout: KeyboardLayoutKind? = nil
    ) {
        self.recipeEnabled = recipeEnabled
        self.resourceKind = resourceKind
        self.selectedSchemaID = selectedSchemaID
        self.requiredSchemaIDs = requiredSchemaIDs
        self.revision = revision
        self.dictionaryName = dictionaryName
        self.packageID = packageID
        self.hasRealPublication = hasRealPublication
        self.publicationName = publicationName
        self.displayConfigName = displayConfigName
        self.schemas = schemas
        self.selectedLayout = selectedLayout
    }

    /// Empty snapshot kept when no usable publication record exists or the read failed (not applied, no input methods).
    public static let none = AppliedSelectionSnapshot(
        recipeEnabled: false, resourceKind: "", selectedSchemaID: nil, requiredSchemaIDs: [])

    /// Shared-container status line (pure value); the wording is user-facing.
    /// `requiresFullAccessNote` appends the "next time the keyboard shows; Full Access needed" note.
    public func keyboardStatusLine(requiresFullAccessNote: Bool) -> String {
        let suffix = requiresFullAccessNote ? "（下次打开键盘时生效，需要开启「允许完全访问」）" : ""
        if recipeEnabled, hasRealPublication, let publicationName {
            return "可以读写共享数据；已选择「\(publicationName)」\(suffix)"
        }
        return "可以读写共享数据；\(ProductionInputAvailability.unconfiguredTitle)\(suffix)"
    }

    /// Whether a source kind is in use: must be enabled and the kind must match.
    public func isApplied(resourceKind kind: String) -> Bool {
        recipeEnabled && resourceKind == kind
    }

    /// IDs of input methods in use (including the publication selection's source mapping):
    /// only the explicit selection if there is one, otherwise the whole enabled list. Empty when not applied.
    public func activeSchemaIDs(resourceKind kind: String) -> Set<String> {
        guard isApplied(resourceKind: kind) else { return [] }
        if let selectedSchemaID { return [selectedSchemaID] }
        return Set(requiredSchemaIDs)
    }
}

/// Result of one structured async read (pure value): a snapshot on success, an error on failure.
public struct AppliedSelectionLoadOutcome: Equatable, Sendable {
    /// Snapshot read successfully; nil = read failed (the caller keeps the old snapshot).
    public let snapshot: AppliedSelectionSnapshot?
    /// Failure reason; nil = success.
    public let error: String?

    public init(snapshot: AppliedSelectionSnapshot?, error: String?) {
        self.snapshot = snapshot
        self.error = error
    }
}

public extension AppliedSelectionSnapshot {
    /// Landing policy for a result (pure value):
    ///  - Read succeeded: replace with the new snapshot and clear the error.
    ///  - Read failed: keep the previous snapshot (no flash back to blank) and surface the error.
    ///
    /// The status line can show a read failure without clearing an already displayed "in use",
    /// and `body` never touches disk on redraw.
    static func resolve(
        previous: AppliedSelectionSnapshot,
        outcome: AppliedSelectionLoadOutcome
    )
        -> (snapshot: AppliedSelectionSnapshot, error: String?)
    {
        guard let snapshot = outcome.snapshot else {
            return (previous, outcome.error)
        }
        return (snapshot, nil)
    }
}

/// Structured refresh key for the onboarding page (pure value): re-runs only on first
/// appearance, return to foreground, and install/apply state changes; paging changes only
/// the displayed content and does not rescan sources or re-read the activation record.
public struct OnboardingRefreshKey: Equatable, Sendable {
    public let refreshTick: Int
    public init(refreshTick: Int) {
        self.refreshTick = refreshTick
    }
}

/// Pure-value display inputs for the onboarding status line: display fields the app layer
/// parses after reading `activation` on the read-only queue. References no app-layer types.
public struct AppliedSelectionDisplayInputs: Equatable, Sendable {
    public let resourceID: String
    public let recipeEnabled: Bool
    /// `ResourceKind.rawValue` ("userDictionary" / "userScheme").
    public let resourceKind: String
    public let displayConfigName: String
    public let selectedInputMethodName: String?
    public let selectedLayoutName: String?

    public init(
        resourceID: String, recipeEnabled: Bool, resourceKind: String,
        displayConfigName: String, selectedInputMethodName: String?,
        selectedLayoutName: String?
    ) {
        self.resourceID = resourceID
        self.recipeEnabled = recipeEnabled
        self.resourceKind = resourceKind
        self.displayConfigName = displayConfigName
        self.selectedInputMethodName = selectedInputMethodName
        self.selectedLayoutName = selectedLayoutName
    }
}

/// Pure-value display snapshot of the onboarding status line: the UI only consumes it (no disk, no await).
public struct AppliedSelectionDisplaySummary: Equatable, Sendable {
    /// The `statusLine` text.
    public let statusLine: String
    /// Whether a real usable scheme exists (decides whether to prompt "add one first").
    public let hasRealScheme: Bool

    public init(statusLine: String, hasRealScheme: Bool) {
        self.statusLine = statusLine
        self.hasRealScheme = hasRealScheme
    }

    /// Derives the status line from immutable display inputs; no disk, no await.
    ///
    /// No record / not enabled / built-in package only gives the explicit "no usable input scheme
    /// configured" line.
    public static func make(from inputs: AppliedSelectionDisplayInputs?) -> AppliedSelectionDisplaySummary {
        guard let inputs, inputs.recipeEnabled,
            !ProductionInputAvailability.isBuiltin(resourceID: inputs.resourceID)
        else {
            return AppliedSelectionDisplaySummary(
                statusLine: ProductionInputAvailability.unconfiguredTitle, hasRealScheme: false)
        }
        return AppliedSelectionDisplaySummary(
            statusLine: UserTerminology.inUseSummary(
                scheme: inputs.displayConfigName, inputMethod: inputs.selectedInputMethodName,
                layout: inputs.selectedLayoutName),
            hasRealScheme: true)
    }
}
