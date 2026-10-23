import Foundation

// MARK: - Keyboard resource set (directories + exact layout-to-schema mapping)
//
// A Rime engine resource = shared directory (schemes/dictionaries, read-only) + user
// directory (build/userdb, writable) + an independent schema selection and optional
// logical-code association. The physical layout is not decided by the resource brand;
// compact keyboards report their specific encoding needs via incompatibilityReason and
// the scheme's algebra is never rewritten automatically.

/// Declares a resource set: the available layouts and the exact schemaID for each layout.
public struct KeyboardResourceSet: Equatable, Sendable {
    /// A runnable pair in this resource source. schemaID is the user-visible enabled schema;
    /// engineSchemaID can be its explicitly installed, validated encoding companion.
    public struct Combination: Equatable, Sendable, Identifiable {
        public let schemaID: String
        public let engineSchemaID: String
        public let layout: KeyboardLayoutKind
        public let name: String
        public var id: String { schemaID + ":" + layout.rawValue }
        public init(schemaID: String, engineSchemaID: String, layout: KeyboardLayoutKind, name: String) {
            self.schemaID = schemaID
            self.engineSchemaID = engineSchemaID
            self.layout = layout
            self.name = name
        }
    }
    public var availableCombinations: [Combination] {
        var result: [Combination] = []
        let auxiliarySchemaIDs = Set(englishCandidateRoutes.map(\.candidateSchemaID))
        var seenSources = Set<String>()
        let enabled =
            (schemas.isEmpty
            ? layoutEntries.map(\.schemaID).filter { seenSources.insert($0).inserted } : schemas.map(\.id))
            .filter { !auxiliarySchemaIDs.contains($0) }
        for source in enabled {
            // The user-visible name accepts only the human name declared by the resource; an
            // empty name or `name == id` stays empty so the upper layer falls back to the
            // layout name and never shows an arbitrary schema/source ID as display copy.
            let sourceName = schemas.first { $0.id == source }?.humanReadableName ?? ""
            for layout in KeyboardLayoutKind.allCases {
                // When non-nil, only combinations explicitly added in the manifest are visible,
                // and only structurally runnable ones appear (a compact layout must have a
                // generated adapter or an author binding; never fall back to the source's 26-key).
                // Implicit alphabet inference for 26-key is also turned off (not added = not offered).
                if let published = publishedKeyboards {
                    guard published.contains(PublishedKeyboard(schemaID: source, layout: layout)),
                        let engine = structurallyRunnableEngineSchema(source: source, layout: layout)
                    else { continue }
                    // A published item represents the source input method; the generated
                    // adapter's internal schema name is not a second user-facing input method
                    // name. Always use the source's human name (may be empty).
                    result.append(
                        .init(
                            schemaID: source, engineSchemaID: engine, layout: layout,
                            name: sourceName))
                    continue
                }
                if let adapter = encodingAdapters.first(where: { $0.sourceSchemaID == source && $0.layout == layout }) {
                    result.append(
                        .init(
                            schemaID: source, engineSchemaID: adapter.schemaID, layout: layout,
                            name: adapter.schemaName ?? sourceName + " · " + layout.shortTitle + "配套"))
                } else if layoutEntries.contains(where: { $0.schemaID == source && $0.layout == layout }) {
                    result.append(.init(schemaID: source, engineSchemaID: source, layout: layout, name: sourceName))
                } else if layout.keyFold == .identity,
                    selectedSchemaID != nil || layoutEntries.isEmpty,
                    let alphabet = schemas.first(where: { $0.id == source })?.alphabet,
                    alphabet.isEmpty || !Set(alphabet).intersection(Set("abcdefghijklmnopqrstuvwxyz")).isEmpty
                {
                    result.append(.init(schemaID: source, engineSchemaID: source, layout: layout, name: sourceName))
                }
            }
        }
        return result
    }

