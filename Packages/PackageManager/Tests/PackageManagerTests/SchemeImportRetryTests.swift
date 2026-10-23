import XCTest

@testable import PackageManager

/// The import retry state machine. A failed operation must be replayable against the SAME
/// already-selected file/scheme; the UI may only ask for a new selection when no operation
/// was captured (so an install failure never reopens the file importer).
final class SchemeImportRetryTests: XCTestCase {
    func testNoCapturedOperationFallsBackToRequestInput() {
        let state = SchemeImportRetryState()
        XCTAssertEqual(state.decision, .requestInput)
        XCTAssertFalse(state.canRetry)
    }

    func testFailedRecognizedImportReplaysSameSelectionInsteadOfRequestingInput() {
        var state = SchemeImportRetryState()
        state.begin(.installRecognizedImport)
        XCTAssertTrue(state.canRetry)
        XCTAssertEqual(state.decision, .repeatOperation(.installRecognizedImport))
        // Retry consumes the captured operation and hands it to the replay; a further
        // failure re-begins it, so it is never silently downgraded to a picker.
        XCTAssertEqual(state.consume(), .installRecognizedImport)
        XCTAssertEqual(state.decision, .requestInput)
    }

    func testSuccessClearsTheRetainedOperation() {
        var state = SchemeImportRetryState()
        state.begin(.installRecognizedImport)
        state.succeeded()
        XCTAssertFalse(state.canRetry)
        XCTAssertEqual(state.decision, .requestInput)
    }

    func testPlannedInstallRetainsExactRecipeArgumentsAndOrderedStages() {
        let stages = [
            SchemeImportStageSelection(
                path: "config.recipe.yaml",
                arguments: [RecipeArgument("schema", "rime_ice")]),
            SchemeImportStageSelection(
                path: "grammar.recipe.yaml",
                arguments: [RecipeArgument("model", "x.gram"), RecipeArgument("model", "y.gram")]),
        ]
        let intent = SchemeImportRetryIntent.installPlannedRecipe(
            recipePath: "install.recipe.yaml",
            arguments: [RecipeArgument("schema", "rime_ice")], stages: stages, installed: false)
        var state = SchemeImportRetryState()
        state.begin(intent)

        guard case .repeatOperation(let captured) = state.decision else {
            return XCTFail("expected the captured operation to be replayed")
        }
        XCTAssertEqual(captured, intent)
        XCTAssertEqual(
            captured,
            .installPlannedRecipe(
                recipePath: "install.recipe.yaml",
                arguments: [RecipeArgument("schema", "rime_ice")], stages: stages, installed: false))
        // A different argument or a reordered stage set is a different selection.
        XCTAssertNotEqual(
            captured,
            .installPlannedRecipe(
                recipePath: "install.recipe.yaml",
                arguments: [RecipeArgument("schema", "other")], stages: stages, installed: false))
        XCTAssertNotEqual(
            captured,
            .installPlannedRecipe(
                recipePath: "install.recipe.yaml",
                arguments: [RecipeArgument("schema", "rime_ice")], stages: Array(stages.reversed()), installed: false))
    }

    func testPlanSourceAndAcquireOperationsRetainTheirTargets() {
        var state = SchemeImportRetryState()
        state.begin(.planRecipe(recipePath: "r.recipe.yaml", arguments: [], stages: [], installed: true))
        XCTAssertEqual(
            state.decision,
            .repeatOperation(.planRecipe(recipePath: "r.recipe.yaml", arguments: [], stages: [], installed: true)))

        state.begin(.installSourcePlan)
        XCTAssertEqual(state.decision, .repeatOperation(.installSourcePlan))

        state.begin(.acquireSource(target: "owner/repo@rev:config:schema=x", updatingPackageID: "source-1"))
        XCTAssertEqual(
            state.decision,
            .repeatOperation(.acquireSource(target: "owner/repo@rev:config:schema=x", updatingPackageID: "source-1")))
    }
}
