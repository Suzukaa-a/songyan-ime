import Foundation

/// Footer widths for an authored page, shared by the runtime and the preview.
///
/// A materialized default footer is the same key set the built-in control row draws. Recognizing
/// that structure (actions/targets and the frozen default widths — never an ID or label) keeps the
/// built-in control-row budget, so copying a page does not immediately squeeze the bottom row that
/// was tuned for it. Any changed width or structure falls back to the real authored relative
/// weights; a custom title, secondary label or long-press list does not change the geometry.
///
/// Pass only the visible keys: the host removes globe keys when the system has no keyboard switch
/// and passes a policy with `hasGlobe == false`, so the filtered default still matches the same
/// budget. The helper never adds, removes or repairs a key.
public struct KeyboardPageFooterGeometry: Equatable, Sendable {
    /// One width per `keys` element.
    public let keyWidths: [Double]
    public let spacing: Double
    /// True when the keys are exactly the live default footer and the shared control-row budget
    /// applies. False means `keyWidths` came from the authored relative weights.
    public let usesControlRowBudget: Bool

    public init(width: Double, keys: [LayoutKey], policy: KeyboardControlPolicy) {
        let metrics = policy.metrics(width: width)
        spacing = metrics.spacing
        let resolvedWidth = width.isFinite ? max(0, width) : 0
        guard !keys.isEmpty else {
            keyWidths = []
            usesControlRowBudget = false
            return
        }
        let slots = policy.slots
        if keys.count == slots.count, Self.isDefaultFooter(keys: keys, policy: policy) {
            keyWidths = slots.map { metrics[$0] }
            usesControlRowBudget = true
            return
        }
        let available = max(0, resolvedWidth - spacing * Double(keys.count - 1))
        // Normalize through the shared projection: legal but huge finite weights must not overflow
        // the sum or the per-key multiplication into NaN frames.
        let projection = LayoutRowWidthProjection(weights: keys.map(\.widthWeight))
        if projection.keyFractions.contains(where: { $0 > 0 }) {
            keyWidths = projection.keyFractions.map { available * $0 }
        } else {
            keyWidths = Array(repeating: available / Double(keys.count), count: keys.count)
        }
        usesControlRowBudget = false
    }

    /// The frozen default footer shape: globe first, then the control row's slots in order, with
    /// the default space weight and every other default key at nil (= native budget width).
    private static func isDefaultFooter(keys: [LayoutKey], policy: KeyboardControlPolicy) -> Bool {
        let slots = policy.slots
        guard keys.count == slots.count else { return false }
        for (key, slot) in zip(keys, slots) {
            guard key.width == (slot == .space ? KeyboardPageDefaultShape.footerSpaceWidth : nil) else { return false }
            guard matches(key.action, expected: policy.key(at: slot), policy: policy) else { return false }
        }
        return true
    }

    private static func matches(
        _ action: LayoutAction, expected: KeyboardControlPolicy.Slot, policy: KeyboardControlPolicy
    ) -> Bool {
        switch expected {
        case .page:
            return action.pageSwitchTarget == policy.pageTarget
        case .returnToLetters:
            // The row pages' left switch is a return, not a language toggle.
            return action.pageSwitchTarget == .letters
        case .language:
            // The categorized default return keeps the native language/tools menu, so it may be an
            // explicit `.letters` language key as well as the page-following nil form.
            guard action.type == .languageSwitch else { return false }
            if policy.page == .symbols && policy.usesCategorySymbolPage {
                return action.languageSwitchBehavior == nil || action.languageSwitchBehavior == .letters
            }
            return action.languageSwitchBehavior == nil
        case .globe:
            return action.type == .globe
        case .space:
            return action.type == .space
        case .enter:
            return action.type == .enter
        case .symbolPage:
            return action.pageSwitchTarget == .symbols
        case .symbolLock:
            return action.type == .symbolLock
        case .utility:
            // Only the digit pad's utility position resolves here: the fixed 0 key.
            return action.type == .literal && action.value == KeyboardPageDefaultShape.keypadZero
        }
    }
}
