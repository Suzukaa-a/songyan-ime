import Foundation

// MARK: - Keyboard layouts (physical keycaps and logical keys, independent of engine data)

/// Physical layouts. A layout says nothing about the input scheme typed on it; which
/// schemes can run on it follows from `keyFold`.
public enum KeyboardLayoutKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case qwerty26
    case merged14
    case merged18
    case phone9

    public var id: String { rawValue }

    /// How the keys cover the 26 letters. Scheme compatibility is decided from this, never from the layout's name.
    public enum KeyFold: Sendable {
        /// One letter per key.
        case identity
        /// Neighbouring letters share a key that sends the group's first letter.
        case letterGroups
        /// Letters share the telephone digit keys 2–9.
        case phoneDigits
    }

    public var keyFold: KeyFold {
        switch self {
        case .qwerty26: return .identity
        case .merged14, .merged18: return .letterGroups
        case .phone9: return .phoneDigits
        }
    }

    /// The letter fold a generated adapter applies for this layout; nil for 26-key.
    public var compactFold: CompactFold? {
        switch self {
        case .qwerty26: return nil
        case .merged14: return .merged14
        case .merged18: return .merged18
        case .phone9: return .phone9
        }
    }

    public var shortTitle: String {
        switch self {
        case .qwerty26: return "26键"
        case .merged14: return "14键"
        case .merged18: return "18键"
        case .phone9: return "9键"
        }
    }

    /// User-facing "keyboard layout" name (same wording in Host and keyboard; see `UserTerminology`).
    public var userTitle: String {
        switch self {
        case .qwerty26: return "26 键"
        case .merged14: return "14 键"
        case .merged18: return "18 键"
        case .phone9: return "9 键"
        }
    }

    /// Folded layouts (merged letters, phone digits): the engine preedit is the folded code,
    /// so unconfirmed segments must be shown as the candidate's real spelling.
    /// This is the sole front-end criterion for requesting candidate spelling from the engine;
    /// native code does no alphabet guessing.
    public var requiresSpellingDisplay: Bool { keyFold != .identity }

    public var detail: String {
        switch self {
        case .qwerty26: return "每个字母一个键。"
        case .merged14: return "两个字母合用一个键。"
        case .merged18: return "部分字母单独一个键，其余两个字母合用一个键。"
        case .phone9: return "数字键 2–9 各对应几个字母。"
        }
    }
}

/// Which key each of the 26 letters lands on in a compact layout: every letter maps to the
/// letter (or digit) its key sends. Adapter generation, identifiers and binding checks read
/// this one value, so a new letter-group layout needs no new code paths.
public struct CompactFold: Hashable, Sendable {
    /// Identifier suffix of generated adapters (`_14`, `_18`, `_9`); also the user-facing key count.
    public let id: String
    /// The folded letters, in a fixed order.
    public let source: String
    /// What the key of each `source` letter sends, position by position.
    public let target: String

    /// What an exact pick of a merged key's own letter sends. A tap sends that same
    /// letter for the whole group, so the exact pick needs a code of its own; the
    /// generated adapter maps the token onto that letter only. The other letters of a
    /// group are never sent by a tap and type themselves. Tokens stay clear of a–z,
    /// digits (alias and 9-key codes) and the pass-through punctuation `;'/``.
    public let exactTokens: [Character: Character]

    private static let exactTokenPool = Array("!#%*+<>@^_|~")

    public init(id: String, source: String, target: String) {
        precondition(source.count == target.count, "fold source and target must align")
        self.id = id
        self.source = source
        self.target = target
        let shared = zip(source, target).filter { $0 != $1 }.map(\.1)
        let leaders = source.filter { Set(shared).contains($0) }
        precondition(leaders.count <= Self.exactTokenPool.count, "too many merged keys for exact tokens")
        exactTokens = Dictionary(uniqueKeysWithValues: zip(leaders, Self.exactTokenPool))
    }

    /// The characters the layout can physically send.
    public var keysSent: Set<Character> { Set(target) }

    /// Telephone digits rather than letter groups.
    public var isPhoneDigits: Bool { target.allSatisfy(\.isNumber) }

    public var map: [Character: Character] {
        Dictionary(uniqueKeysWithValues: zip(source, target))
    }

    public static let merged14 = CompactFold(
        id: "14", source: "qwertyuiopasdfghjklzxcvbnm",
        target: "qqeettuuooaaddggjjlzzccbbm")
    public static let merged18 = CompactFold(
        id: "18", source: "qwertyuiopasdfghjklzxcvbnm",
        target: "qwwrryuiipassffhjjlzxxvbbm")
    public static let phone9 = CompactFold(
        id: "9", source: "abcdefghijklmnopqrstuvwxyz",
        target: "22233344455566677778889999")
}

