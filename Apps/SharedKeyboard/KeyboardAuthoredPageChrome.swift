import Foundation
import KeyboardCore
import LayoutKit
import UIKit

/// Layout facts the authored page shell (chrome != nil) resolves before drawing anything.
///
/// The root width is the real key-area width of the keyboard, and the split activation is settled
/// exactly once against it: a row inside a rail-narrowed main area must never re-apply the
/// automatic width threshold, or a split keyboard would silently re-join below 600pt of inner width.
struct KeyboardAuthoredPageMetrics: Equatable {
    static let spacing: Double = 4
    static let minimumKeyHeight: Double = 44

    let rootWidth: Double
    let keyHeight: Double
    let rowsHeight: Double
    let bottomHeight: Double
    let leadingWidth: Double
    let trailingWidth: Double
    let mainWidth: Double
    let bottomWidth: Double
    let leadingRailHeight: Double
    let trailingRailHeight: Double
    let totalHeight: Double

    init(
        rootWidth: Double, keyHeight: Double, rowCount: Int,
        hasLeading: Bool, hasTrailing: Bool, hasBottom: Bool, hasTrailingSpansBottom: Bool,
        leadingWidth: Double?, trailingWidth: Double?
    ) {
        let width = rootWidth.isFinite ? max(0, rootWidth) : 0
        let height = keyHeight.isFinite ? max(0, keyHeight) : 0
        let spacing = Self.spacing
        let rows = Double(max(0, rowCount))
        // A materialized keypad/category page left the rail widths nil so its shell keeps the
        // built-in phone keypad geometry it was copied from.
        let defaultRail = PhoneKeypadMetrics.resolve(width: width, rowHeight: height).railWidth
        var leading = hasLeading ? Self.railWidth(leadingWidth ?? defaultRail, rootWidth: width) : 0
        var trailing = hasTrailing ? Self.railWidth(trailingWidth ?? defaultRail, rootWidth: width) : 0
        // Keep a usable main area: shrink both rails together instead of overflowing the shell.
        let minimumMain = min(width, PhoneKeypadMetrics.minimumTouchTarget * 3 + spacing * 2)
        let gaps = (leading > 0 ? spacing : 0) + (trailing > 0 ? spacing : 0)
        if leading + trailing > width - gaps - minimumMain {
            let allowed = max(0, width - gaps - minimumMain)
            let total = leading + trailing
            if total > 0 {
                let keptLeading = allowed * leading / total
                leading = keptLeading
                trailing = allowed - keptLeading
            }
        }
        self.rootWidth = width
        self.keyHeight = height
        self.leadingWidth = leading
        self.trailingWidth = trailing
        mainWidth = max(0, width - (leading > 0 ? leading + spacing : 0) - (trailing > 0 ? trailing + spacing : 0))
        rowsHeight = rows > 0 ? rows * (height + spacing) - spacing : 0
        bottomHeight = hasBottom ? height : 0
        bottomWidth =
            hasTrailing && hasTrailingSpansBottom ? max(0, width - trailing - spacing) : width
        leadingRailHeight = hasLeading ? rowsHeight : 0
        trailingRailHeight =
            hasTrailing
            ? (hasTrailingSpansBottom ? rowsHeight + (hasBottom ? spacing + bottomHeight : 0) : rowsHeight)
            : 0
        totalHeight = rowsHeight + (hasBottom ? spacing + bottomHeight : 0)
    }

    private static func railWidth(_ value: Double, rootWidth: Double) -> Double {
        let finite = value.isFinite ? value : 0
        return min(max(0, finite), rootWidth)
    }
}

/// One authored action and the stable key path it belongs to. The renderer routes every tap via the
/// key cap's stable id, never via a label, so an author may rename a control without changing what it does.
struct KeyboardPageAuthoredActionTable {
    struct Entry: Equatable {
        let path: KeyboardPageKeyPath
        let action: LayoutAction
        /// A long-press option: on an English letter page it types an explicit variant instead of
        /// the plain code, exactly like a built-in page keycap.
        let isAlternate: Bool
    }

    private var entries: [String: Entry]

