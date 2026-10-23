import Darwin
import Foundation

/// Shared limits for imported definitions and the catalog consumed by the extension.
/// Byte limits bound JSON decoding; model limits bound rendering, lookup and editing work.
public enum LayoutResourceBudget {
    public static let definitionBytes = 1024 * 1024
    public static let catalogBytes = 8 * 1024 * 1024
    public static let layouts = 64
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

    static func check(_ condition: Bool, _ detail: String) throws {
        guard condition else { throw LayoutError.invalid("超过布局资源限制：\(detail)") }
    }

    struct Usage {
        var keys = 0
        var alternates = 0
        var textBytes = 0
    }

    @discardableResult
    static func validate(_ layout: LayoutDefinition) throws -> Usage {
        try check(layout.rows.count <= rows, "最多 \(rows) 行")
        try check((layout.auxiliaryAreas?.count ?? 0) <= auxiliaryAreas, "辅助区域过多")
        var usage = Usage()
        func text(_ value: String?, maximum: Int) throws {
            guard let value else { return }
            let count = value.utf8.count
            try check(count <= maximum, "单个文本过长")
            usage.textBytes += count
            try check(usage.textBytes <= textBytes, "文本总量过大")
        }
        try text(layout.id, maximum: 256)
        try text(layout.name, maximum: 256)
        try text(layout.input.schemaID, maximum: 256)
        try text(layout.note, maximum: 8192)
        func region(_ keys: [LayoutKey]) throws {
            try check(keys.count <= keysPerRegion, "单行或辅助区域按键过多")
            usage.keys += keys.count
            try check(usage.keys <= Self.keys, "按键总数过多")
            for key in keys {
                let options = key.longPress ?? []
                try check(options.count <= alternatesPerKey, "单键副键过多")
                usage.alternates += options.count
                try check(usage.alternates <= alternates, "副键总数过多")
                try text(key.label, maximum: 256)
                try text(key.secondaryLabel, maximum: 256)
                try text(key.action.value, maximum: 4096)
                for option in options {
                    try text(option.label, maximum: 256)
                    try text(option.action.value, maximum: 4096)
                }
            }
        }
        for row in layout.rows { try region(row.keys) }
        for area in layout.auxiliaryAreas ?? [] { try region(area.keys) }
        return usage
    }

    static func validate(_ registry: LayoutRegistry) throws {
        try check(
            registry.layouts.count <= layouts && registry.enabledIDs.count <= layouts,
            "最多 \(layouts) 个布局")
        var total = Usage()
        for layout in registry.layouts {
            let usage = try validate(layout)
            total.keys += usage.keys
            total.alternates += usage.alternates
            total.textBytes += usage.textBytes
            try check(
                total.keys <= catalogKeys && total.alternates <= catalogAlternates
                    && total.textBytes <= catalogTextBytes, "布局目录总量过大")
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
