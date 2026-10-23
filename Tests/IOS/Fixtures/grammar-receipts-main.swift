import Foundation

@main struct Probe {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let context = GrammarRuntimeReceiptStore.Context(publicationGeneration: "g1", sessionID: "session-1")
        var activation = KeyboardRecipeStore.Activation(generation: "g1", selectedSchemaID: "a", recipeEnabled: true)
        try GrammarRuntimeReceiptStore.record(
            context: context, sourceSchemaID: "a", runtimeSchemaID: "a14", loadedLanguage: "models/中文模型", rootURL: root)
        let receipt = try GrammarRuntimeReceiptStore.receipt(matching: activation, rootURL: root)!
        require(receipt.modelPath == "models/中文模型.gram", "model reference was renamed")
        require(
            receipt.matches(sourceSchemaID: "a", runtimeSchemaID: "a14", modelPath: "models/中文模型.gram"),
            "exact identity not accepted")
        require(
            !receipt.matches(sourceSchemaID: "b", runtimeSchemaID: "b14", modelPath: receipt.modelPath),
            "same model falsely confirmed another source schema")
        require(
            !receipt.matches(sourceSchemaID: "a", runtimeSchemaID: "a9", modelPath: receipt.modelPath),
            "receipt for another runtime adapter was accepted")
        require(
            !receipt.matches(sourceSchemaID: "a", runtimeSchemaID: "a14", modelPath: "other.gram"),
            "different model accepted")
        require(receipt.sessionID == "session-1" && receipt.loadedAt <= Date(), "historical evidence lost session/time")
        activation.selectedSchemaID = "b"
        require(
            try GrammarRuntimeReceiptStore.receipt(matching: activation, rootURL: root) == nil,
            "generation-only match accepted")
        activation.selectedSchemaID = "a"
        activation.generation = "g2"
        require(
            try GrammarRuntimeReceiptStore.receipt(matching: activation, rootURL: root) == nil,
            "stale generation accepted")
        activation.generation = "g1"
        activation.recipeEnabled = false
        require(
            try GrammarRuntimeReceiptStore.receipt(matching: activation, rootURL: root) == nil,
            "disabled publication accepted")
        activation.recipeEnabled = true
        for language in ["", "../escape", "/absolute", "a//b", "a/./b", "a\\b", "a:b", "a\nb"] {
            do {
                try GrammarRuntimeReceiptStore.record(
                    context: context, sourceSchemaID: "a", runtimeSchemaID: "a14", loadedLanguage: language,
                    rootURL: root)
                fatalError("unsafe model path accepted")
            } catch {}
        }
        try GrammarRuntimeReceiptStore.record(
            context: context, sourceSchemaID: "a", runtimeSchemaID: "a14", loadedLanguage: nil, rootURL: root)
        let disabled = try GrammarRuntimeReceiptStore.receipt(matching: activation, rootURL: root)!
        require(disabled.modelPath == nil, "no-grammar runtime did not supersede old model evidence")
        require(
            !disabled.matches(sourceSchemaID: "a", runtimeSchemaID: "a14", modelPath: "models/中文模型.gram"),
            "old model loading remained confirmed")
        print("PASS exact schema/runtime/model/generation and no-grammar supersession")
    }
}
