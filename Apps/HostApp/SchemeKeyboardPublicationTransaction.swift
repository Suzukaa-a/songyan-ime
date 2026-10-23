import KeyboardCore

// MARK: - User-keyboard publication transaction adapter (narrow interface, awaited directly by the production adapter)

/// Production implementation of `UserKeyboardPublicationTransaction`: delegates the narrow interface to the host's real
/// async-throws transaction. The production adapter awaits this type directly and does not poll `busy`/`error`:
/// conflicts or failures are thrown as-is, and success yields a structured result.
///
/// Uses only `PublishedKeyboard` (a KeyboardCore value), introducing none of the adapter layer's types.
struct SchemeKeyboardPublicationTransaction: UserKeyboardPublicationTransaction {
    let center: SchemeImportCenter
    let packageID: String

    func addKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome {
        try await center.performAddKeyboard(packageID: packageID, keyboard: keyboard)
    }

    func removeKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome {
        try await center.performRemoveKeyboard(packageID: packageID, keyboard: keyboard)
    }

    func replaceKeyboards(_ keyboards: [PublishedKeyboard]) async throws -> [PublishedKeyboard] {
        try await center.performReplaceKeyboards(packageID: packageID, requested: keyboards)
    }

    func publishedKeyboards() async throws -> [PublishedKeyboard] {
        try await center.publishedKeyboards(packageID: packageID)
    }

    func addableKeyboards() async throws -> [PublishedKeyboard] {
        try await center.addableKeyboards(packageID: packageID)
    }
}
