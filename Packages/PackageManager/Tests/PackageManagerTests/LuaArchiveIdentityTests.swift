import XCTest

@testable import PackageManager

/// The source archive is raw data identity: whatever bytes an install recorded must come
/// back byte-for-byte, or the recorded SHA256 can never validate. The generated Lua
/// sandbox entry is a *runtime* transformation of the published workspace, so it must not
/// be normalized away while validating the archive it was stored in.
final class LuaArchiveIdentityTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lua-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var packageRime: Data { Data("function t() end\n".utf8) }
    private var schema: Data { Data("schema: {schema_id: main, name: Main}\n".utf8) }

    /// Write a catalog whose archived rime.lua is the given bytes, then read it back.
    @discardableResult
    private func roundTrip(_ files: [String: Data], in root: URL) throws -> InstalledRecipeSources {
        let generation = root.appendingPathComponent("generation")
        try InstalledRecipeSources(files: files, fileResources: [:], receipts: []).write(to: generation)
        return try InstalledRecipeSources.read(resources: generation.appendingPathComponent("resources"))
    }

    /// A package's rime.lua is archived exactly as it was written, and one that already
    /// carries the generated entry still validates against its own recorded hash.
    func testArchiveReturnsExactBytesForBothOriginalAndGeneratedRimeLua() throws {
        let directory = try root()
        let original: [String: Data] = ["rime.lua": packageRime, "main.schema.yaml": schema]
        let restored = try roundTrip(original, in: directory)
        XCTAssertEqual(restored.files["rime.lua"], packageRime)
        XCTAssertEqual(restored.files["main.schema.yaml"], schema)
    }

    func testArchiveContainingGeneratedEntryValidatesAgainstItsOwnHash() throws {
        let directory = try root()
        let generated = LuaSandbox.wrap(packageRime)
        XCTAssertTrue(LuaSandbox.unwrap(generated) != nil, "the fixture really is a generated entry")
        // The archive holds these exact bytes; its catalog recorded their hash.
        let archived: [String: Data] = ["rime.lua": generated, "main.schema.yaml": schema]
        let restored = try roundTrip(archived, in: directory)
        XCTAssertEqual(
            restored.files["rime.lua"], generated,
            "raw archive identity must survive read-back")
        XCTAssertEqual(restored.files["main.schema.yaml"], schema)
    }

    /// An entry generated without a package script is nil on unwrap; the archive still
    /// holds its bytes rather than silently dropping the file.
    func testArchiveWithoutPackageScriptKeepsItsBytes() throws {
        let directory = try root()
        let generated = LuaSandbox.wrap(nil)
        let restored = try roundTrip(["rime.lua": generated, "main.schema.yaml": schema], in: directory)
        XCTAssertNotNil(restored.files["rime.lua"], "the archived file is not dropped")
        XCTAssertEqual(restored.files["rime.lua"], generated)
        XCTAssertNil(LuaSandbox.restoreOriginal(generated), "it is still a script-less entry")
    }

    /// The runtime workspace read is unchanged: it still presents the package's own
    /// rime.lua, never the generated prelude.
    func testRuntimeWorkspaceStillNormalizesTheGeneratedEntry() throws {
        let directory = try root()
        let workspace = directory.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try LuaSandbox.wrap(packageRime).write(to: workspace.appendingPathComponent("rime.lua"))
        try schema.write(to: workspace.appendingPathComponent("main.schema.yaml"))

        let snapshot = try RecipePackageManager.readRecipeWorkspaceSnapshot(resources: workspace)
        XCTAssertEqual(snapshot.files["rime.lua"], packageRime, "re-planning never sees the prelude")
        XCTAssertEqual(snapshot.files["main.schema.yaml"], schema)

        // A script-less entry reads back as absent in the runtime workspace.
        let empty = directory.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try LuaSandbox.wrap(nil).write(to: empty.appendingPathComponent("rime.lua"))
        let emptySnapshot = try RecipePackageManager.readRecipeWorkspaceSnapshot(resources: empty)
        XCTAssertNil(emptySnapshot.files["rime.lua"])
    }
}
