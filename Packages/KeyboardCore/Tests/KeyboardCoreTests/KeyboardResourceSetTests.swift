import XCTest

@testable import KeyboardCore

// Key behaviors of dynamic Rime scheme resource support: resource-set declaration (available layouts + exact schemaID),
// layout selection limits (14/9 must not force the built-in mapping onto the rime-ice schema), and the mapping taking effect through InputSession.

@MainActor
final class KeyboardResourceSetTests: XCTestCase {
    private let shared = URL(fileURLWithPath: "/tmp/res/shared")
    private let user = URL(fileURLWithPath: "/tmp/res/user")

    /// An imported source without layout bindings.
    private func importedSet(prebuiltDirectory: URL? = nil, schemas: [KeyboardSchemaDescriptor]) -> KeyboardResourceSet
    {
        KeyboardResourceSet(
            id: "pkg", name: "test", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], prebuiltDirectory: prebuiltDirectory, schemas: schemas)
    }

    func testBuiltinSchemeNamesMatchAcrossDetailHomeAndExtension() {
        let ids = BuiltinTemplateSchemas.sourceSchemaIDs
        let deployedNames = ["内置全拼", "内置小鹤双拼"]
        func presented(_ names: [String]) -> [String] {
            let schemas = zip(ids, names).map { KeyboardSchemaDescriptor(id: $0.0, name: $0.1) }
            let resources = KeyboardResourceSet.userDictionary(
                name: "41448", sharedDirectory: shared,
                userDirectory: user, schemas: schemas)
            XCTAssertEqual(resources.inputSchemeChoices.map(\.id), ids)
            XCTAssertEqual(
                resources.schemas.map(\.name), names, "only unifies display, does not change the source metadata")
            XCTAssertNil(resources.selectedSchemaID)
            return resources.inputSchemeChoices.map(\.displayName)
        }
        let detail = presented(deployedNames)
        XCTAssertEqual(detail, deployedNames)
        XCTAssertEqual(presented(ids), detail, "an id used as a label still shows the built-in name")
        for (id, oldName) in zip(ids, deployedNames) {
            let custom = oldName + " · 我的词库"
            XCTAssertEqual(KeyboardSchemaDescriptor(id: id, name: custom).displayName, custom)
            XCTAssertEqual(KeyboardSchemaDescriptor(id: "custom_" + id, name: oldName).displayName, oldName)
        }
    }

    func testDictionaryTrialInventoryOffersGeneratedLayoutsWithoutChangingSelection() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        let quanpin = BuiltinTemplateSchemas.quanpin, flypy = BuiltinTemplateSchemas.flypy
        let adapters = [
            KeyboardResourceSet.EncodingAdapter(sourceSchemaID: flypy, schemaID: "flypy_14", layout: .merged14),
            .init(sourceSchemaID: quanpin, schemaID: "quanpin_9", layout: .phone9),
        ]
        try JSONEncoder().encode(adapters).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        let inventory = [KeyboardSchemaDescriptor(id: quanpin, name: "全拼"), .init(id: flypy, name: "双拼")]
        let set = KeyboardResourceSet.userDictionary(
            name: "41448", sharedDirectory: shared,
            userDirectory: user, prebuiltDirectory: build, sourceRevision: "same-revision", schemas: inventory)
        XCTAssertEqual(set.inputSchemeChoices.map(\.id), inventory.map(\.id))
        XCTAssertEqual(set.availableLayouts, [.qwerty26, .merged14, .phone9])
        XCTAssertNil(set.selectedSchemaID)
        let selected = set.selecting(schemaID: quanpin, layout: .qwerty26)
        XCTAssertEqual(selected.selectedSchemaID, quanpin)
        XCTAssertEqual(selected.inputSchemeChoices, inventory)
        XCTAssertEqual(selected.keyboardChoices(for: quanpin).map(\.layout), [.qwerty26, .phone9])
        XCTAssertEqual(selected.keyboardChoices(for: "flypy_14").map(\.engineSchemaID), [flypy, "flypy_14"])
        let restricted = KeyboardResourceSet.userDictionary(
            name: "limited", sharedDirectory: shared,
            userDirectory: user, prebuiltDirectory: build, schemas: [inventory[0]])
        XCTAssertEqual(restricted.inputSchemeChoices, [inventory[0]])
        XCTAssertFalse(restricted.availableCombinations.contains { $0.schemaID == flypy })
    }

    func testSelectingPreservesPublicationGeneration() {
        let set = KeyboardResourceSet(
            id: "published", name: "Published",
            sharedDirectory: shared, userDirectory: user,
            layoutEntries: [.init(layout: .qwerty26, schemaID: "published_schema")],
            schemas: [.init(id: "published_schema", name: "Published")],
            publicationGeneration: "generation-42")

        let selected = set.selecting(schemaID: "published_schema", layout: .qwerty26)
        XCTAssertEqual(selected.publicationGeneration, "generation-42")
    }

    func testBuiltinOffersBothSchemesOnEveryLayoutThroughBundledCompanions() {
        let set = KeyboardResourceSet.builtin(sharedDirectory: shared, userDirectory: user)
        XCTAssertEqual(set.availableLayouts, KeyboardLayoutKind.allCases)
        for source in BuiltinTemplateSchemas.sourceSchemaIDs {
            XCTAssertEqual(set.keyboardChoices(for: source).map(\.layout), KeyboardLayoutKind.allCases)
            for layout in KeyboardLayoutKind.allCases {
                guard let engine = set.engineSchemaID(source: source, layout: layout) else {
                    XCTFail("\(source) has no engine schema on \(layout)")
                    continue
                }
                XCTAssertEqual(engine, BuiltinTemplateSchemas.engineSchemaID(source: source, layout: layout))
                XCTAssertEqual(set.sourceSchemaID(engine), source)
                XCTAssertEqual(BuiltinTemplateSchemas.layout(forSchemaID: engine), layout)
            }
        }
        for layout in KeyboardLayoutKind.allCases {
            XCTAssertEqual(set.schemaID(for: layout), BuiltinTemplateSchemas.defaultSchemaID(for: layout))
        }
    }

    func testImportedResourceWithoutBindingsUsesActualEnabledInventory() {
        let schemas = ["full", "double_one", "double_two"].map {
            KeyboardSchemaDescriptor(id: $0, name: $0, alphabet: "abcdefghijklmnopqrstuvwxyz")
        }
        let set = importedSet(schemas: schemas)
        XCTAssertEqual(set.availableLayouts, [.qwerty26])
        XCTAssertEqual(set.schemaID(for: .qwerty26), "full")
        XCTAssertEqual(Set(set.availableCombinations.map(\.schemaID)), Set(schemas.map(\.id)))
        XCTAssertEqual(set.availableCombinations.count, 3)
        // 14/9-key are not mapped: the built-in companions must not be forced onto imported resources.
        XCTAssertFalse(set.supports(.merged14))
        XCTAssertNil(set.schemaID(for: .merged14))
        XCTAssertFalse(set.supports(.phone9))
        XCTAssertNil(set.schemaID(for: .phone9))
        // Default regular-deployment start (no prebuilt directory).
        XCTAssertNil(set.prebuiltDirectory)
    }

    func testPrebuiltDirectoryIsCarriedForPrebuiltStartup() {
        let build = URL(fileURLWithPath: "/group/KeyboardRecipes/versions/g/resources/build")
        let set = importedSet(
            prebuiltDirectory: build,
            schemas: [.init(id: "rime_ice", name: "test", alphabet: "abcdefghijklmnopqrstuvwxyz")])
        XCTAssertEqual(set.prebuiltDirectory, build)
        // prebuilt only affects the start mode and does not change the available layout/schema mapping.
        XCTAssertEqual(set.availableLayouts, [.qwerty26])
        XCTAssertEqual(set.schemaID(for: .qwerty26), "rime_ice")
        // The built-in resource set stays without prebuilt.
        XCTAssertNil(KeyboardResourceSet.builtin(sharedDirectory: shared, userDirectory: user).prebuiltDirectory)
    }

    func testEncodingCompanionOnlyExposesPairsForEnabledSource() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        let adapters = [
            KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "original", schemaID: "derived9", layout: .phone9),
            .init(sourceSchemaID: "disabled", schemaID: "derived14", layout: .merged14),
        ]
        try JSONEncoder().encode(adapters).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        let set = KeyboardResourceSet(
            id: "source", name: "Source", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], prebuiltDirectory: build,
            schemas: [.init(id: "original", name: "Original", alphabet: "abcdefghijklmnopqrstuvwxyz")],
            selectedSchemaID: "original")
        XCTAssertEqual(set.availableLayouts, [.qwerty26, .phone9])
        XCTAssertEqual(set.schemaID(for: .phone9), "derived9")
        XCTAssertNil(set.schemaID(for: .merged14))
        XCTAssertEqual(set.sourceSchemaID("derived9"), "original")
        XCTAssertNil(set.enabledMembershipReason(schemaID: "derived9"))
        XCTAssertNotNil(set.enabledMembershipReason(schemaID: "derived14"))
        XCTAssertEqual(set.inputSchemeChoices.map(\.id), ["original"])
        XCTAssertEqual(set.keyboardChoices(for: "derived9").map(\.layout), [.qwerty26, .phone9])
        XCTAssertTrue(set.keyboardChoices(for: "disabled").isEmpty)
    }

    func testDuplicateLayoutEntriesCollapseIntoOne() {
        let set = KeyboardResourceSet(
            id: "generic", name: "形码", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [
                .init(layout: .qwerty26, schemaID: "wubi86"), .init(layout: .qwerty26, schemaID: "wubi86"),
                .init(layout: .phone9, schemaID: "wubi86"),
            ])
        XCTAssertEqual(set.layoutEntries.map(\.id), ["wubi86:qwerty26", "wubi86:phone9"])
    }

    func testDuplicateEnglishRoutesCollapse() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        for id in ["source", "english", "other", "english_b"] {
            try Data("schema: fixture".utf8).write(to: build.appendingPathComponent(id + ".schema.yaml"))
        }
        let schemas = ["source", "english", "other", "english_b"].map { KeyboardSchemaDescriptor(id: $0, name: $0) }
        let owner = PublishedKeyboard(schemaID: "source", layout: .qwerty26)
        let other = PublishedKeyboard(schemaID: "other", layout: .qwerty26)
        func resource(_ routes: [EnglishCandidateRoute]) -> KeyboardResourceSet {
            KeyboardResourceSet(
                id: "published", name: "Source", sharedDirectory: shared, userDirectory: user,
                layoutEntries: [], prebuiltDirectory: build, schemas: schemas, selectedSchemaID: "source",
                publicationGeneration: "generation-1", publishedKeyboards: [owner, other],
                englishCandidateRoutes: routes)
        }

        let collapsed = resource([
            EnglishCandidateRoute(
                owner: PublishedKeyboard(schemaID: "source", layout: .qwerty26), candidateSchemaID: "english"),
            EnglishCandidateRoute(owner: owner, candidateSchemaID: "english"),
        ])
        let expected = EnglishCandidateRoute(owner: owner, candidateSchemaID: "english")
        XCTAssertEqual(collapsed.englishCandidateRoutes, [expected])
        XCTAssertEqual(collapsed.runnableEnglishCandidateRoutes(forPublished: [owner, other]), [expected])

        // Two targets for one owner stay ambiguous, but must not disable an unrelated owner.
        let otherRoute = EnglishCandidateRoute(owner: other, candidateSchemaID: "english")
        let conflicting = resource([
            EnglishCandidateRoute(owner: owner, candidateSchemaID: "english"),
            EnglishCandidateRoute(owner: owner, candidateSchemaID: "english_b"),
            otherRoute,
        ])
        XCTAssertEqual(conflicting.runnableEnglishCandidateRoutes(forPublished: [owner, other]), [otherRoute])
    }

    func testSparseLetterSchemaUsesDirectAlphabetKeyboardWithoutCompactInference() {
        let set = KeyboardResourceSet(
            id: "stroke-source", name: "Stroke", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], schemas: [.init(id: "stroke", name: "笔画", alphabet: "hspnz")], selectedSchemaID: "stroke"
        )
        XCTAssertEqual(set.schemaID(for: .qwerty26), "stroke")
        XCTAssertNil(set.schemaID(for: .merged14))
        XCTAssertNil(set.schemaID(for: .phone9))
    }

    /// Same-source publication selection overlay: `selecting` carries the applied schema/layout so general trial typing
    /// reflects the current selection from the shared activation; an unknown schema is returned as is and not applied across sources.
    func testSelectingOverlaysPublishedSchemaAndLayoutOnlyForKnownSchemas() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        // rime_ice has one verified 14-key companion (the engine schema differs from the source).
        try JSONEncoder().encode([
            KeyboardResourceSet.EncodingAdapter(
                sourceSchemaID: "rime_ice", schemaID: "derived14", layout: .merged14, schemaName: "雾凇十四")
        ]).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        let base = importedSet(
            prebuiltDirectory: build,
            schemas: [.init(id: "rime_ice", name: "雾凇拼音", alphabet: "abcdefghijklmnopqrstuvwxyz")])

        // Publication selection: rime_ice + 14-key (even if the base resource set itself carries no selectedSchemaID).
        let selected = base.selecting(schemaID: "rime_ice", layout: .merged14)
        XCTAssertEqual(selected.selectedSchemaID, "rime_ice")
        XCTAssertEqual(selected.preferredLayout, .merged14)
        XCTAssertEqual(selected.id, base.id)
        XCTAssertEqual(selected.schemas, base.schemas)
        // After adoption the 14-key maps to the really verified engine schema.
        XCTAssertEqual(selected.schemaID(for: .merged14), "derived14")
        XCTAssertEqual(selected.sourceSchemaID("derived14"), "rime_ice")

        // An unknown schema does not belong to this resource set: the publication selection is not adopted (no invented selection / no cross-source).
        let unchanged = base.selecting(schemaID: "not_installed", layout: .phone9)
        XCTAssertNil(unchanged.selectedSchemaID)
        XCTAssertNil(unchanged.preferredLayout)
        XCTAssertEqual(unchanged.schemas, base.schemas)
    }

    /// `selecting` is a pure copy: if the adapter disk files change/are deleted after the base is built, the derived set still keeps the original snapshot's
    /// encodingAdapters and combination mapping and does not re-read the disk.
    func testSelectingDoesNotReReadEncodingAdapters() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        let adaptersURL = build.appendingPathComponent("keyboard-adapters.json")
        try JSONEncoder().encode([
            KeyboardResourceSet.EncodingAdapter(sourceSchemaID: "rime_ice", schemaID: "derived14", layout: .merged14)
        ]).write(to: adaptersURL)
        let base = importedSet(
            prebuiltDirectory: build,
            schemas: [.init(id: "rime_ice", name: "雾凇拼音", alphabet: "abcdefghijklmnopqrstuvwxyz")])
        XCTAssertEqual(base.encodingAdapters.count, 1)
        XCTAssertTrue(base.supports(.merged14))

        // Derive after the disk adapter is deleted: must not re-read, the original combination is still there.
        try FileManager.default.removeItem(at: adaptersURL)
        let selected = base.selecting(schemaID: "rime_ice", layout: .merged14)
        XCTAssertEqual(selected.encodingAdapters, base.encodingAdapters)
        XCTAssertEqual(selected.schemaID(for: .merged14), "derived14")
        XCTAssertTrue(selected.supports(.merged14))
    }

    /// A non-empty schemas list is the authority for what is enabled: schemas not enabled in the old layoutEntries are not admitted.
    func testSelectingRejectsSchemaNotInEnabledInventory() {
        let set = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [
                .init(layout: .qwerty26, schemaID: "enabled"),
                .init(layout: .phone9, schemaID: "disabled"),
            ],
            schemas: [.init(id: "enabled", name: "启用", alphabet: "abcdefghijklmnopqrstuvwxyz")])
        let rejected = set.selecting(schemaID: "disabled", layout: .phone9)
        XCTAssertNil(rejected.selectedSchemaID)
        XCTAssertEqual(rejected.schemas, set.schemas)
        // A schema in the enabled list is admitted as usual.
        XCTAssertEqual(set.selecting(schemaID: "enabled", layout: .qwerty26).selectedSchemaID, "enabled")
    }

    /// When the published layout is not a legal combination for the source, the layout preference is dropped (restricting only the schema); no combination is invented.
    func testSelectingDropsInvalidLayoutPreference() {
        let set = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], schemas: [.init(id: "only26", name: "仅26", alphabet: "abcdefghijklmnopqrstuvwxyz")])
        let selected = set.selecting(schemaID: "only26", layout: .phone9)
        XCTAssertEqual(selected.selectedSchemaID, "only26")
        XCTAssertNil(selected.preferredLayout)
    }

    /// An explicit compact-layout request must honor the "new-generation enabled list + author/advanced binding", not just
    /// the automatic registry. Empty registry + an enabled author binding -> usable; a compact layout from a non-enabled source or with no binding
    /// -> rejected (an invalid binding is not resurrected).
    func testExplicitLayoutAcceptsEnabledAuthorBindingWithEmptyRegistry() throws {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: build) }
        // No keyboard-adapters.json → empty auto registry.
        let enabled = KeyboardSchemaDescriptor(
            id: "author_scheme", name: "作者方案", alphabet: "abcdefghijklmnopqrstuvwxyz")
        let set = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [.init(layout: .phone9, schemaID: "author_scheme")],
            prebuiltDirectory: build, schemas: [enabled], selectedSchemaID: "author_scheme")
        XCTAssertTrue(
            set.availableCombinations.contains { $0.schemaID == "author_scheme" && $0.layout == .phone9 },
            "an empty registry + an enabled author binding must form a usable combination")
        // A compact layout with no binding and no registry must be rejected.
        let noBinding = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], prebuiltDirectory: build, schemas: [enabled], selectedSchemaID: "author_scheme")
        XCTAssertFalse(
            noBinding.availableCombinations.contains { $0.schemaID == "author_scheme" && $0.layout == .phone9 })
        // A binding pointing to a non-enabled source (already invalid) -> not admitted.
        let stale = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [.init(layout: .phone9, schemaID: "removed_schema")],
            prebuiltDirectory: build, schemas: [enabled], selectedSchemaID: "author_scheme")
        XCTAssertFalse(
            stale.availableCombinations.contains { $0.layout == .phone9 && $0.schemaID == "removed_schema" },
            "a binding for a non-enabled source must not be adopted")
    }

    /// Startup selection: when restricted to a source, never cross into another source (A only supports 26, B has 9).
    func testBootSelectionDoesNotCrossSource() {
        let set = KeyboardResourceSet(
            id: "pkg", name: "包", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [
                .init(layout: .qwerty26, schemaID: "A"),
                .init(layout: .phone9, schemaID: "B"),
            ],
            schemas: [
                .init(id: "A", name: "A", alphabet: "abcdefghijklmnopqrstuvwxyz"),
                .init(id: "B", name: "B", alphabet: "abcdefghijklmnopqrstuvwxyz9876543210="),
            ])
        // Explicit source A: the candidate 9-key belongs to B, must be rejected, no cross-source.
        XCTAssertNil(set.bootSelection(candidates: [.phone9], restrictedToSource: "A"))
        // Fall back within the same source to A's available layout.
        let withinA = set.bootSelection(candidates: [.phone9, .qwerty26], restrictedToSource: "A")
        XCTAssertEqual(withinA?.layout, .qwerty26)
        XCTAssertEqual(withinA?.schemaID, "A")
        // When unrestricted, map by union (9->B): the existing Panel/built-in route semantics.
        let unrestricted = set.bootSelection(candidates: [.phone9])
        XCTAssertEqual(unrestricted?.layout, .phone9)
        XCTAssertEqual(unrestricted?.schemaID, "B")
    }
}

