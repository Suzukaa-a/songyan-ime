import Foundation

/// The installed built-in scheme publishes like any other: 内置小鹤双拼 on the 18-key layout is
/// written by the host and read back exactly as the keyboard resolves it.
func builtinPublicationChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for d in [root, resources, build] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
    }
    func check(_ condition: Bool, _ message: String) { precondition(condition, "CHECK FAILED: " + message) }

    let quanpin = BuiltinTemplateSchemas.quanpin
    let flypy = BuiltinTemplateSchemas.flypy
    let packageID = ProductionInputAvailability.builtinPackageID
    guard
        let adapter = BuiltinTemplateSchemas.adapters.first(where: {
            $0.sourceSchemaID == flypy && $0.layout == .merged18
        })
    else { fatalError("missing 18-key companion") }
    // The installed generation: both entry schemes plus the adapter generated when the keyboard was added.
    try Data("schema_list:\n  - schema: \(quanpin)\n  - schema: \(flypy)\n".utf8)
        .write(to: build.appendingPathComponent("default.yaml"))
    for schema in [quanpin, flypy, adapter.schemaID] {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(schema).schema.yaml"))
    }
    try JSONEncoder().encode([adapter]).write(to: build.appendingPathComponent("keyboard-adapters.json"))
    let alphabet = "abcdefghijklmnopqrstuvwxyz"
    let schemas = [
        KeyboardSchemaDescriptor(id: quanpin, name: "内置全拼", alphabet: alphabet),
        KeyboardSchemaDescriptor(id: flypy, name: "内置小鹤双拼", alphabet: alphabet),
    ]
    let keyboard = PublishedKeyboard(schemaID: flypy, layout: .merged18)

    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "builtin-1",
        rootURL: root, kind: .userScheme, dictionaryName: ProductionInputAvailability.builtinDisplayName,
        packageID: packageID, schemas: schemas, selectedSchemaID: flypy, layout: .merged18,
        publishedKeyboards: [keyboard], baseline: .absent)
    guard let activation = try KeyboardRecipeStore.activation(rootURL: root) else { fatalError("no publication") }
    check(
        activation.recipeEnabled && activation.kind == .userScheme && activation.packageID == packageID,
        "built-in scheme is published as an installed scheme")
    check(activation.keyboards == [keyboard], "only the added keyboard is published")
    check(activation.displayConfigName == "内置输入方案", "published under its own name")
    check(
        !ProductionInputAvailability.isBuiltin(resourceID: activation.resourceID),
        "a published built-in scheme is not the bundled fallback")

    // The keyboard's read: the same record resolves to exactly the added keyboard, selected.
    guard
        let snapshot = try KeyboardRecipeStore.snapshot(
            selection: KeyboardRecipeStore.readSelection(rootURL: root),
            selectedOnly: true)
    else { fatalError("no snapshot") }
    let set = snapshot.resourceSet(userDirectory: base.appendingPathComponent("user"))
        .restricted(toPublished: snapshot.activation.keyboards)
    check(
        set.availableCombinations.map { "\($0.schemaID):\($0.layout.rawValue)" } == [keyboard.id],
        "the switcher lists the published keyboard only")
    check(set.availableCombinations.first?.engineSchemaID == adapter.schemaID, "18-key runs its generated adapter")
    check(set.selectedSchemaID == flypy && set.preferredLayout == .merged18, "boots on 内置小鹤双拼 · 18 键")

    // Stopping use falls back to the bundle and keeps the roster for the next use.
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    check(try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) == nil, "fallback after stopping use")
    let key = KeyboardRecipeStore.rosterKey(kind: .userScheme, packageID: packageID)
    check(
        try KeyboardRecipeStore.activation(rootURL: root)?.keyboardsBySource?[key ?? ""] == [keyboard],
        "roster kept after stopping use")
    print("PASS: built-in 小鹤双拼 · 18 键 publishes, resolves for the keyboard, and falls back when stopped")
}
