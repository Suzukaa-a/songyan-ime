import AppearanceKit
import CandidateKit
import KeyboardCore
import SkinKit
import SwiftUI
import os

/// The extension reads this preference before freezing each presentation's geometry.
public enum KeyboardHeightPreferences {
    public static let presetKey = "keyboard.heightPreset.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var current: KeyboardHeightPreset {
        KeyboardHeightPreset.resolve(defaults.string(forKey: presetKey))
    }
}

/// One-handed mode, adopted at the next presentation like the height preset; the
/// in-keyboard restore control turns it off in place.
public enum KeyboardOneHandPreferences {
    public static let modeKey = "keyboard.oneHand.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var current: KeyboardOneHandMode {
        KeyboardOneHandMode.resolve(SharedPreferences.object(forKey: modeKey, in: defaults) as? String)
    }
    public static func set(_ mode: KeyboardOneHandMode) {
        SharedPreferences.set(mode.rawValue, forKey: modeKey, in: defaults)
    }
}

/// Which #+= page the 26/14/18-key layouts open. Off (the default) keeps the
/// system keyboards' row-shaped page; on opens the categorised grid. The 9-key
/// always uses the grid, since its 123 page is a digit pad with no rows to share.
/// The keyboard re-reads it on each presentation.
public enum KeyboardSymbolPagePreferences {
    public static let categoryPageKey = "keyboard.categorySymbolPage.v1"
    public static var defaults: UserDefaults { KeyboardRecipeStore.sharedDefaults() ?? .standard }
    public static var usesCategoryPage: Bool {
        (SharedPreferences.object(forKey: categoryPageKey, in: defaults) as? Bool) ?? false
    }
}

extension Notification.Name {
    /// The single appearance-change notification: skin, candidate-area layout and display mode share one
    /// appearance identity, so there is one change channel.
    static let keyboardAppearanceChanged = Notification.Name("keyboard.appearance.changed")

    /// The keyboard panel **lost its rendering host**: sent in-process by the extension host from the
    /// view controller's `viewWillDisappear`. Used to cancel one-shot gestures such as press-and-hold and
    /// to end the Taptic session; it replaces `UIApplication.willResignActiveNotification`, which is not
    /// available to scenes/extensions: a keyboard extension has no app lifecycle, so
    /// `UIApplication.*Notification` never fires there (`didMoveToWindow` remains the fallback).
    ///
    /// Delivered only **in this process**: it is a host lifecycle event, not a cross-process data change.
    /// The host typing area does not send it (its panel is destroyed with the view).
    static let keyboardPanelHostWillDisappear = Notification.Name("keyboard.panelHostWillDisappear")
}

/// The selected definition's facts one presentation's shell height is budgeted for.
/// Fixed for the presentation: a layout switch re-fits inside it, and the next
/// presentation starts at the newly selected definition's height.
public struct KeyboardPresentationShell: Equatable {
    public var readingRow: Bool
    public var candidateArea: Bool
    public init(readingRow: Bool, candidateArea: Bool) {
        self.readingRow = readingRow
        self.candidateArea = candidateArea
    }
}

/// The input view starts with an in-memory default appearance and a cached
/// geometry budget. The complete appearance is resolved by the Host off-main.
public struct KeyboardInitialPresentation {
    public var appearance = AppearanceSnapshot()
    public private(set) var heightPreset: KeyboardHeightPreset = .standard
    public private(set) var hasValidAppearance = false
    /// Whether the cold-start first frame reserves height for the standalone reading row: only reuses the
    /// eligibility hint (`CandidateReadingRowHint`) the host last **adopted** that matches the current layout selection; no hint or mismatch -> false.
    public private(set) var readingRowReserved = false
    public private(set) var candidateAreaReserved = true
    /// Only geometry is cached; a palette or candidate layout must never be
    /// reconstructed from UserDefaults instead of the validated store snapshot.
    public private(set) var candidateHeight = CandidateBarDefinition.systemDefault.collapsed.height
    public private(set) var candidateSize = SkinDefinition.systemDefault.typography.candidateSize
    private static let geometryBudgetKey = "keyboard.appearance.geometryBudget.v1"

