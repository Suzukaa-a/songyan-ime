// ---------------------------------------------------------------------------
// bridge-contracts-main.swift — macOS real-engine proof for the panel-independent
// Rime bridge contracts:
//
//   1. ascii_mode / full_shape / ascii_punct are observed through
//      RimeEngine -> RimeState -> RimeBackend -> EngineSnapshot.
//   2. RimeMenu.select_keys and RimeContext.select_labels are copied per page
//      slot; absent declarations stay nil (never fabricated 1..9, never a
//      comment promoted to a label).
//   3. `RimeEngine.spellingDemand` is a real decode gate: false/nil means zero
//      candidate spelling decodes even when the schema carries an authorized
//      `keyboard_adapter` block; true still has to pass the existing
//      authorization contract.
//
// It runs the SAME production sources the keyboard uses (RimeEngine, the
// RimeBackend mapping, KeyboardCore value types) against the pinned macOS
// librime archive. `--shared` must point at a schema tree whose songyan_quanpin
// declares `menu/alternative_select_keys` and `menu/alternative_select_labels`
// (the harness script builds that fixture); the other lab schemas stay as-is so
// the "no declaration -> nil" case is exercised too.
//
// Usage: bridge-contracts-main --shared <dir> --user <dir> [--prebuilt <dir>]
// ---------------------------------------------------------------------------
import Foundation
import RimeKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS: \(name)") } else { fail(name) }
}

@main
struct BridgeContractsMain {
    /// A key batch reads the state once and matches key-by-key input. Runs on its own
    /// user directory so its learning never reorders the fixtures below.
    static func checkKeyBatches(shared: String, user: String) {
        let backend = RimeBackend(
            sharedDirectory: URL(fileURLWithPath: shared),
            userDirectory: URL(fileURLWithPath: user).appendingPathComponent("key-batches"))
        try! backend.startIfNeeded()
        try! backend.selectSchema("songyan_quanpin")
        // Commits mid-batch, punctuation, digit selection, Return, idle literals and backspace.
        // The first pass learns the commits so the compared passes rank alike.
        for sequence in [
            "nihao", "nihao hao", "ni,hao", "nihao1ni", "ni\nhao", "nihao  ni", "1a", "ni\u{08}\u{08}\u{08}a",
        ] {
            let keys = sequence.map(String.init)
            func stepped() -> EngineSnapshot? {
                _ = try! backend.cancelComposition()
                var last: EngineSnapshot?
                var committed = ""
                for key in keys {
                    let next = try! backend.processKey(key)
                    committed += next.committed
                    last = next
                }
                last?.committed = committed
                return last
            }
            _ = stepped()
            let expected = stepped()
            _ = try! backend.cancelComposition()
            let batch = backend.processKeys(keys, gate: OpenKeyGate())
            check(
                batch.error == nil && batch.processed == keys.count && batch.snapshot == expected,
                "batch matches key by key: \(sequence.debugDescription) -> \(expected?.committed.debugDescription ?? "nil")"
            )
        }
        _ = try! backend.cancelComposition()
        for ch in "nihao" { _ = try! backend.processKey(String(ch)) }
        backend.armSnapshotFailureForTesting()
        let failed = backend.processKeys([" ", "n"], gate: OpenKeyGate())
        check(
            failed.error != nil && failed.processed == 1 && failed.snapshot?.committed == "你好"
                && backend.inputUnavailableReason != nil,
            "failed closing read withholds only the last key")
        _ = try! backend.cancelComposition()
        backend.shutdown()
    }

