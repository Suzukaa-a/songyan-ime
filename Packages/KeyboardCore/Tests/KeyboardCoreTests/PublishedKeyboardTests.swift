import XCTest

@testable import KeyboardCore

/// "User keyboard" publication contract:
///  * publication unit = input method (schema) x layout;
///  * the needed resources are generated only when that keyboard is added/updated (only compact layouts need generated adapters);
///  * after deletion it is removed from the roster;
///  * the extension shows only the added roster; combinations not added are neither offered nor invented;
///  * a compact layout (14 / 9 keys) must have a **structured** adapter and a real engine schema, otherwise it is not runnable
///    and never falls back to the source's 26-key.
///
/// All use **generic** fixtures (a "generic double-pinyin" rather than any brand/concrete ID) to prove schema-agnosticism.
final class PublishedKeyboardTests: XCTestCase {
    private let shared = URL(fileURLWithPath: "/tmp/pub/shared")
    private let user = URL(fileURLWithPath: "/tmp/pub/user")

    /// Builds a build directory: writes the adapter registry and several "compiled" engine schema files.
    private func makeBuild(
        engineSchemas: [String],
        adapters: [KeyboardResourceSet.EncodingAdapter] = []
    ) throws -> URL {
        let build = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        if !adapters.isEmpty {
            try JSONEncoder().encode(adapters).write(to: build.appendingPathComponent("keyboard-adapters.json"))
        }
        for id in engineSchemas {
            try Data("schema: fixture".utf8).write(to: build.appendingPathComponent(id + ".schema.yaml"))
        }
        return build
    }

