import Foundation

func pruneChecks(_ base: URL) throws {
    let root = base.appendingPathComponent("store")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let activeURL = root.appendingPathComponent("active.json")
    let source = KeyboardPublicationSource.userScheme(packageID: "pkg-a")
    let keyboards = [
        PublishedKeyboard(schemaID: "shared", layout: .qwerty26),
        PublishedKeyboard(schemaID: "only-a", layout: .phone9),
    ]
    let original = KeyboardRecipeStore.Activation(
        generation: "g1", revision: "r1", recipeEnabled: false, publishedAt: Date(),
        resourceKind: .userScheme, packageID: "pkg-a",
        schemas: [
            KeyboardSchemaDescriptor(id: "shared", name: "Shared"),
            KeyboardSchemaDescriptor(id: "only-a", name: "Only A"),
        ],
        selectedSchemaID: "shared", selectedLayout: .qwerty26,
        publishedKeyboards: keyboards)
    try JSONEncoder().encode(original).write(to: activeURL, options: .atomic)

    // Partial prune and stale CAS are exercised by publicationChecks.
    let (result, updated) = try KeyboardRecipeStore.prunePublishedKeyboards(
        expected: original, deletingSource: source,
        deletedSchemaIDs: ["shared", "only-a"], rootURL: root)
    let after = try KeyboardRecipeStore.activation(rootURL: root)!
    precondition(result.removed == keyboards && after.keyboards.isEmpty)
    precondition(after.selectedSchemaID == nil && updated == after)
    try KeyboardRecipeStore.restorePublishedKeyboards(original, expectingCurrent: after, rootURL: root)
    let restored = try KeyboardRecipeStore.activation(rootURL: root)!
    precondition(restored == original)

    print("PASS: empty-list prune and exact rollback")
}