    static func main() {
        var shared = "", user = "", prebuilt = ""
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--shared": shared = args.next() ?? ""
            case "--user": user = args.next() ?? ""
            case "--prebuilt": prebuilt = args.next() ?? ""
            default: fail("unknown argument \(a)")
            }
        }
        guard !shared.isEmpty, !user.isEmpty else { fail("args required") }
        checkKeyBatches(shared: shared, user: user)

        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: URL(fileURLWithPath: shared, isDirectory: true),
                userDirectory: URL(fileURLWithPath: user, isDirectory: true),
                appName: "rime.songyan.bridge-contracts",
                prebuiltDirectory: prebuilt.isEmpty ? nil : URL(fileURLWithPath: prebuilt, isDirectory: true)))
        do { try engine.start() } catch { fail("start: \(error)") }

        let schemas = engine.schemas().map(\.id)
        print("schemas=\(schemas)")
        // Built-in ids from Resources/BuiltinPackages/Basic/default.yaml; the keyboard_* id is the
        // generated 14-key companion of songyan_flypy. Every fixture is required.
        let quanpin = "songyan_quanpin"
        let flypy = "songyan_flypy"
        let flypy14 = "keyboard_3d7821f984693864ae91_14"
        for id in [quanpin, flypy, flypy14] where !schemas.contains(id) {
            fail("fixture schema \(id) is missing")
        }

        func type(_ s: String) {
            for ch in s { if let k = RimeKey(character: ch) { _ = try! engine.processKey(k) } }
        }

        // ---- 1. Mode flags observed through engine + backend mapping ----
        _ = engine.selectSchema(quanpin)
        engine.setOption("full_shape", value: false)
        engine.setOption("ascii_punct", value: false)
        engine.setOption("ascii_mode", value: false)
        engine.clearComposition()
        var state = engine.state()
        check(
            !state.isAsciiMode && !state.isFullShape && !state.isAsciiPunct,
            "baseline ascii_mode/full_shape/ascii_punct are all false")

        engine.setOption("full_shape", value: true)
        state = engine.state()
        check(state.isFullShape, "full_shape observed true")
        check(!state.isAsciiMode && !state.isAsciiPunct, "full_shape is independent")

        engine.setOption("ascii_punct", value: true)
        state = engine.state()
        check(state.isAsciiPunct, "ascii_punct observed true")

        engine.setOption("ascii_mode", value: true)
        state = engine.state()
        check(state.isAsciiMode, "ascii_mode observed true")
        // The exact production mapping used by the keyboard.
        var mapped = RimeBackend.snapshot(from: state)
        check(
            mapped.isAsciiMode && mapped.isFullShape && mapped.isAsciiPunct,
            "flags survive RimeState -> EngineSnapshot mapping")
        engine.setOption("ascii_mode", value: false)
        check(!engine.state().isAsciiMode, "ascii_mode toggles back")
        engine.setOption("full_shape", value: false)
        engine.setOption("ascii_punct", value: false)

        // ---- 2. select_keys / select_labels per page slot ----
        // Fixture (songyan_quanpin): page_size 2, select_keys "asdfg",
        // select_labels 甲乙丙丁戊. Slot i -> key[i]/label[i].
        let expectedKeys = ["a", "s", "d", "f", "g"]
        let expectedLabels = ["甲", "乙", "丙", "丁", "戊"]
        func readPage(_ fromIndex: Int, _ count: Int) -> [RimeCandidate] {
            do { return try engine.readCandidatePage(fromIndex: fromIndex, count: count) } catch {
                fail("readCandidatePage(\(fromIndex),\(count)) threw: \(error)")
            }
        }
        func checkSlots(_ page: [RimeCandidate], _ name: String) {
            for (i, c) in page.enumerated() where i < expectedKeys.count {
                check(
                    c.selectKey == expectedKeys[i],
                    "\(name) slot \(i) select key (got \(c.selectKey ?? "nil"))")
                check(
                    c.selectLabel == expectedLabels[i],
                    "\(name) slot \(i) label (got \(c.selectLabel ?? "nil"))")
            }
        }

        _ = engine.selectSchema(quanpin)
        engine.clearComposition()
        type("ni")
        state = engine.state()
        check(state.isComposing, "quanpin composes 'ni'")
        check(state.pageSize == 2, "fixture page size is honored (got \(state.pageSize))")
        check(!state.candidates.isEmpty, "quanpin yields candidates")
        if let first = state.candidates.first {
            check(first.selectKey == "a", "first candidate select key from schema (got \(first.selectKey ?? "nil"))")
            check(first.selectLabel == "甲", "first candidate label from schema (got \(first.selectLabel ?? "nil"))")
            if let comment = first.comment {
                check(comment != first.selectLabel, "candidate comment is not the engine label")
            }
        }
        if state.candidates.count > 1 {
            let second = state.candidates[1]
            check(second.selectKey == "s", "second candidate select key follows page slot")
            check(second.selectLabel == "乙", "second candidate label follows page slot")
        }
        mapped = RimeBackend.snapshot(from: state)
        check(
            mapped.candidates.first?.selectKey == "a" && mapped.candidates.first?.selectLabel == "甲",
            "select key/label survive RimeState -> EngineSnapshot mapping")

        // The cross-page read-only iterator must carry the SAME per-slot metadata
        // as the live page (same composition, no re-typing). This goes through the
        // dedicated, commit-free rb_copy_context_metadata_json (never
        // rb_snapshot_get).
        let pageSize = state.pageSize
        check(pageSize > 0, "quanpin has a positive page size")
        let read0 = readPage(0, pageSize)
        check(
            read0.count == state.candidates.count,
            "read-only page 0 length == live page length")
        checkSlots(read0, "read-only page 0")
        for (i, c) in read0.enumerated() where i < state.candidates.count {
            check(
                c.selectKey == state.candidates[i].selectKey && c.selectLabel == state.candidates[i].selectLabel,
                "read-only page 0 slot \(i) matches the live page slot-for-slot")
        }
        engine.clearComposition()

        // The cross-page read-only read is page-independent: a later page
        // (read WITHOUT changing the engine page) keeps the SAME slot metadata.
        type("shi")
        let stateShi = engine.state()
        check(stateShi.isComposing, "quanpin composes 'shi'")
        let page0 = readPage(0, stateShi.pageSize)
        let p1 = readPage(stateShi.pageSize, stateShi.pageSize)
        check(page0.count == stateShi.pageSize, "read-only page 0 is full (\(page0.count))")
        check(!p1.isEmpty, "quanpin 'shi' has a second read-only page")
        checkSlots(page0, "page 0")
        checkSlots(p1, "page 1")
        for (i, c) in p1.enumerated() where i < page0.count {
            check(
                c.selectKey == page0[i].selectKey && c.selectLabel == page0[i].selectLabel,
                "page 0/1 slot \(i) metadata is consistent")
        }
        // Reading pages is read-only: it must not change the engine's own page.
        let after = engine.state()
        check(
            after.pageIndex == 0 && after.candidates.count == page0.count,
            "read-only page reads do not change the engine page")
        engine.clearComposition()

        // A schema that declares no menu block must report nil, not 1..9, and a
        // schema switch must never leak the previous schema's labels.
        do {
            _ = engine.selectSchema(flypy14)
            engine.clearComposition()
            type("bu")
            state = engine.state()
            check(state.isComposing, "flypy14 composes 'bu'")
            check(
                state.candidates.allSatisfy { $0.selectKey == nil && $0.selectLabel == nil },
                "undeclared menu -> nil select metadata (no default 1..9)")
            let read14 = readPage(0, 5)
            check(
                read14.allSatisfy { $0.selectKey == nil && $0.selectLabel == nil },
                "schema switch does not leak the previous schema's slot metadata")

            // Switching back re-reads the live schema: labels return (no cache).
            _ = engine.selectSchema(quanpin)
            engine.clearComposition()
            type("ni")
            let readBack = readPage(0, engine.state().pageSize > 0 ? engine.state().pageSize : 5)
            check(
                readBack.first?.selectKey == "a" && readBack.first?.selectLabel == "甲",
                "slot metadata returns after switching back (live schema read)")
            engine.clearComposition()
        }

        // ---- 3. spellingDemand is a failure-closed decode gate ----
        let capabilitySchema = flypy14
        _ = engine.selectSchema(capabilitySchema)
        engine.clearComposition()
        type("bu")
        guard engine.state().isComposing else { fail("capability schema must compose for the gate test") }
        // Prove the schema really carries an authorized capability, otherwise the
        // "true must decode" arm would be vacuous.
        guard let context = engine.displayContext(), context.authorizedMode() != nil else {
            fail("\(capabilitySchema) must carry an authorized keyboard_adapter capability for this harness")
        }
        engine.clearComposition()

        engine.spellingDemand = { false }
        engine.clearComposition()
        type("bu")
        var decodeBefore = rb_spelling_decode_count()
        state = engine.state()
        check(
            rb_spelling_decode_count() == decodeBefore,
            "demand=false + capability block performs 0 candidate decodes")
        check(state.highlightedSpelling.isEmpty, "demand=false yields no spelling")
        check(engine.highlightedSpelling().isEmpty, "explicit one-shot is equally gated")
        check(state.isComposing, "demand=false still composes (native preedit untouched)")

        engine.spellingDemand = nil
        engine.clearComposition()
        type("bu")
        decodeBefore = rb_spelling_decode_count()
        state = engine.state()
        check(
            rb_spelling_decode_count() == decodeBefore,
            "nil demand + capability block performs 0 candidate decodes")
        check(state.highlightedSpelling.isEmpty, "nil demand yields no spelling")

        engine.spellingDemand = { true }
        engine.clearComposition()
        type("bu")
        decodeBefore = rb_spelling_decode_count()
        state = engine.state()
        check(
            rb_spelling_decode_count() > decodeBefore,
            "demand=true decodes the highlighted candidate")
        check(!state.highlightedSpelling.isEmpty, "demand=true provides a trusted spelling")
        check(!engine.highlightedSpelling().isEmpty, "explicit one-shot decodes when requested")
        engine.clearComposition()

        // true is not a bypass: a schema with no declared capability still
        // performs zero decodes.
        do {
            _ = engine.selectSchema(flypy)
            engine.spellingDemand = { true }
            engine.clearComposition()
            type("nihao")
            decodeBefore = rb_spelling_decode_count()
            state = engine.state()
            check(
                rb_spelling_decode_count() == decodeBefore,
                "demand=true + no capability still performs 0 candidate decodes")
            check(
                state.highlightedSpelling.isEmpty,
                "no capability -> native preedit, no fabricated spelling")
            check(state.displayMode == .native, "no capability stays native")
            engine.clearComposition()
        }

        // ---- 5. metadata slot bounds are read safely ----
        func meta(_ json: String) -> RimePageSelectMetadata? {
            RimePageSelectMetadata(json: Data(json.utf8))
        }
        let shortKeys = meta("{\"page_size\":5,\"select_keys\":[\"a\",\"s\"],\"select_labels\":null}")
        check(
            shortKeys?.selectKey(pageLocalIndex: 0) == "a",
            "short select_keys: in-range slot reads")
        check(
            shortKeys?.selectKey(pageLocalIndex: 4) == nil,
            "short select_keys: out-of-range slot is nil (no crash/guess)")
        // select_keys may be longer than page_size (the fixture songyan_quanpin does:
        // "asdfg" with page_size 2). The engine maps slot = absolute % page_size, so
        // it only ever asks for slots < page_size; the accessor additionally bounds
        // to the array, so an out-of-array slot is nil rather than a fabricated key.
        let longKeys = meta("{\"page_size\":2,\"select_keys\":[\"a\",\"s\",\"d\",\"f\"],\"select_labels\":null}")
        check(
            longKeys?.selectKey(pageLocalIndex: 1) == "s",
            "long select_keys: page slot reads")
        check(
            longKeys?.selectKey(pageLocalIndex: 4) == nil,
            "long select_keys: out-of-array slot is nil (no crash/guess)")
        check(
            meta("{\"page_size\":5,\"select_keys\":null,\"select_labels\":[\"甲\"]}") == nil,
            "select_labels length != page_size is rejected wholesale")
        check(
            meta("{\"page_size\":0,\"select_keys\":null,\"select_labels\":null}")?
                .selectKey(pageLocalIndex: 0) == nil,
            "page_size 0 yields no slot metadata")

        // ---- 6. hidden session releases the actual userdb LOCK FD ----
        func lockDescriptorCount() -> Int {
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            probe.arguments = ["-p", String(getpid()), "-Fn"]
            let output = Pipe()
            probe.standardOutput = output
            probe.standardError = FileHandle.nullDevice
            do { try probe.run() } catch { fail("lsof launch: \(error)") }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            guard probe.terminationStatus == 0 else { fail("lsof exited \(probe.terminationStatus)") }
            return String(decoding: data, as: UTF8.self).split(separator: "\n")
                .filter { $0.first == "n" && $0.contains(user) && $0.hasSuffix(".userdb/LOCK") }.count
        }
        _ = engine.selectSchema(quanpin)
        engine.setOption("full_shape", value: true)
        engine.clearComposition()
        type("ni")
        check(!engine.state().candidates.isEmpty, "fixture opens user dictionary")
        _ = engine.selectCandidate(0)
        check(lockDescriptorCount() == 1, "visible session owns exactly one userdb LOCK FD")
        for cycle in 0..<30 {
            check(engine.suspendSession(), "suspend #\(cycle) closes live session")
            check(
                !engine.isRunning && lockDescriptorCount() == 0,
                "suspend #\(cycle) releases userdb LOCK FD")
            check(!engine.suspendSession(), "repeated suspend is idempotent")
            do { check(try engine.resumeSession(), "resume #\(cycle) recreates session") } catch {
                fail("resume #\(cycle): \(error)")
            }
            check(
                engine.currentSchemaID == quanpin && engine.option("full_shape"),
                "resume #\(cycle) restores schema and options")
            check(lockDescriptorCount() == 1, "resume #\(cycle) owns one LOCK FD")
            check(!engine.state().isComposing, "resume #\(cycle) discards old preedit")
        }
        // ---- Commit preview arrives with the snapshot's own context read ----
        _ = try! engine.cancelComposition()
        type("nihao")
        var rawContext = RimeContext()
        rawContext.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard let api = rime_get_api(), api.pointee.get_context(engine.session, &rawContext) != 0 else {
            fail("raw context read")
        }
        let rawPreview = rawContext.commit_text_preview.map { String(cString: $0) } ?? ""
        _ = api.pointee.free_context(&rawContext)
        check(
            !rawPreview.isEmpty && engine.state().commitTextPreview == rawPreview, "snapshot carries the commit preview"
        )
        _ = try! engine.cancelComposition()
        check(engine.state().commitTextPreview.isEmpty, "idle snapshot has no commit preview")

        // ---- Fed keys: per-key commit in order, one state read at the end ----
        type("nihao")
        let fed = try! engine.feedKey(.space)
        check(fed.consumed && !fed.hasInput && fed.commitText == "你好", "fed key returns its own commit")
        check(try! engine.actionState().commitText.isEmpty, "fed commit is consumed exactly once")
        for ch in "ni" { _ = try! engine.feedKey(RimeKey(character: ch)!) }
        let fedState = try! engine.actionState()
        check(fedState.isComposing && fedState.input == "ni" && !fedState.candidates.isEmpty, "state after fed keys")
        _ = try! engine.cancelComposition()

        // ---- 7. Unread action snapshots never leak into the next key ----
        func expectError(
            _ expected: RimeEngineError, _ label: String,
            _ action: () throws -> Void
        ) {
            do {
                try action()
                fail("\(label): unexpectedly succeeded")
            } catch { check(error as? RimeEngineError == expected, label) }
        }
        engine.setOption("full_shape", value: false)
        _ = try! engine.cancelComposition()
        type("n")
        let trusted = engine.state()
        engine.armSnapshotFailureForTesting()
        expectError(.snapshotUnavailable, "ordinary key read failure throws") {
            _ = try engine.processKey(RimeKey(character: "i")!)
        }
        check(engine.state() == trusted, "failed read retains last trusted observation")
        expectError(.snapshotUnavailable, "next key refused before mutation") {
            _ = try engine.processKey(.space)
        }
        engine.armSnapshotFailureForTesting()
        expectError(.snapshotUnavailable, "recovery read failure remains blocked") {
            _ = try engine.cancelComposition()
        }
        check(
            engine.requiresSnapshotRecovery && engine.state() == trusted,
            "failed recovery keeps trusted state and gate")
        let recovered = try! engine.cancelComposition()
        check(
            !recovered.isComposing && recovered.commitText.isEmpty && !engine.requiresSnapshotRecovery,
            "retry cancellation validates idle and releases gate")
        for action in ["key", "sequence", "commit", "candidate"] {
            type("nihao")
            let before = engine.state()
            check(before.candidates.first?.text == "你好", "pending commit fixture \(action)")
            engine.armSnapshotFailureForTesting()
            if action == "candidate" {
                check(engine.selectCandidate(0) == nil, "candidate read failure returns nil")
            } else {
                expectError(.snapshotUnavailable, "post-commit read failure \(action)") {
                    switch action {
                    case "key": _ = try engine.processKey(.space)
                    case "sequence": _ = try engine.processKeySequence(" ")
                    default: _ = try engine.commitComposition()
                    }
                }
            }
            check(engine.state() == before, "pending commit not consumed by state query \(action)")
            expectError(.snapshotUnavailable, "pending commit cannot mix with next input \(action)") {
                _ = try engine.processKeySequence("hao")
            }
            let cancelled = try! engine.cancelComposition()
            check(cancelled.commitText.isEmpty && !cancelled.isComposing, "cancel drains pending commit \(action)")
            let next = try! engine.processKeySequence("ni")
            check(
                next.state.input == "ni" && next.state.commitText.isEmpty,
                "new input contains no delayed commit \(action)")
            _ = try! engine.cancelComposition()
        }
        check(engine.suspendSession(), "no-session fixture suspends")
        expectError(.noSession, "no-session key throws") { _ = try engine.processKey(.space) }
        expectError(.noSession, "no-session sequence throws") { _ = try engine.processKeySequence("ni") }
        expectError(.noSession, "no-session commit throws") { _ = try engine.commitComposition() }
        expectError(.noSession, "no-session fed key throws") { _ = try engine.feedKey(.space) }
        expectError(.noSession, "no-session state read throws") { _ = try engine.actionState() }
        check(!engine.requiresSnapshotRecovery, "missing session needs no recovery")
        check(try! engine.resumeSession(), "no-session recovery recreates session")
        engine.shutdown()
        check(lockDescriptorCount() == 0, "full shutdown leaves no userdb LOCK FD")

        // Production backend + InputSession: failure never edits the host model.
        let backend = RimeBackend(
            sharedDirectory: URL(fileURLWithPath: shared),
            userDirectory: URL(fileURLWithPath: user))
        try! backend.startIfNeeded()
        try! backend.selectSchema(quanpin)
        let input = InputSession(engine: backend, layout: .qwerty26)
        var document = "existing host text"
        input.onCommitted = { document += $0 }
        var errors = 0
        input.onError = { _ in errors += 1 }
        backend.armSnapshotFailureForTesting()
        input.tap(.code("n"))
        check(
            !input.snapshot.isComposing && backend.inputUnavailableReason != nil,
            "first-key failure keeps trusted idle and exposes recovery")
        check(document == "existing host text", "failed first key has no literal fallback")
        check(input.discardComposition(), "idle failure reaches explicit cancellation")
        check(backend.inputUnavailableReason == nil, "successful recovery clears backend gate")
        for ch in "nihao" { input.tap(.code(String(ch))) }
        let backendTrusted = input.snapshot
        backend.armSnapshotFailureForTesting()
        input.tap(.space)
        check(
            input.snapshot == backendTrusted && document == "existing host text",
            "commit read failure preserves trusted UI and host document")
        input.tap(.code("x"))
        check(
            input.snapshot == backendTrusted && document == "existing host text",
            "unavailable gate blocks later input and commit delivery")
        backend.armCancelSnapshotFailureForTesting()
        check(
            !input.discardComposition() && input.snapshot == backendTrusted,
            "failed cancellation grants no host-clear permission")
        check(input.discardComposition(), "explicit cancellation can retry after read failure")
        check(
            backend.inputUnavailableReason == nil && document == "existing host text",
            "successful cancellation recovers without delivering old commit")
        input.tap(.code("n"))
        check(
            input.snapshot.rawInput == "n" && document == "existing host text" && errors >= 3,
            "recovered backend accepts fresh input only")

        backend.shutdown()
        print("ALL PASS")
    }
}
