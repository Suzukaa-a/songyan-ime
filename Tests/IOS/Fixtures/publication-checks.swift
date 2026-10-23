import Foundation

func publicationChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for d in [root, resources, build] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
    }
    func check(_ condition: Bool, _ message: String) { precondition(condition, "CHECK FAILED: " + message) }
    func expectFailure(_ action: () throws -> Void) {
        do {
            try action()
            fatalError("expected failure did not occur")
        } catch {}
    }

    // Deployed build fixture: four schemas with compiled configs and one schema_list.
    try Data(
        "schema_list:\n  - schema: rime_ice\n  - schema: double_pinyin_flypy\n  - schema: luna_pinyin\n  - schema: stroke\n"
            .utf8
    )
    .write(to: build.appendingPathComponent("default.yaml"))
    for s in ["rime_ice", "double_pinyin_flypy", "luna_pinyin", "stroke"] {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(s).schema.yaml"))
    }
    let schemas = [
        KeyboardSchemaDescriptor(id: "rime_ice", name: "通用全拼", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "double_pinyin_flypy", name: "通用双拼", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "luna_pinyin", name: "朙月拼音", alphabet: "abcdefghijklmnopqrstuvwxyz"),
        KeyboardSchemaDescriptor(id: "stroke", name: "笔画", alphabet: "abcdefghijklmnopqrstuvwxyz"),
    ]
    let first = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26)
    let second = PublishedKeyboard(schemaID: "double_pinyin_flypy", layout: .qwerty26)
    let kbs = [first, second]

    // Publish a real multi-item publication (two 26-key keyboards need no adapter).
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "multi",
        rootURL: root, kind: .userScheme, packageID: "pkg-m", schemas: schemas, selectedSchemaID: first.schemaID,
        layout: first.layout,
        publishedKeyboards: kbs)
    let before = try KeyboardRecipeStore.activation(rootURL: root)!
    check(before.publishedKeyboards == kbs, "explicit multi-item list persisted")
    check(before.keyboards == kbs, "keyboards projection equals explicit list")

    // Builtin OFF then ON must preserve the full list AND every publication field.
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    let off = try KeyboardRecipeStore.activation(rootURL: root)!
    check(off.recipeEnabled == false, "builtin OFF disabled")
    check(off.publishedKeyboards == kbs, "builtin OFF preserves explicit list field")
    check(off.keyboards == kbs, "builtin OFF preserves multi-item projection")
    try KeyboardRecipeStore.setEnabled(true, rootURL: root)
    let on = try KeyboardRecipeStore.activation(rootURL: root)!
    check(on.recipeEnabled == true, "builtin ON enabled")
    check(on.publishedKeyboards == kbs, "builtin ON preserves explicit list field")
    check(on.keyboards == kbs, "builtin ON preserves multi-item projection")
    check(
        on.generation == before.generation && on.revision == before.revision,
        "setEnabled preserves generation/revision")
    check(
        on.schemas == before.schemas && on.dictionaryName == before.dictionaryName
            && on.packageID == before.packageID,
        "setEnabled preserves schemas and source identity")
    check(
        on.selectedSchemaID == before.selectedSchemaID && on.selectedLayout == before.selectedLayout,
        "setEnabled preserves selection")

    // Removing one item republishes exactly the remaining items.
    let remaining = PublishedKeyboard.removing(first, from: kbs)
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "multi2",
        rootURL: root, kind: .userScheme, packageID: "pkg-m", schemas: schemas, selectedSchemaID: second.schemaID,
        layout: second.layout,
        publishedKeyboards: remaining)
    let afterRemove = try KeyboardRecipeStore.activation(rootURL: root)!
    check(afterRemove.keyboards == [second], "removal keeps exactly the remaining item")
    check(afterRemove.publishedKeyboards == [second], "removal rewrote the explicit list")

    // Safety net: a published compact keyboard without a generated adapter blocks publish.
    let compact = PublishedKeyboard(schemaID: "double_pinyin_flypy", layout: .merged14)
    expectFailure {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: build, revision: "missing-adapter",
            rootURL: root, kind: .userScheme, packageID: "pkg-m", schemas: schemas, selectedSchemaID: compact.schemaID,
            layout: compact.layout,
            publishedKeyboards: [compact])
    }
    check(
        try KeyboardRecipeStore.activation(rootURL: root)!.keyboards == [second],
        "failed publish (missing adapter) leaves the previous publication untouched")

    // --- provenance prune / restore (CAS) with a userScheme publication -------------
    let pkgs = [
        PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26),
        PublishedKeyboard(schemaID: "double_pinyin_flypy", layout: .qwerty26),
    ]
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "pkg-a",
        rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
        selectedSchemaID: "rime_ice", layout: .qwerty26, publishedKeyboards: pkgs)
    let pubA = try KeyboardRecipeStore.activation(rootURL: root)!
    check(pubA.publicationSource == .userScheme(packageID: "pkg-a"), "structured provenance stored")

    // Different source identity: never prune by schema string.
    let (crossResult, crossUpdated) = try KeyboardRecipeStore.prunePublishedKeyboards(
        expected: pubA, deletingSource: .userScheme(packageID: "pkg-b"),
        deletedSchemaIDs: ["rime_ice"], rootURL: root)
    check(
        crossResult.retained == pkgs && crossUpdated == nil,
        "another source's same-named schema is NOT pruned")

    // Same source identity: prune that source's schemas atomically.
    let (pruneResult, pruneUpdated) = try KeyboardRecipeStore.prunePublishedKeyboards(
        expected: pubA, deletingSource: .userScheme(packageID: "pkg-a"),
        deletedSchemaIDs: ["rime_ice"], rootURL: root)
    check(pruneResult.removed == [pkgs[0]] && pruneUpdated != nil, "same source pruned")
    let afterPrune = try KeyboardRecipeStore.activation(rootURL: root)!
    check(afterPrune.keyboards == [pkgs[1]], "prune persisted remaining list")
    check(afterPrune.selectedSchemaID == pkgs[1].schemaID, "selection follows the retained item")

    // CAS: a stale expectation must be refused.
    expectFailure {
        _ = try KeyboardRecipeStore.prunePublishedKeyboards(
            expected: pubA, deletingSource: .userScheme(packageID: "pkg-a"),
            deletedSchemaIDs: ["double_pinyin_flypy"], rootURL: root)
    }
    check(
        try KeyboardRecipeStore.activation(rootURL: root)!.keyboards == [pkgs[1]],
        "refused prune leaves the record untouched")

    // Restore is CAS too: wrong expectation refused, correct expectation reverts the list.
    expectFailure {
        try KeyboardRecipeStore.restorePublishedKeyboards(pubA, expectingCurrent: pubA, rootURL: root)
    }
    try KeyboardRecipeStore.restorePublishedKeyboards(pubA, expectingCurrent: afterPrune, rootURL: root)
    check(
        try KeyboardRecipeStore.activation(rootURL: root)!.keyboards == pkgs,
        "restore round-trip recovers the original list")

    // --- Cross-source persistence: A four items -> B one item -> back to A still four items ---------
    // All four items use the generic 26-key composition; Flypy26 needs an explicit author binding or adapter.
    let a1 = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26)
    let a2 = PublishedKeyboard(schemaID: "luna_pinyin", layout: .qwerty26)
    let a3 = PublishedKeyboard(schemaID: "double_pinyin_flypy", layout: .qwerty26)
    let a4 = PublishedKeyboard(schemaID: "stroke", layout: .qwerty26)
    let rosterA = [a1, a2, a3, a4]
    check(
        PublishedKeyboardRoster.merged([
            PublishedKeyboardRoster(key: "userScheme:pkg-a", keyboards: rosterA)
        ]).keyboards(forKey: "userScheme:pkg-a") == rosterA,
        "pure logic: fetches the complete roster by source key")

    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "A",
        rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
        selectedSchemaID: a1.schemaID, layout: a1.layout, publishedKeyboards: rosterA)
    let pubA4 = try KeyboardRecipeStore.activation(rootURL: root)!
    check(pubA4.keyboards == rosterA, "A's current-source roster has four items")
    check(pubA4.keyboardsBySource?["userScheme:pkg-a"] == rosterA, "A's cross-source roster is recorded by source key")

    // Switch to B and publish one item: A's full roster must be kept, and B writes only its own (never mixed in).
    let b1 = PublishedKeyboard(schemaID: "rime_ice", layout: .qwerty26)
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "B",
        rootURL: root, kind: .userScheme, packageID: "pkg-b", schemas: schemas,
        selectedSchemaID: b1.schemaID, layout: b1.layout, publishedKeyboards: [b1])
    let pubB = try KeyboardRecipeStore.activation(rootURL: root)!
    check(pubB.keyboards == [b1], "the current source writes only its own roster (A is not mixed in)")
    check(pubB.keyboardsBySource?["userScheme:pkg-a"] == rosterA, "switching to B must not drop A's four items")
    check(pubB.keyboardsBySource?["userScheme:pkg-b"] == [b1], "B's roster is recorded by source key")

    // The host takes A's authoritative baseline by source identity and appends an already existing choice: still four items, same order.
    let baselineA = pubB.keyboardsBySource?["userScheme:pkg-a"] ?? []
    check(baselineA == rosterA, "A's authoritative baseline is A's own four items")
    check(
        PublishedKeyboard.adding(a2, to: baselineA) == rosterA,
        "starting to use an existing choice on A must not compact the roster")
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "A2",
        rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
        selectedSchemaID: a2.schemaID, layout: a2.layout,
        publishedKeyboards: PublishedKeyboard.adding(a2, to: baselineA))
    let pubA2 = try KeyboardRecipeStore.activation(rootURL: root)!
    check(
        pubA2.keyboards == rosterA, "after switching back to A the current roster is still four items in the same order"
    )
    check(pubA2.keyboardsBySource?["userScheme:pkg-b"] == [b1], "switching back to A must not drop B's roster")

    let beforeBad = try KeyboardRecipeStore.activation(rootURL: root)!
    // A failed publication must not change any source's roster (compact composition missing its adapter).
    let compactBad = PublishedKeyboard(schemaID: "rime_ice", layout: .merged14)
    expectFailure {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: build, revision: "bad",
            rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
            selectedSchemaID: compactBad.schemaID, layout: compactBad.layout,
            publishedKeyboards: [compactBad])
    }
    let afterBad = try KeyboardRecipeStore.activation(rootURL: root)!
    check(
        afterBad == beforeBad,
        "a failed publication must not change the current record (including cross-source rosters)")
    check(afterBad.keyboards == rosterA, "a failed publication must not change A's four items")

    // A missing source identity (invalid package name / path-escaping identity) must not be recorded as a verifiable key; Unicode is valid.
    check(
        KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "../evil") == nil,
        "an invalid package identity must not form a source key")
    check(
        KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "a/b") == nil,
        "path separators must be rejected")
    check(
        KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "自然码") == "userScheme:自然码",
        "non-ASCII/Chinese package identities accepted by installation must be usable for source keys")
    check(
        KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: "pkg-a") == "userScheme:pkg-a",
        "a valid package identity forms a stable source key")

    // --- Deleting non-current source B: clears only B's own cache; A's flat roster and selected key are unchanged ---
    // Target state: A is the current source and B is in the cache.
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "A-curr",
        rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
        selectedSchemaID: a2.schemaID, layout: a2.layout, publishedKeyboards: rosterA)
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "B-cache",
        rootURL: root, kind: .userScheme, packageID: "pkg-b", schemas: schemas,
        selectedSchemaID: b1.schemaID, layout: b1.layout, publishedKeyboards: [b1])
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "A-curr2",
        rootURL: root, kind: .userScheme, packageID: "pkg-a", schemas: schemas,
        selectedSchemaID: a2.schemaID, layout: a2.layout, publishedKeyboards: rosterA)
    let beforeDelete = try KeyboardRecipeStore.activation(rootURL: root)!
    check(beforeDelete.publicationSource == .userScheme(packageID: "pkg-a"), "A is current")
    check(beforeDelete.keyboardsBySource?["userScheme:pkg-b"] == [b1], "B cached before delete")
    check(
        beforeDelete.keyboards == rosterA && beforeDelete.selectedSchemaID == a2.schemaID,
        "A four + A selection before delete")

    // Delete B (not the current source): clears only B's cache key.
    let (delResult, delUpdated) = try KeyboardRecipeStore.prunePublishedKeyboards(
        expected: beforeDelete, deletingSource: .userScheme(packageID: "pkg-b"),
        deletedSchemaIDs: ["rime_ice"], rootURL: root)
    check(delResult.retained == rosterA, "deleting B must not touch A's flat list")
    check(delUpdated != nil, "cache cleanup writes")
    let afterDelete = try KeyboardRecipeStore.activation(rootURL: root)!
    check(afterDelete.keyboardsBySource?["userScheme:pkg-b"] == nil, "B cache removed")
    check(afterDelete.keyboards == rosterA, "A four remain after deleting B")
    check(
        afterDelete.selectedSchemaID == a2.schemaID && afterDelete.selectedLayout == a2.layout,
        "A selection unchanged after deleting B")
    check(afterDelete.keyboardsBySource?["userScheme:pkg-a"] == rosterA, "A cache intact")
    check(afterDelete.publicationSource == .userScheme(packageID: "pkg-a"), "current source unchanged")

    // Re-import B (same ID): it does not inherit old items (the cache is gone, so the host re-enumerates from an empty baseline).
    check(
        (afterDelete.keyboardsBySource?["userScheme:pkg-b"] ?? []) == [],
        "re-imported B must not inherit old items")

    // A failed delete commit can roll back: roll afterDelete back to beforeDelete (CAS).
    try KeyboardRecipeStore.restorePublishedKeyboards(beforeDelete, expectingCurrent: afterDelete, rootURL: root)
    check(
        try KeyboardRecipeStore.activation(rootURL: root)! == beforeDelete,
        "delete rollback restores B cache intact")

    // Deleting B again when it has no cache is a no-op (nothing written to disk), and A is still unaffected.
    let (_, noChange) = try KeyboardRecipeStore.prunePublishedKeyboards(
        expected: beforeDelete, deletingSource: .userScheme(packageID: "pkg-c"),
        deletedSchemaIDs: ["rime_ice"], rootURL: root)
    check(noChange == nil, "deleting a never-cached other source is a no-op")

    // End to end: a Unicode/Chinese package identity can publish and persist its own cached roster.
    let unicodeID = "自然码"
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "U",
        rootURL: root, kind: .userScheme, packageID: unicodeID, schemas: schemas,
        selectedSchemaID: a1.schemaID, layout: a1.layout, publishedKeyboards: [a1])
    let pubUnicode = try KeyboardRecipeStore.activation(rootURL: root)!
    check(
        pubUnicode.keyboardsBySource?["userScheme:" + unicodeID] == [a1],
        "Unicode package ID persists its own roster")
    check(
        pubUnicode.keyboardsBySource?["userScheme:pkg-a"] == rosterA,
        "publishing a Unicode source keeps A's cached roster")
    check(pubUnicode.keyboards == [a1], "current source list is the Unicode source's own")

    print(
        "PASS: list preserved across builtin toggles; removal keeps remaining; missing adapter blocks publish; provenance prune/restore CAS; cross-source roster retained (A four / B one / back to A four); deleting a non-current source clears only its cache and rolls back; Unicode package IDs accepted"
    )
}
