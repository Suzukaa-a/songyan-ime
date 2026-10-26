import Foundation
import KeyboardCore
import LayoutKit

// MARK: - Pages and number/symbol tables

/// Keyboard pages (pure UI state): letters / 123 numbers and symbols / #+= more symbols.
typealias KeyboardPage = KeyboardControlPolicy.Page

/// Key positions of the 123 / #+= pages. All `.literal`: direct input via controller.insertLiteral;
/// a key pressed mid-composition confirms the composition first (controller semantics), and never enters the pinyin/9-key code tables.
enum SymbolPageTable {
    /// Saved order remains intact; missing defaults are appended, never written back.
    ///
    /// The first three are the fixed direct-input buttons of the left rail; **from the fourth on** they do not hang off those three keys' long presses
    /// but are cycled by repeatedly tapping the main-area first key (see `quickCycle`). The sole source of the order is
    /// `BuiltinLayouts.t9QuickSymbolValues`, so the left rail and the first key always agree.
    static func quickRail(symbols: String, ascii: Bool) -> [KeyCap] {
        literals("quick", BuiltinLayouts.t9QuickRailValues(saved: symbols, ascii: ascii))
    }

    /// The real order from the fourth item on, for first-key cycling. An empty array = that key has nothing to cycle.
    static func quickCycle(symbols: String, ascii: Bool) -> [String] {
        BuiltinLayouts.t9QuickCycleValues(saved: symbols, ascii: ascii)
    }

    /// Decimal, question and exclamation are direct; remaining symbols belong to
    /// the first button's long-press menu, with no vertical punctuation scrolling.
    /// The full decimal/question/exclamation + 123-row rail order owned by LayoutKit, so the
    /// built-in 9-key digit page and an authored keypad page consume the same canonical list.
    static func phoneNumericRail(ascii: Bool) -> [KeyCap] {
        literals("phone", BuiltinLayouts.phoneNumericRailValues(ascii: ascii))
    }

    /// The 123 row. Takes its marks from `BuiltinLayouts`, the same source the
    /// editable page presets read, so the built-in path and an authored copy can
    /// never drift apart.
    static func numericRows(ascii: Bool) -> [KeyboardRow] {
        rows(BuiltinLayouts.numericPageRows(ascii: ascii), prefix: "num", capPrefix: "n")
    }

    /// A phone (digit pad) definition's symbol page, organised like mainstream 9-key
    /// pinyin (Sogou, iFlytek, Baidu: 常用 first, then 中文 / 英文 split by width,
    /// then themed sets): a category rail and a scrolling grid of keys as large as the
    /// digit pad's. The built-in tabs hold every symbol the 123/#+= rows of the other
    /// layouts offer, so nothing is reachable there but missing here; the themed tabs
    /// come from the symbol library, which the user can replace from the app.
    struct PhoneSymbolCategory: Equatable {
        let id: String
        let title: String
        let caps: [KeyCap]
        var authoredKeys: [LayoutKey]? = nil
        var preferredColumns: Int? = nil
        var split: LayoutSplitConfiguration? = nil
        /// Kaomoji and other multi-glyph entries need two wide columns instead of four.
        var columns: Int { preferredColumns ?? (caps.contains { $0.title.count > 3 } ? 2 : 4) }
        var keys: [LayoutKey] {
            authoredKeys ?? caps.map { LayoutKey(label: $0.title, action: .init(.literal, value: $0.title)) }
        }
    }

    static func authoredCategories(
        _ categories: [KeyboardPageCategory], recents: [String], showsGlobe: Bool = true
    ) -> [PhoneSymbolCategory] {
        categories.map { category in
            let source =
                category.source == .recent
                ? recents.map { LayoutKey(label: $0, action: .init(.literal, value: $0)) } : category.keys
            let keys = source.filter { showsGlobe || $0.action.type != .globe }
            let caps = keys.enumerated().map { index, key in
                KeyCap(
                    id: "category-\(category.id)-\(index)", title: key.label,
                    action: .literal(key.action.value ?? key.label))
            }
            return PhoneSymbolCategory(
                id: category.id, title: category.name, caps: caps, authoredKeys: keys,
                preferredColumns: category.columns, split: category.split)
        }
    }

    /// A themed set from the symbol library, in the library's order.
    struct LibraryCategory: Equatable {
        let id: String
        let title: String
        let symbols: [String]
    }

    static let commonCategoryID = "common"
    static let recentCategoryID = "recent"

    /// 常用 opens the page. Its first three rows (all the page shows before a
    /// scroll) are the marks typed most in the current punctuation width, in a fixed
    /// order so their positions can be learned.
    static func phoneCommonSymbols(ascii: Bool) -> [String] {
        ascii
            ? [
                ",", ".", "?", "!", ":", ";", "'", "\"", "(", ")", "@", "#",
                "&", "*", "-", "_", "/", "\\", "~", "%", "+", "=", "$", "^",
            ]
            : [
                "，", "。", "？", "！", "、", "：", "；", "……", "“", "”", "（", "）",
                "《", "》", "——", "·", "@", "#", "%", "&", "*", "/", "~", "-",
            ]
    }

