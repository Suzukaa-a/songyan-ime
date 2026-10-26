import Foundation

/// Builtin presentation policy. DIY rows/actions are deliberately outside this policy.
/// Page changes never own or mutate the engine's remembered Chinese/English mode.
public struct KeyboardControlPolicy: Equatable, Sendable {
    public enum Page: CaseIterable, Hashable, Sendable { case letters, numeric, symbols }
    public enum Slot: CaseIterable, Hashable, Sendable {
        case page, language, globe, space, utility, enter
        /// Keys, never positions: the bundled 9-key's direct 「符号」 key, and the
        /// symbol page's 锁定 toggle (in the utility position).
        case symbolPage, symbolLock
        /// A semantic key, never a physical slot: the 123 the row-shaped #+= page's left
        /// switch is "return to letters" (preserving the input language), not a language toggle.
        case returnToLetters
    }
    public enum LanguageAction: Equatable, Sendable {
        case toggleLanguage
        /// Switch only the panel's symbol language and keep the current page (123 / row-shaped #+=).
        case toggleSymbols
        /// Return to the main letter keyboard without changing the Chinese/English input state.
        case returnToLetters
    }
    public enum Utility: Equatable, Sendable {
        case punctuation(String)
        /// 9-key digit page: the 3x3 holds only 1-9 and 0 goes in the bottom-right slot (as on the system 9-key digit page).
        case digit(String)
    }

    public let page: Page
    public let isEnglishMode: Bool
    public let hasGlobe: Bool
    public let isPhoneLayout: Bool
    public let usesASCIIPunctuation: Bool
    /// Bundled T9 moves Return into its large trailing rail. Other surfaces keep it
    /// in the bottom row. This is presentation only; the action remains `.enter`.
    public let includesBottomEnter: Bool
    /// The #+= page is the categorised grid (with 锁定) rather than rows of keys
    /// shaped like the 123 page's.
    public let usesCategorySymbolPage: Bool
    /// The bundled phone shell's column widths. When set, the first bottom key sits
    /// under the rail and the rest share the grid's width with a wide space bar
    /// (see `Metrics.init(width:columns:includesUtility:)`) instead of the generic
    /// budget.
    public private(set) var phoneColumns: PhoneColumns?

    public struct PhoneColumns: Equatable, Sendable {
        public let rail: Double
        public let digit: Double
        public init(rail: Double, digit: Double) {
            self.rail = rail
            self.digit = digit
        }
    }

    public func aligned(to columns: PhoneColumns?) -> KeyboardControlPolicy {
        var copy = self
        copy.phoneColumns = columns
        return copy
    }

    public init(
        page: Page, isEnglishMode: Bool, hasGlobe: Bool,
        isPhoneLayout: Bool, usesASCIIPunctuation: Bool,
        includesBottomEnter: Bool = true, usesCategorySymbolPage: Bool = true
    ) {
        self.page = page
        self.isEnglishMode = isEnglishMode
        self.hasGlobe = hasGlobe
        self.isPhoneLayout = isPhoneLayout
        self.usesASCIIPunctuation = usesASCIIPunctuation
        self.includesBottomEnter = includesBottomEnter
        self.usesCategorySymbolPage = usesCategorySymbolPage
    }

    /// Slot identities and count stay unchanged across all pages and languages
    /// **for one surface**. Only an actual system-keyboard availability change may
    /// add/remove globe, and only the bundled T9 (which moves Return into its own
    /// trailing column) may drop `enter`. The utility position opens symbols on
    /// letter pages, types 0 on the phone digit pad and locks the categorised symbol page.
    ///
    /// The globe is the leftmost, lowest-frequency control; every other slot keeps its
    /// relative order after it. A surface without a system-keyboard switch has no globe
    /// slot, and the freed width goes to space/Return.
    public var slots: [Slot] {
        [.globe, .page, .language, .space, .utility, .enter].filter {
            ($0 != .globe || hasGlobe) && ($0 != .enter || includesBottomEnter)
        }
    }