    /// The *structured* engine schema for a (source, layout): no disk I/O.
    ///
    ///  * with a generated adapter -> the adapter's engine schema;
    ///  * with an author/advanced binding -> the source schema itself (the author declared it serves that layout);
    ///  * plain 26-key -> the source schema itself; shuangpin hints must be declared by an author binding or a verified adapter;
    ///  * compact layouts (14 / 9 key) without an adapter or binding -> nil (not runnable);
    ///    the source schema is never used as a compact engine (that would be the "fall back to 26-key" bug).
    func structurallyRunnableEngineSchema(source: String, layout: KeyboardLayoutKind) -> String? {
        if let adapter = encodingAdapters.first(where: { $0.sourceSchemaID == source && $0.layout == layout }) {
            return adapter.schemaID
        }
        if layoutEntries.contains(where: { $0.schemaID == source && $0.layout == layout }) {
            return source
        }
        if !layout.requiresSpellingDisplay { return source }
        return nil
    }

    /// Whether a published keyboard is actually runnable in this snapshot: the structured
    /// engine schema exists and its compiled output really exists in the build directory.
    /// For one-shot filtering only (`restricted`), not the `body` hot path.
    func isPublishedKeyboardRunnable(_ keyboard: PublishedKeyboard, build: URL) -> Bool {
        let enabled = schemas.isEmpty ? Set(layoutEntries.map(\.schemaID)) : Set(schemas.map(\.id))
        guard enabled.contains(keyboard.schemaID),
            let engine = structurallyRunnableEngineSchema(source: keyboard.schemaID, layout: keyboard.layout)
        else {
            return false
        }
        return FileManager.default.fileExists(atPath: build.appendingPathComponent(engine + ".schema.yaml").path)
    }

    /// Returns only routes whose owner is in this published roster and whose auxiliary
    /// schema is independently enabled and compiled in the same immutable generation.
    public func runnableEnglishCandidateRoutes(forPublished published: [PublishedKeyboard]) -> [EnglishCandidateRoute] {
        guard publicationGeneration?.isEmpty == false else { return [] }
        guard let build = prebuiltDirectory, let roster = publishedKeyboards else { return [] }
        let storedOwners = Set(roster)
        let requestedOwners = Set(published).intersection(storedOwners)
        // An owner with two different targets is ambiguous: only that owner fails closed.
        var routeCounts: [PublishedKeyboard: Int] = [:]
        for route in englishCandidateRoutes { routeCounts[route.owner, default: 0] += 1 }
        let enabled = Set(schemas.map(\.id))
        return englishCandidateRoutes.filter { route in
            let target = route.candidateSchemaID
            guard routeCounts[route.owner] == 1,
                route.owner.schemaID != target,
                selectedSchemaID != target,
                !roster.contains(where: { $0.schemaID == target }),
                requestedOwners.contains(route.owner),
                isPublishedKeyboardRunnable(route.owner, build: build),
                enabled.contains(target),
                !target.isEmpty,
                !target.contains("/"),
                target != ".",
                !target.contains("..")
            else { return false }
            let targetFile = build.appendingPathComponent(target + ".schema.yaml")
            return FileManager.default.fileExists(
                atPath: targetFile.path)
        }
    }

    public func combination(layout: KeyboardLayoutKind, preferredSchemaID: String? = nil) -> Combination? {
        let pairs = availableCombinations.filter { $0.layout == layout }
        return pairs.first { $0.schemaID == (preferredSchemaID ?? selectedSchemaID) } ?? pairs.first
    }
    public struct EncodingAdapter: Codable, Equatable, Sendable {
        public let sourceSchemaID: String
        public let schemaID: String
        public let layout: KeyboardLayoutKind
        public let schemaName: String?
        public init(sourceSchemaID: String, schemaID: String, layout: KeyboardLayoutKind, schemaName: String? = nil) {
            self.sourceSchemaID = sourceSchemaID
            self.schemaID = schemaID
            self.layout = layout
            self.schemaName = schemaName
        }
    }
    public let encodingAdapters: [EncodingAdapter]
    /// Source schemes appear once. Generated keyboard companions remain diagnostics.
    public var inputSchemeChoices: [KeyboardSchemaDescriptor] {
        let companionIDs = Set(encodingAdapters.filter { $0.schemaID != $0.sourceSchemaID }.map(\.schemaID))
            .union(englishCandidateRoutes.map(\.candidateSchemaID))
        return schemas.filter { !companionIDs.contains($0.id) }
    }
    public func keyboardChoices(for schemaID: String) -> [Combination] {
        availableCombinations.filter { $0.schemaID == sourceSchemaID(schemaID) }
    }
    public static func readEncodingAdapters(build: URL) -> [EncodingAdapter] {
        guard let data = try? Data(contentsOf: build.appendingPathComponent("keyboard-adapters.json")),
            data.count < 1_000_000
        else { return [] }
        return (try? JSONDecoder().decode([EncodingAdapter].self, from: data)) ?? []
    }
    public func logicalSchemaID(_ sourceID: String, layout: KeyboardLayoutKind) -> String {
        encodingAdapters.first { $0.sourceSchemaID == sourceID && $0.layout == layout }?.schemaID ?? sourceID
    }
    public func sourceSchemaID(_ engineID: String) -> String {
        encodingAdapters.first { $0.schemaID == engineID }?.sourceSchemaID ?? engineID
    }
    public struct LayoutEntry: Codable, Equatable, Sendable, Identifiable {
        /// Physical keyboard layout.
        public let layout: KeyboardLayoutKind
        /// The engine schema id this layout maps to in this resource set (exact value, e.g. "rime_ice").
        public let schemaID: String

