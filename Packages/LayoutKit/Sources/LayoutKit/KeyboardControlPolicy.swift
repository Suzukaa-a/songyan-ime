import Foundation

/// Builtin presentation policy. DIY rows/actions are deliberately outside this policy.
/// Page changes never own or mutate the engine's remembered Chinese/English mode.
public struct KeyboardControlPolicy: Equatable, Sendable {
    public enum Page: CaseIterable, Hashable, Sendable { case letters, numeric, symbols }
    public enum Slot: CaseIterable, Hashable, Sendable {
        case page, language, globe, space, utility, enter
    }
    public enum LanguageAction: Equatable, Sendable {
        case toggleLanguage, returnToLetters
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
    /// The bundled phone shell's column widths. When set, the bottom keys sit under
    /// the columns above them (page under the rail, language under 1/4/7, space
    /// across the rest) instead of the generic budget.
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
        includesBottomEnter: Bool = true
    ) {
        self.page = page
        self.isEnglishMode = isEnglishMode
        self.hasGlobe = hasGlobe
        self.isPhoneLayout = isPhoneLayout
        self.usesASCIIPunctuation = usesASCIIPunctuation
        self.includesBottomEnter = includesBottomEnter
    }

    /// Slot identities and count stay unchanged across all pages and languages
    /// **for one surface**. Only an actual system-keyboard availability change may
    /// add/remove globe, and only the bundled T9 (which moves Return into its own
    /// trailing column) may drop `enter`. That column also owns 重输, and its letter
    /// and symbol pages already type punctuation themselves, so they drop the utility
    /// slot too; its 123 page keeps it for 0.
    public var slots: [Slot] {
        Slot.allCases.filter {
            ($0 != .globe || hasGlobe) && ($0 != .enter || includesBottomEnter)
                && ($0 != .utility || includesUtility)
        }
    }

    /// Slots are *positions* (width and view identity stay put); only the first
    /// two exchange their keys. On 123 / #+= the return-to-letters key takes the
    /// leading position — where 「123」 was tapped to get here — and the page key
    /// moves one to the right, so the same spot leads in and back out, as on the
    /// system keyboard.
    public func key(at slot: Slot) -> Slot {
        guard page != .letters else { return slot }
        switch slot {
        case .page: return .language
        case .language: return .page
        default: return slot
        }
    }

    public var includesUtility: Bool {
        // Only the digit pad needs it (for 0); the 9-key symbol grid holds every
        // punctuation mark itself, so its space key takes the slot.
        !(isPhoneLayout && !includesBottomEnter && page != .numeric)
    }

    public var pageTarget: Page { page == .numeric ? .symbols : .numeric }
    public var pageTitle: String { pageTarget == .symbols ? "#+=" : "123" }
    public var languageAction: LanguageAction { page == .letters ? .toggleLanguage : .returnToLetters }
    public var languageTitle: String {
        if page == .letters { return isEnglishMode ? "中文" : "ABC" }
        return isEnglishMode ? "ABC" : "中文"
    }
    public var languageAccessibilityLabel: String {
        if page == .letters { return isEnglishMode ? "切换到中文" : "切换到英文" }
        return isEnglishMode ? "返回英文字母页" : "返回中文字母页"
    }
    public var utility: Utility {
        // The phone keypad already has a direct comma in its first key and
        // quick-punctuation rail. On 26/14 the same bottom punctuation slot
        // makes comma a one-tap action; the period remains a long-press choice.
        // This keeps the number of control slots (and hit geometry) stable.
        if isPhoneLayout && page == .numeric { return .digit("0") }
        let ascii = isEnglishMode || usesASCIIPunctuation
        return .punctuation(isPhoneLayout ? (ascii ? "." : "。") : (ascii ? "," : "，"))
    }

    /// One budget for every builtin page. Fractions apply to *content* width after gaps.
    /// At 382pt content (390pt phone minus panel insets) with globe:
    /// 57/57/44/88.8/44/71.2pt, plus five 4pt gaps.
    /// Space yields to the two left switches first; Return never falls below 60pt
    /// on a supported >=320pt keyboard. Extremely small previews scale as a whole.
    public func metrics(width: Double) -> Metrics {
        if let phoneColumns, !hasGlobe, !includesBottomEnter {
            return Metrics(width: width, columns: phoneColumns, includesUtility: includesUtility)
        }
        return Metrics(
            width: width, hasGlobe: hasGlobe, includesEnter: includesBottomEnter,
            includesUtility: includesUtility)
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
            // The base budget is 50 + 50 + [44] + 44 + 44 + 60.
            // Modest growth goes to switches/Return; the rest goes to space.
            page = 50 * scale + min(12, extra * 0.10)
            language = page
            globe = hasGlobe ? 44 * scale : 0
            utility = includesUtility ? 44 * scale : 0
            enter = includesEnter ? 60 * scale + min(20, extra * 0.16) : 0
            space = max(0, content - page - language - globe - utility - enter)
        }

        /// Column-aligned phone row: page = rail, language = one digit column,
        /// 0 (123 page) = the last digit column, space takes the exact remainder.
        /// Falls back to the generic budget when the columns cannot fit.
        public init(width: Double, columns: PhoneColumns, includesUtility: Bool) {
            let width = width.isFinite ? max(0, width) : 0
            let gaps = Double(includesUtility ? 3 : 2) * 4
            let fixed = columns.rail + columns.digit * (includesUtility ? 2 : 1)
            guard columns.rail >= 0, columns.digit >= 0, width - fixed - gaps >= 44 else {
                self.init(
                    width: width, hasGlobe: false, includesEnter: false,
                    includesUtility: includesUtility)
                return
            }
            self.init(
                spacing: 4, page: columns.rail, language: columns.digit, globe: 0,
                space: width - fixed - gaps,
                utility: includesUtility ? columns.digit : 0, enter: 0)
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
            }
        }
    }
}