    /// Called only after a completed, accepted read on KeyboardResourceReadQueue.
    public static func recordGeometry(from snapshot: AppearanceSnapshot) {
        let height = snapshot.document.candidateBar.collapsed.height
        let size = snapshot.document.skin.typography.candidateSize
        guard (36...56).contains(height), (16...30).contains(size) else { return }
        let budget = ["candidateHeight": height, "candidateSize": size]
        let defaults = UserDefaults.standard
        guard defaults.dictionary(forKey: geometryBudgetKey) as? [String: Double] != budget else { return }
        defaults.set(budget, forKey: geometryBudgetKey)
    }

    /// Selection context shared by cold start and host recording (same defaults source, no duplicated key-name logic).
    private static var readingRowSelection: String {
        let defaults = UserDefaults.standard
        return CandidateReadingRowHint.selectionKey(
            layoutKind: defaults.string(forKey: AppSettings.selectedLayoutKey),
            definitionID: defaults.string(forKey: "keyboard.selectedLayoutDefinitionID"))
    }

    /// Called after the host adopts eligibility: records it as the next cold-start first-frame hint (not rewritten if unchanged).
    public static func recordReadingRow(eligible: Bool, candidateAreaRequired: Bool = true) {
        let hint = CandidateReadingRowHint(
            selection: readingRowSelection, eligible: eligible,
            candidateAreaRequired: candidateAreaRequired)
        let defaults = UserDefaults.standard
        guard CandidateReadingRowHint(storedValue: defaults.object(forKey: CandidateReadingRowHint.defaultsKey)) != hint
        else { return }
        defaults.set(hint.storedValue, forKey: CandidateReadingRowHint.defaultsKey)
    }

    public static func load() -> Self {
        var result = Self()
        result.heightPreset = KeyboardHeightPreferences.current
        let defaults = UserDefaults.standard
        let storedHint = defaults.object(forKey: CandidateReadingRowHint.defaultsKey)
        result.readingRowReserved = CandidateReadingRowHint.resolve(
            storedValue: storedHint, currentSelection: readingRowSelection)
        result.candidateAreaReserved = CandidateReadingRowHint.resolveCandidateArea(
            storedValue: storedHint, currentSelection: readingRowSelection)
        if let budget = defaults.dictionary(forKey: geometryBudgetKey) as? [String: Double],
            let height = budget["candidateHeight"], (36...56).contains(height),
            let size = budget["candidateSize"], (16...30).contains(size)
        {
            result.candidateHeight = height
            result.candidateSize = size
        }
        return result
    }

    public var skin: SkinDefinition { appearance.document.skin }
    public var candidateBar: CandidateBarDefinition { appearance.document.candidateBar }

    /// Cached inputs are adopted before presentation; an accepted async read seeds the next one.
    public func shellHeight(compact: Bool) -> CGFloat {
        CGFloat(presentationBudget(compact: compact).shellHeight)
    }

    public func presentationBudget(compact: Bool) -> KeyboardPanelPresentationBudget {
        KeyboardPanelPresentationBudget(
            candidateHeight: candidateHeight,
            candidateSize: candidateSize,
            readingRow: readingRowReserved,
            candidateArea: candidateAreaReserved,
            compact: compact, heightPreset: heightPreset)
    }

    public var presentationShell: KeyboardPresentationShell {
        KeyboardPresentationShell(readingRow: readingRowReserved, candidateArea: candidateAreaReserved)
    }

    public func appearance(systemDark: Bool) -> KeyboardAppearance {
        KeyboardAppearance(
            skin: skin,
            dark: appearance.document.appearance == .dark
                || (appearance.document.appearance == .system && systemDark))
    }
}