    /// Slots are *positions* (width and view identity stay put); on 123 / #+= the
    /// page and language keys exchange so the return-to-letters key takes the page
    /// position and the page key moves one to the right, while the globe keeps the
    /// leading position it has on every page.
    ///
    /// Every letter page — the bundled 9-key included — reaches the symbol page
    /// from the utility slot, where 26/14/18 used to keep 「，」/「。」, so the page
    /// is one tap away on every layout. Numeric and symbol pages keep their own
    /// utility actions (punctuation, 0 on the 9-key digit page, 锁定 on a
    /// categorised symbol page).
    ///
    /// The categorised symbol page carries 锁定 in the utility position: its grid
    /// already types every mark, and the lock decides whether the page stays open
    /// after a symbol (Sogou and iFlytek return to letters unless locked). The
    /// row-shaped #+= page keeps a punctuation key there, like 123.
    public func key(at slot: Slot) -> Slot {
        switch page {
        case .letters:
            return slot == .utility ? .symbolPage : slot
        case .numeric:
            // 123: the left switch returns to letters (keeping the language), the language key
            // switches the symbol branch in place, and the utility position is the #+= switch.
            // The bundled 9-key digit pad keeps its 0 in the utility position.
            switch slot {
            case .page: return .returnToLetters
            case .utility: return isBundledPhonePad ? .utility : .page
            default: return slot
            }
        case .symbols:
            if usesCategorySymbolPage {
                // Categorised grid: the page position returns (keeping the language), the
                // language position opens 123, and the utility position is the lock.
                switch slot {
                case .page: return .language
                case .language: return .page
                case .utility: return .symbolLock
                default: return slot
                }
            }
            switch slot {
            case .page: return .returnToLetters
            case .utility: return .page
            default: return slot
            }
        }
    }

    /// The phone-pad row: the bundled 9-key, and every layout's categorised symbol
    /// page, move Return into their own trailing column.
    public var isBundledPhonePad: Bool { isPhoneLayout && !includesBottomEnter }

    public var pageTarget: Page { page == .numeric ? .symbols : .numeric }
    public var pageTitle: String {
        guard pageTarget == .symbols else { return "123" }
        return Self.symbolPageTitle
    }
    public static let symbolPageTitle = "符号"

    /// The page-following default: letters toggle the input language; 123 (the 9-key digit pad
    /// included) and the row-shaped #+= page switch the symbol language in place; the categorised
    /// symbol grid returns to the main letter keyboard.
    public var languageAction: LanguageAction { languageAction(for: nil) }

    /// What the language key does. Nil follows the page; an authored behavior overrides the page
    /// rule, including the categorised page's return default.
    public func languageAction(for behavior: LayoutAction.LanguageSwitchBehavior?) -> LanguageAction {
        switch behavior {
        case .symbols: return .toggleSymbols
        case .letters: return .returnToLetters
        case nil:
            switch page {
            case .letters: return .toggleLanguage
            case .numeric: return .toggleSymbols
            case .symbols: return usesCategorySymbolPage ? .returnToLetters : .toggleSymbols
            }
        }
    }

    public var languageTitle: String { languageTitle(for: nil) }
    public func languageTitle(for behavior: LayoutAction.LanguageSwitchBehavior?) -> String {
        switch languageAction(for: behavior) {
        // The auto face names the target language, not the current one.
        case .toggleLanguage: return isEnglishMode ? "中文" : "英文"
        case .toggleSymbols: return usesASCIIPunctuation ? "中文" : "英文"
        case .returnToLetters: return "返回"
        }
    }

    public var languageAccessibilityLabel: String { languageAccessibilityLabel(for: nil) }
    public func languageAccessibilityLabel(for behavior: LayoutAction.LanguageSwitchBehavior?) -> String {
        switch languageAction(for: behavior) {
        case .toggleLanguage: return isEnglishMode ? "切换到中文" : "切换到英文"
        case .toggleSymbols: return usesASCIIPunctuation ? "切换到中文符号" : "切换到英文符号"
        case .returnToLetters: return "返回主键盘"
        }
    }
    public var utility: Utility {
        // Letter pages resolve this position to symbolPage in key(at:).
        // Numeric and symbol pages retain their punctuation or digit utility.
        if isPhoneLayout && page == .numeric { return .digit("0") }
        // Only the effective symbol branch decides the mark: an English input language with an
        // explicit Chinese symbol state must keep Chinese punctuation.
        let ascii = usesASCIIPunctuation
        // The 123 and row-shaped #+= pages already hold comma and period, so the
        // slot carries a common mark their rows lack instead of repeating them.
        if page == .numeric { return .punctuation(ascii ? "#" : "……") }
        if page == .symbols && !usesCategorySymbolPage { return .punctuation(ascii ? "@" : "……") }
        return .punctuation(isPhoneLayout ? (ascii ? "." : "。") : (ascii ? "," : "，"))
    }