/// The bundled input schemes. Both are plain 26-key schemes; every compact layout runs on a
/// companion made by the same generator as for installed schemes, so layouts stay scheme-neutral.
public enum BuiltinTemplateSchemas {
    public static let quanpin = "songyan_quanpin"
    public static let flypy = "songyan_flypy"
    public static let sourceSchemaIDs = [quanpin, flypy]
    /// Same as `schema/name` in the YAML; a companion shows its source's name.
    public static let names = [quanpin: "内置全拼", flypy: "内置小鹤双拼"]

    /// The generated companions shipped in the bundle. Ids follow
    /// `CompactSchemaAdapter.identifier`; the PackageManager tests regenerate the files and
    /// check them against this table.
    public static let adapters: [KeyboardResourceSet.EncodingAdapter] = [
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_14", layout: .merged14,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_18", layout: .merged18,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: quanpin, schemaID: "keyboard_47246213a538cb99d374_9", layout: .phone9,
            schemaName: names[quanpin]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_14", layout: .merged14,
            schemaName: names[flypy]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_18", layout: .merged18,
            schemaName: names[flypy]),
        .init(
            sourceSchemaID: flypy, schemaID: "keyboard_3d7821f984693864ae91_9", layout: .phone9,
            schemaName: names[flypy]),
    ]

    public static var layoutEntries: [KeyboardResourceSet.LayoutEntry] {
        sourceSchemaIDs.map { .init(layout: .qwerty26, schemaID: $0) }
    }

    /// The engine schema running `sourceID` on `layout`.
    public static func engineSchemaID(source sourceID: String, layout: KeyboardLayoutKind) -> String? {
        guard sourceSchemaIDs.contains(sourceID) else { return nil }
        return KeyboardResourceSet.engineSchemaID(
            source: sourceID, layout: layout, adapters: adapters, bindings: layoutEntries)
    }

    public static func layout(forSchemaID schemaID: String) -> KeyboardLayoutKind? {
        if sourceSchemaIDs.contains(schemaID) { return .qwerty26 }
        return adapters.first { $0.schemaID == schemaID }?.layout
    }

    /// Engine schema for a layout when no resource set maps it: the first scheme, as the
    /// built-in resource set picks without a selection.
    public static func defaultSchemaID(for layout: KeyboardLayoutKind) -> String? {
        engineSchemaID(source: quanpin, layout: layout)
    }
}

// MARK: - Key actions and keycaps

public enum KeyAction: Equatable, Sendable {
    /// Input logical code (single character: a letter or digit; the representative letter on 14-key).
    case code(String)
    /// Digit/symbol key that commits text directly (e.g. "，" "1" "@").
    /// See InputSession.insertLiteral: bypasses the engine and composition; during composition it confirms first, then commits.
    case literal(String)
    /// Explicit alphabetic alternate (e.g. á): English Shift applies; DIY literal stays verbatim.
    case letterVariant(String)
    /// Space: commits a space when idle; confirms/selects via the engine during composition.
    case space
    /// Backspace.
    case backspace
    /// Return: confirms during composition, otherwise sends a newline.
    case enter
    /// Switch keyboard (globe key: system input-method list).
    case switchKeyboard
    /// Cycle through the built-in layouts (quick schema switching in the experimental keyboard).
    case cycleLayout

    public static func == (lhs: KeyAction, rhs: KeyAction) -> Bool {
        switch (lhs, rhs) {
        case let (.code(a), .code(b)): return a == b
        case let (.literal(a), .literal(b)): return a == b
        case let (.letterVariant(a), .letterVariant(b)): return a == b
        case (.space, .space), (.backspace, .backspace), (.enter, .enter),
            (.switchKeyboard, .switchKeyboard), (.cycleLayout, .cycleLayout):
            return true
        default: return false
        }
    }
}

/// A keycap (size and labels). `width` is a relative unit for flex layout.
public struct KeyCap: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String  // primary label (letter/symbol/text)
    public let subtitle: String?  // secondary label (small text, e.g. shuangpin final hint, 9-key letters)
    public let action: KeyAction
    public let width: Int  // relative width unit (1 = regular key)

    public init(
        id: String, title: String, subtitle: String? = nil,
        action: KeyAction, width: Int = 1
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.width = width
    }
}

public struct KeyboardRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let caps: [KeyCap]

    public init(id: String, caps: [KeyCap]) {
        self.id = id
        self.caps = caps
    }
}

// MARK: - Layout table