/// One resolved palette and font model for UIKit controls and engine-free SwiftUI previews.
///
/// Every keycap asks for several colours and fonts on each configure/layout pass.
/// Resolving them from the skin (hex parsing, WCAG contrast with `pow`, font
/// descriptors) on every call made a single keystroke cost hundreds of palette
/// resolutions on the main thread, so the resolved palette is shared per
/// `(skin, dark)` and fonts/measurements are cached process-wide.
public struct KeyboardAppearance: Equatable, Sendable {
    public var skin: SkinDefinition {
        didSet { palette = KeyboardPalette.resolve(skin: skin, dark: dark) }
    }
    public var dark: Bool {
        didSet { palette = KeyboardPalette.resolve(skin: skin, dark: dark) }
    }
    private var palette: KeyboardPalette
    public init(skin: SkinDefinition = .systemDefault, dark: Bool = false) {
        // Stored/fallback/default appearances share one source; custom skins stay exact.
        let skin = skin.id == SkinDefinition.systemDefault.id ? .systemDefault : skin
        self.skin = skin
        self.dark = dark
        self.palette = KeyboardPalette.resolve(skin: skin, dark: dark)
    }

    /// The palette is derived from `(skin, dark)`, so those two decide equality.
    /// SwiftUI uses this to skip environment-driven updates when a parent rebuilds
    /// an identical appearance.
    public static func == (lhs: KeyboardAppearance, rhs: KeyboardAppearance) -> Bool {
        lhs.dark == rhs.dark && lhs.skin == rhs.skin
    }

    public var isSystemDefault: Bool { skin.id == SkinDefinition.systemDefault.id }

    /// Whether this appearance paints its own keyboard surface.
    ///
    /// The **system default** appearance owns no background: iOS (`UIInputView` /
    /// the keyboard host) supplies the keyboard surface, its rounded corners and
    /// the bottom input-mode bar. Painting an approximate opaque panel there is
    /// exactly the second, mismatched background the Apple contract forbids. Only a
    /// user-authored skin overrides a surface the product actually owns.
    public var drawsOwnSurface: Bool { !isSystemDefault }

    /// The panel's full-field backing. System default = transparent so the iOS
    /// keyboard surface shows through; a custom skin = its authored background.
    @ViewBuilder public var panelBackground: some View {
        if drawsOwnSurface { background } else { Color.clear }
    }

    /// Backing for the candidate/status header. System default = transparent
    /// (candidates sit on the iOS keyboard surface); a custom skin paints its
    /// own panel colour.
    public var headerBacking: Color { drawsOwnSurface ? color("panel") : .clear }

    /// Accent for glyphs drawn directly on the panel (status icons, the chosen
    /// reading, tool links, checkmarks). The system palette's `accent` is a pale
    /// return-key *fill*; as a glyph on the panel it nearly vanished, so a fill
    /// without contrast is deepened (or lightened in dark mode) until legible.
    public var accentForeground: Color { Color(uiColor: palette.accentForeground) }
    public var uiAccentForeground: UIColor { palette.accentForeground }