        public var id: String { schemaID + ":" + layout.rawValue }

        public init(layout: KeyboardLayoutKind, schemaID: String) {
            self.layout = layout
            self.schemaID = schemaID
        }
    }

    /// Stable resource set identifier (e.g. "builtin", "user-pinyin", an installed package id).
    public let id: String
    /// Display name (for the UI; not a unique key).
    public let name: String
    /// Rime shared directory (default.yaml, *.schema.yaml, dictionaries; read-only for the engine).
    public let sharedDirectory: URL
    /// Writable user directory (build/, *.userdb/, sync/).
    public let userDirectory: URL
    /// Read-only compiled resource directory (the AppGroup shared recipe's published output).
    /// Non-nil = prebuilt launch: skips deploy/maintenance, and a schema or version mismatch
    /// fails the launch explicitly, never falling back to a full deploy;
    /// learning data is still written to `userDirectory`. nil = normal launch (first-time dictionary deploy).
    public let prebuiltDirectory: URL?
    /// Available layouts and exact schemaIDs (order is the suggested UI display order).
    public let layoutEntries: [LayoutEntry]
    public let schemas: [KeyboardSchemaDescriptor]
    public let selectedSchemaID: String?
    public let preferredLayout: KeyboardLayoutKind?
    /// Used for the "same source, same revision" check when the Host overlays a publication selection; nil never passes by default.
    public let sourceRevision: String?
    /// App Group publication generation carried by the authoritative Snapshot.
    /// Nil means this resource is builtin/unpublished; callers must never infer it
    /// from a filesystem path spelling.
    public let publicationGeneration: String?
    /// Added keyboard manifest (publication unit = input method x layout). nil = unrestricted
    /// (built-in / typing-trial path, keeping the historical capability inference); an
    /// empty array = explicitly no keyboards added (the extension offers no combinations).
    public let publishedKeyboards: [PublishedKeyboard]?
    /// Declared auxiliary routes; dispatch must use the generation-validated route accessor below.
    public let englishCandidateRoutes: [EnglishCandidateRoute]
    public var usesIndependentSelection: Bool {
        selectedSchemaID != nil || !schemas.isEmpty || !encodingAdapters.isEmpty
    }

    public init(
        id: String, name: String, sharedDirectory: URL, userDirectory: URL,
        layoutEntries: [LayoutEntry], prebuiltDirectory: URL? = nil,
        schemas: [KeyboardSchemaDescriptor] = [], selectedSchemaID: String? = nil,
        preferredLayout: KeyboardLayoutKind? = nil, sourceRevision: String? = nil,
        publicationGeneration: String? = nil, publishedKeyboards: [PublishedKeyboard]? = nil,
        englishCandidateRoutes: [EnglishCandidateRoute] = []
    ) {
        self.init(
            id: id, name: name, sharedDirectory: sharedDirectory, userDirectory: userDirectory,
            layoutEntries: layoutEntries, prebuiltDirectory: prebuiltDirectory, schemas: schemas,
            selectedSchemaID: selectedSchemaID, preferredLayout: preferredLayout,
            sourceRevision: sourceRevision, publicationGeneration: publicationGeneration,
            publishedKeyboards: publishedKeyboards,
            englishCandidateRoutes: englishCandidateRoutes,
            encodingAdapters: Self.readEncodingAdapters(
                build: prebuiltDirectory ?? userDirectory.appendingPathComponent("build")))
    }

