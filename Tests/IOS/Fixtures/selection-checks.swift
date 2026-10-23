import Foundation

func selectionChecks(_ base: URL) throws {
    let fm = FileManager.default
    let root = base.appendingPathComponent("store")
    let resources = base.appendingPathComponent("resources")
    let build = base.appendingPathComponent("build")
    for directory in [root, resources, build] {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func expectFailure(_ action: () throws -> Void) {
        do {
            try action()
            fatalError("Expected failure")
        } catch {}
    }
    func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
    let activeURL = root.appendingPathComponent("active.json")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    check(try KeyboardRecipeStore.activation(rootURL: root) == nil, "builtin before install needs no record")
    expectFailure { try KeyboardRecipeStore.setEnabled(true, rootURL: root) }
    check(try KeyboardRecipeStore.activation(rootURL: root) == nil, "failed selection preserves builtin")
    func writeDefault(_ schemas: [String]) {
        let text = "schema_list:\n" + schemas.map { "  - schema: \($0)\n" }.joined()
        try! Data(text.utf8).write(to: build.appendingPathComponent("default.yaml"))
    }
    for schema in ["rime_ice", "double_pinyin_flypy"] {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(schema).schema.yaml"))
    }
    writeDefault(["rime_ice", "double_pinyin_flypy"])
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "fixture", rootURL: root,
        kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)  // keyboard chooses builtin
    check(try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) == nil, "builtin route")
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "new", rootURL: root,
        kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice")  // host applies
    check(
        try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true)?.activation.revision == "new",
        "host overrides keyboard selection")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    try KeyboardRecipeStore.setEnabled(true, rootURL: root)  // keyboard chooses recipe itself
    check(
        try KeyboardRecipeStore.activation(rootURL: root)?.recipeEnabled == true, "keyboard selection shared with host")
    let saved = try Data(contentsOf: activeURL)
    expectFailure {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: resources, revision: "broken", rootURL: root,
            kind: .userScheme, packageID: "pkg-a", selectedSchemaID: "rime_ice")
    }
    check(try Data(contentsOf: activeURL) == saved, "failed publication preserves selection and generation")
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
    expectFailure { try KeyboardRecipeStore.setEnabled(false, rootURL: root) }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
    check(try Data(contentsOf: activeURL) == saved, "write failure preserves exact successful selection")
    let snapshot = try KeyboardRecipeStore.snapshot(rootURL: root)!
    try fm.moveItem(at: snapshot.build, to: base.appendingPathComponent("unavailable-build"))
    expectFailure { _ = try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) }
    check(try Data(contentsOf: activeURL) == saved, "resource fallback must not write selection")
    check(
        try KeyboardRecipeStore.activation(rootURL: root)?.recipeEnabled == true,
        "host still reports saved recipe despite resource failure")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    check(
        try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) == nil,
        "builtin works despite damaged recipe resources")
    // A record without a source kind is not a usable publication: reading it fails, so the
    // keyboard falls back to built-in pinyin through the normal error path.
    var unkinded = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
    unkinded.removeValue(forKey: "resourceKind")
    try JSONSerialization.data(withJSONObject: unkinded).write(to: activeURL, options: .atomic)
    expectFailure { _ = try KeyboardRecipeStore.activation(rootURL: root) }
    expectFailure { _ = try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) }
    try saved.write(to: activeURL, options: .atomic)
    // Dictionary-import configuration: the two built-in schemes are enabled but not compiled yet => publication must fail.
    writeDefault(BuiltinTemplateSchemas.sourceSchemaIDs)
    let beforeImport = try Data(contentsOf: activeURL)
    expectFailure {
        try KeyboardRecipeStore.publish(
            resources: resources, compiledBuild: build, revision: "import", rootURL: root,
            kind: .userDictionary, dictionaryName: "测试词库")
    }
    check(try Data(contentsOf: activeURL) == beforeImport, "import cannot apply with missing compiled schemes")
    // The compact layouts come from the companions generated at install time.
    for schema in BuiltinTemplateSchemas.sourceSchemaIDs + BuiltinTemplateSchemas.adapters.map(\.schemaID) {
        try Data("schema: fixture".utf8).write(to: build.appendingPathComponent("\(schema).schema.yaml"))
    }
    try JSONEncoder().encode(BuiltinTemplateSchemas.adapters)
        .write(to: build.appendingPathComponent("keyboard-adapters.json"))
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "import", rootURL: root,
        kind: .userDictionary, dictionaryName: "测试词库")
    let imported = try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true)!
    let set = imported.resourceSet(userDirectory: base.appendingPathComponent("private-user"))
    check(set.id == "user-pinyin" && set.name == "测试词库", "typed import resource/name")
    check(set.availableLayouts == KeyboardLayoutKind.allCases, "import offers every layout")
    for layout in KeyboardLayoutKind.allCases {
        check(
            set.schemaID(for: layout) == BuiltinTemplateSchemas.defaultSchemaID(for: layout),
            "import routes to the built-in scheme")
    }
    check(set.prebuiltDirectory == imported.build, "import keeps prebuilt startup")
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    check(try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true) == nil, "builtin recovery")
    try KeyboardRecipeStore.setEnabled(true, rootURL: root)
    let reselected = try KeyboardRecipeStore.snapshot(rootURL: root, selectedOnly: true)!
    check(
        reselected.activation.kind == .userDictionary && reselected.activation.name == "测试词库",
        "reselect keeps import type")
    check(reselected.activation.generation == imported.activation.generation, "does not change applied generation")
    // A damaged record never blocks the ways out: built-in replaces it, and so does a publish.
    try Data("{ not json".utf8).write(to: activeURL, options: .atomic)
    expectFailure { _ = try KeyboardRecipeStore.activation(rootURL: root) }
    try KeyboardRecipeStore.setEnabled(false, rootURL: root)
    check(try KeyboardRecipeStore.activation(rootURL: root) == nil, "damaged record: switching to built-in replaces it")
    try Data("{ not json".utf8).write(to: activeURL, options: .atomic)
    check(try KeyboardRecipeStore.writeBaseline(rootURL: root) == nil, "damaged record reads as no baseline")
    try KeyboardRecipeStore.publish(
        resources: resources, compiledBuild: build, revision: "recovered", rootURL: root,
        kind: .userDictionary, dictionaryName: "测试词库", baseline: .absent)
    let recovered = try KeyboardRecipeStore.activation(rootURL: root)
    check(
        recovered?.revision == "recovered" && recovered?.recipeEnabled == true, "damaged record: publishing replaces it"
    )
    print(
        "PASS: shared selection, unkinded record rejected, failed save, temporary fallback, typed import four-layout route, reselect, damaged record recovery"
    )
}
