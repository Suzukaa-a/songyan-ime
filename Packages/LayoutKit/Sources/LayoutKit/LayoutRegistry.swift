import Foundation

/// Value-type snapshot. Ordering enabledIDs also orders the keyboard's layout switcher.
public struct LayoutRegistry: Codable, Equatable, Sendable {
    public private(set) var layouts: [LayoutDefinition]
    public private(set) var enabledIDs: [String]
    public var enabledLayouts: [LayoutDefinition] {
        enabledIDs.compactMap { id in layouts.first { $0.id == id } }
    }

    public init(layouts: [LayoutDefinition] = BuiltinLayouts.all, enabledIDs: [String]? = nil) throws {
        self.layouts = layouts
        self.enabledIDs = enabledIDs ?? layouts.map(\.id)
        try validate()
    }

    public func layout(id: String) -> LayoutDefinition? { layouts.first { $0.id == id } }

    /// Replace in place, including the last enabled layout, preserving all ordering/state.
    public mutating func replace(_ definition: LayoutDefinition) throws {
        try definition.validate()
        guard let index = layouts.firstIndex(where: { $0.id == definition.id }) else {
            throw LayoutError.unknownID(definition.id)
        }
        var candidate = self
        candidate.layouts[index] = definition
        try candidate.validate()
        self = candidate
    }

    @discardableResult
    public mutating func copy(
        _ definition: LayoutDefinition, name: String? = nil,
        enable: Bool = false
    ) throws -> LayoutDefinition {
        try definition.validate()
        let copy = definition.copy(name: name)
        try install(copy.encoded(), enable: enable)
        return copy
    }

    /// New IDs may be enabled on install; same-ID imports preserve existing enable state/order.
    @discardableResult
    public mutating func install(
        _ data: Data, replaceExisting: Bool = false,
        enable: Bool = true
    ) throws -> LayoutDefinition {
        let definition = try LayoutDefinition.decode(data)
        var candidate = self
        if let index = candidate.layouts.firstIndex(where: { $0.id == definition.id }) {
            guard replaceExisting else { throw LayoutError.duplicateID(definition.id) }
            candidate.layouts[index] = definition
        } else {
            candidate.layouts.append(definition)
            if enable { candidate.enabledIDs.append(definition.id) }
        }
        try candidate.validate()
        self = candidate
        return definition
    }

    public mutating func remove(id: String) throws {
        guard layout(id: id) != nil else { throw LayoutError.unknownID(id) }
        guard enabledIDs != [id] else { throw LayoutError.lastEnabledLayout }
        layouts.removeAll { $0.id == id }
        enabledIDs.removeAll { $0 == id }
    }

    /// Enables/disables and reorders in a single operation; rejects unknown or repeated IDs.
    public mutating func setEnabledIDs(_ ids: [String]) throws {
        var candidate = self
        candidate.enabledIDs = ids
        try candidate.validate()
        self = candidate
    }

    /// Host supplies actual resource/engine compatibility. If enabled layouts are unavailable,
    /// use a compatible bundled layout transiently without rewriting the user's preferences.
    /// An empty result means no supported schema exists; the host must present recovery UI.
    public func usableLayouts(where isSupported: (LayoutDefinition) -> Bool) -> [LayoutDefinition] {
        let supported = enabledLayouts.filter(isSupported)
        if !supported.isEmpty { return supported }
        return BuiltinLayouts.all.first(where: isSupported).map { [$0] } ?? []
    }

    public func validate() throws {
        try LayoutResourceBudget.validate(self)
        guard !enabledIDs.isEmpty else { throw LayoutError.lastEnabledLayout }
        guard Set(layouts.map(\.id)).count == layouts.count,
            Set(enabledIDs).count == enabledIDs.count
        else {
            throw LayoutError.invalid("duplicate layout IDs")
        }
        for layout in layouts { try layout.validate() }
        for id in enabledIDs where layout(id: id) == nil { throw LayoutError.unknownID(id) }
    }
}

/// The HostApp is the single writer; extensions call load() for a fresh atomic snapshot.
/// No App Group discovery, UserDefaults mutation, or filesystem writes occur at initialization.
public struct LayoutStore: Sendable {
    public let directoryURL: URL
    public var catalogURL: URL { directoryURL.appendingPathComponent("layouts.json") }
    public init(directoryURL: URL) { self.directoryURL = directoryURL }

    public func load() throws -> LayoutRegistry {
        let data: Data
        do {
            data = try LayoutResourceBudget.read(catalogURL, maximumBytes: LayoutResourceBudget.catalogBytes)
        } catch let error as POSIXError where error.code == .ENOENT {
            return try LayoutRegistry()
        }
        let registry = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        try registry.validate()
        return registry
    }

    public func save(_ registry: LayoutRegistry) throws {
        try registry.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try LayoutResourceBudget.check(data.count <= LayoutResourceBudget.catalogBytes, "布局目录文件过大")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: catalogURL, options: .atomic)
    }

    /// Caller owns any security-scoped URL access. Failed import never changes the catalog.
    @discardableResult
    public func importLayout(from url: URL, replaceExisting: Bool = false) throws -> LayoutRegistry {
        var registry = try load()
        let data = try LayoutResourceBudget.read(url, maximumBytes: LayoutResourceBudget.definitionBytes)
        try registry.install(data, replaceExisting: replaceExisting)
        try save(registry)
        return registry
    }
}