    init(page: KeyboardPageDefinition) {
        var entries: [String: Entry] = [:]
        for (rowIndex, row) in page.rows.enumerated() {
            for (keyIndex, key) in row.keys.enumerated() {
                Self.insert(key, path: .row(rowIndex, key: keyIndex), into: &entries)
            }
        }
        for region in KeyboardPageChrome.Region.allCases {
            for (index, key) in (page.chrome?.keys(in: region) ?? []).enumerated() {
                Self.insert(key, path: .chrome(region, key: index), into: &entries)
            }
        }
        self.entries = entries
    }

    /// One key outside the page's own regions (a category's authored content): the visible face
    /// and its long-press options come from the key, and the caller routes the returned action.
    init(singleKey key: LayoutKey, path: KeyboardPageKeyPath) {
        var entries: [String: Entry] = [:]
        Self.insert(key, path: path, into: &entries)
        self.entries = entries
    }

    private static func insert(
        _ key: LayoutKey, path: KeyboardPageKeyPath, into entries: inout [String: Entry]
    ) {
        entries[capID(path)] = Entry(path: path, action: key.action, isAlternate: false)
        for (index, option) in (key.longPress ?? []).enumerated() {
            entries[optionCapID(path, index)] = Entry(path: path, action: option.action, isAlternate: true)
        }
    }

    func entry(for capID: String) -> Entry? { entries[capID] }

    static func capID(_ path: KeyboardPageKeyPath) -> String {
        switch path {
        case .row(let row, let key): return "page-row-\(row)-\(key)"
        case .chrome(let region, let key): return "page-chrome-\(region.rawValue)-\(key)"
        }
    }

    static func optionCapID(_ path: KeyboardPageKeyPath, _ index: Int) -> String {
        "\(capID(path))-option-\(index)"
    }
}

/// Every live fact an authored page key face reads. Automatic keys draw their native title and
/// state from here; an author label (titleMode == .custom) only replaces the title, never the state.
struct KeyboardPageAuthoredState: Equatable {
    /// The page the keyboard is showing, so a return-to-letters language key knows its meaning.
    var page: KeyboardPage
    var kind: KeyboardPageKind
    var isEnglishMode: Bool
    var shiftState: ShiftState
    var returnTitle: String
    var isReturnEnabled: Bool
    var symbolLocked: Bool
    var isComposing: Bool
    var hasGlobe: Bool
    /// A phone-shaped page (keypad/category) names the symbol page 符号, a 123 row page uses #+=.
    var isPhoneStyled: Bool
    /// Effective panel symbol branch, not the raw controller state. Automatic paired faces and
    /// the language key title/action read this.
    var usesASCIIPunctuation = false
    /// Explicit category decision. A trailing rail alone must never tag a keypad/row page as the
    /// categorized grid (that changes the language key's return/toggle semantics).
    var usesCategorySymbolPage = false

    var shiftActive: Bool { shiftState.isActive }

    /// The shared policy used for automatic language/page faces. The runtime passes the resolved
    /// category decision and effective symbol branch; previews pass the page's own defaults.
    var controlPolicy: KeyboardControlPolicy {
        KeyboardControlPolicy(
            page: page, isEnglishMode: isEnglishMode, hasGlobe: hasGlobe,
            isPhoneLayout: isPhoneStyled, usesASCIIPunctuation: usesASCIIPunctuation,
            includesBottomEnter: true, usesCategorySymbolPage: usesCategorySymbolPage)
    }

    /// The real title of a key: the authored label for .custom, otherwise the live native title.
    /// A nil titleMode keeps per-action semantics (see below).
    func title(for key: LayoutKey) -> String {
        switch key.titleMode {
        case .custom:
            return key.label
        case .automatic:
            return automaticTitle(for: key)
        case nil:
            // Without a title mode, Return draws the live host/composition title whatever label it
            // stores, while space draws its label; copying a page must not freeze Return into a
            // stale label.
            return key.action.type == .enter ? returnTitle : key.label
        }
    }

    private func automaticTitle(for key: LayoutKey) -> String {
        switch key.action.type {
        case .enter: return returnTitle
        case .space: return isEnglishMode ? "space" : "空格"
        case .literal:
            return key.literalFaceTitle(usesASCIIPunctuation: usesASCIIPunctuation)
        default:
            return KeyboardPageControlFace.title(for: key, policy: controlPolicy) ?? key.label
        }
    }