    /// Full-width marks; 「……」 and 「——」 are the doubled forms Chinese text uses.
    static let phoneChineseSymbols = [
        "，", "。", "？", "！", "、", "：", "；", "……", "“", "”", "‘", "’",
        "（", "）", "《", "》", "——", "·", "…", "—", "「", "」", "『", "』",
        "【", "】", "〈", "〉", "〔", "〕", "～", "￥",
    ]

    static let phoneEnglishSymbols = [
        ",", ".", "?", "!", ":", ";", "'", "\"", "(", ")", "[", "]",
        "{", "}", "<", ">", "@", "#", "$", "%", "&", "*", "-", "_",
        "+", "=", "/", "\\", "|", "~", "^", "`", "–", "¥", "€", "£", "•",
    ]

    /// Pairs side by side, two pairs per row.
    static let phoneBracketSymbols = [
        "（", "）", "【", "】", "《", "》", "「", "」", "『", "』", "〈", "〉",
        "〔", "〕", "〖", "〗", "(", ")", "[", "]", "{", "}", "<", ">",
    ]

    /// 常用, then 最近 (once something has been typed from this page or the symbol
    /// library), 中文, 英文, 括号, then the library's sets. A library set whose every
    /// symbol is already in a built-in tab (the default 标点 set) is not repeated.
    static func phoneSymbolCategories(
        ascii: Bool, recents: [String] = [], library: [LibraryCategory] = []
    ) -> [PhoneSymbolCategory] {
        func category(_ id: String, _ title: String, _ symbols: [String]) -> PhoneSymbolCategory {
            var seen = Set<String>()
            return PhoneSymbolCategory(
                id: id, title: title,
                caps: literals("ps-\(id)", symbols.filter { !$0.isEmpty && seen.insert($0).inserted }))
        }
        let common = category(commonCategoryID, "常用", phoneCommonSymbols(ascii: ascii))
        let widths = [
            category("chinese", "中文", phoneChineseSymbols),
            category("english", "英文", phoneEnglishSymbols),
            category("brackets", "括号", phoneBracketSymbols),
        ]
        let covered = Set(([common] + widths).flatMap { $0.caps.map(\.title) })
        let themed = library.compactMap { set -> PhoneSymbolCategory? in
            let result = category("library-\(set.id)", set.title, set.symbols)
            guard result.caps.contains(where: { !covered.contains($0.title) }) else { return nil }
            return result
        }
        let recent = recents.isEmpty ? [] : [category(recentCategoryID, "最近", recents)]
        return [common] + recent + widths + themed
    }

    /// The row-shaped #+= page shares the 123 page's ten-column geometry: the
    /// third row holds nine direct marks and Delete closes the tenth column, so
    /// its caps are exactly as wide as the rows above. The categorised page also
    /// exposes every mark in these rows.
    static func symbolRows(ascii: Bool) -> [KeyboardRow] {
        rows(BuiltinLayouts.symbolPageRows(ascii: ascii), prefix: "sym", capPrefix: "s")
    }

    /// One `KeyboardRow` per canonical character row; the prefix keeps the caps'
    /// SwiftUI identity stable and distinct between the two pages.
    private static func rows(_ values: [[String]], prefix: String, capPrefix: String) -> [KeyboardRow] {
        values.enumerated().map { index, row in
            KeyboardRow(id: "\(prefix)-\(index + 1)", caps: literals("\(capPrefix)\(index + 1)", row))
        }
    }

    /// The id is the row prefix + the character itself: stable and repeatably renderable (SwiftUI identity does not change per access).
    private static func literals(_ prefix: String, _ chars: String) -> [KeyCap] {
        literals(prefix, chars.map(String.init))
    }

    private static func literals(_ prefix: String, _ chars: [String]) -> [KeyCap] {
        chars.enumerated().map { index, char in
            KeyCap(id: "lit-\(prefix)-\(index)-\(char)", title: char, action: .literal(char))
        }
    }
}

extension LayoutAction {
    /// A literal with an explicit Chinese/ASCII pair; it resolves before any legacy single-letter
    /// heuristics (an English page may pair arbitrary text, not only punctuation).
    var isPairedLiteral: Bool { type == .literal && asciiValue != nil }
}

extension LayoutKey {
    /// The visible/typed literal for the effective symbol branch. Nil for non-literals; custom
    /// faces keep their stored label and only the action value resolves.
    func resolvedLiteralValue(usesASCIIPunctuation: Bool) -> String? {
        action.literalValue(usesASCIIPunctuation: usesASCIIPunctuation)
    }

    /// Automatic literal faces resolve the branch; custom/legacy faces keep the authored label.
    func literalFaceTitle(usesASCIIPunctuation: Bool) -> String {
        guard titleMode == .automatic,
            let value = resolvedLiteralValue(usesASCIIPunctuation: usesASCIIPunctuation)
        else { return label }
        return value
    }
}
