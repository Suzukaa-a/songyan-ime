import Foundation

/// Value-type snapshot of the layout catalog: layouts, pages and each keyboard's pairing.
public struct LayoutRegistry: Codable, Equatable, Sendable {
    public private(set) var layouts: [LayoutDefinition]
    public private(set) var pages: [KeyboardPageDefinition]
    public private(set) var compositions: [String: KeyboardComposition]

    private enum CodingKeys: String, CodingKey { case layouts, pages, pageOrder, compositions }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layouts = try values.decode([LayoutDefinition].self, forKey: .layouts)
        // Pages, their order and pairings are absent from catalogs written before pages existed.
        let storedPages = try values.decodeIfPresent([KeyboardPageDefinition].self, forKey: .pages) ?? []
        // Saves omit unchanged built-in pages, and a release may add one; the default pairings
        // reference pages by ID, so every built-in page must be present after loading.
        let merged = KeyboardPagePresets.mergingInto(storedPages)
        if let pageOrder = try values.decodeIfPresent([String].self, forKey: .pageOrder) {
            // Saves omit unchanged presets; the order list restores their original positions so a
            // save/load round trip does not reshuffle the page library. A repeated ID is corrupt
            // input: keep every entry so validate() rejects it instead of a dictionary silently
            // swallowing one copy.
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
        // Code-owned presets are restored by `mergingInto` on decode. Omitting the unchanged ones
        // keeps a full catalog under the byte cap when a release adds presets; a user-modified
        // stored preset still goes on the wire so that edit survives.
        try values.encode(pages.filter { !KeyboardPagePresets.isUnmodifiedPreset($0) }, forKey: .pages)
        try values.encode(pages.map(\.id), forKey: .pageOrder)
        try values.encode(compositions, forKey: .compositions)
    }

    public init(
        layouts: [LayoutDefinition] = BuiltinLayouts.all,
        pages: [KeyboardPageDefinition] = KeyboardPagePresets.all,
        compositions: [String: KeyboardComposition] = [:]
    ) throws {
        self.layouts = layouts
        self.pages = pages
        self.compositions = compositions
        try validate()
    }

    public func layout(id: String) -> LayoutDefinition? { layouts.first { $0.id == id } }

    /// The stored layout, or the bundled preset with this ID that an older catalog left out.
    /// Bundled presets are always available as main layouts.
    public func resolvedLayout(id: String) -> LayoutDefinition? {
        layout(id: id) ?? BuiltinLayouts.all.first { $0.id == id }
    }

    /// Every layout `isSupported` accepts, plus the bundled presets an older catalog left out.
    public func usableLayouts(where isSupported: (LayoutDefinition) -> Bool) -> [LayoutDefinition] {
        let missing = BuiltinLayouts.all.filter { preset in !layouts.contains { $0.id == preset.id } }
        return (layouts + missing).filter(isSupported)
    }

    /// The layouts 页面搭配 offers as this keyboard's main layout.
    public func mainLayoutCandidates(for key: KeyboardCompositionKey) -> [LayoutDefinition] {
        usableLayouts { $0.supportsComposition(inputMethodID: key.inputMethodID, layout: key.layout) }
    }

    public func page(id: String) -> KeyboardPageDefinition? { pages.first { $0.id == id } }

    /// Keyboards that use this layout as the main layout, in a stable order: every saved pairing,
    /// plus each of `keyboards` whose effective pairing (saved or default) names it. A keyboard
    /// without a saved pairing still uses its default layout.
    public func keyboards(usingLayout id: String, among keyboards: [KeyboardCompositionKey] = [])
        -> [KeyboardCompositionKey]
    {
        var raw = Set(compositions.filter { $0.value.mainLayoutID == id }.keys)
        for key in keyboards where composition(for: key).mainLayoutID == id { raw.insert(key.rawValue) }
        return raw.sorted().compactMap(KeyboardCompositionKey.init)
    }

    /// Keyboards whose saved pairing uses this page, in a stable order.
    public func keyboards(usingPage id: String) -> [KeyboardCompositionKey] {
        let using = compositions.filter { _, composition in
            KeyboardPageKind.allCases.contains { composition.pageID(for: $0) == id }
        }
        return using.keys.sorted().compactMap(KeyboardCompositionKey.init)
    }

    /// The saved pairing, or the default one built on `defaultMainLayoutID(for:)`.
    public func composition(for key: KeyboardCompositionKey) -> KeyboardComposition {
        compositions[key.rawValue] ?? KeyboardComposition(mainLayoutID: defaultMainLayoutID(for: key))
    }