    /// Native disabled state. clearInput (重输) only clears a live composition.
    func isEnabled(_ key: LayoutKey) -> Bool {
        if key.action.type == .clearInput { return isComposing }
        if key.action.type == .shift { return isEnglishMode }
        if key.action.type == .globe { return hasGlobe }
        return true
    }

    /// Extra accessible value for automatic controls (the visible face stays the native one).
    func accessibilityValue(for key: LayoutKey) -> String? {
        guard key.titleMode == .automatic else { return nil }
        switch key.action.type {
        case .symbolLock: return symbolLocked ? "已开启" : "已关闭"
        case .shift: return shiftState == .locked ? "大写锁定" : (shiftState == .once ? "下一字母大写" : "小写")
        default: return nil
        }
    }
}

/// Automatic faces of the page UI controls. Authored pages and main-layout definition keys read
/// this one table, so a control never carries two names.
enum KeyboardPageControlFace {
    /// The native title of a page UI control, or nil for any other action.
    static func title(for key: LayoutKey, policy: KeyboardControlPolicy) -> String? {
        switch key.action.type {
        case .pageSwitch:
            switch key.action.pageSwitchTarget {
            case .letters: return "返回"
            case .numeric: return "123"
            case .symbols: return "符号"
            case nil: return key.label
            }
        case .languageSwitch: return policy.languageTitle(for: key.action.languageSwitchBehavior)
        case .symbolLock: return "锁定"
        case .clearInput: return "重输"
        case .shift: return "上档"
        default: return nil
        }
    }

    /// The spoken name of a page UI control, or nil for any other action.
    static func accessibilityLabel(for key: LayoutKey, policy: KeyboardControlPolicy) -> String? {
        switch key.action.type {
        case .pageSwitch where key.action.pageSwitchTarget == .letters: return "返回主键盘"
        case .pageSwitch: return title(for: key, policy: policy).map { "打开\($0)页" }
        case .languageSwitch: return policy.languageAccessibilityLabel(for: key.action.languageSwitchBehavior)
        case .symbolLock: return "锁定符号页"
        case .shift: return "上档键"
        default: return title(for: key, policy: policy)
        }
    }
}

/// The UI-layer dispatch of an authored page. New actions (shift/page switch/language/lock/clear)
/// never become an engine KeyAction; the panel maps them onto controller entries or page state.
struct KeyboardPageAuthoredActions {
    var perform: (KeyboardPageKeyPath, LayoutAction, Bool) -> Void
    /// A primary (short-press) authored control action.
    func primary(_ path: KeyboardPageKeyPath, _ action: LayoutAction) {
        perform(path, action, false)
    }
    /// Shift's double tap locks the case; every other action routes through perform.
    var performShiftDoubleTap: (KeyboardPageKeyPath) -> Void
    var moveCursor: ((Int) -> Void)?
    var systemKeyboardSwitch: ((UIView, UIEvent) -> Void)?
    /// Native space decoration (current keyboard name and its transient switch hint).
    var spaceLayoutName: String?
    var spaceHintName: String?
    var spaceHintToken: UUID?
    /// The native language long-press menu (published keyboards, then More tools). A languageSwitch
    /// key with no authored long press keeps that system menu instead of losing it.
    var languageMenuAlternates: [KeyCap] = []
    var handleLanguageMenu: ((KeyCap) -> Void)? = nil
    /// Native repeating delete: receives whether this call is a repeat, so authored pages keep the
    /// native rule of no haptic/sound per repeat.
    var performNativeDelete: ((KeyboardPageKeyPath, Bool) -> Void)? = nil
}

extension LayoutAction.Kind {
    /// Page-level controls the host dispatches itself; they never become an engine key action.
    var isPageUI: Bool {
        switch self {
        case .shift, .pageSwitch, .languageSwitch, .symbolLock, .clearInput: return true
        default: return false
        }
    }
}

extension LayoutAction {
    /// The single ASCII letter this literal key types, or nil for symbols and multi-character text.
    var singleASCIILetter: String? {
        // A bilingual pair is typed through literalValue on every branch; it must never fall back
        // to the English single-letter code path (value=a, asciiValue=★ stays a literal).
        guard type == .literal, asciiValue == nil, let value = value, value.utf8.count == 1,
            let character = value.first, character.isLetter, character.isASCII
        else { return nil }
        return value
    }
}
