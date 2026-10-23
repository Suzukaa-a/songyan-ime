import Foundation

/// One already-resolved recipe stage selection: ordered recipe path plus its literal
/// arguments. Captured with a retry intent so a retry replays the exact same stages.
public struct SchemeImportStageSelection: Equatable, Sendable {
    public let path: String
    public let arguments: [RecipeArgument]
    public init(path: String, arguments: [RecipeArgument]) {
        self.path = path
        self.arguments = arguments
    }
}

/// The exact user operation that most recently started and has not yet succeeded.
///
/// It carries the already-selected inputs: the recognized package bytes themselves live
/// in the import center, while the recipe path/arguments/stages or the literal source
/// target are captured here. Retry therefore repeats the SAME selection and must never
/// reopen a file picker to ask the user to choose again.
public enum SchemeImportRetryIntent: Equatable, Sendable {
    /// Plain install of the already-recognized prepared package (`SchemeImportCenter.install`).
    case installRecognizedImport
    /// Plan check for the already-selected recipe/arguments/stages.
    case planRecipe(
        recipePath: String, arguments: [RecipeArgument],
        stages: [SchemeImportStageSelection], installed: Bool)
    /// Install of an already-planned recipe on a fresh import or an installed package.
    case installPlannedRecipe(
        recipePath: String, arguments: [RecipeArgument],
        stages: [SchemeImportStageSelection], installed: Bool)
    /// Install of the already-checked ordered Rime-source plan.
    case installSourcePlan
    /// Acquisition for the same literal Rime-source target.
    case acquireSource(target: String, updatingPackageID: String?)
}

/// What the UI must do for "重试".
public enum SchemeImportRetryDecision: Equatable, Sendable {
    /// Replay the captured operation against the same in-memory selection.
    case repeatOperation(SchemeImportRetryIntent)
    /// No captured operation: the UI may fall back to asking for input again
    /// (e.g. open the file importer for a genuinely new selection).
    case requestInput
}

/// Retains the last started-but-not-succeeded operation. `begin` records it when an
/// operation starts and `succeeded` clears it, so a failed operation always has a
/// replayable intent and retry does not need the file importer. `consume` is used by
/// retry itself; the replayed operation begins the intent again if it fails.
public struct SchemeImportRetryState: Equatable, Sendable {
    public private(set) var intent: SchemeImportRetryIntent?
    public init() {}

    public mutating func begin(_ intent: SchemeImportRetryIntent) { self.intent = intent }
    public mutating func succeeded() { intent = nil }

    public var decision: SchemeImportRetryDecision {
        intent.map(SchemeImportRetryDecision.repeatOperation) ?? .requestInput
    }

    /// True when a captured operation is available to replay right now.
    public var canRetry: Bool { intent != nil }

    public mutating func consume() -> SchemeImportRetryIntent? {
        defer { intent = nil }
        return intent
    }
}
