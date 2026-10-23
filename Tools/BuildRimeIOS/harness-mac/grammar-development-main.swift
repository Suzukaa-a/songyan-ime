import CryptoKit
import Darwin
import Foundation

/// Implementation check only. Can be linked for macOS or either iOS slice without UI.
@main struct GrammarDevelopmentMain {
    struct Replay: Codable {
        let code: String
        let candidates: [String]
        let preview: String
        let commit: String
        let diagnostics: RimeGrammarDiagnostics
    }
    struct Report: Codable {
        let platform: String
        let version: String
        let mode: String
        let schema: String
        let luaRegistered: Bool
        let grammarRegistered: Bool
        let modelSHA256: String?
        let luaOpenCCCommit: String?
        let maxRSSBefore: Int
        let maxRSSAfter: Int
        let decodingSeconds: Double
        let replay: [Replay]
        let final: RimeGrammarDiagnostics
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw RimeEngineError.operationFailed(message) }
    }
    static func rss() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss)
    }
    static func main() {
        do { try run() } catch {
            fputs("development check failed: \(error)\n", stderr)
            exit(1)
        }
    }
    static func run() throws {
        guard (5...6).contains(CommandLine.arguments.count) else {
            print("grammar-harness <shared> <fresh-user> <mode> <report.json> [codes.json]")
            return
        }
        let shared = URL(fileURLWithPath: CommandLine.arguments[1])
        let user = URL(fileURLWithPath: CommandLine.arguments[2])
        let mode = CommandLine.arguments[3]
        let report = URL(fileURLWithPath: CommandLine.arguments[4])
        try require(
            ["enabled", "disabled", "invalid", "association", "recording-off", "benchmark-on", "benchmark-off"]
                .contains(mode), "unknown check mode")
        var fixtureCodes: [String]?
        if CommandLine.arguments.count == 6 {
            struct Codes: Decodable { let codes: [String] }
            fixtureCodes = try JSONDecoder().decode(
                Codes.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[5]))
            ).codes
            try require(mode == "enabled" || mode == "disabled", "ranking fixtures require an enabled/disabled pair")
            try require(
                fixtureCodes!.count > 0 && fixtureCodes!.count <= 64
                    && fixtureCodes!.allSatisfy {
                        !$0.isEmpty && $0.count <= 128
                            && $0.unicodeScalars.allSatisfy { (97...122).contains($0.value) || $0 == "'" }
                    }, "invalid ranking input fixture")
        }
        if FileManager.default.fileExists(atPath: user.path) {
            let names = try FileManager.default.contentsOfDirectory(atPath: user.path)
            try require(
                !names.contains(where: { $0 == "build" || $0 == "installation.yaml" || $0.contains("userdb") }),
                "user directory contains previous engine state")
        }
        let before = rss()
        let recording = mode != "recording-off" && mode != "benchmark-off"
        let engine = RimeEngine(
            configuration: .init(sharedDirectory: shared, userDirectory: user, grammarDiagnosticsEnabled: recording))
        defer { engine.shutdown() }
        try engine.start()
        try require(
            engine.hasModule("lua") && engine.hasModule("grammar") && engine.hasModule("octagram"),
            "actual runtime module registration missing")
        try require(engine.selectSchema("songyan_quanpin"), "schema selection failed")
        try engine.validateSchemaDependencies(schemaID: "songyan_quanpin")
        var replay: [Replay] = []
        var luaOpenCCCommit: String?
        var decodingSeconds = 0.0
        if mode == "invalid" {
            var rejected = false
            do { try engine.validateGrammarLoaded(schemaID: "songyan_quanpin") } catch {
                rejected = true
                print("expected rejection: \(error)")
            }
            try require(rejected, "invalid/missing model was silently accepted")
            try require(
                try engine.grammarDiagnostics().loads.allSatisfy { !$0.success }, "invalid model claimed load success")
        } else {
            if mode == "enabled" || mode == "recording-off" || mode == "association" || mode.hasPrefix("benchmark-") {
                try engine.validateSchemaForActivation(schemaID: "songyan_quanpin")
            } else {
                try require(
                    (engine.schemaValue("songyan_quanpin", key: "grammar/language") ?? "").isEmpty,
                    "control did not actually disable grammar")
            }
            let codes =
                fixtureCodes
                ?? (mode.hasPrefix("benchmark-")
                    ? Array(repeating: "woshizhongguorenwomenxuexinihaozhongguoren", count: 100)
                    : ["woshizhongguoren", "womenxuexi", "nihaozhongguoren"])
            let start = DispatchTime.now().uptimeNanoseconds
            for code in codes {
                engine.clearComposition()
                for character in code { _ = try! engine.processKey(RimeKey(character: character)!) }
                let state = engine.state()
                let committed = try! engine.commitComposition().state.commitText
                try require(!committed.isEmpty && !state.candidates.isEmpty, "real decoding/commit failed")
                replay.append(
                    Replay(
                        code: code, candidates: state.candidates.map(\.text), preview: state.commitTextPreview,
                        commit: committed, diagnostics: try engine.grammarDiagnostics()))
            }
            decodingSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        }
        if mode == "association" {
            try require(engine.selectSchema("no_grammar_instance"), "missing association control schema")
            var rejected = false
            do { try engine.validateGrammarLoaded(schemaID: "no_grammar_instance") } catch { rejected = true }
            try require(rejected, "stale model path success accepted for schema with no live grammar")
            try engine.validateSchemaForActivation(schemaID: "songyan_quanpin")
            print("PASS live instance: A loaded → B same language/no instance rejected → A cached db reattached")
        }
        if mode != "invalid" {
            try require(engine.selectSchema("capability_probe"), "Lua/OpenCC probe schema unavailable")
            engine.setOption("traditionalization", value: true)
            _ = try! engine.processKeySequence("ab")
            let luaCandidates = engine.state().candidates.map(\.text)
            luaOpenCCCommit = try! engine.commitComposition().state.commitText
            try require(
                luaOpenCCCommit == "漢語",
                "Lua candidate/OpenCC conversion regression: candidates=\(luaCandidates), commit=\(luaOpenCCCommit ?? "nil")"
            )
            try require(engine.selectSchema("songyan_quanpin"), "Could not restore grammar schema")
        }
        let final = try engine.grammarDiagnostics()
        if mode == "enabled" || mode == "benchmark-on" {
            try require(final.loads.contains { $0.success && $0.entries > 0 }, "native GramDb load did not complete")
            try require(
                final.queryCount > 0 && final.lookupCount > 0 && final.matchCount > 0,
                "no actual decoder grammar lookup/match evidence: query=\(final.queryCount) lookup=\(final.lookupCount) match=\(final.matchCount); replay=\(replay.map { ($0.code, $0.candidates, $0.diagnostics.queryCount, $0.diagnostics.lookupCount, $0.diagnostics.matchCount) })"
            )
            let scores = Set(replay.flatMap { $0.diagnostics.samples.compactMap(\.score) })
            try require(scores.count > 1, "need context/score calibration; identical rankings are not a load proof")
        } else if mode == "recording-off" || mode == "benchmark-off" {
            try require(
                final.loads.contains { $0.success && $0.entries > 0 }, "disabled diagnostics lost required Load records"
            )
            try require(
                final.queryCount == 0 && final.lookupCount == 0 && final.samples.isEmpty,
                "disabled diagnostics sampled queries")
        } else if mode == "disabled" {
            try require(final.loads.isEmpty && final.queryCount == 0, "control unexpectedly used a model")
        }
        #if os(iOS)
            let platform = "iOS development probe"
        #else
            let platform = "macOS development probe (not iOS memory acceptance)"
        #endif
        var modelSHA256: String?
        if mode != "invalid", let language = try engine.loadedGrammarLanguage(schemaID: "songyan_quanpin") {
            guard
                let model = [user, shared].map({ $0.appendingPathComponent(language + ".gram") })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else {
                throw RimeEngineError.operationFailed("loaded model disappeared before hashing")
            }
            let handle = try FileHandle(forReadingFrom: model)
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
            modelSHA256 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let result = Report(
            platform: platform, version: engine.engineVersion, mode: mode, schema: engine.currentSchemaID ?? "",
            luaRegistered: engine.hasModule("lua"), grammarRegistered: engine.hasModule("grammar"),
            modelSHA256: modelSHA256,
            luaOpenCCCommit: luaOpenCCCommit,
            maxRSSBefore: before, maxRSSAfter: rss(), decodingSeconds: decodingSeconds, replay: replay, final: final)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: report)
        print(
            "DEVELOPMENT CHECK \(mode): load events=\(final.loads.count), queries=\(final.queryCount), matches=\(final.matchCount), maxRSS=\(rss())"
        )
    }
}
