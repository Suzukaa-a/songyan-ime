import Darwin
import Foundation

/// Shared limits for imported definitions and the catalog consumed by the extension.
/// Byte limits bound JSON decoding; model limits bound rendering, lookup and editing work.
public enum LayoutResourceBudget {
    public static let definitionBytes = 1024 * 1024
    /// Storage bound for the whole catalog. The model's key/text allowances are independent and
    /// can describe a legal catalog whose pretty-printed JSON is larger than this; `LayoutStore.save`
    /// then fails closed with "布局目录文件过大" and writes nothing. Trimming content (or the editor
    /// surfacing that message) is the caller's job, never a partial save.
    public static let catalogBytes = 8 * 1024 * 1024
    public static let layouts = 64
    /// User pages one catalog may carry. The built-in presets ship in code and are merged into
    /// every catalog, so they are not counted against this allowance.
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
    public static let keysPerRegion = 32
    public static let keys = 256
    public static let alternatesPerKey = 16
    public static let alternates = 1024
    public static let textBytes = 64 * 1024
    public static let catalogKeys = 4096
    public static let catalogAlternates = 16 * 1024
    public static let catalogTextBytes = 1024 * 1024

    // MARK: - Materialisation allowance

    /// A legacy page never stored the controls the renderer synthesized for it (Shift/Delete in the
    /// last row, the footer and the editing rail). Materialising them into real data must not force
    /// the user to delete already-saved keys just to open and save the page, so an authored page
    /// gets this bounded allowance on top of the legacy limits. Everything is still counted, and a
    /// page that authors even more function keys hits these limits normally.
    public static let pageControlKeys = 12
    /// The default function area's labels, action values and title modes.
    public static let pageControlTextBytes = 1024
    /// The last row may gain the synthesized Shift and Delete.
    public static let pageControlRowKeys = 2
    /// The default 123 footer's punctuation key carries the alternates the built-in control row
    /// offered (one Chinese mark, two ASCII marks); a page already at the alternate cap keeps its
    /// content afterward.
    public static let pageControlAlternates = 2
    public static let catalogControlKeys = pages * pageControlKeys
    public static let catalogControlTextBytes = pages * pageControlTextBytes
    public static let catalogControlAlternates = pages * pageControlAlternates