@MainActor
final class ResourceSetInputSessionTests: XCTestCase {
    private func makeSet(_ entries: [KeyboardResourceSet.LayoutEntry]) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: "test", name: "测试",
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"),
            layoutEntries: entries,
            schemas: (BuiltinTemplateSchemas.sourceSchemaIDs + BuiltinTemplateSchemas.adapters.map(\.schemaID))
                .map { .init(id: $0, name: $0) })
    }

    private func makeEngine() throws -> DemoEngine {
        let engine = DemoEngine()
        try engine.setup(
            sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"))
        return engine
    }

    /// Mapping takes effect: select(layout:) uses the resource set's mapped exact schemaID (here mapped to a built-in scheme the DemoEngine
    /// knows, to verify the path); an undeclared layout is rejected with unsupportedSchema and not forced.
    func testSelectUsesMappedSchemaAndRejectsUnsupportedLayout() throws {
        let engine = try makeEngine()
        let set = makeSet([
            .init(layout: .merged14, schemaID: "keyboard_3d7821f984693864ae91_14"),
            .init(layout: .phone9, schemaID: "keyboard_47246213a538cb99d374_9"),
        ])
        var errors: [Error] = []
        let session = InputSession(engine: engine, layout: .merged14, resourceSet: set)
        session.onError = { errors.append($0) }

        // Switch to t9 via the mapping: after the 9-key companion takes effect, 9-key code 64426 should yield the "你好" candidate.
        session.select(layout: .phone9)
        XCTAssertEqual(session.layout, .phone9)
        "64426".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(
            session.snapshot.candidates.contains { $0.text == "你好" },
            "the t9 code table takes effect = the mapped schemaID is really selected")

        // The resource set does not declare qwerty26: the switch is refused, the original layout is kept, and the error is reported.
        session.select(layout: .qwerty26)
        XCTAssertEqual(session.layout, .phone9)
        XCTAssertEqual(errors.count, 1)
        guard case EngineBackendError.unsupportedSchema = errors[0] else {
            return XCTFail("should be unsupportedSchema, actual \(errors[0])")
        }
    }

    /// A nil resource set (built-in package) keeps the historical behavior: select uses the layout.schemaID hard-coded mapping.
    func testNilResourceSetKeepsLegacyHardcodedMapping() throws {
        let engine = try makeEngine()
        let session = InputSession(engine: engine, layout: .qwerty26)
        XCTAssertNil(session.resourceSet)
        session.select(layout: .merged14)
        XCTAssertEqual(session.layout, .merged14)
        "bugao".forEach { session.tap(.code(String($0))) }
        XCTAssertTrue(session.snapshot.candidates.contains { $0.text == "你好" })
    }

    /// A compact layout with neither a companion nor a binding is refused instead of running the 26-key source.
    func testCompactLayoutWithoutCompanionIsRefusedRatherThanRunningTheSource() throws {
        let engine = try makeEngine()
        let set = KeyboardResourceSet(
            id: "test", name: "测试", sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"), layoutEntries: [], prebuiltDirectory: nil,
            schemas: [.init(id: BuiltinTemplateSchemas.quanpin, name: "全拼", alphabet: "")],
            selectedSchemaID: BuiltinTemplateSchemas.quanpin, preferredLayout: nil, sourceRevision: nil,
            publicationGeneration: nil, publishedKeyboards: nil, englishCandidateRoutes: [], encodingAdapters: [])
        var errors: [Error] = []
        let session = InputSession(engine: engine, layout: .merged14, resourceSet: set)
        session.onError = { errors.append($0) }
        let refused = EngineBackendError.unsupportedSchema(UserTerminology.layoutUnavailableReason(.merged14))

        session.revalidateCurrentSchema()
        XCTAssertEqual(errors as? [EngineBackendError], [refused])

        let wide = InputSession(engine: engine, layout: .qwerty26, resourceSet: set)
        wide.onError = { errors.append($0) }
        wide.select(layout: .merged14, boundSchemaID: BuiltinTemplateSchemas.quanpin)
        XCTAssertEqual(wide.layout, .qwerty26)
        XCTAssertEqual(errors as? [EngineBackendError], [refused, refused])
    }
}

