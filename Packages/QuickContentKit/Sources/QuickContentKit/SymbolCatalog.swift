import Foundation

// MARK: - Errors

public struct SymbolCatalogError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Symbol catalog (v1, frozen minimal schema)

/// A symbol entry. `text` is the string inserted into the host (one or a few combining
/// characters); `name` is the Chinese display name; `aliases` are lowercase pinyin/English
/// search aliases; `category` references a category ID in the catalog.
public struct SymbolItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var name: String
    public var aliases: [String]
    public var category: String

    public init(id: String, text: String, name: String, aliases: [String], category: String) {
        self.id = id
        self.text = text
        self.name = name
        self.aliases = aliases
        self.category = category
    }
}

/// A catalog category (display name + sort weight). Items in unknown categories remain
/// searchable and sort after known categories (by category ID); nothing is dropped.
public struct SymbolCategory: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var order: Int

    public init(id: String, name: String, order: Int) {
        self.id = id
        self.name = name
        self.order = order
    }
}

/// Symbol catalog: items + categories. The JSON top level is
/// `{version:1, categories:[{id,name,order}], items:[{id,text,name,aliases,category}]}`。
public struct SymbolCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var categories: [SymbolCategory]
    public var items: [SymbolItem]

    public init(version: Int = 1, categories: [SymbolCategory], items: [SymbolItem]) {
        self.version = version
        self.categories = categories
        self.items = items
    }

    /// `categories` may be omitted (items then show under unknown categories at the end).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        categories = try container.decodeIfPresent([SymbolCategory].self, forKey: .categories) ?? []
        items = try container.decode([SymbolItem].self, forKey: .items)
    }

    /// The original default catalog (read-only bundle resource). A decode failure is a
    /// packaging error and is thrown rather than silently replaced with other data.
    public static func bundledDefault() throws -> SymbolCatalog {
        guard let url = Bundle.module.url(forResource: "default-symbols", withExtension: "json") else {
            throw SymbolCatalogError("默认符号目录资源缺失")
        }
        return try decode(contentsOf: url)
    }

    // MARK: Derived data (render budget)

    /// Category display order: known categories by ascending order (ties by id), unknown
    /// ones appended. Categories without items are included (the UI decides whether to hide them).
    public var orderedCategories: [SymbolCategory] {
        let known = categories.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        let knownIDs = Set(known.map(\.id))
        let extras = Set(items.map(\.category)).subtracting(knownIDs)
            .sorted()
            .map { SymbolCategory(id: $0, name: $0, order: Int.max) }
        return known + extras
    }

    /// Items of a category, in catalog declaration order for stable rendering.
    public func items(in category: String) -> [SymbolItem] {
        items.filter { $0.category == category }
    }

    /// Search over Chinese name / pinyin or English alias / symbol text using its own
    /// query buffer; never touches the host text proxy or the engine. Deterministic
    /// ranking: name prefix > alias prefix > name contains > alias contains > text match;
    /// ties keep catalog declaration order.
    /// - Parameter rawQuery: raw user input (may be uppercase, contain spaces or full-width characters).
    public func search(_ rawQuery: String) -> [SymbolItem] {
        let query = SymbolSearch.normalize(rawQuery)
        guard !query.isEmpty else { return [] }
        var byPrefixName: [SymbolItem] = []
        var byPrefixAlias: [SymbolItem] = []
        var byContainsName: [SymbolItem] = []
        var byContainsAlias: [SymbolItem] = []
        var byText: [SymbolItem] = []
        for item in items {
            let name = SymbolSearch.normalize(item.name)
            if name.hasPrefix(query) {
                byPrefixName.append(item)
                continue
            }
            if item.aliases.contains(where: { SymbolSearch.normalize($0).hasPrefix(query) }) {
                byPrefixAlias.append(item)
                continue
            }
            if name.contains(query) {
                byContainsName.append(item)
                continue
            }
            if item.aliases.contains(where: { SymbolSearch.normalize($0).contains(query) }) {
                byContainsAlias.append(item)
                continue
            }
            if SymbolSearch.normalize(item.text) == query
                || item.text.contains(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                byText.append(item)
            }
        }
        return byPrefixName + byPrefixAlias + byContainsName + byContainsAlias + byText
    }
}

