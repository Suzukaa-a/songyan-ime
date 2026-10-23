import CryptoKit
import Darwin
import Foundation

/// Runs against the shipped Simulator slice. Every fixture and user DB lives in one
/// new, exclusive scratch subtree; this harness never uses an installed app's data.
@main
struct LearningBackupMain {
    private static let dictionary = "learning_proof"
    private static let phraseA = "\u{65e5}\u{6708}"
    private static let phraseB = "\u{5c71}\u{6c34}"

    private static func require(_ condition: Bool, _ label: String) throws {
        guard condition else {
            throw NSError(
                domain: "LearningBackupProof", code: 1,
                userInfo: [NSLocalizedDescriptionKey: label])
        }
    }

    static func main() {
        setbuf(stdout, nil)
        do { try run() } catch {
            fputs("FAIL learning backup: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func freshRoot(_ argument: String) throws -> URL {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL.resolvingSymlinksInPath()
        let scratch = repository.appendingPathComponent(".scratch", isDirectory: true)
        let root = URL(fileURLWithPath: argument, isDirectory: true).standardizedFileURL
        try require(argument.hasPrefix("/"), "scratch root must be absolute")
        try require(
            scratch.resolvingSymlinksInPath() == scratch && root.deletingLastPathComponent() == scratch
                && root.resolvingSymlinksInPath() == root && root.lastPathComponent.hasPrefix("learning-backup-"),
            "use a direct new .scratch/learning-backup-<UUID> child")
        // mkdir, unlike createDirectory, rejects an existing directory atomically.
        try require(
            root.path.withCString { mkdir($0, 0o700) } == 0,
            "runtime root must not already exist")
        return root
    }

    private static func createFixture(_ shared: URL) throws {
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let files: [(String, String)] = [
            (
                "default.yaml",
                """
                config_version: '1'
                schema_list:
                  - schema: learning_proof
                  - schema: learning_late
                menu:
                  page_size: 5
                """
            ),
            (
                "learning_proof.schema.yaml",
                """
                schema:
                  schema_id: learning_proof
                  name: Learning Proof
                  version: '1'
                engine:
                  processors: [speller, selector, navigator, express_editor]
                  segmentors: [abc_segmentor, fallback_segmentor]
                  translators: [script_translator]
                  filters: [uniquifier]
                speller:
                  alphabet: abcdefghijklmnopqrstuvwxyz
                  delimiter: " '"
                  algebra: []
                translator:
                  dictionary: learning_proof
                  prism: learning_proof
                  user_dict: learning_proof
                  db_class: userdb
                  enable_user_dict: true
                  enable_completion: false
                  enable_encoder: true
                  encode_commit_history: false
                  max_phrase_length: 8
                """
            ),
            (
                "learning_proof.dict.yaml",
                """
                ---
                name: learning_proof
                version: '1'
                sort: by_weight
                use_preset_vocabulary: false
                ...
                \u{65e5}\tri\t1000
                \u{6708}\tyue\t1000
                \u{5c71}\tshan\t1000
                \u{6c34}\tshui\t1000
                """
            ),
        ]
        for (name, text) in files {
            try Data((text + "\n").utf8).write(
                to: shared.appendingPathComponent(name),
                options: [.withoutOverwriting])
            if name.hasPrefix("learning_proof.") {
                let lateName = name.replacingOccurrences(of: "learning_proof", with: "learning_late", options: .literal)
                let lateText = text.replacingOccurrences(of: "learning_proof", with: "learning_late", options: .literal)
                try Data((lateText + "\n").utf8).write(
                    to: shared.appendingPathComponent(lateName),
                    options: [.withoutOverwriting])
            }
        }
    }

    private static func hashes(_ directory: URL) throws -> [String: Data] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var enumerationFailed = false
        guard
            let iterator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: keys,
                errorHandler: { _, _ in
                    enumerationFailed = true
                    return false
                })
        else {
            throw NSError(domain: "LearningBackupProof", code: 2)
        }
        var hashes: [String: Data] = [:]
        for case let file as URL in iterator {
            let info = try file.resourceValues(forKeys: Set(keys))
            try require(
                info.isSymbolicLink != true && file.resolvingSymlinksInPath() == file.standardizedFileURL,
                "prebuilt fixture contains a symbolic link")
            if info.isDirectory == true { continue }
            try require(
                info.isRegularFile == true && (info.fileSize ?? -1) >= 0
                    && (info.fileSize ?? Int.max) <= 8 * 1_024 * 1_024 && hashes.count < 128,
                "invalid or oversized prebuilt fixture")
            try require(file.path.hasPrefix(directory.path + "/"), "prebuilt file escaped its root")
            let key = String(file.path.dropFirst(directory.path.count + 1))
            hashes[key] = Data(SHA256.hash(data: try Data(contentsOf: file)))
        }
        try require(!enumerationFailed && !hashes.isEmpty, "prebuilt enumeration incomplete")
        return hashes
    }

