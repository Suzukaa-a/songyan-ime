import Foundation

/// Value-type snapshot. Ordering enabledIDs also orders the keyboard's layout switcher.
public struct LayoutRegistry: Codable, Equatable, Sendable {
    public private(set) var layouts: [LayoutDefinition]
    public private(set) var enabledIDs: [String]
    public private(set) var pages: [KeyboardPageDefinition]
    public private(set) var compositions: [String: KeyboardComposition]

    private enum CodingKeys: String, CodingKey { case layouts, enabledIDs, pages, pageOrder, compositions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try values.decode([LayoutDefinition].self, forKey: .layouts)
        enabledIDs = try values.decode([String].self, forKey: .enabledIDs)
        let storedPages = try values.decodeIfPresent([KeyboardPageDefinition].self, forKey: .pages) ?? []
        // A catalog saved before a built-in page existed still gets it: the default pairings
        // reference pages by ID, so a missing preset would otherwise fail every composition save.
        let merged = KeyboardPagePresets.mergingInto(storedPages)
        if let pageOrder = try values.decodeIfPresent([String].self, forKey: .pageOrder) {
            // Saves omit unchanged presets; the order list restores their original positions so a
            // save/load round trip does not reshuffle the page library. A repeated ID is corrupt
            // external input: keep every entry so validate() rejects it exactly as before instead
            // of a dictionary silently swallowing one copy.
            var byID: [String: KeyboardPageDefinition] = [:]
            var hasDuplicateID = false
            for page in merged where byID.updateValue(page, forKey: page.id) != nil {
                hasDuplicateID = true
            }
            if hasDuplicateID {
                pages = merged
            } else {
                var ordered: [KeyboardPageDefinition] = []
                var seen = Set<String>()
                for id in pageOrder where seen.insert(id).inserted {
                    if let page = byID.removeValue(forKey: id) { ordered.append(page) }
                }
                ordered += merged.filter { !seen.contains($0.id) }
                pages = ordered
            }
        } else {
            pages = merged
        }
        compositions = try values.decodeIfPresent([String: KeyboardComposition].self, forKey: .compositions) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(layouts, forKey: .layouts)
        try values.encode(enabledIDs, forKey: .enabledIDs)
        // Code-owned presets are restored by `mergingInto` on decode. Omitting the unchanged ones
        // keeps a full catalog under the byte cap when a release adds presets; a user-modified
        // stored preset still goes on the wire so that edit survives.
        try values.encode(pages.filter { !KeyboardPagePresets.isUnmodifiedPreset($0) }, forKey: .pages)
        try values.encode(pages.map(\.id), forKey: .pageOrder)
        try values.encode(compositions, forKey: .compositions)
    }

    public var enabledLayouts: [LayoutDefinition] {
        enabledIDs.compactMap { id in layouts.first { $0.id == id } }
    }

    public init(
        layouts: [LayoutDefinition] = BuiltinLayouts.all, enabledIDs: [String]? = nil,
        pages: [KeyboardPageDefinition] = KeyboardPagePresets.all,
        compositions: [String: KeyboardComposition] = [:]
    ) throws {
        self.layouts = layouts
        self.enabledIDs = enabledIDs ?? layouts.map { $0.id }
        self.pages = pages
        self.compositions = compositions
        try validate()
    }

    public func layout(id: String) -> LayoutDefinition? { layouts.first { $0.id == id } }

    public func page(id: String) -> KeyboardPageDefinition? { pages.first { $0.id == id } }

    public func composition(for keyboardID: String, defaultMainLayoutID: String) -> KeyboardComposition {
        compositions[keyboardID] ?? KeyboardComposition(mainLayoutID: defaultMainLayoutID)
    }

    public mutating func savePage(_ page: KeyboardPageDefinition) throws {
        var candidate = self
        if let index = candidate.pages.firstIndex(where: { $0.id == page.id }) {
            candidate.pages[index] = page
        } else {
            candidate.pages.append(page)
        }
        try candidate.validate()
        self = candidate
    }

    public mutating func removePage(id: String) throws {
        guard page(id: id) != nil else { throw LayoutError.unknownID(id) }
        guard
            !compositions.values.contains(where: {
                $0.symbolPageID == id || $0.numericPageID == id || $0.englishPageID == id
            })
        else { throw LayoutError.invalid("这个页面正在搭配使用，请先更换页面。") }
        guard !KeyboardPagePresets.all.contains(where: { $0.id == id }) else {
            throw LayoutError.invalid("预设页面请先复制，再编辑副本。")
        }
        pages.removeAll { $0.id == id }
    }

    /// Drops the page pairings whose input method has no provider left, and returns how many
    /// were removed. The caller owns the "no provider" judgement (an install was deleted and
    /// no other install or built-in scheme still offers that input method); this type owns the map.
    @discardableResult
    public mutating func pruneCompositions(where isObsoleteInputMethod: (String) -> Bool) -> Int {
        let obsolete = compositions.keys.filter { key in
            guard let separator = key.lastIndex(of: ":") else { return false }
            return isObsoleteInputMethod(String(key[..<separator]))
        }
        for key in obsolete { compositions.removeValue(forKey: key) }
        return obsolete.count
    }

    public mutating func setComposition(_ composition: KeyboardComposition, for keyboardID: String) throws {
        var candidate = self
        candidate.compositions[keyboardID] = composition
        try candidate.validate()
        self = candidate
    }

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
        guard !compositions.values.contains(where: { $0.mainLayoutID == id }) else {
            throw LayoutError.invalid("这个布局正在搭配使用，请先更换主布局。")
        }
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
        guard Set(pages.map { $0.id }).count == pages.count else {
            throw LayoutError.invalid("页面标识重复，请重新复制页面。")
        }
        for page in pages { try page.validate() }
        for (keyboardID, composition) in compositions {
            guard !keyboardID.isEmpty, keyboardID.utf8.count <= 512 else {
                throw LayoutError.invalid("找不到要搭配的键盘，请重新选择。")
            }
            guard let separator = keyboardID.lastIndex(of: ":"), separator != keyboardID.startIndex,
                let kind = LayoutInput.Builtin(rawValue: String(keyboardID[keyboardID.index(after: separator)...])),
                let main = layout(id: composition.mainLayoutID),
                main.supportsComposition(inputMethodID: String(keyboardID[..<separator]), layout: kind)
            else { throw LayoutError.invalid("主布局与输入方式不兼容，请重新选择。") }
            for kind in KeyboardPageKind.allCases {
                guard page(id: composition.pageID(for: kind))?.kind == kind else {
                    throw LayoutError.invalid("找不到搭配的页面，请重新选择。")
                }
            }
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
