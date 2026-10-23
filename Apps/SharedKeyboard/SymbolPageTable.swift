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

    /// A phone (digit pad) definition's symbol page, like mainstream 9-key pinyin: a
    /// category rail and a scrolling grid of keys as large as the digit pad's. It holds
    /// every symbol the 123/#+= rows of the other layouts offer (- / @ included), so
    /// nothing is reachable there but missing here.
    struct PhoneSymbolCategory: Equatable {
        let id: String
        let title: String
        let caps: [KeyCap]
    }

    static func phoneSymbolCategories() -> [PhoneSymbolCategory] {
        func category(_ id: String, _ title: String, _ symbols: [String]) -> PhoneSymbolCategory {
            var seen = Set<String>()
            return PhoneSymbolCategory(
                id: id, title: title,
                caps: literals("ps-\(id)", symbols.filter { seen.insert($0).inserted }))
        }
        // "." (the 123-page half-width period) is the half-width set in both punctuation modes (addresses, URLs, code);
        // full-width punctuation is one tap away under the Chinese page.
        let common = [
            ",", ".", "?", "!", "@", "/", "-", ":", ";", "(", ")", "\"", "'", "&", "_", "~",
            "#", "*", "…", "¥",
        ]
        return [
            category("common", "常用", common),
            category(
                "chinese", "中文",
                [
                    "，", "。", "？", "！", "、", "：", "；", "…", "—", "·", "“", "”", "‘", "’",
                    "（", "）", "《", "》", "〈", "〉", "「", "」", "『", "』", "【", "】", "～", "¥",
                ]),
            category(
                "english", "英文",
                [
                    ",", ".", "?", "!", ":", ";", "'", "\"", "`", "@", "#", "$", "%", "&", "*",
                    "-", "_", "/", "\\", "|", "~", "^", "(", ")", "[", "]", "{", "}", "<", ">",
                ]),
            category(
                "brackets", "括号",
                [
                    "（", "）", "【", "】", "《", "》", "「", "」", "『", "』", "〈", "〉",
                    "〔", "〕", "(", ")", "[", "]", "{", "}", "<", ">",
                ]),
            category(
                "math", "数学",
                [
                    "+", "-", "×", "÷", "=", "≠", "≈", "<", ">", "≤", "≥", "%", "‰", "±",
                    "√", "°", "∞", "π", "∑", "²", "³", "½", "¼", "^",
                ]),
            category(
                "other", "其他",
                [
                    "¥", "$", "€", "£", "¢", "&", "#", "§", "©", "®", "™", "℃", "·", "•", "※",
                    "★", "☆", "○", "●", "△", "□", "→", "←", "↑", "↓", "✓", "✗", "_", "\\", "|",
                ]),
        ]
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