    public var controlTextSize: Double { min(isSystemDefault ? 14 : 20, skin.typography.keySize) }
    public var keyTextSize: Double { isSystemDefault ? 18 : skin.typography.keySize }
    public var controlIconSize: Double { min(20, skin.typography.keySize) }
    /// Scales font size to the available key width: long labels (merged keys, nine-key letter clusters,
    /// function words) shrink to the measured width, single letters keep the familiar system key size; the
    /// lower bound is 55% so narrow keys do not turn into tiny text.
    public func scaledFontSize(_ base: Double, label: String, availableWidth: CGFloat) -> Double {
        let base = isSystemDefault && label.count > 1 ? min(base, 18) : base
        guard availableWidth > 0, !label.isEmpty else { return base }
        let width = KeyboardTextMeasure.width(of: label, font: uiFont(base))
        guard width > availableWidth else { return base }
        return max(base * 0.55, base * availableWidth / width)
    }
    public func visualRect(in bounds: CGRect) -> CGRect {
        bounds.insetBy(dx: skin.spacing.visualInsetX, dy: skin.spacing.visualInsetY)
    }
    public func color(_ name: String) -> Color { Color(uiColor: uiColor(name)) }
    public func uiColor(_ name: String) -> UIColor { palette.fill(name) }
    public func text(on role: String, secondary: Bool = false) -> UIColor {
        palette.text(on: role, secondary: secondary)
    }
    public func uiFont(_ size: Double) -> UIFont {
        KeyboardFontCache.font(size: size, weight: skin.typography.weight, family: skin.typography.family)
    }
    public func font(_ size: Double) -> Font { Font(uiFont(size)) }
    public var backgroundColors: [UIColor] {
        let b = (dark ? skin.variants.dark : skin.variants.light)?.background
        func color(_ hex: String?) -> UIColor {
            hex.flatMap(SkinColor.init(hex:)).map {
                UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
            } ?? uiColor("panel")
        }
        return b?.type == "linearGradient" ? [color(b?.from), color(b?.to)] : [color(b?.color), color(b?.color)]
    }
    public var background: LinearGradient {
        LinearGradient(colors: backgroundColors.map { Color(uiColor: $0) }, startPoint: .top, endPoint: .bottom)
    }
}
/// The colours of one `(skin, dark)` pair, resolved once. Instances are immutable
/// and shared through a small most-recently-used cache: a keyboard only ever
/// shows a handful of `(skin, dark)` pairs (light/dark of the applied skin plus
/// previews), and `SkinDefinition ==` short-circuits on shared storage.
private final class KeyboardPalette: Sendable {
    private let resolved: [String: SkinColor]
    private let fills: [String: UIColor]
    private let texts: [String: UIColor]
    private let secondaryTexts: [String: UIColor]
    let accentForeground: UIColor

    private init(skin: SkinDefinition, dark: Bool) {
        let colors = skin.resolvedColors(dark: dark)
        resolved = colors
        func ui(_ c: SkinColor) -> UIColor { UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1) }
        fills = colors.mapValues(ui)
        var texts: [String: UIColor] = [:]
        var secondary: [String: UIColor] = [:]
        for role in colors.keys {
            texts[role] = ui(Self.textColor(colors, role: role, secondary: false))
            secondary[role] = ui(Self.textColor(colors, role: role, secondary: true))
        }
        self.texts = texts
        secondaryTexts = secondary
        let panel = colors["panel"] ?? colors["key"]!
        let accent = colors["accent"] ?? panel
        accentForeground = ui(Self.legibleAccent(accent, text: colors["accentText"], on: panel))
    }

    /// An authored accent that already reads as a glyph on the panel (3:1) is
    /// kept exactly. A fill that does not (the system palette's pale return-key
    /// blue, or its dark counterpart) is moved towards the palette's own accent
    /// text colour, or black/white when that is not legible either, until it
    /// reads as text (4.5:1): the hue survives instead of turning grey or white.
    private static func legibleAccent(_ accent: SkinColor, text: SkinColor?, on panel: SkinColor) -> SkinColor {
        if accent.contrast(on: panel) >= 3 { return accent }
        let black = SkinColor(hex: "#000000")!, white = SkinColor(hex: "#FFFFFF")!
        let extreme = black.contrast(on: panel) >= white.contrast(on: panel) ? black : white
        let target = text.map { $0.contrast(on: panel) >= 4.5 ? $0 : extreme } ?? extreme
        for step in 1...10 {
            let t = Double(step) / 10
            func mix(_ a: Double, _ b: Double) -> Int { Int(((a + (b - a) * t) * 255).rounded()) }
            let hex = String(
                format: "#%02X%02X%02X", mix(accent.red, target.red),
                mix(accent.green, target.green), mix(accent.blue, target.blue))
            if let candidate = SkinColor(hex: hex), candidate.contrast(on: panel) >= 4.5 { return candidate }
        }
        return target
    }

    private static func textColor(_ colors: [String: SkinColor], role: String, secondary: Bool) -> SkinColor {
        colors[secondary ? "secondaryText" : (role == "accent" ? "accentText" : "text")]!
            .contrasting(on: colors[role] ?? colors["key"]!)
    }

    func fill(_ name: String) -> UIColor { fills[name] ?? .black }

    func text(on role: String, secondary: Bool) -> UIColor {
        if let cached = (secondary ? secondaryTexts : texts)[role] { return cached }
        // Unknown role: contrast against the key surface, exactly as before.
        let c = Self.textColor(resolved, role: role, secondary: secondary)
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
    }

    private static let recent = OSAllocatedUnfairLock<[(skin: SkinDefinition, dark: Bool, palette: KeyboardPalette)]>(
        initialState: [])

    static func resolve(skin: SkinDefinition, dark: Bool) -> KeyboardPalette {
        recent.withLock { recent in
            if let index = recent.firstIndex(where: { $0.dark == dark && $0.skin == skin }) {
                let hit = recent.remove(at: index)
                recent.append(hit)
                return hit.palette
            }
            let palette = KeyboardPalette(skin: skin, dark: dark)
            recent.append((skin, dark, palette))
            if recent.count > 6 { recent.removeFirst(recent.count - 6) }
            return palette
        }
    }
}

