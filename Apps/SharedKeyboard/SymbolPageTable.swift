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
    static func phoneNumericRail(ascii: Bool) -> [KeyCap] {
        let priority = ascii ? [".", "?", "!"] : [".", "？", "！"]
        let rows = numericRows(ascii: ascii)
        let rest = (rows.last?.caps ?? []) + (rows.count > 1 ? rows[1].caps : [])
        var seen = Set<String>()
        return (literals("phone", priority) + rest).filter { seen.insert($0.title).inserted }
    }

    static func numericRows(ascii: Bool) -> [KeyboardRow] {
        [
            KeyboardRow(id: "num-1", caps: literals("n1", "1234567890")),
            // The Chinese punctuation page matches the system pinyin keyboard: full-width colon/semicolon/brackets and Chinese quotes.
            KeyboardRow(
                id: "num-2",
                caps: literals(
                    "n2",
                    ascii
                        ? "-/:;()¥&@\"".map(String.init)
                        : ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"])),
            // The system Simplified Pinyin 123 page also has a half-width "." on its third row (decimal point, URLs, version numbers);
            // the ellipsis moves to the #+= page, still one tap away.
            KeyboardRow(
                id: "num-3",
                caps: literals("n3", ascii ? [".", ",", "?", "!", "'", "\""] : ["，", "。", "？", "！", "、", "."])),
        ]
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
        /// Kaomoji and other multi-glyph entries need two wide columns instead of four.
        var columns: Int { caps.contains { $0.title.count > 3 } ? 2 : 4 }
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
        "+", "=", "/", "\\", "|", "~", "^", "`", "–", "¥", "€", "£",
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

    static func symbolRows(ascii: Bool) -> [KeyboardRow] {
        [
            // Chinese symbol page: title marks, square brackets, em dash and & are directly visible (as on the system Chinese keyboard);
            // the euro and pound signs remain available on long press of the yen / dollar keys.
            KeyboardRow(
                id: "sym-1",
                caps: literals(
                    "s1",
                    ascii
                        ? "[]{}#%^*+=".map(String.init)
                        : ["【", "】", "{", "}", "#", "%", "^", "*", "+", "="])),
            KeyboardRow(
                id: "sym-2",
                caps: literals(
                    "s2",
                    ascii
                        ? "_\\|~<>€£¥·".map(String.init)
                        : ["_", "—", "\\", "|", "~", "《", "》", "&", "$", "·"])),
            KeyboardRow(
                id: "sym-3",
                caps: literals("s3", ascii ? [".", ",", "?", "!", "@", "/"] : ["，", "。", "？", "！", "「", "」", "…"])),
        ]
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