final class EngineSchemaResolverTests: XCTestCase {
    private let source = "src"

    private func resolve(
        _ layout: KeyboardLayoutKind, adapters: [KeyboardResourceSet.EncodingAdapter] = [],
        bindings: [KeyboardResourceSet.LayoutEntry] = []
    ) -> String? {
        KeyboardResourceSet.engineSchemaID(source: source, layout: layout, adapters: adapters, bindings: bindings)
    }

    func testEveryLayoutResolvesCompanionThenBindingThenPlainSource() {
        for layout in KeyboardLayoutKind.allCases {
            let adapter = KeyboardResourceSet.EncodingAdapter(
                sourceSchemaID: source, schemaID: "companion", layout: layout)
            let binding = KeyboardResourceSet.LayoutEntry(layout: layout, schemaID: source)
            XCTAssertEqual(resolve(layout, adapters: [adapter]), "companion", "\(layout)")
            XCTAssertEqual(resolve(layout, adapters: [adapter], bindings: [binding]), "companion", "\(layout)")
            XCTAssertEqual(resolve(layout, bindings: [binding]), source, "\(layout)")
            XCTAssertEqual(resolve(layout), layout == .qwerty26 ? source : nil, "\(layout)")
        }
    }

    func testOtherSourcesAndLayoutsDoNotLeakIntoTheResolution() {
        let otherSource = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: "other", schemaID: "x_14", layout: .merged14)
        let otherLayout = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: source, schemaID: "src_9", layout: .phone9)
        let otherBinding = KeyboardResourceSet.LayoutEntry(layout: .merged14, schemaID: "other")
        XCTAssertNil(resolve(.merged14, adapters: [otherSource, otherLayout], bindings: [otherBinding]))
        XCTAssertEqual(resolve(.phone9, adapters: [otherSource, otherLayout]), "src_9")
    }

    func testResourceSetAndBuiltinTableUseTheSameResolver() {
        let adapter = KeyboardResourceSet.EncodingAdapter(sourceSchemaID: source, schemaID: "src_9", layout: .phone9)
        let binding = KeyboardResourceSet.LayoutEntry(layout: .merged18, schemaID: source)
        let set = KeyboardResourceSet(
            id: "pkg", name: "", sharedDirectory: URL(fileURLWithPath: "/tmp/shared"),
            userDirectory: URL(fileURLWithPath: "/tmp/user"), layoutEntries: [binding], prebuiltDirectory: nil,
            schemas: [.init(id: source, name: "源", alphabet: "")], selectedSchemaID: source, preferredLayout: nil,
            sourceRevision: nil, publicationGeneration: nil, publishedKeyboards: nil, englishCandidateRoutes: [],
            encodingAdapters: [adapter])
        for layout in KeyboardLayoutKind.allCases {
            let expected = resolve(layout, adapters: [adapter], bindings: [binding])
            XCTAssertEqual(set.engineSchemaID(source: source, layout: layout), expected, "\(layout)")
            XCTAssertEqual(set.combination(layout: layout)?.engineSchemaID, expected, "\(layout)")
            for builtin in BuiltinTemplateSchemas.sourceSchemaIDs {
                XCTAssertEqual(
                    BuiltinTemplateSchemas.engineSchemaID(source: builtin, layout: layout),
                    KeyboardResourceSet.engineSchemaID(
                        source: builtin, layout: layout, adapters: BuiltinTemplateSchemas.adapters,
                        bindings: BuiltinTemplateSchemas.layoutEntries))
            }
        }
        XCTAssertNil(set.engineSchemaID(source: source, layout: .merged14))
        XCTAssertNil(set.combination(layout: .merged14))
    }
}
