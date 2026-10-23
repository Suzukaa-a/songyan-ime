import Foundation
import RimeKit

private func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}
private func expect(_ error: RimeEngineError, _ label: String, _ body: () throws -> Void) {
    do {
        try body()
        fatalError("FAIL: \(label) succeeded")
    } catch let actual { check(actual as? RimeEngineError == error, label) }
}

/// Give the deployment-mode probe a real supported switch without changing the built-in package.
private func optionFixture(shared: URL, user: URL) throws -> URL {
    let fixture = user.deletingLastPathComponent().appendingPathComponent("snapshot-shared-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: shared, to: fixture)
    let schema = fixture.appendingPathComponent("songyan_quanpin.schema.yaml")
    var text = try String(contentsOf: schema, encoding: .utf8)
    precondition(text.contains("    - uniquifier"))
    text = text.replacingOccurrences(of: "    - uniquifier", with: "    - simplifier\n    - uniquifier")
    text +=
        "\nswitches:\n  - name: simplification\n    reset: 0\n    states: [原文, 转换]\nsimplifier:\n  option_name: simplification\n  opencc_config: s2t.json\n"
    try text.write(to: schema, atomically: true, encoding: .utf8)
    let opencc = fixture.appendingPathComponent("opencc")
    try FileManager.default.createDirectory(at: opencc, withIntermediateDirectories: true)
    try "你\t你\n".write(to: opencc.appendingPathComponent("identity.txt"), atomically: true, encoding: .utf8)
    let config =
        #"{"name":"Snapshot identity fixture","segmentation":{"type":"mmseg","dict":{"type":"text","file":"identity.txt"}},"conversion_chain":[{"dict":{"type":"text","file":"identity.txt"}}]}"#
    try config.write(to: opencc.appendingPathComponent("s2t.json"), atomically: true, encoding: .utf8)
    return fixture
}

private func offMain<T>(_ body: @escaping () throws -> T) throws -> T {
    let finished = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    DispatchQueue.global().async {
        result = Result(catching: body)
        finished.signal()
    }
    finished.wait()
    return try result.get()
}

/// Link against either native bridge or the delivered simulator slice. No UI,
/// no process-global changes; all user data goes to the supplied fresh directory.
@main struct SnapshotRecoveryMain {
    static func main() throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        precondition(args.count == 4, "shared fresh-user prebuilt")
        let originalShared = URL(fileURLWithPath: args[1])
        let user = URL(fileURLWithPath: args[2])
        let build: URL? = args[3] == "-" ? nil : URL(fileURLWithPath: args[3])
        let shared = try build == nil ? optionFixture(shared: originalShared, user: user) : originalShared
        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: shared,
                userDirectory: user, prebuiltDirectory: build))
        expect(.notStarted, "unstarted key throws") { _ = try engine.processKey(.space) }
        try engine.start()
        precondition(engine.selectSchema("songyan_quanpin"))
        _ = try engine.processKeySequence("n")
        let trusted = engine.state()
        engine.armSnapshotFailureForTesting()
        expect(.snapshotUnavailable, "ordinary key read failure") {
            _ = try engine.processKey(RimeKey(character: "i")!)
        }
        check(engine.state() == trusted, "retain trusted snapshot")
        expect(.snapshotUnavailable, "block subsequent key") { _ = try engine.processKey(.space) }
        engine.armSnapshotFailureForTesting()
        expect(.snapshotUnavailable, "failed recovery") { _ = try engine.cancelComposition() }
        check(engine.state() == trusted && engine.requiresSnapshotRecovery, "retain state after recovery failure")
        _ = try engine.cancelComposition()
        check(!engine.requiresSnapshotRecovery, "recovery retry succeeds")
        for action in ["key", "sequence", "commit", "candidate"] {
            let before = try engine.processKeySequence("nihao").state
            check(before.candidates.first?.text == "你好", "commit fixture \(action)")
            engine.armSnapshotFailureForTesting()
            if action == "candidate" {
                check(engine.selectCandidate(0) == nil, "candidate failure explicit")
            } else {
                expect(.snapshotUnavailable, "post-commit read failure \(action)") {
                    switch action {
                    case "key": _ = try engine.processKey(.space)
                    case "sequence": _ = try engine.processKeySequence(" ")
                    default: _ = try engine.commitComposition()
                    }
                }
            }
            check(engine.state() == before, "pending commit not consumed by state query")
            expect(.snapshotUnavailable, "block next sequence") { _ = try engine.processKeySequence("hao") }
            let cancelled = try engine.cancelComposition()
            check(!cancelled.isComposing && cancelled.commitText.isEmpty, "cancel drains pending commit")
            let next = try engine.processKeySequence("ni").state
            check(next.input == "ni" && next.commitText.isEmpty, "no delayed commit in fresh input")
            _ = try engine.cancelComposition()
        }
        check(engine.suspendSession(), "suspend live session")
        expect(.noSession, "no-session key") { _ = try engine.processKey(.space) }
        expect(.noSession, "no-session sequence") { _ = try engine.processKeySequence("ni") }
        expect(.noSession, "no-session commit") { _ = try engine.commitComposition() }
        check(try engine.resumeSession(), "resume session")
        if build == nil {
            _ = try engine.redeploy(fullCheck: false)
            let trusted = engine.state()
            engine.armSnapshotFailureForTesting()
            expect(.snapshotUnavailable, "maintenance snapshot failure throws") {
                _ = try engine.redeploy(fullCheck: false)
            }
            check(engine.requiresSnapshotRecovery && engine.state() == trusted, "maintenance retains trusted state")
            _ = try engine.cancelComposition()
            check(!engine.requiresSnapshotRecovery, "maintenance failure recovers explicitly")
            check(engine.selectSchema("keyboard_47246213a538cb99d374_9"), "select the built-in 9-key layout")
            _ = try engine.redeploy(fullCheck: true)
            check(engine.displayContext()?.authorizedMode() == .canonical, "built-in 9-key display is authorized")
        }
        engine.shutdown()

        let optionStore = OptionStore(directory: user.appendingPathComponent("option-preferences"))
        let backend = RimeBackend(
            sharedDirectory: shared, userDirectory: user, prebuiltDirectory: build,
            resourceID: "snapshot-recovery", optionStore: optionStore)
        try offMain { try backend.startIfNeeded() }
        try backend.selectSchema("songyan_quanpin")
        let input = InputSession(engine: backend, layout: .qwerty26)
        var document = "existing host text"
        input.onCommitted = { document += $0 }
        backend.armSnapshotFailureForTesting()
        input.tap(.code("n"))
        check(!input.snapshot.isComposing && input.inputUnavailableReason != nil, "idle read failure exposes recovery")
        check(document == "existing host text", "no literal fallback on read failure")
        check(input.discardComposition(), "idle recovery reaches backend")
        check(input.inputUnavailableReason == nil, "backend recovery clears gate")
        for ch in "nihao" { input.tap(.code(String(ch))) }
        let saved = input.snapshot
        backend.armSnapshotFailureForTesting()
        input.tap(.space)
        check(
            input.snapshot == saved && document == "existing host text",
            "commit read failure preserves UI and host document")
        input.tap(.code("x"))
        check(input.snapshot == saved && document == "existing host text", "later input blocked")
        backend.armCancelSnapshotFailureForTesting()
        check(!input.discardComposition() && input.snapshot == saved, "failed cancel does not authorize host clear")
        check(input.discardComposition() && input.inputUnavailableReason == nil, "cancel retries successfully")
        input.tap(.code("n"))
        check(input.snapshot.rawInput == "n" && document == "existing host text", "fresh input without delayed commit")
        _ = try backend.cancelComposition()
        if build == nil {
            guard let option = try backend.optionStates().first(where: { $0.descriptor.name == "simplification" })
            else {
                fatalError("FAIL: real simplifier switch was not deployed")
            }
            input.tap(.code("n"))
            let before = input.snapshot
            backend.armSnapshotFailureForTesting()
            expect(.snapshotUnavailable, "option post-write snapshot failure throws") {
                try input.setOption(option.descriptor.name, value: true)
            }
            check(input.snapshot == before && input.inputUnavailableReason != nil, "option failure retains trusted UI")
            // Drain the same FIFO used by beginSave: no late save may hide behind
            // an immediate disk read of an otherwise empty preference directory.
            try offMain { OptionPersistenceIO.preload {} }
            check(try optionStore.value(for: option.descriptor) == nil, "failed option read never persists preference")
            check(input.discardComposition(), "option failure explicit recovery")
        }
        try backend.selectSchema("keyboard_47246213a538cb99d374_9")
        for failingAction in ["apply", "restore"] {
            for key in "986" { _ = try backend.processKey(String(key)) }
            let observedReport = try backend.ambiguitySpellings()
            guard let report = observedReport, let option = report.options.first else {
                fatalError(
                    "FAIL: the built-in 9-key layout has no real lockable spelling: \(backend.currentSnapshot()) report=\(String(describing: observedReport))"
                )
            }
            if failingAction == "restore" {
                let baseline = try backend.applyAmbiguitySpelling(
                    expectedInput: report.revisionInput,
                    segment: report.segment, option: option)
                check(baseline == .applied, "real ambiguity apply baseline")
            }
            let before = backend.currentSnapshot()
            backend.armSnapshotFailureForTesting()
            expect(.snapshotUnavailable, "ambiguity \(failingAction) snapshot failure throws") {
                if failingAction == "apply" {
                    _ = try backend.applyAmbiguitySpelling(
                        expectedInput: report.revisionInput,
                        segment: report.segment, option: option)
                } else {
                    _ = try backend.restoreAmbiguitySpelling(
                        expectedInput: before.rawInput,
                        segment: 0..<before.rawInput.utf8.count, expectedOption: option, reducedCode: "986")
                }
            }
            check(
                backend.currentSnapshot() == before && backend.inputUnavailableReason != nil,
                "ambiguity failure preserves state and quarantines input")
            _ = try backend.cancelComposition()
            check(backend.inputUnavailableReason == nil, "ambiguity failure explicit recovery")
        }
        backend.shutdown()
        print("ALL PASS snapshot recovery")
    }
}
