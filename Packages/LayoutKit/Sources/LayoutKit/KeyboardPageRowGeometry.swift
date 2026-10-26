import Foundation

/// The page editor, extension and preview resolve the same character and control widths.
public struct KeyboardPageRowGeometry: Equatable, Sendable {
    public let keyIndices: [Int]
    public let keyWidths: [Double]
    /// Legacy (`chrome == nil`) pages only: the geometry still synthesizes Shift/Delete around
    /// the last row. Authored pages carry those keys as data, so both stay false and
    /// `keyWidths` has one entry per `keyIndices` element.
    public let showsShift: Bool
    public let showsDelete: Bool
    public let sideWidth: Double
    public let rowWidth: Double
    public let inset: Double
    public let gap: Double
    /// Full-row index of the split cut, or the row's key count when it is not split.
    public let splitIndex: Int
    /// The authored row is the standard 10 / 9 / (Shift+7 letters+Delete) alphabet, so it keeps
    /// equal letter columns instead of relative weights.
    public let usesStandardAlphabet: Bool

    public init(
        width: Double, page: KeyboardPageDefinition, row: Int, split: LayoutSplitConfiguration?,
        showsGlobe: Bool = true
    ) {
        guard page.rows.indices.contains(row) else {
            keyIndices = []
            keyWidths = []
            showsShift = false
            showsDelete = false
            sideWidth = 0
            rowWidth = 0
            inset = 0
            gap = 0
            splitIndex = 0
            usesStandardAlphabet = false
            return
        }
        let keys = page.rows[row].keys
        if page.chrome != nil {
            keyIndices = Array(keys.indices)
            showsShift = false
            showsDelete = false
            let last = row == page.rows.count - 1
            let standard = Self.standardAlphabetStructure(page)
            usesStandardAlphabet = standard
            if standard {
                let metrics = StandardKeyRowGeometry(width: width, split: split)
                gap = metrics.gap
                sideWidth = metrics.thirdRowSideWidth
                splitIndex = split?.breakIndex(row: row, keyCount: keys.count, width: width) ?? keys.count
                if last {
                    // Shift/Delete take StandardKeyRowGeometry's real side width, not a literal
                    // 1.5 * keyWidth: the two differ by spacing / 2, and the row must still end
                    // exactly on the keyboard edge.
                    let middle = Array(keys.dropFirst().dropLast())
                    rowWidth = max(0, width - sideWidth * 2 - 8)
                    keyWidths = [sideWidth] + middle.map { _ in metrics.keyWidth } + [sideWidth]
                    let available = max(0, rowWidth - Double(max(0, middle.count - 1)) * 4 - gap)
                    inset = max(0, (available - Double(middle.count) * metrics.keyWidth) / 2)
                } else {
                    rowWidth = max(0, width)
                    keyWidths = keys.map { _ in metrics.keyWidth }
                    let available = max(0, width - Double(max(0, keys.count - 1)) * 4 - gap)
                    inset = max(0, (available - Double(keys.count) * metrics.keyWidth) / 2)
                }
            } else {
                sideWidth = 0
                gap = keys.count > 1 ? (split?.gap(width: width, keyCount: keys.count) ?? 0) : 0
                splitIndex = split?.breakIndex(row: row, keyCount: keys.count, width: width) ?? keys.count
                rowWidth = max(0, width)
                let available = max(0, width - Double(max(0, keys.count - 1)) * 4 - gap)
                if keys.isEmpty {
                    keyWidths = []
                    inset = 0
                } else {
                    let projection = LayoutRowWidthProjection(weights: keys.map(\.widthWeight))
                    keyWidths = projection.keyFractions.map { available * $0 }
                    inset = available * projection.insetFraction
                }
            }
            return
        }

        // Legacy page: exactly the old synthesis, so old catalogs render unchanged.
        keyIndices = keys.indices.filter { showsGlobe || keys[$0].action.type != .globe }
        let visible = keyIndices.map { keys[$0] }
        let alphabet =
            page.kind == .english && page.rows.map { $0.keys.count } == [10, 9, 7]
            && page.rows.flatMap(\.keys).allSatisfy {
                $0.widthWeight == 1 && $0.action.type == .literal && $0.action.value?.utf8.count == 1
                    && $0.action.value?.first?.isLetter == true
            }
        let tenColumns =
            page.kind != .english && page.rows.map { $0.keys.count } == [10, 10, 9]
            && page.rows.flatMap(\.keys).allSatisfy { $0.widthWeight == 1 && $0.action.type == .literal }
        let last = row == page.rows.count - 1
        showsShift = last && page.kind == .english
        showsDelete = last && !page.rows.flatMap(\.keys).contains { $0.action.type == .backspace }
        usesStandardAlphabet = alphabet
        let standard = StandardKeyRowGeometry(width: width, split: split)
        sideWidth =
            alphabet
            ? standard.thirdRowSideWidth : (tenColumns ? standard.keyWidth : max(44, standard.thirdRowSideWidth))
        rowWidth = max(0, width - (showsShift ? sideWidth + 4 : 0) - (showsDelete ? sideWidth + 4 : 0))
        gap = alphabet || tenColumns ? standard.gap : (split?.gap(width: rowWidth, keyCount: visible.count) ?? 0)
        splitIndex = split?.breakIndex(row: row, keyCount: visible.count, width: width) ?? visible.count
        let available = max(0, rowWidth - Double(max(0, visible.count - 1)) * 4 - gap)
        if alphabet || tenColumns {
            keyWidths = visible.map { _ in standard.keyWidth }
            inset = max(0, (available - Double(visible.count) * standard.keyWidth) / 2)
        } else {
            let projection = LayoutRowWidthProjection(weights: visible.map(\.widthWeight))
            keyWidths = projection.keyFractions.map { available * $0 }
            inset = available * projection.insetFraction
        }
    }

    /// Structural recognition (never by page id): 10 / 9 / Shift+7 letters+Delete with side
    /// weights 1.5 and every other weight nil or 1. Any other valid weight falls back to real
    /// relative sizing, so a side set to 1 really gets narrower.
    private static func standardAlphabetStructure(_ page: KeyboardPageDefinition) -> Bool {
        guard page.rows.count == 3, page.rows.map({ $0.keys.count }) == [10, 9, 9] else { return false }
        let lastRow = page.rows[2].keys
        guard lastRow.first?.action.type == .shift, lastRow.last?.action.type == .backspace,
            lastRow.first?.widthWeight == 1.5, lastRow.last?.widthWeight == 1.5
        else { return false }
        for (index, row) in page.rows.enumerated() {
            let middle = index == 2 ? Array(row.keys.dropFirst().dropLast()) : row.keys
            guard middle.allSatisfy(Self.isSingleLetterKey) else { return false }
        }
        return true
    }

    /// The standard alphabet's letters are literal single characters, not just equal-weight keys:
    /// replacing one with a control or a phrase must fall back to real relative sizing.
    private static func isSingleLetterKey(_ key: LayoutKey) -> Bool {
        guard key.widthWeight == 1, key.action.type == .literal, let value = key.action.value,
            value.count == 1
        else { return false }
        return value.first?.isLetter == true
    }
}
