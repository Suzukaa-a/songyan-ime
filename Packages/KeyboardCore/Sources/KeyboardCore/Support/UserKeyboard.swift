import Foundation

// MARK: - User keyboards (human display projection of the publication record)
//
// There is one source of published facts: the canonical `PublishedKeyboard` manifest
// (`KeyboardCore.PublishedKeyboard` / `KeyboardRecipeStore.Activation.keyboards`).
// This file does not define the publication transaction, source selection, or persistence
// format; it only defines:
//  * `UserKeyboard`: a pure display projection of a published item plus an optional display name.
//  * `PublishedKeyboardListProviding`: the interface that reads this projection (implemented by the publication record).
//  * `UserKeyboardRoster`: the runtime "manifest AND current resource capability" filter and cycling rule.
//  * `UserKeyboardCandidate` and `UserKeyboardManaging`: narrow convenience protocols for
//    the main app UI (the production adapter wraps the canonical transaction, see
//    `Apps/HostApp/DictionaryImportCenterUserKeyboards.swift`).
//
// There is no manifest file format, no manifest writing, and no capability inference parallel
// to `InputConfigurationChoices`: the keyboard manifest is produced and verified by the
// publication transaction, and the extension only reads it.

/// Human display projection of a published keyboard: input method plus keyboard layout.
public struct UserKeyboard: Equatable, Sendable, Identifiable {
    /// Input method identifier (the source schema id in the publication record; kept as-is, never interpreted or guessed).
    public let inputMethodID: String
    /// Input method display name (from that publication's scheme description; the layout name is shown when empty).
    public let inputMethodName: String
    /// Front-end keyboard layout capability.
    public let layout: KeyboardLayoutKind

    public init(inputMethodID: String, inputMethodName: String, layout: KeyboardLayoutKind) {
        self.inputMethodID = inputMethodID
        self.inputMethodName = inputMethodName
        self.layout = layout
    }

    /// Identity is the combination itself (same shape as `PublishedKeyboard.id`; renaming does not change identity).
    public var id: String { "\(inputMethodID):\(layout.rawValue)" }

    /// Display name: input method name plus layout name; only the layout name when the input method name is empty, never exposing the internal id.
    public var title: String {
        let name = inputMethodName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return layout.userTitle }
        return "\(name) · \(layout.userTitle)"
    }

    /// Whether this keyboard is the currently running combination.
    public func isCurrent(schemaID: String, layout: KeyboardLayoutKind) -> Bool {
        inputMethodID == schemaID && self.layout == layout
    }
}

// MARK: - Read interface (publication record to display projection)

/// Read interface for the published-keyboard display projection. Production is backed by the
/// publication record (`Apps/SharedKeyboard/PublishedKeyboardProvider.swift`); tests/previews use a fixed implementation.
public protocol PublishedKeyboardListProviding: Sendable {
    /// Reads the published-keyboard projection. No manifest is a normal empty state (returns
    /// `[]`); a read failure throws, and the caller keeps the old list and says so, never treating failure as "no keyboards".
    func publishedKeyboards() async throws -> [UserKeyboard]
}

/// Fixed projection provider (fixtures / unit tests / previews).
public struct StaticPublishedKeyboardListProvider: PublishedKeyboardListProviding {
    public let keyboards: [UserKeyboard]
    public init(_ keyboards: [UserKeyboard]) { self.keyboards = keyboards }
    public func publishedKeyboards() async throws -> [UserKeyboard] { keyboards }
}

// MARK: - Runtime filtering

public enum UserKeyboardRoster {
    /// What the switcher lists when nothing is published: the built-in fallback input method on
    /// every layout, so the layout can still be changed from the keyboard.
    public static var builtinFallback: [UserKeyboard] {
        KeyboardLayoutKind.allCases.map {
            UserKeyboard(
                inputMethodID: BuiltinTemplateSchemas.quanpin,
                inputMethodName: ProductionInputAvailability.fallbackInputMethodName, layout: $0)
        }
    }

    /// The current published pair's display name, never an unrelated keyboard's name.
    public static func currentTitle(
        schemaID: String, layout: KeyboardLayoutKind,
        in keyboards: [UserKeyboard]
    ) -> String? {
        keyboards.first { $0.isCurrent(schemaID: schemaID, layout: layout) }?.title
    }

    /// Manifest AND combinations the current resource can really run, in publication order,
    /// de-duplicated by id (defensive: the publication transaction already guarantees uniqueness).
    /// The display name is the current resource's scheme name, so a stale name is not kept.
    ///
    /// This is the only constructor of the extension's long-press switch list: a published item
    /// that cannot run does not appear, and an unpublished combination is never added.
    public static func runnable(
        _ keyboards: [UserKeyboard],
        combinations: [KeyboardResourceSet.Combination]
    ) -> [UserKeyboard] {
        var names: [String: String] = [:]
        for combination in combinations {
            names["\(combination.schemaID):\(combination.layout.rawValue)"] = combination.name
        }
        var seen = Set<String>()
        return keyboards.compactMap { keyboard in
            guard let name = names[keyboard.id], seen.insert(keyboard.id).inserted else { return nil }
            return UserKeyboard(
                inputMethodID: keyboard.inputMethodID,
                inputMethodName: name,
                layout: keyboard.layout)
        }
    }

