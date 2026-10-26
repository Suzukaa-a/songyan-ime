import Foundation

/// Recent categories retain authored keys so switching back to fixed content is reversible.
public struct KeyboardPageCategory: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case fixed, recent }

    public var id: String
    public var name: String
    public var columns: Int
    public var keys: [LayoutKey]
    public var split: LayoutSplitConfiguration?
    public var source: Source?

    public init(
        id: String = UUID().uuidString.lowercased(), name: String, columns: Int = 4,
        keys: [LayoutKey], split: LayoutSplitConfiguration? = nil, source: Source? = nil
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.keys = keys
        self.split = split
        self.source = source
    }

    public var rows: [LayoutRow] {
        guard columns > 0 else { return [] }
        return stride(from: 0, to: keys.count, by: columns).map {
            LayoutRow(keys: Array(keys[$0..<min($0 + columns, keys.count)]))
        }
    }

    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 256,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256
        else { throw LayoutError.invalid("请填写分类名称。") }
        guard (1...LayoutResourceBudget.categoryColumns).contains(columns) else {
            throw LayoutError.invalid("分类列数应在 1 到 \(LayoutResourceBudget.categoryColumns) 之间。")
        }
        guard source == .recent || !keys.isEmpty else { throw LayoutError.invalid("分类请至少保留一个按键。") }
        for key in keys { try KeyboardPageDefinition.validateKey(key) }
        // Recent content changes independently of the fixed-key backup.
        let rowCount =
            source == .recent
            ? (LayoutResourceBudget.recentCategoryKeys + columns - 1) / columns : rows.count
        // A partial final row keeps the full grid's split boundary.
        try split?.validate(rowKeyCounts: Array(repeating: columns, count: rowCount))
    }
}
