import CandidateKit
import Combine
import KeyboardCore
import LayoutKit
import SwiftUI

/// A key that acts on release. While it is held, the next key's touch-down commits
/// it first (`KeyRollover`).
@MainActor protocol KeyboardRolloverPress: AnyObject {
    func commitRolloverPress()
}

/// The key a finger is still on as a plain tap. Fast two-thumb typing lands the next key
/// before this one lifts; like the system keyboard, that touch-down commits this key first,
/// so keys keep press order instead of lift order. Every key's touch-down reports here.
@MainActor enum KeyRollover {
    private static weak var pending: (any KeyboardRolloverPress)?

    /// A key went down: the press still held on another key is typed first.
    static func keyDown(_ key: AnyObject) {
        guard let held = pending, held !== key else { return }
        pending = nil
        held.commitRolloverPress()
    }

    /// `key` is now a plain tap that the next touch-down types first.
    static func hold(_ key: any KeyboardRolloverPress) { pending = key }

    /// `key` no longer acts on release as a plain tap (lifted, cancelled, held, slid off).
    static func release(_ key: AnyObject) {
        if pending === key { pending = nil }
    }
}

/// Ordered alternate KeyCaps are the renderer's data boundary; no LayoutKit types required.
struct AlternateCharacterKey: UIViewRepresentable {
    @Environment(\.keyboardPanelHostLifetime) private var hostLifetime
    @Environment(\.keyboardAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.keyboardPopupSurface) private var popupSurface
    let cap: KeyCap
    let alternates: [KeyCap]
    var longPressDelay: TimeInterval = 0.35
    var layoutPicker = false
    var phoneKey = false
    var phoneSideKey = false
    var requiresExplicitAlternateSelection = false
    var showsKeyPreview = false
    var visualRole: String? = nil
    /// Explicit title size (points) for keys whose label is content rather than a
    /// keycap glyph, e.g. the 9-key rail's readings. nil = the role's key size.
    var titleSize: Double? = nil
    /// The letters of a merged cap (`["w", "e"]`): the first in the primary tone, the
    /// rest in the secondary tone. Empty for ordinary keys.
    var letterGroup: [String] = []
    /// One shuangpin hint per letter of `letterGroup`, drawn in a column under its letter.
    var groupHints: [String?] = []
    /// One cap per letter of a two-letter key: a sideways swipe types the left or right one.
    var letterSwipe: [KeyCap] = []
    /// Committed by a short upward swipe that starts on the key (phone digits).
    var swipeUp: KeyCap? = nil
    /// The subtitle is a shuangpin final table: draw it as a small line under the
    /// letter and keep the corner for the first long-press alternate (the digit),
    /// as on the quanpin 26-key.
    var syllableHintBelow = false
    /// Overrides the default AX hint. The default only describes "long-press alternate", which is wrong for a tap-cycling key
    /// (the 9-key idle first key); that key must announce the real cycling order.
    var accessibilityHintOverride: String? = nil
    var accessibilityID: String? = nil
    let onSelect: (KeyCap) -> Void

    func makeUIView(context: Context) -> CharacterButton {
        let button = CharacterButton(frame: .zero)
        button.appearance = appearance
        button.popupSurface = popupSurface
        button.hostLifetime = hostLifetime
        button.accessibilityIdentifier = accessibilityID
        button.configure(
            cap: cap, alternates: alternates, longPressDelay: longPressDelay, layoutPicker: layoutPicker,
            phoneKey: phoneKey, phoneSideKey: phoneSideKey,
            requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
            showsKeyPreview: showsKeyPreview,
            visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
            groupHints: groupHints, letterSwipe: letterSwipe,
            swipeUp: swipeUp, syllableHintBelow: syllableHintBelow,
            accessibilityHintOverride: accessibilityHintOverride, onSelect: onSelect)
        button.isEnabled = isEnabled
        return button
    }

    func updateUIView(_ button: CharacterButton, context: Context) {
        button.appearance = appearance
        button.popupSurface = popupSurface
        button.hostLifetime = hostLifetime
        button.accessibilityIdentifier = accessibilityID
        button.configure(
            cap: cap, alternates: alternates, longPressDelay: longPressDelay, layoutPicker: layoutPicker,
            phoneKey: phoneKey, phoneSideKey: phoneSideKey,
            requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
            showsKeyPreview: showsKeyPreview,
            visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
            groupHints: groupHints, letterSwipe: letterSwipe,
            swipeUp: swipeUp, syllableHintBelow: syllableHintBelow,
            accessibilityHintOverride: accessibilityHintOverride, onSelect: onSelect)
        // `isEnabled` repaints the cap in its setter; only write a real change.
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        if !isEnabled { button.cancelPress() }
    }