    private static func saveHashes(_ values: [String: Data], to file: URL) throws {
        let lines =
            values.keys.sorted().map { key in
                values[key]!.map { String(format: "%02x", $0) }.joined() + "  " + key
            }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: file, options: [.withoutOverwriting])
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: learning-backup-probe /absolute/repository/.scratch/learning-backup-FRESH_UUID")
            exit(2)
        }
        let root = try freshRoot(CommandLine.arguments[1])
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let bootstrap = root.appendingPathComponent("bootstrap", isDirectory: true)
        try createFixture(shared)
        let host = RimeEngine(
            configuration: .init(
                sharedDirectory: shared, userDirectory: bootstrap,
                appName: "rime.learning-backup-proof"))
        do {
            defer { host.shutdown() }
            try host.start()
            try require(host.selectSchema(dictionary), "fixture-only host compilation failed")
        }
        let prebuilt = bootstrap.appendingPathComponent("build", isDirectory: true)
        let originalHashes = try hashes(prebuilt)
        try saveHashes(originalHashes, to: root.appendingPathComponent("prebuilt-before.sha256"))
        print("PASS fixture compiled with real host engine, then shut down")

        func engine(_ name: String) -> RimeEngine {
            RimeEngine(
                configuration: .init(
                    sharedDirectory: shared,
                    userDirectory: root.appendingPathComponent(name, isDirectory: true),
                    appName: "rime.learning-backup-proof", prebuiltDirectory: prebuilt))
        }
        func learned(_ engine: RimeEngine, _ code: String, _ phrase: String) throws {
            try require(engine.selectSchema(dictionary), "prebuilt fixture schema unavailable")
            let result = try engine.processKeySequence(code + " ")
            try require(result.state.commitText == phrase, "real commit mismatch")
        }
        let source = engine("source")
        defer { source.shutdown() }
        try source.start()
        try learned(source, "ri'yue", phraseA)
        let snapshots = try source.backupLearningData()
        try require(
            snapshots.count == 1 && !source.isRunning,
            "backup omitted source or rebuilt an input session")
        try require(
            try RimeLearningFormat.parse(snapshots[0]).entryCount == 1,
            "new phrase absent from real source learning")
        try snapshots[0].data.write(
            to: root.appendingPathComponent("source.userdb.txt"), options: [.withoutOverwriting])
        try source.restoreLearningData(snapshots)
        source.shutdown()
        print("PASS real source backup then same-engine restore with session=0")

        let destination = engine("destination")
        defer { destination.shutdown() }
        try destination.start()
        try learned(destination, "shan'shui", phraseB)
        let before = try destination.backupLearningData()
        try require(before != snapshots, "destination must hold different learning than the source")
        let invalid = RimeLearningSnapshot(name: "other", data: Data("not a snapshot\n".utf8))
        do {
            try destination.restoreLearningData(snapshots + [invalid])
            try require(false, "partly invalid batch unexpectedly restored")
        } catch RimeLearningBackupError.invalidSnapshot {
            print("PASS whole invalid batch rejected before native restore")
        }
        try require(try destination.backupLearningData() == before, "invalid batch changed existing learning")
        try destination.restoreLearningData(snapshots)
        let merged = try destination.backupLearningData()
        try require(
            merged.count == 1 && RimeLearningFormat.parse(merged[0]).entryCount == 2,
            "verified merge lost existing or incoming learning")
        try merged[0].data.write(to: root.appendingPathComponent("merged.userdb.txt"), options: [.withoutOverwriting])
        try destination.restoreLearningData(snapshots)
        try require(try destination.backupLearningData() == merged, "repeat restore was not idempotent")
        destination.shutdown()
        print("PASS invalid batch then valid merge, existing learning, repeat idempotence")

        let fresh = engine("fresh-target")
        defer { fresh.shutdown() }
        try fresh.start()
        let emptyBefore = try fresh.backupLearningData()
        try require(emptyBefore.count == 1, "fresh declared user dictionary omitted")
        let emptyDocument = try RimeLearningFormat.parse(emptyBefore[0])
        try require(emptyDocument.entryCount == 0, "fresh target did not produce empty native learning")
        try fresh.restoreLearningData(snapshots)
        let restored = try fresh.backupLearningData()
        try require(
            restored.count == 1 && RimeLearningFormat.parse(restored[0]).entryCount == 1,
            "new-device restore without target learning failed")
        fresh.shutdown()
        print("PASS completely fresh target restored real source learning")

        let gate = engine("composition-gate")
        defer { gate.shutdown() }
        try gate.start()
        _ = try gate.processKeySequence("ri")
        do {
            _ = try gate.backupLearningData()
            try require(false, "composing input allowed learning maintenance")
        } catch RimeLearningBackupError.unsupported {
            print("PASS composing input rejected")
        }
        _ = try gate.cancelComposition()
        _ = try gate.backupLearningData()
        gate.shutdown()
        print("PASS verified cancellation allows subsequent backup")

        let after = try hashes(prebuilt)
        try require(after == originalHashes, "learning operations changed prebuilt input hashes")
        try saveHashes(after, to: root.appendingPathComponent("prebuilt-after.sha256"))
        print("PASS all prebuilt input SHA-256 values unchanged")
        print("PASS learning backup: production RimeEngine and shipped Simulator slice; \(root.path)")
    }
}