/// Normalization shared by query and matching: lowercase, strip whitespace, fold
/// full-width ASCII to half-width. Used only for comparison; user data is never rewritten.
public enum SymbolSearch {
    public static func normalize(_ value: String) -> String {
        String(
            value.lowercased().unicodeScalars.map { scalar -> Character in
                Character(foldFullwidthASCII(scalar))
            }
        ).filter { !$0.isWhitespace }
    }

    private static func foldFullwidthASCII(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        // U+FF01...U+FF5E -> U+0021...U+007E; U+3000 (ideographic space) -> space.
        if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
            return Unicode.Scalar(scalar.value - 0xFF01 + 0x21)!
        }
        if scalar.value == 0x3000 { return " " }
        return scalar
    }
}

// MARK: Coding (strict fields + defaults; same discipline as SkinKit/CandidateKit)

extension SymbolCatalog {
    private static let maxJSONBytes = 256 * 1024
    private static let maxItems = 2_000
    private static let maxAliasesPerItem = 16

    /// Validate and bound the same regular-file descriptor before JSON decoding.
    public static func decode(contentsOf url: URL) throws -> SymbolCatalog {
        try decode(
            QuickContentFileReader.read(
                url, maximumBytes: maxJSONBytes,
                sizeError: "$: JSON 超过 256KB"))
    }

    public static func decode(_ data: Data) throws -> SymbolCatalog {
        guard data.count <= maxJSONBytes else { throw SymbolCatalogError("$: JSON 超过 256KB") }
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SymbolCatalogError("$: 需要对象")
        }
        guard source["version"] as? Int == 1 else { throw SymbolCatalogError("$.version: 只支持 1") }
        // Only schema fields are allowed; categories may be omitted.
        let allowed: Set<String> = ["version", "categories", "items"]
        for key in source.keys where !allowed.contains(key) {
            throw SymbolCatalogError("$.\(key): 未知字段")
        }
        if let categories = source["categories"] as? [[String: Any]] {
            for (index, category) in categories.enumerated() {
                let keys = Set(category.keys)
                guard keys.isSubset(of: ["id", "name", "order"]) else {
                    throw SymbolCatalogError("$.categories[\(index)]: 未知字段")
                }
            }
        }
        guard let items = source["items"] as? [[String: Any]] else {
            throw SymbolCatalogError("$.items: 需要数组")
        }
        for (index, item) in items.enumerated() {
            let keys = Set(item.keys)
            guard keys.isSubset(of: ["id", "text", "name", "aliases", "category"]) else {
                throw SymbolCatalogError("$.items[\(index)]: 未知字段")
            }
        }
        let catalog = try JSONDecoder().decode(SymbolCatalog.self, from: data)
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        func require(_ test: Bool, _ path: String) throws { if !test { throw SymbolCatalogError("\(path): 值无效") } }
        try require(version == 1, "$.version")
        try require(items.count <= SymbolCatalog.maxItems, "$.items")
        var seenIDs = Set<String>()
        var seenTexts = Set<String>()
        for (index, item) in items.enumerated() {
            let path = "$.items[\(index)]"
            try require(
                !item.id.isEmpty && item.id.utf8.count <= 64
                    && item.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") },
                "\(path).id")
            try require(seenIDs.insert(item.id).inserted, "\(path).id: 重复 \(item.id)")
            try require(!item.text.isEmpty && item.text.count <= 32, "\(path).text")
            try require(seenTexts.insert(item.text).inserted, "\(path).text: 重复 \(item.text)")
            try require(!item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(path).name")
            try require(item.aliases.count <= SymbolCatalog.maxAliasesPerItem, "\(path).aliases")
            try require(!item.category.isEmpty, "\(path).category")
            for (aliasIndex, alias) in item.aliases.enumerated() {
                try require(
                    !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(path).aliases[\(aliasIndex)]")
            }
        }
        var seenCategoryIDs = Set<String>()
        for (index, category) in categories.enumerated() {
            let path = "$.categories[\(index)]"
            try require(
                !category.id.isEmpty && category.id.utf8.count <= 64
                    && category.id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") },
                "\(path).id")
            try require(seenCategoryIDs.insert(category.id).inserted, "\(path).id: 重复 \(category.id)")
            try require(!category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(path).name")
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= SymbolCatalog.maxJSONBytes else { throw SymbolCatalogError("$: JSON 超过 256KB") }
        return data
    }
}