/// Process-wide font cache: building a designed system font goes through a
/// descriptor lookup that is far more expensive than the dictionary hit.
enum KeyboardFontCache {
    // NSCache is internally synchronized; it just is not annotated Sendable.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIFont>()

    static func font(size: Double, weight: String, family: String) -> UIFont {
        let key = "\(family)|\(weight)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let uiWeight: UIFont.Weight = weight == "semibold" ? .semibold : weight == "regular" ? .regular : .medium
        let base = UIFont.systemFont(ofSize: size, weight: uiWeight)
        let design: UIFontDescriptor.SystemDesign =
            family == "rounded"
            ? .rounded
            : family == "serif"
                ? .serif
                : family == "monospaced" ? .monospaced : .default
        let font = UIFont(descriptor: base.fontDescriptor.withDesign(design) ?? base.fontDescriptor, size: size)
        cache.setObject(font, forKey: key)
        return font
    }
}

/// Cached single-line text widths for keycap fitting (labels repeat on every pass).
enum KeyboardTextMeasure {
    // NSCache is internally synchronized; it just is not annotated Sendable.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSNumber>()

    static func width(of text: String, font: UIFont) -> CGFloat {
        let key = "\(font.fontName)|\(font.pointSize)|\(text)" as NSString
        if let cached = cache.object(forKey: key) { return CGFloat(cached.doubleValue) }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        cache.setObject(NSNumber(value: Double(width)), forKey: key)
        return width
    }
}

private struct KeyboardAppearanceKey: EnvironmentKey { static let defaultValue = KeyboardAppearance() }

/// UIKit → UIKit-free policy mapping (`KeyboardAppearancePolicy` lives in SkinKit so it
/// is testable off-device). `.default` maps to `.unspecified`.
extension HostKeyboardAppearance {
    init(_ appearance: UIKeyboardAppearance) {
        switch appearance {
        case .light: self = .light
        case .dark: self = .dark
        default: self = .unspecified
        }
    }
}

extension EnvironmentValues {
    public var keyboardAppearance: KeyboardAppearance {
        get { self[KeyboardAppearanceKey.self] }
        set { self[KeyboardAppearanceKey.self] = newValue }
    }
}