    /// The main layout of a keyboard without a saved pairing; the host and the keyboard both
    /// resolve it here. A layout of this shape bound to this input method wins (the smallest ID
    /// when there are several, so catalog order never decides); otherwise the bundled preset of
    /// the shape. Unbound user copies are used only once chosen in a pairing.
    public func defaultMainLayoutID(for key: KeyboardCompositionKey) -> String {
        layouts.filter { $0.input.schemaID == key.inputMethodID && $0.input.builtinLayout == key.layout }
            .map(\.id).min() ?? BuiltinLayouts.preset(for: key.layout).id
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
        guard page(id: id) != nil else { throw LayoutError.invalid("找不到这个页面，它可能已经被删除。") }
        guard
            !compositions.values.contains(where: {
                $0.symbolPageID == id || $0.numericPageID == id || $0.englishPageID == id
            })
        else { throw LayoutError.invalid("这个页面正在被键盘使用，请先在「页面搭配」里换成别的页面。") }
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
            KeyboardCompositionKey(key).map { isObsoleteInputMethod($0.inputMethodID) } ?? false
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

    /// Replace in place, preserving the catalog order.
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
    public mutating func copy(_ definition: LayoutDefinition, name: String? = nil) throws -> LayoutDefinition {
        try definition.validate()
        let copy = definition.copy(name: name)
        try install(copy.encoded())
        return copy
    }

    /// New IDs are appended; a same-ID import replaces in place only when asked.
    @discardableResult
    public mutating func install(_ data: Data, replaceExisting: Bool = false) throws -> LayoutDefinition {
        let definition = try LayoutDefinition.decode(data)
        var candidate = self
        if let index = candidate.layouts.firstIndex(where: { $0.id == definition.id }) {
            guard replaceExisting else { throw LayoutError.duplicateID(definition.id) }
            candidate.layouts[index] = definition
        } else {
            candidate.layouts.append(definition)
        }
        try candidate.validate()
        self = candidate
        return definition
    }

    public mutating func remove(id: String) throws {
        guard layout(id: id) != nil else { throw LayoutError.unknownID(id) }
        // Bundled presets are the default main layouts, so they stay; an edit can be reset instead.
        guard !BuiltinLayouts.all.contains(where: { $0.id == id }) else {
            throw LayoutError.invalid("内置布局不能删除，可以复制一份再修改。")
        }
        guard !compositions.values.contains(where: { $0.mainLayoutID == id }) else {
            throw LayoutError.invalid("这个键盘布局正在被键盘使用，请先在「页面搭配」里换一个主布局。")
        }
        layouts.removeAll { $0.id == id }
    }

    /// Every layout and page is validated exactly once; the catalog totals reuse those results.
    /// The extension runs this on every load.
    public func validate() throws {
        guard Set(layouts.map(\.id)).count == layouts.count else {
            throw LayoutError.invalid("布局列表里有重复的布局，请删掉其中一个后重试。")
        }
        guard Set(pages.map(\.id)).count == pages.count else {
            throw LayoutError.invalid("页面库里有重复的页面，请删掉其中一个后重试。")
        }
        var layoutUsage = LayoutResourceBudget.Usage()
        for layout in layouts { layoutUsage.add(try layout.validatedUsage()) }
        // Unchanged built-in pages ship in code and are merged into every catalog, so they are
        // not charged; an edited one is user content like any other page.
        var userPageCount = 0
        var userPageUsage = LayoutResourceBudget.Usage()
        for page in pages {
            let usage = try page.validatedUsage()
            guard !KeyboardPagePresets.isUnmodifiedPreset(page) else { continue }
            userPageCount += 1
            userPageUsage.add(usage)
        }
        try LayoutResourceBudget.checkCatalog(
            self, layoutUsage: layoutUsage, userPageCount: userPageCount, userPageUsage: userPageUsage)
        for (keyboardID, composition) in compositions {
            guard keyboardID.utf8.count <= 512, let key = KeyboardCompositionKey(keyboardID) else {
                throw LayoutError.invalid("「页面搭配」里有一个键盘找不到了，请重新选择键盘。")
            }
            guard let main = resolvedLayout(id: composition.mainLayoutID) else {
                throw LayoutError.invalid("「页面搭配」选的主布局已经不存在，请重新选择。")
            }
            guard main.supportsComposition(inputMethodID: key.inputMethodID, layout: key.layout) else {
                throw LayoutError.invalid("这个键盘布局不适用于当前输入方式，请换一个键盘布局。")
            }
            for kind in KeyboardPageKind.allCases {
                guard page(id: composition.pageID(for: kind))?.kind == kind else {
                    throw LayoutError.invalid("「页面搭配」选的页面已经不存在，请重新选择。")
                }
            }
        }
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
        try LayoutResourceBudget.check(
            data.count <= LayoutResourceBudget.catalogBytes,
            "所有布局和页面加起来太大了，没能保存，请先删掉一些不用的布局或页面。")
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
