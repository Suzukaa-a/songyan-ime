import Foundation
import KeyboardCore

/// Last grammar model the keyboard extension confirmed loaded; the host reads it to show "model in use".
public enum GrammarRuntimeReceiptStore {
    public struct Context: Sendable {
        public let publicationGeneration: String
        public let sessionID: String

        public init(publicationGeneration: String, sessionID: String) {
            self.publicationGeneration = publicationGeneration
            self.sessionID = sessionID
        }
    }

    public struct Receipt: Codable, Equatable, Sendable {
        public let publicationGeneration: String
        public let sourceSchemaID: String
        public let runtimeSchemaID: String
        public let modelPath: String?
        public let loadedAt: Date
        public let sessionID: String

        public func matches(sourceSchemaID: String, runtimeSchemaID: String, modelPath: String?) -> Bool {
            self.sourceSchemaID == sourceSchemaID
                && self.runtimeSchemaID == runtimeSchemaID && self.modelPath == modelPath
        }
    }

    private static let filename = "runtime-grammar-receipt.json"

    public static func record(
        context: Context, sourceSchemaID: String,
        runtimeSchemaID: String, loadedLanguage: String?, rootURL: URL? = nil
    ) throws {
        let modelPath: String?
        if let loadedLanguage {
            guard let path = GrammarModelPath.path(for: loadedLanguage) else {
                throw KeyboardRecipeStore.StoreError(message: "语言模型文件路径不支持")
            }
            modelPath = path
        } else {
            modelPath = nil
        }
        let receipt = Receipt(
            publicationGeneration: context.publicationGeneration,
            sourceSchemaID: sourceSchemaID, runtimeSchemaID: runtimeSchemaID,
            modelPath: modelPath, loadedAt: Date(), sessionID: context.sessionID)
        let root = try rootURL ?? KeyboardRecipeStore.root()
        try canonicalJSONEncoder().encode(receipt).write(to: root.appendingPathComponent(filename), options: .atomic)
    }

    /// The receipt for the current publication and selected input method, if any.
    public static func receipt(matching activation: KeyboardRecipeStore.Activation, rootURL: URL? = nil) throws
        -> Receipt?
    {
        guard activation.recipeEnabled else { return nil }
        let root = try rootURL ?? KeyboardRecipeStore.readRoot()
        guard let data = try? Data(contentsOf: root.appendingPathComponent(filename)) else { return nil }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.publicationGeneration == activation.generation,
            receipt.sourceSchemaID == activation.selectedSchemaID
        else { return nil }
        return receipt
    }
}