struct SkinKeyBackground: View {
    @Environment(\.keyboardAppearance) private var appearance
    /// Set by the press modifier so the SwiftUI keycap tightens its shadow with
    /// the same constants as the UIKit keycaps (`KeyboardPressPhysics`).
    @Environment(\.keyboardKeyPressed) private var pressed
    var role = "key"
    var body: some View {
        RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius)
            .fill(appearance.color(role))
            .overlay(
                RoundedRectangle(cornerRadius: appearance.skin.keycap.cornerRadius).stroke(
                    appearance.color("border"), lineWidth: appearance.skin.keycap.borderWidth)
            )
            .shadow(
                color: .black.opacity(restShadowOpacity),
                radius: 0,
                y: pressed ? KeyboardPressPhysics.shadowOffsetY(from: 1) : 1
            )
            .padding(.horizontal, appearance.skin.spacing.visualInsetX)
            .padding(.vertical, appearance.skin.spacing.visualInsetY)
            .allowsHitTesting(false)
    }

    private var restShadowOpacity: Double {
        let rest = appearance.skin.keycap.shadow == "subtle" ? 0.18 : 0
        return pressed ? Double(KeyboardPressPhysics.shadowOpacity(from: Float(rest))) : rest
    }
}

/// Render-only: a pressed keycap's shadow tightens. Never touches layout.
private struct KeyboardKeyPressedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var keyboardKeyPressed: Bool {
        get { self[KeyboardKeyPressedKey.self] }
        set { self[KeyboardKeyPressedKey.self] = newValue }
    }
}

/// Visual layer is inset; the UIControl bounds and tracking remain full-sized.
final class SkinCapLayer: CALayer {
    @MainActor func update(in view: UIView, appearance: KeyboardAppearance, role: String, pressed: Bool = false) {
        if superlayer == nil { view.layer.insertSublayer(self, at: 0) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = appearance.visualRect(in: view.bounds)
        cornerRadius = appearance.skin.keycap.cornerRadius
        backgroundColor = appearance.uiColor(role).cgColor
        borderWidth = appearance.skin.keycap.borderWidth
        borderColor = appearance.uiColor("border").cgColor
        let restOpacity: Float = appearance.skin.keycap.shadow == "subtle" ? 0.18 : 0
        shadowColor = UIColor.black.cgColor
        shadowOpacity = pressed ? KeyboardPressPhysics.shadowOpacity(from: restOpacity) : restOpacity
        shadowOffset = CGSize(
            width: 0,
            height: pressed ? KeyboardPressPhysics.shadowOffsetY(from: 1) : 1)
        shadowRadius = 0
        view.backgroundColor = .clear
        view.layer.borderWidth = 0
        CATransaction.commit()
    }
}

/// Key hit target: the root input view hands touches that land in the gap between two adjacent keys to the nearer key.
protocol KeyboardKeyHitTarget: UIView {}

/// The gap/edge point `FeedbackInputView.hitTest` last routed to a key. After hit
/// testing, UIKit asks the chosen view `point(inside:)` again at the real touch
/// point and drops the touch when it is outside, so a routed key accepts exactly
/// that one point (window space) in addition to its own bounds.
@MainActor
enum KeyboardRoutedTouch {
    private static weak var key: UIView?
    private static var windowPoint = CGPoint.zero

    static func route(_ key: UIView, at windowPoint: CGPoint) {
        self.key = key
        self.windowPoint = windowPoint
    }

    /// Drops a recorded route so a stale entry cannot outlive the layout that produced it
    /// (one-handed restore moves keys under a recorded window point).
    static func clear() {
        key = nil
        windowPoint = .zero
    }

    // MARK: One-handed gutter exclusion

    /// True while a restore control covers the gutter; `FeedbackInputView` then
    /// declines nearest-key routing for gutter touches.
    private static var oneHandGutterExposed = false
    /// The control's frame in window coordinates; nil when unknown.
    private static var oneHandGutterWindowFrame: CGRect?
    private static weak var oneHandGutterControl: UIControl?

    static func setOneHandGutter(exposed: Bool) {
        oneHandGutterExposed = exposed
        if !exposed {
            oneHandGutterWindowFrame = nil
            oneHandGutterControl = nil
            // A route recorded against the narrowed layout must not survive it.
            clear()
        }
    }