    /// The punctuation slot's long-press list, its first entry being the corner
    /// hint. On the 123 and #+= pages it holds only marks the rows above lack.
    public var utilityAlternates: [String] {
        guard case .punctuation(let text) = utility else { return [] }
        switch text {
        case "……": return page == .numeric ? ["——"] : []
        case "#": return ["*", "="]
        case "@": return []
        case ".", ",": return [text == "," ? "." : ",", "?", "!", "'", "\""]
        default: return [text == "，" ? "。" : "，", "？", "！", "、", "…"]
        }
    }

    /// One budget for every builtin page. Fractions apply to *content* width after gaps.
    /// At 382pt content (390pt phone minus panel insets) with globe:
    /// 44/44/44/114.8/44/71.2pt, plus five 4pt gaps. The two switches keep the
    /// 44pt target and the width they no longer take goes to space, the most-hit key.
    /// Return never falls below 60pt on a supported >=320pt keyboard; extremely small
    /// previews scale as a whole.
    public func metrics(width: Double) -> Metrics {
        if let phoneColumns, !hasGlobe, !includesBottomEnter {
            return Metrics(width: width, columns: phoneColumns, includesUtility: true)
        }
        return Metrics(
            width: width, hasGlobe: hasGlobe, includesEnter: includesBottomEnter,
            includesUtility: true)
    }

    public struct Metrics: Equatable, Sendable {
        public let spacing: Double
        public let page: Double
        public let language: Double
        public let globe: Double
        public let space: Double
        public let utility: Double
        public let enter: Double

        public init(
            width: Double, hasGlobe: Bool, includesEnter: Bool = true,
            includesUtility: Bool = true
        ) {
            let width = width.isFinite ? max(0, width) : 0
            let count = (hasGlobe ? 4 : 3) + (includesUtility ? 1 : 0) + (includesEnter ? 1 : 0)
            let minimumContent =
                (hasGlobe ? 188.0 : 144.0) + (includesUtility ? 44.0 : 0)
                + (includesEnter ? 60.0 : 0)
            let minimumTotal = minimumContent + Double(count - 1) * 4
            let scale = min(1, width / minimumTotal)
            spacing = 4 * scale
            let content = max(0, width - Double(count - 1) * spacing)
            let extra = max(0, content - minimumContent * scale)
            if hasGlobe {
                // The globe already takes a slot; keeping both switches at the 44pt target
                // hands their old base + growth to space instead of widening the switches.
                page = 44 * scale
                language = page
            } else {
                // The base budget is 50 + 50 + [44] + 44 + 44 + 60.
                // Modest growth goes to switches/Return; the rest goes to space.
                page = 50 * scale + min(12, extra * 0.10)
                language = page
            }
            globe = hasGlobe ? 44 * scale : 0
            utility = includesUtility ? 44 * scale : 0
            enter = includesEnter ? 60 * scale + min(20, extra * 0.16) : 0
            space = max(0, content - page - language - globe - utility - enter)
        }

        /// Phone row: the first key sits under the rail; the keys under the 3×3 grid
        /// do not follow its columns. Like iFlytek's and Sogou's 9-key, the space bar
        /// takes most of that span (side keys : space ≈ 1 : 2.4 : 1), since it is the
        /// most-hit key of the row, and the two side switches stay wide enough to hit.
        /// Falls back to the generic budget when the span cannot fit.
        public init(width: Double, columns: PhoneColumns, includesUtility: Bool) {
            let width = width.isFinite ? max(0, width) : 0
            let gaps = Double(includesUtility ? 3 : 2) * 4
            let span = width - columns.rail - gaps
            let sideShare = includesUtility ? 1 / 4.4 : 1 / 3.4
            let side = span * sideShare
            guard columns.rail >= 0, side >= 44, span - side * (includesUtility ? 2 : 1) >= 44 else {
                self.init(
                    width: width, hasGlobe: false, includesEnter: false,
                    includesUtility: includesUtility)
                return
            }
            self.init(
                spacing: 4, page: columns.rail, language: side, globe: 0,
                space: span - side * (includesUtility ? 2 : 1),
                utility: includesUtility ? side : 0, enter: 0)
        }

        private init(
            spacing: Double, page: Double, language: Double, globe: Double,
            space: Double, utility: Double, enter: Double
        ) {
            self.spacing = spacing
            self.page = page
            self.language = language
            self.globe = globe
            self.space = space
            self.utility = utility
            self.enter = enter
        }

        public subscript(slot: Slot) -> Double {
            switch slot {
            case .page: return page
            case .language: return language
            case .globe: return globe
            case .space: return space
            case .utility: return utility
            case .enter: return enter
            case .symbolPage: return page
            case .symbolLock: return utility
            // Semantic slot only; it occupies the physical page position.
            case .returnToLetters: return page
            }
        }
    }
}
