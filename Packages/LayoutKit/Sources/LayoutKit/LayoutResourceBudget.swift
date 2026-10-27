import Darwin
import Foundation

/// Shared limits for imported definitions and the catalog consumed by the extension.
/// Byte limits bound JSON decoding; model limits bound rendering, lookup and editing work.
/// Every built-in page, and the editable copy made from it, fits well inside the page limits.
public enum LayoutResourceBudget {
    public static let definitionBytes = 1024 * 1024
    /// Storage bound for the whole catalog. The model's key/text allowances are independent and
    /// can describe a legal catalog whose pretty-printed JSON is larger than this; `LayoutStore.save`
    /// then fails closed and writes nothing. Trimming content is the caller's job, never a partial save.
    public static let catalogBytes = 8 * 1024 * 1024
    public static let layouts = 64
    /// User pages one catalog may carry. Unchanged built-in pages ship in code and are merged into
    /// every catalog, so they are not counted; an edited built-in page is.
    public static let pages = 96
    public static let compositions = 256
    public static let pageCategories = 64
    public static let categoryColumns = 10
    public static let categoryKeys = 2048
    public static let recentCategoryKeys = 100
    public static let categorizedPageKeys = 4096
    public static let categorizedCatalogKeys = 32768
    public static let rows = 16
    public static let auxiliaryAreas = 4
    /// Keys in one row, one side area or one function-key region.
    public static let keysPerRegion = 32
    public static let keys = 256
    public static let alternatesPerKey = 16
    public static let alternates = 1024
    public static let textBytes = 64 * 1024
    public static let catalogKeys = 4096
    public static let catalogAlternates = 16 * 1024
    public static let catalogTextBytes = 1024 * 1024

    static let nameBytes = 256
    static let valueBytes = 4096
    static let noteBytes = 8192

    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw LayoutError.invalid(message()) }
    }

    /// What one layout or page spends; the catalog check sums these.
    struct Usage {
        var keys = 0
        var alternates = 0
        var textBytes = 0

        mutating func add(_ other: Usage) {
            keys += other.keys
            alternates += other.alternates
            textBytes += other.textBytes
        }

        mutating func text(_ value: String?, maximum: Int = nameBytes) throws {
            guard let value else { return }
            let count = value.utf8.count
            try check(count <= maximum, "有一段文字太长，请缩短后再保存。")
            textBytes += count
        }

        /// The single per-key rule: faces, action values and long-press options all spend text,
        /// whichever region or category the key sits in.
        mutating func key(_ key: LayoutKey) throws {
            let options = key.longPress ?? []
            try check(
                options.count <= alternatesPerKey,
                "一个键最多 \(alternatesPerKey) 个长按项，请删掉一些。")
            keys += 1
            alternates += options.count
            try text(key.label)
            try text(key.secondaryLabel)
            try text(key.action.value, maximum: valueBytes)
            try text(key.action.asciiValue, maximum: valueBytes)
            for option in options {
                try text(option.label)
                try text(option.action.value, maximum: valueBytes)
                try text(option.action.asciiValue, maximum: valueBytes)
            }
        }

        mutating func region(_ keys: [LayoutKey]) throws {
            try check(
                keys.count <= keysPerRegion,
                "一行或一侧最多 \(keysPerRegion) 个键，请删掉一些。")
            for key in keys { try self.key(key) }
        }

        func checkTotals(keys keyLimit: Int, alternates alternateLimit: Int, textBytes textLimit: Int) throws {
            try check(keys <= keyLimit, "按键超过 \(keyLimit) 个，请删掉一些按键。")
            try check(alternates <= alternateLimit, "长按项超过 \(alternateLimit) 个，请删掉一些长按项。")
            try check(textBytes <= textLimit, "文字太多了，请删掉一些按键或缩短文字。")
        }
    }

    static func usage(_ layout: LayoutDefinition) throws -> Usage {
        try check(layout.rows.count <= rows, "最多 \(rows) 行，请删掉多出来的行。")
        try check(
            (layout.auxiliaryAreas?.count ?? 0) <= auxiliaryAreas,
            "最多 \(auxiliaryAreas) 个侧栏，请删掉多出来的侧栏。")
        var usage = Usage()
        try usage.text(layout.id)
        try usage.text(layout.name)
        try usage.text(layout.input.schemaID)
        try usage.text(layout.note, maximum: noteBytes)
        for row in layout.rows { try usage.region(row.keys) }
        for area in layout.auxiliaryAreas ?? [] { try usage.region(area.keys) }
        try usage.checkTotals(keys: keys, alternates: alternates, textBytes: textBytes)
        return usage
    }

    /// Function keys are real keys: they spend the same budget as row keys. A categorized page
    /// carries its category content and gets the larger categorized allowance.
    static func usage(_ page: KeyboardPageDefinition) throws -> Usage {
        try check(page.rows.count <= rows, "最多 \(rows) 行，请删掉多出来的行。")
        var usage = Usage()
        try usage.text(page.id)
        try usage.text(page.name)
        for row in page.rows { try usage.region(row.keys) }
        if let chrome = page.chrome {
            for region in KeyboardPageChrome.Region.allCases { try usage.region(chrome.keys(in: region)) }
        }
        guard page.symbolPresentation == .categorized else {
            try usage.checkTotals(keys: keys, alternates: alternates, textBytes: textBytes)
            return usage
        }
        let categories = page.categories ?? []
        try check(categories.count <= pageCategories, "最多 \(pageCategories) 个分类，请删掉一些分类。")
        for category in categories {
            try usage.text(category.id)
            try usage.text(category.name)
            try check(
                category.keys.count <= categoryKeys,
                "一个分类最多 \(categoryKeys) 个键，请删掉一些。")
            for key in category.keys { try usage.key(key) }
        }
        try usage.checkTotals(keys: categorizedPageKeys, alternates: catalogAlternates, textBytes: catalogTextBytes)
        return usage
    }

    /// Catalog-wide counts and totals over usages the caller already validated one by one.
    static func checkCatalog(
        _ registry: LayoutRegistry, layoutUsage: Usage, userPageCount: Int, userPageUsage: Usage
    ) throws {
        try check(
            registry.layouts.count <= layouts,
            "最多 \(layouts) 个键盘布局，请先删掉不用的布局。")
        try check(userPageCount <= pages, "最多 \(pages) 个页面，请先删掉不用的页面。")
        try check(registry.compositions.count <= compositions, "页面搭配最多保存 \(compositions) 个，已经存满了。")
        let catalogFull = "所有布局和页面加起来内容太多了，请先删掉一些不用的布局或页面。"
        try check(
            layoutUsage.keys <= catalogKeys && layoutUsage.alternates <= catalogAlternates
                && layoutUsage.textBytes <= catalogTextBytes, catalogFull)
        try check(
            userPageUsage.keys <= categorizedCatalogKeys && userPageUsage.alternates <= catalogAlternates
                && userPageUsage.textBytes <= catalogTextBytes, catalogFull)
    }

    /// Reads a user-imported layout file: regular files only (symlinks followed), capped at `maximumBytes`.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try check(url.isFileURL, "只能打开这台设备上的文件，请重新选择。")
        let resolved = url.resolvingSymlinksInPath()
        // Callers treat ENOENT as "not present yet".
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw POSIXError(.ENOENT) }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        try check(values.isRegularFile == true, "请选择一个文件，不能是文件夹。")
        try check((values.fileSize ?? .max) <= maximumBytes, "文件过大，请选择小一些的文件。")
        return try Data(contentsOf: resolved)
    }
}