    static func setOneHandGutterFrame(_ frame: CGRect?, control: UIControl? = nil) {
        oneHandGutterWindowFrame = frame
        oneHandGutterControl = frame == nil ? nil : control
    }

    /// Only the owner may retire its region; an old view must not clear a replacement.
    static func registerOneHandGutter(_ control: UIControl, frame: CGRect?) {
        guard let frame else {
            if oneHandGutterControl === control { setOneHandGutter(exposed: false) }
            return
        }
        oneHandGutterControl = control
        oneHandGutterWindowFrame = frame
        oneHandGutterExposed = true
    }

    /// SwiftUI can return its transparent container instead of this visible native descendant.
    static func oneHandRestoreTarget(at point: CGPoint, in window: UIWindow) -> UIControl? {
        guard pointIsInOneHandGutter(point), let control = oneHandGutterControl,
            control.window === window, control.isEnabled,
            control.bounds.contains(control.convert(point, from: window))
        else { return nil }
        var ancestor: UIView? = control
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
            ancestor = view.superview
        }
        return control
    }

    /// Whether a window-coordinate point falls into the live restore gutter.
    static func pointIsInOneHandGutter(_ windowPoint: CGPoint) -> Bool {
        oneHandGutterExposed && oneHandGutterWindowFrame?.contains(windowPoint) == true
    }

    static func accepts(_ view: UIView, _ point: CGPoint) -> Bool {
        guard view === key, let window = view.window else { return false }
        let p = view.convert(point, to: window)
        return abs(p.x - windowPoint.x) < 0.5 && abs(p.y - windowPoint.y) < 0.5
    }
}

class SkinnedButton: UIButton, KeyboardKeyHitTarget {
    /// Feedback on touch down (system keyboard behavior); the globe key leaves switch feedback to the system, so subclasses can turn this off.
    var emitsTouchDownFeedback: Bool { true }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || KeyboardRoutedTouch.accepts(self, point)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if emitsTouchDownFeedback, isEnabled { KeyboardFeedbackService.shared.keyTouchDown() }
        super.touchesBegan(touches, with: event)
    }
    // Representables reassign these on every SwiftUI update; only a real change
    // needs another layout pass (and another cap-layer repaint).
    var appearance = KeyboardAppearance() { didSet { if appearance != oldValue { setNeedsLayout() } } }
    var skinRole = "control" { didSet { if skinRole != oldValue { setNeedsLayout() } } }
    private let capLayer = SkinCapLayer()
    private let releaseAnimator = KeyboardKeyReleaseAnimator()
    override var isHighlighted: Bool { didSet { setNeedsLayout() } }
    override func layoutSubviews() {
        // A frame write on a transformed layer is undefined: start every pass
        // from identity and re-apply the press physics at the end.
        releaseAnimator.resetPressVisual(layers: pressVisualLayers)
        super.layoutSubviews()
        let role = isHighlighted ? "pressed" : skinRole
        capLayer.update(in: self, appearance: appearance, role: role, pressed: isHighlighted)
        releaseAnimator.update(layer: capLayer, isPressed: isHighlighted)
        releaseAnimator.updatePressVisual(container: layer, layers: pressVisualLayers, isPressed: isHighlighted)
        tintColor = appearance.text(on: role)
        setTitleColor(appearance.text(on: role), for: .normal)
        titleLabel?.font = appearance.uiFont(appearance.controlTextSize)
        setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: appearance.controlIconSize, weight: .regular), forImageIn: .normal)
    }
    /// The keycap surface plus its glyphs move together; the button's own layer
    /// (hit testing / tracking geometry) is deliberately not transformed.
    private var pressVisualLayers: [CALayer?] { [capLayer, titleLabel?.layer, imageView?.layer] }
    override func contentRect(forBounds bounds: CGRect) -> CGRect { appearance.visualRect(in: bounds) }
}