public enum KeyboardLayoutTable {
    /// Letter/main rows for a layout (excluding the bottom control row).
    public static func mainRows(for layout: KeyboardLayoutKind) -> [KeyboardRow] {
        switch layout {
        case .qwerty26:
            return [
                letterRow("qwertyuiop"),
                letterRow("asdfghjkl"),
                letterRow("zxcvbnm"),
            ]
        case .merged14:
            return [
                groupRow(["qw", "er", "ty", "ui", "op"]),
                groupRow(["as", "df", "gh", "jk"]),
                groupRow(["l", "zx", "cv", "bn", "m"]),
            ]
        case .merged18:
            return [
                groupRow(["q", "we", "rt", "y", "u", "io", "p"]),
                groupRow(["a", "sd", "fg", "h", "jk", "l"]),
                groupRow(["z", "xc", "v", "bn", "m"]),
            ]
        case .phone9:
            return [
                groupRow(["1", "2", "3"], phone: true),
                groupRow(["4", "5", "6"], phone: true),
                groupRow(["7", "8", "9"], phone: true),
            ]
        }
    }

    /// Bottom control row, shared by all layouts: switch keyboard / space / backspace / return / layout cycle.
    public static func controlRow() -> KeyboardRow {
        KeyboardRow(
            id: "controls",
            caps: [
                KeyCap(
                    id: "layout", title: "布局",
                    subtitle: nil, action: .cycleLayout, width: 1),
                KeyCap(
                    id: "globe", title: "🌐",
                    subtitle: "切换", action: .switchKeyboard, width: 1),
                KeyCap(id: "space", title: "空格", action: .space, width: 4),
                KeyCap(id: "backspace", title: "⌫", action: .backspace, width: 1),
                KeyCap(id: "enter", title: "⏎", action: .enter, width: 1),
            ])
    }

    /// All rows = main rows + control row.
    public static func rows(for layout: KeyboardLayoutKind) -> [KeyboardRow] {
        mainRows(for: layout) + [controlRow()]
    }

    // MARK: Standalone English QWERTY (direct English mode only; not a KeyboardLayoutKind)

    /// Standalone 26-key QWERTY main rows for direct English mode (three letter rows; the
    /// control row is shared via `controlRow()`). Decoupled from any Chinese layout/schema:
    /// English mode uses the full 26 keys even when the Chinese layout is 14/9-key, and does
    /// not change the Chinese layout remembered by `select(layout:)` or the resource-set
    /// schema mapping.
    ///
    /// `displayShift` only affects the case of the keycap title; the action is always a
    /// lowercase `.code`. The committed case is decided by InputSession from the current
    /// Shift state in English mode (Chinese composition codes stay lowercase).
    /// Key ids don't depend on display case (e.g. `en-a`), so Shift re-renders keep SwiftUI identity.
    public static func englishRows(displayShift: ShiftState = .off) -> [KeyboardRow] {
        let shifted = displayShift.isActive
        return ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated().map { rowIndex, letters in
            let caps = letters.map { ch -> KeyCap in
                let lower = String(ch)
                return KeyCap(
                    id: "en-\(lower)",
                    title: shifted ? lower.uppercased() : lower,
                    action: .code(lower))
            }
            return KeyboardRow(id: "en-row-\(rowIndex)", caps: caps)
        }
    }

    // MARK: helpers

    private static func letterRow(_ letters: String) -> KeyboardRow {
        let caps = letters.map { ch -> KeyCap in
            let id = "code-\(ch)"
            return KeyCap(id: id, title: String(ch), action: .code(String(ch)))
        }
        return KeyboardRow(id: "row-\(letters.prefix(3))", caps: caps)
    }

    private static func groupRow(_ groups: [String], phone: Bool = false) -> KeyboardRow {
        let caps = groups.enumerated().map { index, g -> KeyCap in
            let id = "group-\(g)-\(index)"
            if phone {
                // Phone keys: digit as title, letters as subtitle
                let letters = phoneLetters[g] ?? ""
                return KeyCap(id: id, title: g, subtitle: letters, action: .code(g))
            }
            // 14-key cluster: sends the representative letter (first of the cluster); the subtitle lists the cluster's letters
            let rep = String(g.prefix(1))
            return KeyCap(id: id, title: rep, subtitle: g, action: .code(rep))
        }
        return KeyboardRow(id: "row-\(groups.joined().prefix(6))", caps: caps)
    }

    /// Telephone keypad letters (abc/def/ghi/jkl/mno/pqrs/tuv/wxyz).
    private static let phoneLetters: [String: String] = [
        "1": "", "2": "abc", "3": "def",
        "4": "ghi", "5": "jkl", "6": "mno",
        "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]
}
