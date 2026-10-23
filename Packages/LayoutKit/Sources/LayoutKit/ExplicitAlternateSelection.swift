import Foundation

/// Destructive-to-preferences alternate pickers must not select an item merely
/// because the popup appears over the stationary finger. Ordinary character
/// alternates may keep their existing hold/release behavior.
public struct ExplicitAlternateSelection: Sendable {
    private var originX = 0.0
    private var originY = 0.0
    private var initialItem: Int?
    public private(set) var hasDepartedInitialRegion = false
    public init() {}
    public mutating func begin(x: Double, y: Double, overlappingItem: Int?) {
        originX = x
        originY = y
        initialItem = overlappingItem
        hasDepartedInitialRegion = false
    }
    public mutating func selection(x: Double, y: Double, hitItem: Int?) -> Int? {
        if !hasDepartedInitialRegion {
            let dx = x - originX, dy = y - originY
            guard dx * dx + dy * dy >= 100, hitItem != initialItem else { return nil }
            hasDepartedInitialRegion = true
        }
        return hitItem
    }
}