    /// I/O-free internal snapshot construction: keeps the caller's already-resolved
    /// `encodingAdapters`. Derived resource sets (`selecting` / session schema reconciliation)
    /// must go through here and never re-read disk adapters because a schema/layout was replaced.
    init(
        id: String, name: String, sharedDirectory: URL, userDirectory: URL,
        layoutEntries: [LayoutEntry], prebuiltDirectory: URL?,
        schemas: [KeyboardSchemaDescriptor], selectedSchemaID: String?,
        preferredLayout: KeyboardLayoutKind?, sourceRevision: String?,
        publicationGeneration: String?, publishedKeyboards: [PublishedKeyboard]?,
        englishCandidateRoutes: [EnglishCandidateRoute],
        encodingAdapters: [EncodingAdapter]
    ) {
        self.id = id
        self.name = name
        self.sharedDirectory = sharedDirectory
        self.userDirectory = userDirectory
        // Keep the first of duplicate pairs to stay Identifiable-unique.
        var seenEntries = Set<String>()
        self.layoutEntries =
            layoutEntries
            .map { LayoutEntry(layout: $0.layout, schemaID: $0.schemaID) }
            .filter { seenEntries.insert($0.id).inserted }
        self.prebuiltDirectory = prebuiltDirectory
        self.schemas = schemas
        self.selectedSchemaID = selectedSchemaID
        self.preferredLayout = preferredLayout
        self.sourceRevision = sourceRevision
        self.publicationGeneration = publicationGeneration
        self.publishedKeyboards = publishedKeyboards.map {
            PublishedKeyboard.resolve(published: $0)
        }
        // Owners are already standardized, so the same collapse can repeat a route verbatim.
        var seenRoutes = Set<EnglishCandidateRoute>()
        self.englishCandidateRoutes = englishCandidateRoutes.filter { seenRoutes.insert($0).inserted }
        self.encodingAdapters = encodingAdapters
    }

    /// Independent selection of a resource shows all physical layouts and checks the specific encoding compatibility reason before selection.
    public var availableLayouts: [KeyboardLayoutKind] {
        KeyboardLayoutKind.allCases.filter { layout in availableCombinations.contains { $0.layout == layout } }
    }

    public func supports(_ layout: KeyboardLayoutKind) -> Bool {
        availableLayouts.contains(layout)
    }

    /// The exact schemaID for a layout; nil when the layout is not in this resource set (never fall back to a guess).
    public func schemaID(for layout: KeyboardLayoutKind) -> String? {
        combination(layout: layout)?.engineSchemaID
    }

    public func incompatibilityReason(layout: KeyboardLayoutKind, schemaID: String) -> String? {
        let source = sourceSchemaID(schemaID)
        if availableCombinations.contains(where: { $0.schemaID == source && $0.layout == layout }) { return nil }
        return UserTerminology.layoutUnavailableReason(layout)
    }

