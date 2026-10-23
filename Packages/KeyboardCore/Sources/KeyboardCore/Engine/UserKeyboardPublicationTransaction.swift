import Foundation

// MARK: - User keyboard publication transaction (narrow, injectable async throws API)
//
// Adding/removing a user keyboard in the host app is a real transaction:
//  * `async throws`: conflicts (busy / source mismatch / not installed) throw and
//    failures propagate unchanged;
//  * success returns a structured result (the entry + full list afterwards);
//  * results are never inferred by polling mutable UI state like `busy` / `error`.
//
// Uses only KeyboardCore's own `PublishedKeyboard`, so app-layer adapters can `await` it
// and map results to their own UI models.

/// Structured result of an add/remove transaction.
public struct UserKeyboardMutationOutcome: Equatable, Sendable {
    /// The keyboard this transaction targeted.
    public let keyboard: PublishedKeyboard
    /// true if added, false if removed.
    public let added: Bool
    /// Full published list of the source after the transaction (publication order).
    public let publishedKeyboards: [PublishedKeyboard]

    public init(
        keyboard: PublishedKeyboard, added: Bool,
        publishedKeyboards: [PublishedKeyboard]
    ) {
        self.keyboard = keyboard
        self.added = added
        self.publishedKeyboards = publishedKeyboards
    }
}

/// Failure reasons (plain user-facing wording; implementations keep raw errors in diagnostics).
public enum UserKeyboardPublicationError: Error, LocalizedError, Equatable, Sendable {
    /// Another keyboard transaction is in progress.
    case busy
    /// The target source is not installed.
    case sourceNotInstalled
    /// The keyboard to remove is not in the current list.
    case notAdded
    /// The source has no addable keyboards.
    case noAddableKeyboards
    /// Capability unavailable (generation/validation failed or invalid combination).
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .busy: return "另一项键盘操作正在进行，请稍后。"
        case .sourceNotInstalled: return "这个输入方案还没有安装。"
        case .notAdded: return "这个键盘不在当前列表中。"
        case .noAddableKeyboards: return "这个输入方案没有可添加的键盘。"
        case .unavailable(let value): return value
        }
    }
}

/// Narrow user keyboard publication API. Implementations generate, validate and publish
/// atomically; callers only `await`.
///
/// Read methods (`publishedKeyboards` / `addableKeyboards`) live here too so callers
/// don't poll state fields.
public protocol UserKeyboardPublicationTransaction: Sendable {
    /// Adds/updates a keyboard. Throws on conflict or failure; nothing is published.
    func addKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome
    /// Removes a keyboard. Throws if absent or on conflict; nothing is published.
    func removeKeyboard(_ keyboard: PublishedKeyboard) async throws -> UserKeyboardMutationOutcome
    /// Replaces the whole list. Implementations generate and validate all compact layouts first, then publish once.
    func replaceKeyboards(_ keyboards: [PublishedKeyboard]) async throws -> [PublishedKeyboard]
    /// Published keyboards of the current source.
    func publishedKeyboards() async throws -> [PublishedKeyboard]
    /// Keyboards the current source can add (structurally adaptable).
    func addableKeyboards() async throws -> [PublishedKeyboard]
}