    static func dismantleUIView(_ button: CharacterButton, coordinator: ()) { button.cancelPress() }

    final class CharacterButton: UIControl, KeyboardKeyHitTarget, KeyboardRolloverPress {
        var hostLifetime: KeyboardPanelHostLifetime? {
            didSet {
                guard oldValue !== hostLifetime else { return }
                cancelPress()
                rebindPanelHostObserver(self, selector: #selector(abandonPress), from: oldValue, to: hostLifetime)
            }
        }
        var appearance = KeyboardAppearance()
        private let capLayer = SkinCapLayer()
        private let releaseAnimator = KeyboardKeyReleaseAnimator()
        let title = UILabel()
        let subtitle = UILabel()
        private let alternateHint = UILabel()
        var cap: KeyCap?
        var alternates: [KeyCap] = []
        private var longPressDelay: TimeInterval = 0.35
        private var onSelect: ((KeyCap) -> Void)?
        var holdTimer: Timer?
        var popup: UIScrollView?
        weak var keyPreview: KeyCalloutView?
        var popupLabels: [UILabel] = []
        /// Trailing checkmark of the current keyboard in the language-key menu.
        var layoutCheckmarks: [Int: UIImageView] = [:]
        var scrollTimer: Timer?
        weak var popupSurface: UIView?
        var popupHostSize = CGSize.zero
        weak var popupHost: UIView?
        /// A popup *cell* index (blind-drag space), not an alternate index.
        var highlightedAlternate: Int?
        /// Popup cell → alternate index. A key on the right half mirrors its
        /// popup: the options run right to left from the cell above the finger.
        var cellAlternates: [Int] = []
        var lastLocation = CGPoint.zero
        /// The language menu's stationary-release target is anchored to the
        /// original touch, not to the key's changing SwiftUI/UIView bounds.
        var layoutHoldOrigin = CGPoint.zero
        /// Blind drag: the long-press origin and the popup grid, both in the
        /// popup's **content** coordinate space, so vertical auto-scroll is
        /// accounted for and the mapping never depends on precise cell landing.
        var dragOrigin = CGPoint.zero
        /// The same long-press point in **window** space. The drop-away cancel
        /// is measured from it on screen, because content coordinates move with
        /// the popup's auto-scroll.
        var dragOriginInWindow = CGPoint.zero
        var dragGeometry: AlternateDragPicker.Geometry?
        /// Ordinary keys only: keeps the opening default (usually not under the
        /// finger) from jumping against the finger's motion.
        var motionGuard: AlternateDragPicker.MotionGuard?
        /// The opening default: horizontal travel steps through options from it.
        var dragAnchor: Int?
        /// Which hint policy each secondary label obeys (`KeyHintLayoutPolicy`).
        private var subtitleHintKind = KeyHintLayoutPolicy.Kind.syllableHint
        private var hintKind = KeyHintLayoutPolicy.Kind.alternate
        /// Line counts resolved by the hint policy, used for the label frames.
        private var subtitleLines = 1
        private var hintLines = 1
        private var previousSize = CGSize.zero
        var layoutPicker = false
        private var phoneKey = false
        private var phoneSideKey = false
        private var visualRole: String?
        var didHold = false
        var requiresExplicitAlternateSelection = false
        var showsKeyPreview = false
        private var titleSize: Double?
        private var letterGroup: [String] = []
        private var groupHints: [String?] = []
        private var letterSwipe: [KeyCap] = []
        /// Per-letter hint labels of a merged cap, one per letter while any hint shows.
        private var columnHints: [UILabel] = []
        private var columnHintLines = 1
        /// Sideways pick on a two-letter key (`LetterSwipeTracker`).
        private var letterTracker: LetterSwipeTracker?
        var didLetterSwipe = false
        /// The finger left a two-letter key sideways before the swipe locked.
        var exitedSideways = false
        /// The letter the swipe currently picks; drawn in the primary tone.
        private var swipeChoice: Int?
        private var swipeUp: KeyCap?
        private var syllableHintBelow = false
        /// Overrides the default AX hint (the default only describes "long-press alternate", wrong for a tap-cycling key).
        /// Assigned only from `configure`; takes no part in state outside `Configuration`.
        private var accessibilityHintOverride: String?
        /// Window-space touch-down point; an upward travel past
        /// `swipeUpDistance` before the hold fires selects `swipeUp`.
        private var touchOrigin = CGPoint.zero
        var didSwipeUp = false
        /// A flick shorter than this (or than 40% of the key) is finger drift in a
        /// normal tap; 20pt let slightly upward taps on 9-key type the digit.
        private static let swipeUpDistance: CGFloat = 24
        /// Coming back this close to the touch-down point undoes the flick.
        private static let swipeUpReturn: CGFloat = 10
        private var swipeUpThreshold: CGFloat { max(Self.swipeUpDistance, bounds.height * 0.4) }
        /// The finger left the key before a hold completed. Like the system
        /// keyboard, the character key under the finger at lift types instead.
        var slidOff = false
        /// This press was already typed by a rollover; the rest of its touch is inert.
        var consumed = false
        /// A flick key's touch rose out of the key without becoming its swipe-up.
        var exitedUpward = false
        var explicitSelection = ExplicitAlternateSelection()
        /// Everything `configure` derives the labels, hints and cap paint from.
        /// SwiftUI calls `updateUIView` for every key on every panel update (each
        /// keystroke re-renders the panel); an unchanged key must not re-measure
        /// its labels, rebuild accessibility actions and schedule another layout.
        private struct Configuration: Equatable {
            let cap: KeyCap
            let alternates: [KeyCap]
            let longPressDelay: TimeInterval
            let layoutPicker: Bool
            let phoneKey: Bool
            let phoneSideKey: Bool
            let requiresExplicitAlternateSelection: Bool
            let showsKeyPreview: Bool
            let visualRole: String?
            let titleSize: Double?
            let letterGroup: [String]
            let groupHints: [String?]
            let letterSwipe: [KeyCap]
            let swipeUp: KeyCap?
            let syllableHintBelow: Bool
            let accessibilityHintOverride: String?
            let appearance: KeyboardAppearance
        }
        private var configuration: Configuration?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isAccessibilityElement = true
            accessibilityTraits = .keyboardKey
            isMultipleTouchEnabled = false
            layer.cornerRadius = 6
            layer.borderWidth = 0.5
            title.textAlignment = .center
            title.font = .systemFont(ofSize: 22, weight: .medium)
            title.adjustsFontSizeToFitWidth = true
            title.minimumScaleFactor = 0.6
            subtitle.font = .systemFont(ofSize: 10)
            subtitle.textColor = .secondaryLabel
            subtitle.textAlignment = .center
            subtitle.adjustsFontSizeToFitWidth = true
            alternateHint.font = .systemFont(ofSize: 9)
            alternateHint.textColor = .secondaryLabel
            alternateHint.textAlignment = .right
            for label in [title, subtitle, alternateHint] {
                label.isUserInteractionEnabled = false
                addSubview(label)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(
            cap: KeyCap, alternates: [KeyCap], longPressDelay: TimeInterval,
            layoutPicker: Bool, phoneKey: Bool, phoneSideKey: Bool,
            requiresExplicitAlternateSelection: Bool,
            showsKeyPreview: Bool,
            visualRole: String?, titleSize: Double? = nil,
            letterGroup: [String] = [], groupHints: [String?] = [],
            letterSwipe: [KeyCap] = [], swipeUp: KeyCap? = nil,
            syllableHintBelow: Bool = false,
            accessibilityHintOverride: String? = nil,
            onSelect: @escaping (KeyCap) -> Void
        ) {
            // The action closure is cheap to swap and must always be the latest one.
            self.onSelect = onSelect
            let next = Configuration(
                cap: cap, alternates: alternates, longPressDelay: longPressDelay,
                layoutPicker: layoutPicker, phoneKey: phoneKey, phoneSideKey: phoneSideKey,
                requiresExplicitAlternateSelection: requiresExplicitAlternateSelection,
                showsKeyPreview: showsKeyPreview,
                visualRole: visualRole, titleSize: titleSize, letterGroup: letterGroup,
                groupHints: groupHints, letterSwipe: letterSwipe,
                swipeUp: swipeUp, syllableHintBelow: syllableHintBelow,
                accessibilityHintOverride: accessibilityHintOverride,
                appearance: appearance)
            guard next != configuration else { return }
            configuration = next
            // Cancel the press only when key identity/behavior changes; a re-render that changes only the title (e.g. Shift) must not swallow a key still held
            // (when typing quickly, the previous key's release consumes the one-shot Shift while the next is not yet released). Alternate changes cancel only while the candidate popup is open.
            if self.cap?.id != cap.id || self.cap?.action != cap.action || self.longPressDelay != longPressDelay
                || self.requiresExplicitAlternateSelection != requiresExplicitAlternateSelection
                || self.letterSwipe != letterSwipe
                || (popup != nil && self.alternates != alternates)
            {
                abandonPress()
            }
            self.cap = cap
            self.alternates = alternates
            self.longPressDelay = longPressDelay
            self.layoutPicker = layoutPicker
            self.phoneKey = phoneKey
            self.phoneSideKey = phoneSideKey
            self.visualRole = visualRole
            self.requiresExplicitAlternateSelection = requiresExplicitAlternateSelection
            self.showsKeyPreview = showsKeyPreview
            self.titleSize = titleSize
            self.letterGroup = letterGroup
            self.groupHints = groupHints
            self.letterSwipe = letterSwipe.count == 2 ? letterSwipe : []
            configureColumnHints()
            self.swipeUp = swipeUp
            self.syllableHintBelow = syllableHintBelow
            self.accessibilityHintOverride = accessibilityHintOverride
            title.text = cap.title
            subtitle.text =
                cap.subtitle == cap.title
                ? nil
                : syllableHintBelow ? cap.subtitle?.replacingOccurrences(of: "/", with: "/\u{200B}") : cap.subtitle
            alternateHint.text = alternates.first?.title == cap.subtitle ? nil : alternates.first?.title
            // Hint policy: only the label that carries `KeyCap.subtitle` (the
            // shuangpin syllable table) may wrap to a second line; the first
            // long-press alternate and the phone-key digit stay single-line.
            subtitleHintKind = .syllableHint
            hintKind = alternates.first?.title == cap.subtitle ? .syllableHint : .alternate
            if phoneKey {
                subtitle.text = nil
                alternateHint.text = phoneSideKey ? alternates.first?.title : cap.subtitle
                alternateHint.font = .systemFont(ofSize: 11)
                hintKind = .phoneLetters
            } else {
                alternateHint.font = .systemFont(ofSize: 9)
            }
            if layoutPicker {
                // Visible menu indicator: a long press on the language key opens the published-keyboard switch list (ending with "More tools").
                // A genuinely drawn corner badge, not explanatory text.
                alternateHint.text = KeyboardToolsAffordance.indicatorGlyph
                subtitle.text = nil
                // Note: do **not** set accessibilityHint here -- the layoutPicker branch below
                // assigns after this and would override it. The visible entry is described in the final assignment.
            }
            if appearance.isSystemDefault, !phoneKey, !layoutPicker, !syllableHintBelow {
                // Secondary codes/digits live in the corner, not a second centered baseline.
                if subtitle.text != nil { hintKind = .syllableHint }
                alternateHint.text = subtitle.text ?? alternateHint.text
                subtitle.text = nil
            }
            accessibilityLabel = cap.title
            accessibilityValue = cap.subtitle
            accessibilityHint =
                accessibilityHintOverride
                ?? (alternates.isEmpty ? nil : "长按并滑动选择副键，也可使用辅助功能操作")
            if letterGroup.count > 1 {
                accessibilityLabel = letterGroup.joined(separator: " ")
                let described = zip(letterGroup, groupHints).compactMap { letter, hint in
                    hint.map { "\(letter)：\($0)" }
                }
                accessibilityValue = described.isEmpty ? nil : described.joined(separator: "，")
                if !self.letterSwipe.isEmpty, alternates.isEmpty, accessibilityHintOverride == nil {
                    accessibilityHint = "向左或向右滑动可输入对应的字母，也可使用辅助功能操作"
                }
            }
            if layoutPicker {
                if cap.subtitle == "返回" {
                    accessibilityLabel = cap.title == "中文" ? "返回中文字母页" : "返回英文字母页"
                } else {
                    accessibilityLabel = cap.title == "中文" ? "切换到中文输入" : "切换到英文输入"
                }
                // Final assignment: the long-press list contains the added keyboards and, at the end, More tools.
                accessibilityHint =
                    alternates.isEmpty
                    ? UserTerminology.userKeyboardSwitcherEmpty
                    : "长按滑选已添加的键盘或更多工具，按住列表边缘滚动；也可使用辅助功能操作"
            }
            accessibilityCustomActions = (self.letterSwipe + alternates).map { alternate in
                UIAccessibilityCustomAction(
                    name:
                        "\(requiresExplicitAlternateSelection ? "设为快捷符号：" : layoutPicker ? "切换键盘：" : "输入 ")\(alternate.title)"
                ) { [weak self] _ in
                    guard let self, self.isEnabled else { return false }
                    self.onSelect?(alternate)
                    return true
                }
            }
            updateAppearance(in: bounds)
            setNeedsLayout()
        }

        override func layoutSubviews() {
            // A frame write on a transformed layer is undefined: every pass starts
            // from identity, lays out cleanly, then re-applies the press physics.
            releaseAnimator.resetPressVisual(layers: pressVisualLayers)
            super.layoutSubviews()
            updateAppearance(in: bounds)
            if previousSize != bounds.size {
                cancelPress()
                previousSize = bounds.size
            }
            let visual = appearance.visualRect(in: bounds)
            let content = visual.insetBy(dx: 3, dy: 2)
            // Hint policy (`KeyHintLayoutPolicy`): a shuangpin syllable hint may
            // use two lines when one is not enough, everything else keeps its
            // single-line semantics. Only the hint label's own frame is touched.
            if appearance.isSystemDefault {
                // Primary labels share one baseline even when a key has a secondary label.
                // A shuangpin final line under the letter lifts the letter slightly so both read.
                let lifted = (syllableHintBelow && !(subtitle.text ?? "").isEmpty) || !columnHints.isEmpty
                title.frame = lifted ? content.offsetBy(dx: 0, dy: -4) : content
                // A wrapped shuangpin hint grows upward into the lifted letter's room.
                let subtitleHeight = CGFloat(
                    KeyHintLayoutPolicy.height(
                        lines: subtitleLines, lineHeight: Double(subtitle.font.lineHeight)))
                subtitle.frame = CGRect(
                    x: content.minX, y: content.maxY - subtitleHeight,
                    width: content.width, height: subtitleHeight)
                alternateHint.frame = CGRect(
                    x: content.minX, y: content.minY,
                    width: content.width,
                    height: CGFloat(
                        KeyHintLayoutPolicy.height(
                            lines: hintLines,
                            lineHeight: Double(alternateHint.font.lineHeight))))
            } else {
                let hasSubtitle = !(subtitle.text ?? "").isEmpty || !columnHints.isEmpty
                title.frame = CGRect(
                    x: content.minX, y: hasSubtitle ? content.minY + 4 : content.minY,
                    width: content.width, height: hasSubtitle ? 29 : content.height)
                // The centered secondary baseline grows upward so its bottom edge
                // (and therefore nothing about the primary label) stays put.
                let subtitleHeight = CGFloat(
                    KeyHintLayoutPolicy.height(
                        lines: subtitleLines, lineHeight: Double(subtitle.font.lineHeight)))
                subtitle.frame = CGRect(
                    x: content.minX, y: content.maxY - subtitleHeight,
                    width: content.width, height: subtitleHeight)
                alternateHint.frame = CGRect(
                    x: content.minX, y: content.minY, width: content.width,
                    height: CGFloat(
                        KeyHintLayoutPolicy.height(
                            lines: hintLines,
                            lineHeight: Double(alternateHint.font.lineHeight))))
            }
            layoutColumnHints(in: content)
            // Under a callout the keycap keeps its full size so the callout's stem meets its edges.
            releaseAnimator.updatePressVisual(
                container: layer, layers: pressVisualLayers,
                isPressed: isHighlighted, scales: !showsCallout)
        }

        /// Applies the shared hint policy to an already-populated hint label and
        /// returns its line count. `natural` is the label's intended one-line font;
        /// a short hint keeps it exactly, a wrapped hint steps down and shrinks.
        @discardableResult
        private func applyHintLayout(
            to label: UILabel, kind: KeyHintLayoutPolicy.Kind,
            availableWidth: CGFloat, natural: UIFont
        ) -> Int {
            let text = label.text ?? ""
            let measured = text.isEmpty ? 0 : KeyboardTextMeasure.width(of: text, font: natural)
            let lines = KeyHintLayoutPolicy.lineCount(
                kind: kind,
                measuredWidth: Double(measured),
                availableWidth: Double(availableWidth))
            let scale = CGFloat(KeyHintLayoutPolicy.fontScale(lines: lines))
            let targetSize = natural.pointSize * scale
            // Only touch the font when it actually changes: the label font setter
            // invalidates layout, and this runs on every appearance refresh.
            if abs((label.font?.pointSize ?? 0) - targetSize) > 0.01 {
                label.font = natural.withSize(targetSize)
            }
            label.numberOfLines = lines
            if lines > 1 {
                label.lineBreakMode = text.contains("\u{200B}") ? .byWordWrapping : .byCharWrapping
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = CGFloat(KeyHintLayoutPolicy.minimumScaleFactor)
            } else {
                // Restore the label's original one-line behaviour exactly:
                // `subtitle` shrinks to fit, `alternateHint` truncates.
                label.lineBreakMode = .byTruncatingTail
                label.adjustsFontSizeToFitWidth = (label === subtitle) || columnHints.contains(label)
                label.minimumScaleFactor = 0
            }
            return lines
        }

        /// The cap surface and its glyphs move together. The button's own layer is
        /// deliberately not transformed, so `bounds.contains` in tracking, the hit
        /// target and the popup placement stay exactly as before.
        private var pressVisualLayers: [CALayer?] {
            [capLayer, title.layer, subtitle.layer, alternateHint.layer] + columnHints.map(\.layer)
        }

        private func updateAppearance(in bounds: CGRect) {
            let isControl: Bool
            switch cap?.action {
            case .code?, .literal?, .letterVariant?, .space?: isControl = false
            default: isControl = true
            }
            let role =
                isHighlighted
                ? "pressed"
                : visualRole ?? (cap?.action == .enter ? "accent" : ((isControl || phoneSideKey) ? "control" : "key"))
            capLayer.update(in: self, appearance: appearance, role: role, pressed: isHighlighted)
            // A disabled key (e.g. "Search" with an empty search field) must be visibly untappable.
            alpha = isEnabled ? 1 : 0.45
            title.textColor = appearance.text(on: role)
            subtitle.textColor = appearance.text(on: role, secondary: true)
            alternateHint.textColor = appearance.text(on: role, secondary: true)
            let base =
                titleSize
                ?? (isControl || phoneSideKey
                    ? appearance.controlTextSize
                    : phoneKey
                        ? min(appearance.isSystemDefault ? 17 : 20, appearance.skin.typography.keySize)
                        : appearance.keyTextSize)
            // Merged keys / letter clusters shrink to the actual available width (QQ scaling floor: see scaledFontSize),
            // while a single letter keeps the default key font size; the label's own adjustsFontSizeToFitWidth remains the fallback.
            // The font setter invalidates the label's layout even for an equal font.
            let titleFont = appearance.uiFont(
                appearance.scaledFontSize(
                    base, label: title.text ?? "", availableWidth: bounds.width - 10))
            if title.font != titleFont { title.font = titleFont }
            if letterGroup.count > 1 {
                let contentWidth = appearance.visualRect(in: bounds).insetBy(dx: 3, dy: 2).width
                let merged = mergedTitle(font: titleFont, role: role, contentWidth: contentWidth)
                if title.attributedText != merged { title.attributedText = merged }
            }
            // Resolve the hint policy here so any appearance refresh (including a
            // press) re-applies the right font size and line behaviour before the
            // frames are computed in `layoutSubviews`.
            let secondaryFont = appearance.uiFont(appearance.skin.typography.secondarySize)
            let contentWidth = appearance.visualRect(in: bounds).insetBy(dx: 3, dy: 2).width
            subtitleLines = applyHintLayout(
                to: subtitle, kind: subtitleHintKind,
                availableWidth: contentWidth, natural: secondaryFont)
            hintLines = applyHintLayout(
                to: alternateHint, kind: hintKind,
                availableWidth: contentWidth, natural: secondaryFont)
            columnHintLines = 1
            let columnWidth = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(contentWidth),
                    columns: columnHints.count))
            for (index, label) in columnHints.enumerated() {
                let hintColour = appearance.text(on: role, secondary: true)
                label.textColor =
                    swipeChoice.map { $0 == index ? hintColour : hintColour.withAlphaComponent(0.3) }
                    ?? hintColour
                label.textAlignment = .center
                columnHintLines = max(
                    columnHintLines,
                    applyHintLayout(
                        to: label, kind: .syllableHint, availableWidth: columnWidth, natural: secondaryFont))
            }
        }