    /// The only pure rule for cycling: given the running input method/layout and the runnable
    /// published keyboards, returns the next keyboard to switch to; `nil` = safe no-op.
    ///
    /// Contract (shared by the long-press switcher and the layout key):
    ///  * Empty list (no keyboard added / none runnable): nil, with no fallback to any 26/14/9 layout itself.
    ///  * Current combination in the list: the next one (wrapping at the end); nil if it is the
    ///    only item (re-selecting itself is meaningless).
    ///  * Current combination not in the list (e.g. just switched to a source outside the
    ///    manifest): the first item (which exists only when the list is non-empty, and is still a published keyboard).
    public static func cycleTarget(
        currentSchemaID: String,
        currentLayout: KeyboardLayoutKind,
        in keyboards: [UserKeyboard]
    ) -> UserKeyboard? {
        guard !keyboards.isEmpty else { return nil }
        if let index = keyboards.firstIndex(where: {
            $0.isCurrent(schemaID: currentSchemaID, layout: currentLayout)
        }) {
            guard keyboards.count > 1 else { return nil }
            return keyboards[(index + 1) % keyboards.count]
        }
        return keyboards[0]
    }

    /// Fills blank display names with the input method name from the same source's addable
    /// combinations (matched by input method ID).
    ///
    /// A published manifest from a non-current source carries only neutral names (group titles
    /// fall back to the generic "input method"); this page's source has its own names for its
    /// addable combinations, so they are safe to fill in. Only blank names are filled: existing
    /// names, order, and items are untouched, and nothing changes when a candidate has no name either.
    public static func backfillingNames(
        _ keyboards: [UserKeyboard],
        from candidates: [UserKeyboardCandidate]
    ) -> [UserKeyboard] {
        func isBlank(_ name: String) -> Bool {
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var names: [String: String] = [:]
        for candidate in candidates
        where !isBlank(candidate.inputMethodName)
            && names[candidate.inputMethodID] == nil
        {
            names[candidate.inputMethodID] = candidate.inputMethodName
        }
        return keyboards.map { keyboard in
            guard isBlank(keyboard.inputMethodName),
                let name = names[keyboard.inputMethodID]
            else { return keyboard }
            return UserKeyboard(
                inputMethodID: keyboard.inputMethodID,
                inputMethodName: name, layout: keyboard.layout)
        }
    }
}

// MARK: - Narrow convenience protocol for the main app UI

/// An addable user-keyboard candidate (input method plus layout).
///
/// Candidates come only from the production adapter mapping the canonical transaction's
/// `addableKeyboards()` (`[PublishedKeyboardDisplay]`); this package neither infers capability nor builds its own candidate table.
public struct UserKeyboardCandidate: Equatable, Sendable, Identifiable {
    public let inputMethodID: String
    public let inputMethodName: String
    public let layout: KeyboardLayoutKind

    public init(inputMethodID: String, inputMethodName: String, layout: KeyboardLayoutKind) {
        self.inputMethodID = inputMethodID
        self.inputMethodName = inputMethodName
        self.layout = layout
    }

    public var id: String { "\(inputMethodID):\(layout.rawValue)" }
    public var inputMethodNameOrLayout: String {
        inputMethodName.trimmingCharacters(in: .whitespaces).isEmpty
            ? layout.userTitle : inputMethodName
    }

    public func keyboard() -> UserKeyboard {
        UserKeyboard(inputMethodID: inputMethodID, inputMethodName: inputMethodName, layout: layout)
    }
}

/// Narrow convenience protocol the main app "user keyboards" UI depends on (just this one;
/// it does not duplicate the transaction semantics).
///
/// Contract:
///  * `supportsManagement`: false means read-only (the UI must say so and not offer buttons that must fail).
///  * `addableKeyboards()`: the authoritative addable combinations. Production maps the
///    canonical transaction's `addableKeyboards()` (`[PublishedKeyboardDisplay]`) to `UserKeyboardCandidate`.
///  * `addKeyboard(_:)` / `removeKeyboard(_:)`: `await` the same canonical transaction
///    (`KeyboardCore.UserKeyboardPublicationTransaction`); success returns a user-facing
///    message, failure throws; never poll `busy`/error fields to fake completion.
///
/// This protocol does not define source selection: the production adapter resolves the
/// current source from the publication record and builds the canonical transaction.
@MainActor
public protocol UserKeyboardManaging: AnyObject {
    /// Whether the implementation can actually run add/remove transactions. false = read-only.
    var supportsManagement: Bool { get }

    /// Authoritative addable combinations.
    func addableKeyboards() async throws -> [UserKeyboardCandidate]

    /// Adds/updates a keyboard. Success returns a user-facing message; failure throws and publishes nothing.
    func addKeyboard(_ candidate: UserKeyboardCandidate) async throws -> String

    /// Removes an added keyboard. Success returns a user-facing message; failure throws and publishes nothing.
    func removeKeyboard(_ keyboard: UserKeyboard) async throws -> String

    /// Commits the edited full list as one transaction, instead of generating, publishing, and re-reading per toggle.
    func replaceKeyboards(_ keyboards: [UserKeyboard]) async throws -> String
}
