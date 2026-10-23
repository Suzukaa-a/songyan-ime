import Foundation
import RimeKit

// Real-engine proof that a sideways pick of either letter on a merged key is exact,
// while a tap still reads as both letters, on the bundled 14- and 18-key companions.
// Keys are written the way the keypad sends them: a tap sends the key's own letter,
// a pick of that letter sends the fold's exact token, a pick of the other letter
// sends that letter.

private func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
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

@main struct ExactLetterMain {
    static func main() throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        precondition(args.count == 3, "shared fresh-user")
        let engine = RimeEngine(
            configuration: .init(
                sharedDirectory: URL(fileURLWithPath: args[1]),
                userDirectory: URL(fileURLWithPath: args[2]), prebuiltDirectory: nil))
        try engine.start()

        func candidates(_ schema: String, _ keys: [Character]) throws -> (texts: Set<String>, preedit: String) {
            precondition(engine.selectSchema(schema), schema)
            _ = try engine.cancelComposition()
            var state: RimeState?
            for key in keys { state = try engine.processKey(RimeKey(character: key)!).state }
            let texts = try engine.readCandidatePage(fromIndex: 0, count: 50).map(\.text)
            return (Set(texts), state?.preedit ?? "")
        }
        func token(_ fold: CompactFold, _ letter: Character) -> Character { fold.exactTokens[letter]! }

        // 14 keys: DF sends `d`, UI sends `u`.
        let quanpin14 = "keyboard_47246213a538cb99d374_14"
        let fold14 = CompactFold.merged14
        let tap14 = try candidates(quanpin14, ["d", "u"])
        check(tap14.texts.isSuperset(of: ["度", "复"]), "14 tap DF UI reads du and fu")
        let left14 = try candidates(quanpin14, [token(fold14, "d"), "u"])
        check(left14.texts.contains("度") && !left14.texts.contains("复"), "14 pick d then tap UI: du only")
        check(!left14.preedit.contains(token(fold14, "d")), "14 pick d shows a letter in the preedit")
        let right14 = try candidates(quanpin14, ["f", "u"])
        check(right14.texts.contains("复") && !right14.texts.contains("度"), "14 pick f then tap UI: fu only")
        let exact14 = try candidates(quanpin14, [token(fold14, "d"), token(fold14, "u")])
        check(exact14.texts.contains("度") && !exact14.texts.contains("的"), "14 pick d then pick u: du, not di")

        // 18 keys: SD sends `s`, FG sends `f`; U has its own key.
        let quanpin18 = "keyboard_47246213a538cb99d374_18"
        let fold18 = CompactFold.merged18
        let tap18 = try candidates(quanpin18, ["f", "u"])
        check(tap18.texts.contains("复"), "18 tap FG U reads fu")
        let left18 = try candidates(quanpin18, [token(fold18, "f"), "e"])
        check(!left18.texts.contains("个"), "18 pick f then E: not ge")
        let right18 = try candidates(quanpin18, ["g", "e"])
        check(right18.texts.contains("个"), "18 pick g then E: ge")
        let tapSD = try candidates(quanpin18, ["s", "u"])
        check(tapSD.texts.contains("度"), "18 tap SD U reads du")
        let leftSD = try candidates(quanpin18, [token(fold18, "s"), "u"])
        check(!leftSD.texts.contains("度"), "18 pick s then U: not du")
        let rightSD = try candidates(quanpin18, ["d", "u"])
        check(rightSD.texts.contains("度"), "18 pick d then U: du")
        engine.shutdown()

        // A host-added keyboard's adapter is compiled into build/ and listed in
        // keyboard-adapters.json, never in schema_list. Rebuild that shape from the
        // deployed companions and check the backend still knows its alphabet.
        let fm = FileManager.default
        let user = URL(fileURLWithPath: args[2])
        let hostBuild = user.deletingLastPathComponent().appendingPathComponent("host-added-build")
        try? fm.removeItem(at: hostBuild)
        try fm.copyItem(at: user.appendingPathComponent("build"), to: hostBuild)
        let flypy14 = "keyboard_3d7821f984693864ae91_14"
        let defaultYAML = hostBuild.appendingPathComponent("default.yaml")
        let listed = try String(contentsOf: defaultYAML, encoding: .utf8)
        let unlisted = listed.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("schema: keyboard_") }.joined(separator: "\n")
        check(unlisted != listed, "companions removed from schema_list")
        try unlisted.write(to: defaultYAML, atomically: true, encoding: .utf8)
        let adapter = KeyboardResourceSet.EncodingAdapter(
            sourceSchemaID: "songyan_flypy", schemaID: flypy14, layout: .merged14)
        try JSONEncoder().encode([adapter]).write(to: hostBuild.appendingPathComponent("keyboard-adapters.json"))
        let hostAdded = RimeBackend(
            sharedDirectory: URL(fileURLWithPath: args[1]), userDirectory: user, prebuiltDirectory: hostBuild)
        try offMain { try hostAdded.startIfNeeded() }
        check(!hostAdded.availableSchemas.contains { $0.id == flypy14 }, "host-added adapter is not in schema_list")
        check(
            hostAdded.spellerAlphabet(schemaID: flypy14)?.contains(token(fold14, "d")) == true,
            "host-added adapter alphabet carries the exact tokens")
        hostAdded.shutdown()

        // Confirm with no candidates: the engine's Return commits the raw input, which
        // holds the exact token; the host must get the letter.
        let backend = RimeBackend(sharedDirectory: URL(fileURLWithPath: args[1]), userDirectory: user)
        try offMain { try backend.startIfNeeded() }
        try backend.selectSchema(flypy14)
        let input = InputSession(engine: backend, layout: .merged14)
        var document = ""
        input.onCommitted = { document += $0 }
        input.tap(.code(String(token(fold14, "q"))))
        check(
            input.snapshot.isComposing && input.snapshot.candidates.isEmpty, "flypy 14 lone exact q has no candidates")
        input.commitComposition()
        check(document == "q" && !input.snapshot.isComposing, "confirming a lone exact q commits the letter q")

        // Partial selection: Return commits the selected text, then the raw tail.
        document = ""
        for key in ["b", "u", String(token(fold14, "q"))] { input.tap(.code(key)) }
        check(!input.snapshot.candidates.isEmpty, "flypy 14 BN UI then exact q offers a candidate")
        let picked = input.snapshot.candidates[0].text
        input.selectCandidate(0)
        check(
            input.snapshot.isComposing && input.snapshot.candidates.isEmpty && document.isEmpty,
            "only the exact q is left unconverted")
        input.commitComposition()
        check(document == picked + "q", "confirming after a partial selection commits the selection then q")
        backend.shutdown()
        print("ALL PASS exact letter picks")
    }
}
