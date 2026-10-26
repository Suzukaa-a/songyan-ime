import Foundation

/// The authored function area of a page: the footer row and the two side rails.
///
/// `KeyboardPageDefinition.chrome == nil` draws the native controls (built-in pages). A non-nil
/// chrome is fully authored: the host draws only these keys and never invents a Shift, Delete,
/// footer or rail a user deleted or never added.
public struct KeyboardPageChrome: Codable, Equatable, Sendable {
    public enum Region: String, Codable, CaseIterable, Hashable, Sendable {
        /// Footer row under the key area. Key `width` is a relative width.
        case bottom
        /// Left rail. Key `width` is a relative vertical span.
        case leading
        /// Right rail. Key `width` is a relative vertical span.
        case trailing
    }

    public var bottom: [LayoutKey]
    public var leading: [LayoutKey]
    public var trailing: [LayoutKey]
    /// The trailing rail also covers the footer row (the phone shell's full-height editing
    /// column ends in the bottom corner).
    public var trailingSpansBottom: Bool
    /// Rail width in points. Nil keeps the host's existing default for the surface.
    public var leadingWidth: Double?
    public var trailingWidth: Double?

    public init(
        bottom: [LayoutKey] = [], leading: [LayoutKey] = [], trailing: [LayoutKey] = [],
        trailingSpansBottom: Bool = false, leadingWidth: Double? = nil, trailingWidth: Double? = nil
    ) {
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
        self.trailingSpansBottom = trailingSpansBottom
        self.leadingWidth = leadingWidth
        self.trailingWidth = trailingWidth
    }

    public func keys(in region: Region) -> [LayoutKey] {
        switch region {
        case .bottom: return bottom
        case .leading: return leading
        case .trailing: return trailing
        }
    }

    /// Replaces one key; an out-of-range region index returns nil instead of silently doing
    /// nothing, so an editor can reject the move.
    public func replacingKey(in region: Region, at index: Int, with key: LayoutKey)
        -> KeyboardPageChrome?
    {
        let current = keys(in: region)
        guard current.indices.contains(index) else { return nil }
        var updated = current
        updated[index] = key
        var chrome = self
        switch region {
        case .bottom: chrome.bottom = updated
        case .leading: chrome.leading = updated
        case .trailing: chrome.trailing = updated
        }
        return chrome
    }

    public var allKeys: [LayoutKey] { bottom + leading + trailing }

    /// Rail span weights, or nil when the rail is empty.
    public func railWeights(in region: Region) -> [Double]? {
        let keys = keys(in: region)
        guard !keys.isEmpty, region != .bottom else { return nil }
        return keys.map(\.widthWeight)
    }

    /// Key counts are part of the page budget (`LayoutResourceBudget.usage(_:)`).
    func validate() throws {
        for key in allKeys { try KeyboardPageDefinition.validateKey(key) }
        for (width, detail) in [
            (leadingWidth, "请把左侧栏宽度设为大于 0 的数字。"),
            (trailingWidth, "请把右侧栏宽度设为大于 0 的数字。"),
        ] {
            guard let width else { continue }
            guard width.isFinite, width > 0 else { throw LayoutError.invalid(detail) }
        }
    }
}