        /// The letters of a merged cap: the picked (or first) letter in the primary tone.
        /// With per-letter hints the letters spread so each sits over its own hint column;
        /// otherwise a fixed gap reads as separate letters without splitting the cap in two.
        private func mergedTitle(font: UIFont, role: String, contentWidth: CGFloat) -> NSAttributedString {
            let primary = swipeChoice ?? 0
            let text = NSMutableAttributedString()
            for (index, letter) in letterGroup.enumerated() {
                // The pressed cap draws both tones alike, so a swipe fades the letters it leaves out.
                let colour =
                    swipeChoice == nil
                    ? appearance.text(on: role, secondary: index != primary)
                    : index == primary ? appearance.text(on: role) : appearance.text(on: role).withAlphaComponent(0.3)
                text.append(NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: colour]))
            }
            let widths = letterGroup.map { KeyboardTextMeasure.width(of: $0, font: font) }
            let columns = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(contentWidth),
                    columns: letterGroup.count))
            var offset = 0
            for index in letterGroup.indices.dropLast() {
                let length = (letterGroup[index] as NSString).length
                // Centre to centre: one column plus the gap between columns.
                let kern =
                    columnHints.isEmpty
                    ? font.pointSize * 0.4
                    : max(0, columns + CGFloat(KeyHintLayoutPolicy.columnGap) - (widths[index] + widths[index + 1]) / 2)
                text.addAttribute(.kern, value: kern, range: NSRange(location: offset + length - 1, length: 1))
                offset += length
            }
            return text
        }

        /// Creates one hint label per letter while any letter of a merged cap has a hint.
        private func configureColumnHints() {
            let wanted =
                letterGroup.count > 1 && groupHints.count == letterGroup.count
                && groupHints.contains { !($0 ?? "").isEmpty }
            if !wanted {
                columnHints.forEach { $0.removeFromSuperview() }
                columnHints = []
                return
            }
            while columnHints.count < letterGroup.count {
                let label = UILabel()
                label.isUserInteractionEnabled = false
                label.textAlignment = .center
                addSubview(label)
                columnHints.append(label)
            }
            while columnHints.count > letterGroup.count { columnHints.removeLast().removeFromSuperview() }
            // A zero-width break after each slash lets a two-line hint wrap between
            // finals ("ong/" + "iong") instead of mid-syllable.
            for (label, hint) in zip(columnHints, groupHints) {
                label.text = hint?.replacingOccurrences(of: "/", with: "/\u{200B}")
            }
            // The per-letter columns replace the single subtitle line.
            subtitle.text = nil
        }

        private func layoutColumnHints(in content: CGRect) {
            guard !columnHints.isEmpty else { return }
            let width = CGFloat(
                KeyHintLayoutPolicy.columnWidth(
                    total: Double(content.width),
                    columns: columnHints.count))
            let gap = CGFloat(KeyHintLayoutPolicy.columnGap)
            let lineHeight = Double(columnHints.first?.font.lineHeight ?? 12)
            let height = CGFloat(KeyHintLayoutPolicy.height(lines: columnHintLines, lineHeight: lineHeight))
            for (index, label) in columnHints.enumerated() {
                label.frame = CGRect(
                    x: content.minX + CGFloat(index) * (width + gap),
                    y: content.maxY - height, width: width, height: height)
            }
        }

        override var isHighlighted: Bool {
            didSet {
                // `cancelPress()` runs on every begin/configure change; only a real
                // press transition repaints the cap and replays the press physics.
                guard isHighlighted != oldValue else { return }
                updateAppearance(in: bounds)
                setNeedsLayout()
            }
        }
        override var isEnabled: Bool { didSet { if isEnabled != oldValue { updateAppearance(in: bounds) } } }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Feedback on touch-down (system keyboard behavior); the effect feedback of the same keypress is then coalesced, not repeated.
            if isEnabled {
                KeyboardFeedbackService.shared.keyTouchDown()
                KeyRollover.keyDown(self)
            }
            super.touchesBegan(touches, with: event)
        }

        /// A finger sliding slightly off the keycap still counts as pressing this key (ordinary finger jitter/offset); only a clear slide-away cancels.
        private var trackingBounds: CGRect {
            bounds.insetBy(dx: -min(10, bounds.width * 0.25), dy: -min(10, bounds.height * 0.2))
        }

        /// On this key: inside its slop, or still where it landed. A touch routed here
        /// from a gap or the keyboard edge (`FeedbackInputView.hitTest`) starts outside
        /// the slop and must not count as having slid off.
        private func isOnKey(_ touch: UITouch) -> Bool {
            if trackingBounds.contains(touch.location(in: self)) { return true }
            let point = touch.location(in: window)
            return hypot(point.x - touchOrigin.x, point.y - touchOrigin.y) < 10
        }

        private var typesCharacter: Bool {
            switch cap?.action {
            case .code?, .literal?, .letterVariant?: return !layoutPicker
            default: return false
            }
        }

        /// Return keeps press order like the character keys (a letter lifted before it would
        /// otherwise join the composition it was about to confirm), but a slide off it still cancels.
        private var joinsRollover: Bool { typesCharacter || (cap?.action == .enter && !layoutPicker) }

        func commitRolloverPress() {
            guard popup == nil, !didHold, !didSwipeUp, !didLetterSwipe, !slidOff,
                isHighlighted, joinsRollover, let cap
            else { return }
            cancelPress()
            consumed = true
            onSelect?(cap)
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            cancelPress()
            consumed = false
            isHighlighted = true
            lastLocation = touch.location(in: window)
            layoutHoldOrigin = lastLocation
            touchOrigin = lastLocation
            letterTracker = letterSwipe.isEmpty ? nil : LetterSwipeTracker(letterCount: letterSwipe.count)
            if joinsRollover { KeyRollover.hold(self) }
            showKeyPreviewIfNeeded()
            if layoutPicker || !alternates.isEmpty {
                // Main run loop timers fire on the main thread.
                let timer = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.holdDelayElapsed() }
                }
                holdTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            lastLocation = touch.location(in: window)
            if slidOff || consumed { return true }
            if popup == nil, trackLetterSwipe() { return true }
            if popup == nil, swipeUp != nil, !didSwipeUp,
                touchOrigin.y - lastLocation.y >= swipeUpThreshold,
                abs(lastLocation.x - touchOrigin.x) < touchOrigin.y - lastLocation.y
            {
                // A short upward flick: the hold popup no longer opens for this press.
                holdTimer?.invalidate()
                holdTimer = nil
                didSwipeUp = true
            }
            if didSwipeUp { return true }
            if popup != nil {
                updateSelection(at: lastLocation)
            } else if !isOnKey(touch) {
                // Leaving before a hold completes ends this key's press. A character key
                // keeps tracking so the key under the finger at lift can type (a fast
                // tap that rolls onto the neighbour is not silently eaten); any other
                // key cancels.
                guard typesCharacter else {
                    cancelPress()
                    return false
                }
                // Rising out of a flick key may still become its swipe-up, never the key above;
                // a rise that never qualifies (rolling up and sideways) types the key itself.
                if swipeUp != nil, lastLocation.y < touchOrigin.y {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    exitedUpward = true
                    return true
                }
                // Leaving a two-letter key sideways is the start of its swipe, not a roll onto the neighbour.
                if letterTracker != nil,
                    abs(lastLocation.x - touchOrigin.x) > abs(lastLocation.y - touchOrigin.y)
                {
                    holdTimer?.invalidate()
                    holdTimer = nil
                    exitedSideways = true
                    return true
                }
                holdTimer?.invalidate()
                holdTimer = nil
                keyPreview?.hide(for: self, immediately: true)
                keyPreview = nil
                KeyRollover.release(self)
                isHighlighted = false
                slidOff = true
            }
            return true
        }

        /// The enabled character key under a window point (gaps route through
        /// `FeedbackInputView.hitTest`); overlays and non-character keys yield nil.
        private func characterKey(at point: CGPoint) -> CharacterButton? {
            var view = window?.hitTest(point, with: nil)
            while let current = view, !(current is CharacterButton) { view = current.superview }
            guard let key = view as? CharacterButton, key.isEnabled, key.typesCharacter, key.cap != nil else {
                return nil
            }
            return key
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            let selected: KeyCap?
            if consumed {
                consumed = false
                cancelPress()
                return
            } else if let popup {
                let point = touch?.location(in: window) ?? lastLocation
                if touch != nil { updateSelection(at: point, emitHighlight: false) }
                selected = popupReleaseSelection(at: point, in: popup)
                if selected == nil, !layoutPicker,
                    AlternateDragPicker.dropProgress(dragDrop(at: point)) >= 1
                {
                    // A drop-cancel finishes the fade it showed instead of vanishing.
                    let cancelled = popup
                    self.popup = nil
                    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                        cancelled.alpha = 0
                        cancelled.transform = cancelled.transform.translatedBy(x: 0, y: 8)
                    } completion: { _ in
                        cancelled.removeFromSuperview()
                    }
                }
            } else if slidOff {
                let target = touch.flatMap { characterKey(at: $0.location(in: window)) }
                cancelPress()
                if let target, let cap = target.cap { target.onSelect?(cap) }
                return
            } else if didSwipeUp {
                let rise = touchOrigin.y - (touch?.location(in: window) ?? lastLocation).y
                selected = isHighlighted ? (rise < Self.swipeUpReturn ? cap : swipeUp) : nil
            } else if didLetterSwipe {
                selected = isHighlighted ? (swipeChoice.map { letterSwipe[$0] } ?? cap) : nil
            } else {
                selected =
                    !didHold && (exitedUpward || exitedSideways || touch.map(isOnKey) == true)
                        && isHighlighted ? cap : nil
            }
            cancelPress()
            if let selected { onSelect?(selected) }
        }

        override func cancelTracking(with event: UIEvent?) { cancelPress() }

        /// Feeds the sideways swipe of a two-letter key; true once the swipe owns the press.
        private func trackLetterSwipe() -> Bool {
            guard var tracker = letterTracker else { return false }
            let changed = tracker.update(
                dx: Double(lastLocation.x - touchOrigin.x),
                dy: Double(lastLocation.y - touchOrigin.y))
            letterTracker = tracker
            guard tracker.isLocked else { return false }
            if !didLetterSwipe {
                // The swipe replaces the hold menu and the slide-off typing for this press.
                didLetterSwipe = true
                holdTimer?.invalidate()
                holdTimer = nil
                KeyRollover.release(self)
            }
            if changed {
                swipeChoice = tracker.choice
                updateAppearance(in: bounds)
                if tracker.choice != nil { KeyboardFeedbackService.shared.alternateHighlightMoved() }
            }
            return true
        }

        /// Clears the sideways swipe state of the current press.
        func resetLetterSwipe() {
            letterTracker = nil
            didLetterSwipe = false
            exitedSideways = false
            if swipeChoice != nil {
                swipeChoice = nil
                updateAppearance(in: bounds)
            }
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            super.point(inside: point, with: event) || KeyboardRoutedTouch.accepts(self, point)
        }

        override func accessibilityActivate() -> Bool {
            guard isEnabled, let cap else { return false }
            onSelect?(cap)
            return true
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { cancelPress() }
        }

    }
}