    /// Returns a copy of the resource set carrying an explicit publication selection (the
    /// schema / physical layout currently applied for that source). General source typing
    /// trials use it to reflect the current selection without rewriting the resource
    /// identity; trials that name a schema explicitly do not call this, so their named identity is kept.
    ///
    /// - `schemaID` must be a source scheme within this snapshot's *enabled manifest*: when
    ///   `schemas` is non-empty the manifest is authoritative (disabled schemas in
    ///   `layoutEntries` are not accepted); only a layout mapping without metadata falls
    ///   back to `layoutEntries`/combination enumeration. An unknown schema is returned
    ///   unchanged, never invented across sources.
    /// - `layout` must be a combination that really exists under that source; otherwise the
    ///   layout preference is dropped (constraining only the schema) and never inserted as a legitimate selection.
    /// - Derivation reads no disk (keeps this snapshot's already-resolved `encodingAdapters`).
    public func selecting(schemaID: String, layout: KeyboardLayoutKind? = nil) -> KeyboardResourceSet {
        guard !englishCandidateRoutes.contains(where: { $0.candidateSchemaID == schemaID }) else { return self }
        let enabled: Bool
        if !schemas.isEmpty {
            enabled = schemas.contains { $0.id == schemaID }
        } else if !layoutEntries.isEmpty {
            enabled = layoutEntries.contains { $0.schemaID == schemaID }
        } else {
            enabled = availableCombinations.contains { $0.schemaID == schemaID }
        }
        guard enabled else { return self }
        let validLayout = layout.flatMap { candidate in
            availableCombinations.contains { $0.schemaID == schemaID && $0.layout == candidate }
                ? candidate : nil
        }
        return KeyboardResourceSet(
            id: id, name: name, sharedDirectory: sharedDirectory,
            userDirectory: userDirectory, layoutEntries: layoutEntries,
            prebuiltDirectory: prebuiltDirectory, schemas: schemas,
            selectedSchemaID: schemaID, preferredLayout: validLayout,
            sourceRevision: sourceRevision, publicationGeneration: publicationGeneration,
            publishedKeyboards: publishedKeyboards,
            englishCandidateRoutes: englishCandidateRoutes,
            encodingAdapters: encodingAdapters)
    }

    /// Picks a launchable (physical layout, engine schema) from candidate layouts. When
    /// `restrictedToSource` is non-nil, only combinations under that source schema are
    /// allowed and there is never a cross-source fallback (the launch identity of an
    /// explicit/published source must not drift to another source's layout in the union);
    /// when nil, the resource-set mapping applies (built-in route).
    public func bootSelection(
        candidates: [KeyboardLayoutKind],
        restrictedToSource sourceID: String? = nil
    )
        -> (layout: KeyboardLayoutKind, schemaID: String)?
    {
        for savedCandidate in candidates {
            let candidate = savedCandidate
            if let sourceID {
                guard
                    let combo = availableCombinations.first(where: {
                        $0.schemaID == sourceID && $0.layout == candidate
                    })
                else { continue }
                guard incompatibilityReason(layout: candidate, schemaID: combo.engineSchemaID) == nil else { continue }
                return (candidate, combo.engineSchemaID)
            }
            guard supports(candidate), let schema = schemaID(for: candidate) else { continue }
            guard incompatibilityReason(layout: candidate, schemaID: schema) == nil else { continue }
            return (candidate, schema)
        }
        return nil
    }

    /// Keeps only the input method x layout combinations in the *published keyboard manifest*.
    /// This is the extension-side publication fact: an empty manifest = no keyboards added
    /// (no combinations offered, and never discovers/prepares unadded ones on its own);
    /// non-empty = only exact combinations in the manifest that are actually runnable are visible.
    ///
    /// Each published item must satisfy: the source is in the enabled manifest; a compact
    /// layout (14 / 9 key) has a structured generated adapter or author binding (never
    /// falling back to the source's 26-key); its engine schema's compiled output really
    /// exists in the build directory. Items that fail are filtered out and can be retrieved
    /// with `unrunnablePublished(_:)` for reporting (neither treated as usable nor
    /// silently swallowed). 26-key can use the source schema directly.
    ///
    /// One-shot filtering (call during route resolution / host reads), not the `body` hot path.
    public func restricted(toPublished published: [PublishedKeyboard]) -> KeyboardResourceSet {
        let build = prebuiltDirectory ?? userDirectory.appendingPathComponent("build")
        let runnable = published.filter { isPublishedKeyboardRunnable($0, build: build) }
        return KeyboardResourceSet(
            id: id, name: name, sharedDirectory: sharedDirectory,
            userDirectory: userDirectory, layoutEntries: layoutEntries, prebuiltDirectory: prebuiltDirectory,
            schemas: schemas, selectedSchemaID: selectedSchemaID, preferredLayout: preferredLayout,
            sourceRevision: sourceRevision, publicationGeneration: publicationGeneration,
            publishedKeyboards: runnable,
            englishCandidateRoutes: englishCandidateRoutes,
            encodingAdapters: encodingAdapters)
    }

