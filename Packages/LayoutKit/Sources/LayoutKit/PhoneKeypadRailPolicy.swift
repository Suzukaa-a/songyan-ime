import Foundation

/// What a phone-keypad rail should render. Kept as data so the rail decision is
/// testable without SwiftUI.
public enum PhoneKeypadRailContent: Equatable, Sendable {
    /// Bundled T9 only: the shell's own authored rail (leading quick-symbol /
    /// reading sidebar, trailing Delete + 重输 + bottom-corner Return/Confirm with the
    /// fixed `[1, 1, 2]` span). Never produced for an imported definition.
    case bundledAuthored
    /// An imported definition declared this many keys for the rail; render exactly
    /// those keys in deterministic slots. No action is invented.
    case declared(keyCount: Int)
    /// Nothing declared and not the bundled shell: render nothing. Delete and the
    /// like remain wherever the definition actually placed them (its control row /
    /// bottom bar); the shell must not add an action the user did not author.
    case empty
}

/// The single rail policy shared by both phone-keypad rails.
///
/// Only the bundled T9 may receive the shell-authored static keys. An imported
/// keypad keeps its declared keys — the shell never fabricates a Delete/separator
/// for a layout that did not author one. Verified engine reading choices are
/// runtime controls and can precede authored keys in the same scrollable rail.
public enum PhoneKeypadRailPolicy {
    public static func content(isBuiltinPhonePad: Bool, declaredKeyCount: Int) -> PhoneKeypadRailContent {
        if isBuiltinPhonePad { return .bundledAuthored }
        return declaredKeyCount > 0 ? .declared(keyCount: declaredKeyCount) : .empty
    }

    public static func leading(isBuiltinPhonePad: Bool, declaredKeyCount: Int) -> PhoneKeypadRailContent {
        content(isBuiltinPhonePad: isBuiltinPhonePad, declaredKeyCount: declaredKeyCount)
    }

    public static func trailing(isBuiltinPhonePad: Bool, declaredKeyCount: Int) -> PhoneKeypadRailContent {
        content(isBuiltinPhonePad: isBuiltinPhonePad, declaredKeyCount: declaredKeyCount)
    }

    /// The fixed trailing column spans only for the bundled shell, as on the
    /// system / mainstream pinyin 9-key pads: Delete on row 0, 重输 on row 1, and
    /// Return/Confirm across row 2 *and the control row* (`[1, 1, 2]`), so Return
    /// sits in the bottom-right corner. The control row ends before this column.
    public static let bundledTrailingSpans: [Int] = [1, 1, 2]

    /// The keys a definition declares for one rail. Engine-disambiguation areas
    /// are excluded (they are runtime-only). Shared by the view and its tests so
    /// "what the rail shows" has exactly one definition.
    public static func declaredKeys(
        in definition: LayoutDefinition,
        position: LayoutAuxiliaryArea.Position
    ) -> [LayoutKey] {
        (definition.auxiliaryAreas ?? [])
            .filter { $0.position == position && !$0.requiresEngineDisambiguation }
            .flatMap(\.keys)
    }

    /// The definition's declared non-encoding control row, if any. For an imported
    /// keypad this is what the bottom bar renders; the shell never substitutes a
    /// Delete/return for a pad that declared none.
    public static func controlRowKeys(in definition: LayoutDefinition) -> [LayoutKey]? {
        guard let last = definition.rows.last,
            last.keys.allSatisfy({ $0.action.type != .code && $0.action.type != .literal })
        else { return nil }
        return last.keys
    }
}
