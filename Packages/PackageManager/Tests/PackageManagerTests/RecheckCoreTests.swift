import CryptoKit
import XCTest

@testable import PackageManager

final class RecheckCoreTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc-core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manifest(_ bytes: [String: Data], origin: RecipeManifest.Origin? = .userScheme) -> RecipeManifest {
        .init(
            id: "test", repository: "user/test", revision: String(repeating: "a", count: 40),
            recipePath: "a.schema.yaml", license: "test", schemaID: "a", requiredComponents: [],
            files: bytes.map {
                .init(
                    path: $0.key, sha256: SHA256.hash(data: $0.value).map { String(format: "%02x", $0) }.joined(),
                    size: $0.value.count)
            }, origin: origin)
    }
    private static func receipt(_ d: RecipeDeployment, config: String = "schema_list: [{schema: a}]") throws
        -> RecipeDeploymentReceipt
    {
        let build = d.userDataURL.appendingPathComponent("build")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: build.appendingPathComponent("default.yaml"))
        try Data("schema: {schema_id: a}\ngrammar: {language: L}".utf8).write(
            to: build.appendingPathComponent("a.schema.yaml"))
        return .init(availableComponents: [], validatedSchemaID: "a", validatedEnabledSchemaIDs: ["a"])
    }
    func testModelShadowRemovedOnlyFromNewSnapshotAndIdentityTamperingRejected() async throws {
        let root = try root(), seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        let old = Data("old-fixture".utf8), new = Data("new-good-fixture".utf8)
        try old.write(to: seed.appendingPathComponent("L.gram"))
        try Data("learned".utf8).write(to: seed.appendingPathComponent("learning.userdb.txt"))
        let bytes = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8), "L.gram": new]
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        let first = try await manager.installResources(
            manifest(bytes), initialUserDataURL: seed,
            deploy: { d in
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: d.userDataURL.appendingPathComponent("L.gram").path))
                XCTAssertEqual(try Data(contentsOf: d.resourceURL.appendingPathComponent("L.gram")), new)
                return try Self.receipt(d)
            }, read: { bytes[$0.path]! })
        let active = try await manager.activeInstallation()!
        // A newly created shadow after live verification must still fail core's identity check.
        do {
            _ = try await manager.installResources(
                manifest(bytes), initialUserDataURL: nil,
                deploy: { d in
                    let receipt = try Self.receipt(d)
                    try old.write(to: d.userDataURL.appendingPathComponent("L.gram"))
                    return receipt
                }, read: { bytes[$0.path]! })
            XCTFail("Wrong resolved identity accepted")
        } catch {}
        let status = try await manager.status()
        XCTAssertEqual(status.active?.generation, first.generation)
        XCTAssertEqual(try Data(contentsOf: seed.appendingPathComponent("L.gram")), old)
        XCTAssertEqual(
            try Data(contentsOf: active.userDataURL.appendingPathComponent("learning.userdb.txt")), Data("learned".utf8)
        )
    }
    func testDuplicateDeployedEnabledRejected() async throws {
        let bytes = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8)]
        let manager = RecipePackageManager(rootURL: try root())
        do {
            _ = try await manager.installResources(
                manifest(bytes), initialUserDataURL: nil,
                deploy: {
                    try Self.receipt($0, config: "schema_list: [{schema: a}, {schema: a}]")
                }, read: { bytes[$0.path]! })
            XCTFail("Duplicate deployed enabled accepted")
        } catch {}
        let status = try await manager.status()
        XCTAssertNil(status.active)
    }
    func testPrefetchDoesNotTouchStoreAndSnapshotUsesLatestSeedBytes() async throws {
        let root = try root(), store = root.appendingPathComponent("store"), seed = root.appendingPathComponent("seed")
        let bytes = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8), "recipe.yaml": Data(), "LICENSE": Data()]
        let manager = RecipePackageManager(rootURL: store, fetch: { bytes[$0.lastPathComponent]! })
        let prepared = try await manager.prefetch(manifest(bytes, origin: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try Data("latest learning".utf8).write(to: seed.appendingPathComponent("learning.txt"))
        _ = try await manager.installPrefetched(prepared, initialUserDataURL: seed) { d in
            XCTAssertEqual(
                try Data(contentsOf: d.userDataURL.appendingPathComponent("learning.txt")), Data("latest learning".utf8)
            )
            return try Self.receipt(d)
        }
    }
    func testPrefetchCancellationAfterFetchNeverCreatesStore() async throws {
        let store = try root().appendingPathComponent("store")
        let bytes = ["a.schema.yaml": Data("schema: {schema_id: a}".utf8), "LICENSE": Data()]
        let manager = RecipePackageManager(
            rootURL: store,
            fetch: { url in
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes[url.lastPathComponent]!
            })
        let manifest = manifest(bytes, origin: nil)
        let task = Task { try await manager.prefetch(manifest) }
        do {
            _ = try await task.value
            XCTFail("Cancelled prefetch returned frozen resources")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }
    func testLocalByteBudgetAndCancellation() async throws {
        let file = try root().appendingPathComponent("ordinary.txt")
        try Data(repeating: 1, count: 1025).write(to: file)
        XCTAssertThrowsError(try BoundedLocalFile.read(file, maximumBytes: 1024))
        XCTAssertEqual(try BoundedLocalFile.read(file, maximumBytes: 1025).count, 1025)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try BoundedLocalFile.read(file, maximumBytes: 1025)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled read accepted")
        } catch is CancellationError {}
    }

    /// Optional real-engine regression. Uses an already-built macOS harness and lawful
    /// lawful fixture; neither native code nor old build/cache artifacts are modified.
    func testNativeOldUserModelToNewValidAndNewCorrupt() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["RC_GRAMMAR_HARNESS"], let fixture = env["RC_GRAMMAR_FIXTURE"] else {
            throw XCTSkip("Set RC_GRAMMAR_HARNESS and RC_GRAMMAR_FIXTURE for native model replacement regression")
        }
        let root = try root(), fixtureURL = URL(fileURLWithPath: fixture)
        let modelPath = "wanxiang-lts-zh-hans.gram"
        let model = try RecipeFileResource.reference(
            at: fixtureURL.appendingPathComponent(modelPath).resolvingSymlinksInPath())
        // Trailing unused bytes distinguish old identity while preserving valid trie/metadata.
        let oldURL = root.appendingPathComponent("old.gram")
        try model.copy(to: oldURL, maximumBytes: RecipeResourceBudget.modelFile)
        let tail = try FileHandle(forWritingTo: oldURL)
        try tail.seekToEnd()
        try tail.write(contentsOf: Data("old-generation".utf8))
        try tail.close()
        let oldModel = try RecipeFileResource.reference(at: oldURL)
        var bytes: [String: Data] = [:]
        let fixtureFiles = FileManager.default.enumerator(
            at: fixtureURL, includingPropertiesForKeys: [.isRegularFileKey])!.allObjects
        for case let url as URL in fixtureFiles {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                bytes[String(url.path.dropFirst(fixtureURL.path.count + 1))] = try Data(contentsOf: url)
            }
        }
        bytes["default.yaml"] = Data(
            "config_version: 'rc-core'\nschema_list: [{schema: songyan_quanpin}, {schema: capability_probe}]".utf8)
        let sources = bytes
        @Sendable func native(_ shared: URL, _ user: URL, _ mode: String, _ report: URL) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [shared.path, user.path, mode, report.path]
            let log = report.appendingPathExtension("log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw RecipeInstallError.deployment("Native validator failed; evidence: \(log.path)")
            }
        }
        // Prove the OLD variant really loads, instead of labelling arbitrary bytes 'good'.
        let control = root.appendingPathComponent("old-control")
        for (path, data) in sources {
            let target = control.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        try oldModel.copy(to: control.appendingPathComponent(modelPath), maximumBytes: RecipeResourceBudget.modelFile)
        try native(
            control, root.appendingPathComponent("old-control-user"), "enabled",
            root.appendingPathComponent("old-valid.json"))
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try oldModel.copy(to: seed.appendingPathComponent(modelPath), maximumBytes: RecipeResourceBudget.modelFile)
        try Data("learning-preserved".utf8).write(to: seed.appendingPathComponent("learning.txt"))
        let manager = RecipePackageManager(rootURL: root.appendingPathComponent("store"))
        func nativeManifest(_ data: [String: Data], model: RecipeFileResource) -> RecipeManifest {
            .init(
                id: "native", repository: "user/test", revision: String(repeating: "b", count: 40),
                recipePath: "default.yaml",
                license: "fixture", schemaID: "songyan_quanpin", requiredComponents: [],
                files: data.map {
                    .init(
                        path: $0.key, sha256: SHA256.hash(data: $0.value).map { String(format: "%02x", $0) }.joined(),
                        size: $0.value.count)
                } + [.init(path: modelPath, sha256: model.sha256, size: model.size)], origin: .userScheme)
        }
        let first = try await manager.installResources(
            nativeManifest(sources, model: model), initialUserDataURL: seed,
            deploy: { d in
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: d.userDataURL.appendingPathComponent(modelPath).path))
                try native(d.resourceURL, d.userDataURL, "enabled", root.appendingPathComponent("new-valid.json"))
                return .init(
                    availableComponents: [], validatedSchemaID: "songyan_quanpin",
                    validatedEnabledSchemaIDs: ["songyan_quanpin", "capability_probe"])
            }, fileResources: [modelPath: model], read: { sources[$0.path]! })
        let previous = try await manager.activeInstallation()!
        // Model a valid user shadow added in the active generation before a subsequent update.
        try oldModel.copy(
            to: previous.userDataURL.appendingPathComponent(modelPath), maximumBytes: RecipeResourceBudget.modelFile)
        let corruptURL = root.appendingPathComponent("corrupt.gram")
        try Data("corrupt-new-model".utf8).write(to: corruptURL)
        let corrupt = try RecipeFileResource.reference(at: corruptURL)
        do {
            _ = try await manager.installResources(
                nativeManifest(sources, model: corrupt), initialUserDataURL: nil,
                deploy: { d in
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: d.userDataURL.appendingPathComponent(modelPath).path))
                    // This legacy harness only accepts fresh engine metadata. Preserve the new
                    // snapshot's installation marker under another name; old generation is untouched.
                    let marker = d.userDataURL.appendingPathComponent("installation.yaml")
                    if FileManager.default.fileExists(atPath: marker.path) {
                        try FileManager.default.moveItem(
                            at: marker, to: d.userDataURL.appendingPathComponent("retained-installation.yaml"))
                    }
                    // Harness invalid mode itself asserts current-session grammar rejection and no successful Load.
                    try native(d.resourceURL, d.userDataURL, "invalid", root.appendingPathComponent("new-corrupt.json"))
                    throw RecipeInstallError.deployment("Native current-session validator rejected corrupt model")
                }, fileResources: [modelPath: corrupt], read: { sources[$0.path]! })
            XCTFail("Corrupt replacement activated")
        } catch {}
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("new-corrupt.json").path),
            "Must reach native invalid-model validation")
        let status = try await manager.status()
        XCTAssertEqual(status.active?.generation, first.generation)
        XCTAssertEqual(
            try RecipeFileResource.reference(at: previous.userDataURL.appendingPathComponent(modelPath)).sha256,
            oldModel.sha256)
        XCTAssertEqual(
            try Data(contentsOf: previous.userDataURL.appendingPathComponent("learning.txt")),
            Data("learning-preserved".utf8))
        XCTAssertEqual(
            try RecipeFileResource.reference(at: seed.appendingPathComponent(modelPath)).sha256, oldModel.sha256)
        print("native run kept at: \(root.path)")
    }
}
