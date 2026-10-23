import XCTest
import ZIPFoundation

@testable import PackageManager

final class ImportModelNamespaceTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-namespace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private var schema: Data { Data("schema: {schema_id: main, name: Main}\n".utf8) }
    private var database: Data {
        var data = Data(repeating: 0, count: 84)
        let format = Data("Rime::Predict/1.0".utf8)
        data.replaceSubrange(0..<format.count, with: format)
        data[36] = 16
        data[40] = 4  // key table starts at 52, contains four units
        data[44] = 24
        data[48] = 16  // value table starts at 68
        return data
    }

    private func zip(_ url: URL, files: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in files {
            try archive.addEntry(
                with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate
            ) { offset, count in
                bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
    }

    func testCatalogRoundTripKeepsNamespacedRootDatabaseAsFileResource() throws {
        let root = try directory(), model = root.appendingPathComponent("predict.db")
        try database.write(to: model)
        let resource = try RecipeFileResource.reference(at: model)
        let recipeBytes = Data("recipe:\n  description: prediction\ninstall_files:\n  - predict.db\n".utf8)
        let plan = try DeclarativeRecipePlan(
            recipe: DeclarativeRecipe(path: "recipe.yaml", source: recipeBytes),
            packageReference: "owner/repo", selectedRecipe: "", arguments: [],
            packageFiles: ["recipe.yaml": recipeBytes],
            existingFiles: [:], packageFileResources: ["predict.db": resource]
        )
        .archivingSources(prefix: "source-repositories/owner/repo/")
        let catalog = InstalledRecipeSources.merging(nil, plan: plan)
        let generation = root.appendingPathComponent("generation")
        try catalog.write(to: generation)
        let restored = try InstalledRecipeSources.read(resources: generation.appendingPathComponent("resources"))
        let path = "source-repositories/owner/repo/predict.db"
        XCTAssertNil(restored.files[path])
        XCTAssertEqual(restored.fileResources[path]?.sha256, resource.sha256)
        XCTAssertEqual(restored.fileResources[path]?.size, resource.size)
        XCTAssertEqual(restored.receipts.map(\.recipePath), ["source-repositories/owner/repo/recipe.yaml"])
        // The same physical spelling in an ordinary workspace remains a nested file.
        let ordinary = try RecipePackageManager.readRecipeWorkspaceSnapshot(
            resources: generation.appendingPathComponent("recipe-inputs"))
        XCTAssertNotNil(ordinary.files[path])
        XCTAssertNil(ordinary.fileResources[path])
    }

    func testSourceNamespaceBudgetDoesNotFlattenNestedOrUnsafePaths() throws {
        let logical = RecipeResourceBudget.sourceArchiveLogicalPath
        let large = RecipeResourceBudget.sourceFile + 1
        XCTAssertNoThrow(
            try RecipeResourceBudget.validate(
                ["source-repositories/owner/repo/predict.db": large], logicalPath: logical))
        XCTAssertThrowsError(
            try RecipeResourceBudget.validate(
                ["source-repositories/owner/repo/lua/predict.db": large], logicalPath: logical))
        XCTAssertThrowsError(
            try RecipeResourceBudget.validate(["source-repositories/owner/../predict.db": large], logicalPath: logical))
        XCTAssertThrowsError(
            try RecipeResourceBudget.validate(
                [
                    "source-repositories/a/one/predict.db": RecipeResourceBudget.modelFile,
                    "source-repositories/b/two/predict.db": RecipeResourceBudget.modelFile,
                    "source-repositories/c/three/predict.db": 1,
                ], logicalPath: logical), "logical-name collisions across repositories must not erase budget entries")
    }

    func testWrapperAndFinderMetadataPreserveRootDatabaseClassification() throws {
        let root = try directory()
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        for prefix in ["", "repo/"] {
            let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
            // No explicit directory entries: common GitHub archives are handled too.
            try zip(
                archive,
                files: [
                    (prefix + "main.schema.yaml", schema), (prefix + "predict.db", database),
                    ("__MACOSX/repo/._predict.db", Data([1])), (prefix + ".DS_Store", Data([2])),
                ])
            let prepared = try manager.prepareSchemeArchive(archive)
            XCTAssertNotNil(prepared.fileResources["predict.db"])
            XCTAssertNil(prepared.sourceFiles["predict.db"])
            XCTAssertEqual(prepared.fileResources["predict.db"]?.size, database.count)
        }
        let single = root.appendingPathComponent("single.zip")
        try zip(single, files: [("main.schema.yaml", schema)])
        XCTAssertEqual(try manager.prepareSchemeArchive(single).schemaIDs, ["main"])
    }

    func testWrappedDatabaseLargerThanSourceBudgetUsesDiskModelBudget() throws {
        let root = try directory(), url = root.appendingPathComponent("large.zip")
        let archive = try Archive(url: url, accessMode: .create)
        let schema = self.schema, header = database
        try archive.addEntry(with: "repo/main.schema.yaml", type: .file, uncompressedSize: Int64(schema.count)) {
            offset, count in
            schema.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let size = RecipeResourceBudget.sourceFile + 1
        // Stream a compressible fixture in small chunks; never allocate a 128 MiB Data.
        try archive.addEntry(
            with: "repo/predict.db", type: .file, uncompressedSize: Int64(size), compressionMethod: .deflate
        ) { offset, count in
            var chunk = Data(repeating: 0, count: count)
            if offset < header.count {
                let length = min(count, header.count - Int(offset))
                chunk.replaceSubrange(0..<length, with: header[Int(offset)..<(Int(offset) + length)])
            }
            return chunk
        }
        let prepared = try RecipePackageManager(rootURL: root.appendingPathComponent("store")).prepareSchemeArchive(url)
        XCTAssertEqual(prepared.fileResources["predict.db"]?.size, size)
        XCTAssertNil(prepared.sourceFiles["predict.db"])
    }

    func testZIPPhysicalTraversalAndCaseDuplicatesRemainRejected() throws {
        let root = try directory(), manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        for paths in [["../main.schema.yaml"], ["repo/main.schema.yaml", "repo/MAIN.schema.yaml"]] {
            let archive = root.appendingPathComponent(UUID().uuidString + ".zip")
            try zip(archive, files: paths.map { ($0, schema) })
            XCTAssertThrowsError(try manager.prepareSchemeArchive(archive))
        }
    }
}
