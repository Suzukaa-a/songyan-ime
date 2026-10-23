import Foundation
import KeyboardCore

/// Production read implementation of the published keyboard list (shared by the host app and the keyboard extension).
///
/// The published record's keyboard list is the single source of truth. This file:
///  1. runs the read on a dedicated low-priority read-only queue (no disk I/O on the main thread);
///  2. maps the published record to the read model `UserKeyboard`.
///
/// Failures are passed through faithfully: no list is a normal empty state (empty array); a read failure throws,
/// so callers keep the old list and tell the user, never treating a failure as "no keyboards".
///
public struct ActivationPublishedKeyboardProvider: PublishedKeyboardListProviding, Sendable {
    public init() {}

    public func publishedKeyboards() async throws -> [UserKeyboard] {
        // The read must stay inside this read-queue closure (static gate: no disk I/O on the main thread).
        try await KeyboardResourceReadQueue.async {
            guard let activation = try KeyboardRecipeStore.activation() else { return [] }
            return Self.keyboards(from: activation)
        }
    }

    /// The only source of truth is `Activation.keyboards`; this projection layer never re-derives or
    /// invents combinations.
    static func keyboards(from activation: KeyboardRecipeStore.Activation) -> [UserKeyboard] {
        keyboards(activation.keyboards, schemas: activation.schemas ?? [])
    }

    /// Projects the display model from a given keyboard list and structured scheme descriptions (reusable for per-source reads;
    /// no disk writes, no capability inference). The name comes from the scheme description, falling back to the layout name.
    static func keyboards(
        _ keyboards: [PublishedKeyboard],
        schemas: [KeyboardSchemaDescriptor]
    ) -> [UserKeyboard] {
        PublishedKeyboard.displays(keyboards, in: schemas).map {
            UserKeyboard(
                inputMethodID: $0.keyboard.schemaID,
                inputMethodName: $0.inputMethodName,
                layout: $0.keyboard.layout)
        }
    }
}