    /// Published-manifest items that are not runnable in this snapshot (input order kept):
    /// a compact layout lacking a structured adapter/binding, an unenabled source, or a
    /// missing compiled engine schema. Callers report from this and never treat
    /// "published but not runnable" as usable, nor silently add a source combination.
    public func unrunnablePublished(_ published: [PublishedKeyboard]) -> [PublishedKeyboard] {
        let build = prebuiltDirectory ?? userDirectory.appendingPathComponent("build")
        return published.filter { !isPublishedKeyboardRunnable($0, build: build) }
    }

    /// Combinations in the published keyboard manifest that this resource set really supports
    /// (in manifest order). Lets the UI keep real names; unmapped items do not appear. An
    /// empty manifest returns empty (not added = not offered).
    public func publishedCombinations(_ published: [PublishedKeyboard]) -> [Combination] {
        let byID = Dictionary(availableCombinations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return published.compactMap { byID[$0.id] }
    }

    /// Human projection of the published keyboard manifest: names come from this snapshot's
    /// structured `schemas` (the currently published scheme descriptions); it is not a
    /// persisted field, so it follows source renames/updates automatically. Unrunnable items are filtered out.
    public func publishedDisplays(_ published: [PublishedKeyboard]) -> [PublishedKeyboardDisplay] {
        PublishedKeyboard.displays(
            publishedCombinations(published).map {
                PublishedKeyboard(schemaID: $0.schemaID, layout: $0.layout)
            }, in: schemas)
    }

    /// Whether the target schema belongs to this resource set's *actual enabled manifest*
    /// (the `schemas` of the install receipt / publication record). Merely being compiled as
    /// a dependency (build output exists and can be activated) does not mean enabled:
    /// whether it can be activated and whether it is authorized are separate matters, and a
    /// target outside the manifest must be rejected before confirming a combination,
    /// otherwise a split state arises where the switch happened but the publication manifest does not recognize it.
    /// A resource without metadata (the built-in templates) must rebuild from the current engine's explicit
    /// enabled list; an empty set is rejected.
    /// Publication resource metadata is rebuilt in the Snapshot from that generation's effective default.
    public func enabledMembershipReason(schemaID: String, engineSchemas: [KeyboardSchemaDescriptor] = []) -> String? {
        let allowed = schemas.isEmpty ? engineSchemas : schemas
        let sourceID = sourceSchemaID(schemaID)
        guard !allowed.contains(where: { $0.id == sourceID }) else { return nil }
        return "输入方案 \(schemaID) 未启用（已启用："
            + allowed.map(\.id).joined(separator: "、")
            + "）。如需使用，请先在「松烟」App 中启用这个输入方案。"
    }
}

public extension KeyboardResourceSet {
    /// Imported dictionaries run on the built-in schemes and their shared learning; the compact
    /// layouts come from the adapters generated into `prebuiltDirectory` at install time.
    static func userDictionary(
        name: String, sharedDirectory: URL, userDirectory: URL,
        prebuiltDirectory: URL? = nil, sourceRevision: String? = nil,
        schemas: [KeyboardSchemaDescriptor] = []
    ) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: "user-pinyin", name: name, sharedDirectory: sharedDirectory,
            userDirectory: userDirectory,
            layoutEntries: BuiltinTemplateSchemas.layoutEntries, prebuiltDirectory: prebuiltDirectory, schemas: schemas,
            sourceRevision: sourceRevision)
    }

    /// The bundled schemes with their bundled compact companions, so every layout works
    /// before (or without) the app preparing anything. Identity/names come from
    /// `ProductionInputAvailability`; the package does not appear as a product scheme in Release.
    static func builtin(sharedDirectory: URL, userDirectory: URL) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: ProductionInputAvailability.builtinResourceID,
            name: ProductionInputAvailability.builtinDisplayName,
            sharedDirectory: sharedDirectory,
            userDirectory: userDirectory,
            layoutEntries: BuiltinTemplateSchemas.layoutEntries,
            prebuiltDirectory: nil, schemas: [], selectedSchemaID: nil, preferredLayout: nil,
            sourceRevision: nil, publicationGeneration: nil, publishedKeyboards: nil,
            englishCandidateRoutes: [],
            encodingAdapters: BuiltinTemplateSchemas.adapters
        )
    }
}