    static func check(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw LayoutError.invalid("超过布局资源限制：\(detail)") }
    }

    struct Usage {
        var keys = 0
        var alternates = 0
        var textBytes = 0
    }

    /// Text and per-region scale limits, plus bounded aggregate limits. Main layouts keep the
    /// legacy limits; an authored page offsets only what materialising its function area adds.
    @discardableResult
    static func validate(
        _ layout: LayoutDefinition, rowKeyLimit: Int = keysPerRegion,
        keyLimit: Int = keys, alternatesLimit: Int = alternates, textLimit: Int = textBytes
    ) throws -> Usage {
        try check(layout.rows.count <= rows, "最多 \(rows) 行")
        try check((layout.auxiliaryAreas?.count ?? 0) <= auxiliaryAreas, "辅助区域过多")
        var usage = Usage()
        func text(_ value: String?, maximum: Int) throws {
            guard let value else { return }
            let count = value.utf8.count
            try check(count <= maximum, "单个文本过长")
            usage.textBytes += count
        }
        try text(layout.id, maximum: 256)
        try text(layout.name, maximum: 256)
        try text(layout.input.schemaID, maximum: 256)
        try text(layout.note, maximum: 8192)
        func region(_ keys: [LayoutKey], limit: Int) throws {
            try check(keys.count <= limit, "单行或辅助区域按键过多")
            usage.keys += keys.count
            for key in keys {
                let options = key.longPress ?? []
                try check(options.count <= alternatesPerKey, "单键副键过多")
                usage.alternates += options.count
                try text(key.label, maximum: 256)
                try text(key.secondaryLabel, maximum: 256)
                try text(key.action.value, maximum: 4096)
                try text(key.action.asciiValue, maximum: 4096)
                for option in options {
                    try text(option.label, maximum: 256)
                    try text(option.action.value, maximum: 4096)
                    try text(option.action.asciiValue, maximum: 4096)
                }
            }
        }
        for row in layout.rows { try region(row.keys, limit: rowKeyLimit) }
        for area in layout.auxiliaryAreas ?? [] { try region(area.keys, limit: keysPerRegion) }
        try check(usage.keys <= keyLimit, "按键总数过多")
        try check(usage.alternates <= alternatesLimit, "副键总数过多")
        try check(usage.textBytes <= textLimit, "文本总量过大")
        return usage
    }

    /// Counts an authored function area. Chrome keys are real keys: their labels, alternates and
    /// action values spend the same page budget as row keys.
    static func chromeUsage(_ chrome: KeyboardPageChrome) throws -> Usage {
        var usage = Usage()
        func text(_ value: String?, maximum: Int) throws {
            guard let value else { return }
            try check(value.utf8.count <= maximum, "单个文本过长")
            usage.textBytes += value.utf8.count
        }
        func keys(_ values: [LayoutKey]) throws {
            try check(values.count <= keysPerRegion, "单侧功能键过多")
            usage.keys += values.count
            for key in values {
                let options = key.longPress ?? []
                try check(options.count <= alternatesPerKey, "单键副键过多")
                usage.alternates += options.count
                try text(key.label, maximum: 256)
                try text(key.secondaryLabel, maximum: 256)
                try text(key.action.value, maximum: 4096)
                try text(key.action.asciiValue, maximum: 4096)
                try text(key.titleMode?.rawValue, maximum: 16)
                for option in options {
                    try text(option.label, maximum: 256)
                    try text(option.action.value, maximum: 4096)
                    try text(option.action.asciiValue, maximum: 4096)
                }
            }
        }
        for region in KeyboardPageChrome.Region.allCases { try keys(chrome.keys(in: region)) }
        return usage
    }

    @discardableResult
    static func validate(_ page: KeyboardPageDefinition) throws -> Usage {
        guard page.symbolPresentation == .categorized else {
            guard let chrome = page.chrome else { return try validate(page.layoutDefinition) }
            let control = try chromeUsage(chrome)
            // The inserted Shift/Delete labels are part of the row text, so the intermediate check
            // already uses the materialisation allowance instead of rejecting a page whose legacy
            // text sat exactly on the old limit.
            var usage = try validate(
                page.layoutDefinition, rowKeyLimit: keysPerRegion + pageControlRowKeys,
                keyLimit: keys + pageControlRowKeys, textLimit: textBytes + pageControlTextBytes)
            usage.keys += control.keys
            usage.alternates += control.alternates
            usage.textBytes += control.textBytes
            try check(usage.keys <= keys + pageControlKeys, "按键总数过多")
            try check(usage.alternates <= alternates + pageControlAlternates, "副键总数过多")
            try check(usage.textBytes <= textBytes + pageControlTextBytes, "文本总量过大")
            return usage
        }
        try check((page.categories?.count ?? 0) <= pageCategories, "分类过多")
        // Legacy browser rows remain readable, but authored categories are stored only once.
        var usage = try validate(page.layoutDefinition, rowKeyLimit: keysPerRegion + pageControlRowKeys)
        func text(_ value: String?, maximum: Int) throws {
            guard let value else { return }
            try check(value.utf8.count <= maximum, "单个文本过长")
            usage.textBytes += value.utf8.count
        }
        for category in page.categories ?? [] {
            try text(category.id, maximum: 256)
            try text(category.name, maximum: 256)
            try check(category.keys.count <= categoryKeys, "分类按键过多")
            usage.keys += category.keys.count
            for key in category.keys {
                try text(key.label, maximum: 256)
                try text(key.secondaryLabel, maximum: 256)
                try text(key.action.value, maximum: 4096)
                try text(key.action.asciiValue, maximum: 4096)
                let options = key.longPress ?? []
                try check(options.count <= alternatesPerKey, "单键副键过多")
                usage.alternates += options.count
                for option in options {
                    try text(option.label, maximum: 256)
                    try text(option.action.value, maximum: 4096)
                    try text(option.action.asciiValue, maximum: 4096)
                }
            }
        }
        if let chrome = page.chrome {
            let control = try chromeUsage(chrome)
            usage.keys += control.keys
            usage.alternates += control.alternates
            usage.textBytes += control.textBytes
        }
        try check(usage.keys <= categorizedPageKeys + pageControlKeys, "页面按键总数过多")
        try check(usage.alternates <= catalogAlternates, "页面副键总数过多")
        try check(usage.textBytes <= catalogTextBytes + pageControlTextBytes, "页面文本总量过大")
        return usage
    }

    static func validate(_ registry: LayoutRegistry) throws {
        try check(
            registry.layouts.count <= layouts && registry.enabledIDs.count <= layouts,
            "最多 \(layouts) 个布局")
        // Built-in pages ship in code and are merged into every catalog (an upgrade must not fail
        // because the new preset pushed the list over an old limit or spent a new preset's keys and
        // bytes), so neither the page count nor the catalog totals charge for preset IDs; each
        // preset is still validated on its own.
        let presetIDs = KeyboardPagePresets.codeOwnedIDs
        let userPages = registry.pages.filter { !presetIDs.contains($0.id) }
        try check(userPages.count <= pages, "最多 \(pages) 个页面")
        try check(registry.compositions.count <= compositions, "键盘搭配过多")
        // Pages receive their own budget so legacy catalogs retain their existing capacity.
        let groups = [
            (try registry.layouts.map { try validate($0) }, catalogKeys, catalogAlternates, catalogTextBytes),
            (
                try userPages.map { try validate($0) },
                categorizedCatalogKeys + catalogControlKeys,
                catalogAlternates + catalogControlAlternates,
                catalogTextBytes + catalogControlTextBytes
            ),
        ]
        for (usages, keyLimit, alternateLimit, textLimit) in groups {
            var total = Usage()
            for usage in usages {
                total.keys += usage.keys
                total.alternates += usage.alternates
                total.textBytes += usage.textBytes
            }
            try check(
                total.keys <= keyLimit && total.alternates <= alternateLimit
                    && total.textBytes <= textLimit, "布局目录总量过大")
        }
        for id in registry.enabledIDs {
            try check(id.utf8.count <= 256, "启用布局 ID 过长")
        }
    }

    /// Reads a user-imported layout file: regular files only (symlinks followed), capped at `maximumBytes`.
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        try check(url.isFileURL, "需要本地普通文件")
        let resolved = url.resolvingSymlinksInPath()
        // Callers treat ENOENT as "not present yet".
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw POSIXError(.ENOENT) }
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        try check(values.isRegularFile == true, "需要普通文件")
        try check((values.fileSize ?? .max) <= maximumBytes, "文件过大")
        return try Data(contentsOf: resolved)
    }
}