    private func set(build: URL) -> KeyboardResourceSet {
        KeyboardResourceSet(
            id: "user-scheme-generic", name: "通用来源",
            sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], prebuiltDirectory: build,
            schemas: [
                KeyboardSchemaDescriptor(id: "mspy", name: "通用双拼", alphabet: "abcdefghijklmnopqrstuvwxyz"),
                KeyboardSchemaDescriptor(id: "shape", name: "通用形码", alphabet: "abcdefghijklmnopqrstuvwxyz"),
            ], selectedSchemaID: "mspy")
    }

    // MARK: - 1) Only compact layouts need generated adapters

    func testOnlyCompactLayoutsNeedGeneratedAdapters() {
        XCTAssertFalse(PublishedKeyboard(schemaID: "mspy", layout: .qwerty26).needsGeneratedAdapter)
        XCTAssertTrue(PublishedKeyboard(schemaID: "mspy", layout: .merged14).needsGeneratedAdapter)
        XCTAssertTrue(PublishedKeyboard(schemaID: "mspy", layout: .phone9).needsGeneratedAdapter)
    }

    /// generationTasks keeps only compact layouts, de-duplicated with order preserved; a 26-key combination yields no task.
    func testGenerationTasksExcludeTwentySixAndDeduplicate() {
        let requested = [
            PublishedKeyboard(schemaID: "mspy", layout: .qwerty26),
            PublishedKeyboard(schemaID: "mspy", layout: .merged14),
            PublishedKeyboard(schemaID: "mspy", layout: .merged14),  // duplicate
            PublishedKeyboard(schemaID: "mspy", layout: .phone9),
        ]
        XCTAssertEqual(
            PublishedKeyboard.generationTasks(for: requested),
            [
                PublishedKeyboard(schemaID: "mspy", layout: .merged14),
                PublishedKeyboard(schemaID: "mspy", layout: .phone9),
            ])
        XCTAssertTrue(
            PublishedKeyboard.generationTasks(for: [
                PublishedKeyboard(schemaID: "mspy", layout: .qwerty26)
            ]).isEmpty)
    }

    // MARK: - 2) Pure model of add/delete

    func testAddingIsIdempotentAndPreservesOrder() {
        let a = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let b = PublishedKeyboard(schemaID: "mspy", layout: .phone9)
        var list = PublishedKeyboard.adding(a, to: [])
        list = PublishedKeyboard.adding(b, to: list)
        list = PublishedKeyboard.adding(a, to: list)
        XCTAssertEqual(list, [a, b])
    }

    func testRemovingDropsExactlyThatEntry() {
        let a = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let b = PublishedKeyboard(schemaID: "mspy", layout: .phone9)
        XCTAssertEqual(PublishedKeyboard.removing(a, from: [a, b]), [b])
        XCTAssertEqual(PublishedKeyboard.removing(b, from: [a, b]), [a])
        // Delete the last item -> empty roster (the extension offers no combination any more).
        XCTAssertEqual(PublishedKeyboard.removing(a, from: [a]), [])
        // Idempotent: unchanged when absent.
        XCTAssertEqual(PublishedKeyboard.removing(b, from: [a]), [a])
    }

    func testSelectionAfterRemovalPreservesUnaffectedCurrentKeyboard() {
        let first = PublishedKeyboard(schemaID: "first", layout: .qwerty26)
        let removed = PublishedKeyboard(schemaID: "first", layout: .merged14)
        let current = PublishedKeyboard(schemaID: "other", layout: .phone9)
        let remaining = PublishedKeyboard.removing(removed, from: [first, removed, current])

        XCTAssertEqual(
            PublishedKeyboard.selectionAfterRemoval(
                from: remaining, current: current), current)
    }

    func testSelectionAfterRemovalFallsBackOnlyWhenCurrentIsGoneOrInvalid() {
        let first = PublishedKeyboard(schemaID: "first", layout: .qwerty26)
        let removedCurrent = PublishedKeyboard(schemaID: "other", layout: .phone9)
        let remaining = PublishedKeyboard.removing(removedCurrent, from: [first, removedCurrent])

        XCTAssertEqual(
            PublishedKeyboard.selectionAfterRemoval(
                from: remaining, current: removedCurrent), first)
        XCTAssertEqual(
            PublishedKeyboard.selectionAfterRemoval(
                from: remaining, current: nil), first)
        XCTAssertNil(PublishedKeyboard.selectionAfterRemoval(from: [], current: removedCurrent))
    }

    /// Add/delete several keyboards in sequence + registry integrity: adding a second item must not drop the first.
    func testMultiKeyboardAddRemoveKeepsRegistryComplete() {
        let a = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let b = PublishedKeyboard(schemaID: "mspy", layout: .phone9)
        let c = PublishedKeyboard(schemaID: "shape", layout: .merged14)
        var list: [PublishedKeyboard] = []
        // Each step generates tasks from the "full published compact set after the transaction"; the second item cannot push out the first.
        for keyboard in [a, b, c] {
            list = PublishedKeyboard.adding(keyboard, to: list)
            XCTAssertEqual(
                Set(PublishedKeyboard.generationTasks(for: list)), Set(list),
                "the generated tasks must cover the full published compact set")
        }
        XCTAssertEqual(list, [a, b, c])

        // Delete b: the generated tasks still cover the remaining set (without b).
        list = PublishedKeyboard.removing(b, from: list)
        XCTAssertEqual(Set(PublishedKeyboard.generationTasks(for: list)), Set([a, c]))
        XCTAssertFalse(PublishedKeyboard.generationTasks(for: list).contains(b))

        // Delete a: only c remains.
        list = PublishedKeyboard.removing(a, from: list)
        XCTAssertEqual(PublishedKeyboard.generationTasks(for: list), [c])

        // Delete the last item: empty.
        list = PublishedKeyboard.removing(c, from: list)
        XCTAssertTrue(PublishedKeyboard.generationTasks(for: list).isEmpty)
    }

    // MARK: - 3) Roster resolution (never invent)

    func testRosterIsTheRecordedListOnly() {
        XCTAssertEqual(PublishedKeyboard.resolve(published: []), [])
        XCTAssertEqual(PublishedKeyboard.resolve(published: nil), [])
        let list = [PublishedKeyboard(schemaID: "mspy", layout: .merged14)]
        XCTAssertEqual(PublishedKeyboard.resolve(published: list), list)
        XCTAssertEqual(PublishedKeyboard.resolve(published: list + list), list)
    }

    // MARK: - 4) The extension shows only the added roster (structured runnable)

    func testEmptyPublishedListYieldsNoCombinations() throws {
        let restricted = set(build: try makeBuild(engineSchemas: ["mspy"]))
            .restricted(toPublished: [])
        XCTAssertTrue(
            restricted.availableCombinations.isEmpty,
            "no keyboards added = no combination is offered and none is discovered on its own")
        XCTAssertTrue(restricted.availableLayouts.isEmpty)
    }

    /// A compact layout missing a structured adapter -> not runnable, and **never** falls back to the source's 26-key.
    func testCompactWithoutAdapterIsNotRunnableAndNeverFallsBackToSource() throws {
        // Only the source schema's compiled artifact exists, with no 14-key adapter and no binding.
        let build = try makeBuild(engineSchemas: ["mspy"])
        let keyboard = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let set = set(build: build)
        XCTAssertTrue(
            set.unrunnablePublished([keyboard]).contains(keyboard),
            "a compact keyboard missing a structured adapter must be judged unrunnable")
        let restricted = set.restricted(toPublished: [keyboard])
        XCTAssertTrue(
            restricted.availableCombinations.isEmpty,
            "an unrunnable compact keyboard must not be exposed")
        XCTAssertNil(
            restricted.schemaID(for: .merged14),
            "must never fall back to the source's 26-key")
    }

    /// The adapter exists but the engine schema's compiled artifact is missing -> still not runnable (never exposed).
    func testCompactWithAdapterButMissingEngineSchemaIsNotRunnable() throws {
        let build = try makeBuild(
            engineSchemas: ["mspy"],  // mspy_14 missing
            adapters: [.init(sourceSchemaID: "mspy", schemaID: "mspy_14", layout: .merged14)])
        let keyboard = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let set = set(build: build)
        XCTAssertTrue(set.unrunnablePublished([keyboard]).contains(keyboard))
        XCTAssertTrue(set.restricted(toPublished: [keyboard]).availableCombinations.isEmpty)
    }

    /// A structured adapter + a real engine schema -> runnable, mapped to the adapter's engine schema.
    func testCompactWithAdapterAndEngineSchemaIsRunnable() throws {
        let build = try makeBuild(
            engineSchemas: ["mspy", "mspy_14"],
            adapters: [.init(sourceSchemaID: "mspy", schemaID: "mspy_14", layout: .merged14)])
        let keyboard = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let set = set(build: build)
        XCTAssertTrue(set.unrunnablePublished([keyboard]).isEmpty)
        let restricted = set.restricted(toPublished: [keyboard])
        XCTAssertEqual(restricted.availableCombinations.map(\.id), ["mspy:merged14"])
        XCTAssertEqual(
            restricted.schemaID(for: .merged14), "mspy_14",
            "an added combination maps to the generated and verified engine schema")
    }

    /// An author binding (without a generated adapter) also counts as a structured capability, and the engine schema must have a compiled artifact.
    func testAuthorBindingIsStructuralButRequiresEngineSchema() throws {
        let build = try makeBuild(engineSchemas: ["author_double"])  // no adapter
        let bound = KeyboardResourceSet(
            id: "pkg", name: "通用来源", sharedDirectory: shared,
            userDirectory: user,
            layoutEntries: [.init(layout: .merged14, schemaID: "author_double")],
            prebuiltDirectory: build,
            schemas: [
                KeyboardSchemaDescriptor(
                    id: "author_double", name: "通用双拼",
                    alphabet: "abcdefghijklmnopqrstuvwxyz")
            ],
            selectedSchemaID: "author_double")
        let keyboard = PublishedKeyboard(schemaID: "author_double", layout: .merged14)
        let restricted = bound.restricted(toPublished: [keyboard])
        XCTAssertEqual(restricted.availableCombinations.map(\.id), ["author_double:merged14"])
        XCTAssertEqual(restricted.schemaID(for: .merged14), "author_double")
    }

    /// A 26-key layout (full pinyin / double-pinyin hint) can use the source schema directly as long as the compiled artifact exists.
    func testTwentySixKeyUsesSourceDirectly() throws {
        let set = set(build: try makeBuild(engineSchemas: ["mspy"]))
        let restricted = set.restricted(toPublished: [
            PublishedKeyboard(schemaID: "mspy", layout: .qwerty26)
        ])
        XCTAssertEqual(restricted.availableCombinations.map(\.id), ["mspy:qwerty26"])
        XCTAssertEqual(
            restricted.schemaID(for: .qwerty26), "mspy",
            "26-key uses the source schema directly")
    }

    /// A compact layout not added does not appear; another input method does not appear either (a restricted roster is an exact set).
    func testOnlyPublishedPairsAreExposed() throws {
        let build = try makeBuild(
            engineSchemas: ["mspy", "mspy_14"],
            adapters: [.init(sourceSchemaID: "mspy", schemaID: "mspy_14", layout: .merged14)])
        let set = set(build: build)
        let one = set.restricted(toPublished: [
            PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        ])
        XCTAssertEqual(one.availableCombinations.map(\.id), ["mspy:merged14"])
        XCTAssertFalse(one.availableCombinations.contains { $0.schemaID == "mspy" && $0.layout == .phone9 })
        XCTAssertFalse(one.availableCombinations.contains { $0.schemaID == "shape" })
    }

    func testEnglishCandidateRouteRequiresPublishedOwnerAndSameGenerationEnabledBuild() throws {
        let owner = PublishedKeyboard(schemaID: "generic_input", layout: .qwerty26)
        let route = EnglishCandidateRoute(owner: owner, candidateSchemaID: "generic_english")
        let build = try makeBuild(engineSchemas: ["generic_input", "generic_english"])
        defer { try? FileManager.default.removeItem(at: build) }
        let schemas = [
            KeyboardSchemaDescriptor(id: "generic_input", name: "Generic input"),
            KeyboardSchemaDescriptor(id: "generic_english", name: "English candidates"),
        ]
        let resource = KeyboardResourceSet(
            id: "published", name: "Generic source",
            sharedDirectory: shared, userDirectory: user, layoutEntries: [],
            prebuiltDirectory: build, schemas: schemas, selectedSchemaID: owner.schemaID,
            publicationGeneration: "generation-1", publishedKeyboards: [owner],
            englishCandidateRoutes: [route])

        XCTAssertEqual(resource.runnableEnglishCandidateRoutes(forPublished: [owner]), [route])
        XCTAssertEqual(resource.restricted(toPublished: [owner]).englishCandidateRoutes, [route])
        XCTAssertEqual(
            resource.availableCombinations.map(\.id), [owner.id],
            "The auxiliary schema must not become an addable keyboard")
        XCTAssertEqual(resource.inputSchemeChoices.map(\.id), [owner.schemaID])
        XCTAssertEqual(resource.selecting(schemaID: route.candidateSchemaID).selectedSchemaID, owner.schemaID)

        let selectedAuxiliary = KeyboardResourceSet(
            id: "published", name: "Generic source",
            sharedDirectory: shared, userDirectory: user, layoutEntries: [],
            prebuiltDirectory: build, schemas: schemas, selectedSchemaID: route.candidateSchemaID,
            publicationGeneration: "generation-1", publishedKeyboards: [owner],
            englishCandidateRoutes: [route])
        XCTAssertTrue(
            selectedAuxiliary.runnableEnglishCandidateRoutes(forPublished: [owner]).isEmpty)

        let wrongOwner = PublishedKeyboard(schemaID: owner.schemaID, layout: .phone9)
        XCTAssertTrue(
            resource.runnableEnglishCandidateRoutes(forPublished: [wrongOwner]).isEmpty,
            "Ownership includes both source schema and layout")

        let dependencyOnly = KeyboardResourceSet(
            id: "published", name: "Generic source",
            sharedDirectory: shared, userDirectory: user, layoutEntries: [],
            prebuiltDirectory: build, schemas: [schemas[0]], selectedSchemaID: owner.schemaID,
            publicationGeneration: "generation-1", publishedKeyboards: [owner],
            englishCandidateRoutes: [route])
        XCTAssertTrue(
            dependencyOnly.runnableEnglishCandidateRoutes(forPublished: [owner]).isEmpty,
            "A compiled dependency is not enabled-schema authority")

        let noGeneration = KeyboardResourceSet(
            id: "unpublished", name: "Generic source",
            sharedDirectory: shared, userDirectory: user, layoutEntries: [],
            prebuiltDirectory: build, schemas: schemas, selectedSchemaID: owner.schemaID,
            publishedKeyboards: [owner], englishCandidateRoutes: [route])
        XCTAssertTrue(noGeneration.runnableEnglishCandidateRoutes(forPublished: [owner]).isEmpty)

        let missingTargetBuild = try makeBuild(engineSchemas: ["generic_input"])
        defer { try? FileManager.default.removeItem(at: missingTargetBuild) }
        let missingTarget = KeyboardResourceSet(
            id: "published", name: "Generic source",
            sharedDirectory: shared, userDirectory: user, layoutEntries: [],
            prebuiltDirectory: missingTargetBuild, schemas: schemas, selectedSchemaID: owner.schemaID,
            publicationGeneration: "generation-1", publishedKeyboards: [owner],
            englishCandidateRoutes: [route])
        XCTAssertTrue(
            missingTarget.runnableEnglishCandidateRoutes(forPublished: [owner]).isEmpty,
            "Enabled metadata without this generation's compiled target is insufficient")
    }

    func testEnglishCandidateRouteRoundTripsWithoutChangingKeyboardIdentity() throws {
        let owner = PublishedKeyboard(schemaID: "generic_input", layout: .merged14)
        let route = EnglishCandidateRoute(owner: owner, candidateSchemaID: "generic_english")
        let decoded = try JSONDecoder().decode(EnglishCandidateRoute.self, from: JSONEncoder().encode(route))
        let oldKeyboard = try JSONDecoder().decode(
            PublishedKeyboard.self,
            from: Data(#"{"schemaID":"generic_input","layout":"merged14"}"#.utf8))

        XCTAssertEqual(decoded, route)
        XCTAssertEqual(decoded.id, owner.id)
        XCTAssertEqual(oldKeyboard, owner, "Legacy published keyboard identity remains schema × layout")
    }

    /// 26-key implicit alphabet inference is turned off under a restricted roster: a 26-key combination not added does not appear either.
    func testRestrictedClosesImplicitTwentySixInference() throws {
        let set = set(build: try makeBuild(engineSchemas: ["mspy"]))
        let restricted = set.restricted(toPublished: [
            PublishedKeyboard(schemaID: "mspy", layout: .qwerty26)
        ])
        XCTAssertEqual(
            restricted.availableCombinations.map(\.id), ["mspy:qwerty26"],
            "only the explicitly added 26-key is kept; no other combination is inferred from the alphabet")
    }

    // MARK: - 5) Human projection (names come from structured schemas, not persisted)

    func testProjectionNameComesFromStructuredSchemas() {
        let keyboard = PublishedKeyboard(schemaID: "mspy", layout: .merged14)
        let named = PublishedKeyboard.display(
            keyboard,
            in: [
                KeyboardSchemaDescriptor(id: "mspy", name: "通用双拼")
            ])
        XCTAssertEqual(named.inputMethodName, "通用双拼")
        XCTAssertEqual(named.title, "通用双拼 · 14 键")
        // No structured name -> show only the layout name, never leak an internal id.
        let unnamed = PublishedKeyboard.display(keyboard, in: [])
        XCTAssertEqual(unnamed.inputMethodName, "")
        XCTAssertEqual(unnamed.title, "14 键")
        XCTAssertFalse(unnamed.title.contains("mspy"))

        // Even when a descriptor exists, an empty name or a name equal to the id must not be used as user-facing text.
        for descriptor in [
            KeyboardSchemaDescriptor(id: "opaque.schema_42", name: ""),
            KeyboardSchemaDescriptor(id: "opaque.schema_42", name: "opaque.schema_42"),
        ] {
            let opaque = PublishedKeyboard.display(
                PublishedKeyboard(schemaID: descriptor.id, layout: .merged14),
                in: [descriptor])
            XCTAssertEqual(opaque.inputMethodName, "")
            XCTAssertEqual(opaque.title, "14 键")
            XCTAssertFalse(opaque.title.contains(descriptor.id))
        }
    }

    /// The projection resolves names from the snapshot's structured `schemas` (following source renames automatically) and contains only runnable items.
    func testPublishedDisplaysUseSnapshotNamesAndDropUnrunnable() throws {
        let build = try makeBuild(
            engineSchemas: ["mspy", "mspy_14"],
            adapters: [.init(sourceSchemaID: "mspy", schemaID: "mspy_14", layout: .merged14)])
        let set = KeyboardResourceSet(
            id: "pkg", name: "通用来源", sharedDirectory: shared,
            userDirectory: user, layoutEntries: [], prebuiltDirectory: build,
            schemas: [
                KeyboardSchemaDescriptor(
                    id: "mspy", name: "通用双拼",
                    alphabet: "abcdefghijklmnopqrstuvwxyz")
            ],
            selectedSchemaID: "mspy")
        let displays = set.publishedDisplays([
            PublishedKeyboard(schemaID: "mspy", layout: .merged14),
            PublishedKeyboard(schemaID: "missing", layout: .phone9),
        ])
        XCTAssertEqual(displays.map(\.title), ["通用双拼 · 14 键"])
    }

    func testRestrictedRuntimeCombinationNeverLeaksOpaqueSchemaID() throws {
        let build = try makeBuild(
            engineSchemas: ["opaque.schema_42", "opaque_14"],
            adapters: [
                .init(
                    sourceSchemaID: "opaque.schema_42", schemaID: "opaque_14",
                    layout: .merged14, schemaName: "opaque_14")
            ])
        let resource = KeyboardResourceSet(
            id: "pkg", name: "来源", sharedDirectory: shared, userDirectory: user,
            layoutEntries: [], prebuiltDirectory: build,
            schemas: [
                KeyboardSchemaDescriptor(
                    id: "opaque.schema_42", name: "opaque.schema_42",
                    alphabet: "abcdefghijklmnopqrstuvwxyz")
            ],
            selectedSchemaID: "opaque.schema_42",
            publishedKeyboards: [PublishedKeyboard(schemaID: "opaque.schema_42", layout: .merged14)])
        let combination = try XCTUnwrap(resource.availableCombinations.first)
        XCTAssertEqual(combination.name, "")

        let roster = UserKeyboardRoster.runnable(
            [
                UserKeyboard(
                    inputMethodID: "opaque.schema_42", inputMethodName: "",
                    layout: .merged14)
            ],
            combinations: resource.availableCombinations)
        XCTAssertEqual(roster.map(\.title), ["14 键"])
        XCTAssertFalse(roster[0].title.contains("opaque.schema_42"))
        XCTAssertFalse(roster[0].title.contains("opaque_14"))
    }

    // MARK: - 6) End-to-end publication roster lifecycle (generic fixture, nothing hardcoded)

    func testGenericFixtureLifecycleAddExposeRemove() throws {
        let build = try makeBuild(
            engineSchemas: [
                "generic_double", "generic_double_14",
                "generic_double_9",
            ],
            adapters: [
                .init(sourceSchemaID: "generic_double", schemaID: "generic_double_14", layout: .merged14),
                .init(sourceSchemaID: "generic_double", schemaID: "generic_double_9", layout: .phone9),
            ])
        func set() -> KeyboardResourceSet {
            KeyboardResourceSet(
                id: "pkg", name: "通用来源", sharedDirectory: shared,
                userDirectory: user, layoutEntries: [], prebuiltDirectory: build,
                schemas: [
                    KeyboardSchemaDescriptor(
                        id: "generic_double", name: "通用双拼",
                        alphabet: "abcdefghijklmnopqrstuvwxyz")
                ],
                selectedSchemaID: "generic_double")
        }
        // Not added: no combination is exposed (nothing generated/published).
        XCTAssertTrue(set().restricted(toPublished: []).availableCombinations.isEmpty)

        let added14 = PublishedKeyboard(schemaID: "generic_double", layout: .merged14)
        var list = PublishedKeyboard.adding(added14, to: [])
        XCTAssertEqual(
            set().restricted(toPublished: list).availableCombinations.map(\.id),
            ["generic_double:merged14"])

        let added9 = PublishedKeyboard(schemaID: "generic_double", layout: .phone9)
        list = PublishedKeyboard.adding(added9, to: list)
        XCTAssertEqual(
            set().restricted(toPublished: list).availableCombinations.map(\.id),
            ["generic_double:merged14", "generic_double:phone9"])

        list = PublishedKeyboard.removing(added14, from: list)
        XCTAssertEqual(list, [added9])
        XCTAssertEqual(
            set().restricted(toPublished: list).availableCombinations.map(\.id),
            ["generic_double:phone9"])

        list = PublishedKeyboard.removing(added9, from: list)
        XCTAssertTrue(list.isEmpty)
        XCTAssertTrue(set().restricted(toPublished: list).availableCombinations.isEmpty)
    }
}
