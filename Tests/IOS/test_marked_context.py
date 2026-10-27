"""Compile the shipping proxy ownership/marked/commit exits against a delayed host."""
import re
import sys
import unittest

from swift_probe import ROOT, run_swift, section, type_source_text


def method(source, name):
    start = re.search(r"^    (?:private |public |override )?func " + name + r"\(", source, re.M).start()
    opening = source.index("{", start)
    depth, cursor = 1, opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor].replace("private func", "func").replace("public func", "func")


@unittest.skipUnless(sys.platform == "darwin", "requires macOS Swift")
class MarkedContextProductionTests(unittest.TestCase):
    def test_bounded_delayed_context_keeps_complete_commits_and_rejects_moves(self):
        source = type_source_text(ROOT / "Apps/KeyboardExtension", "KeyboardViewController")
        core = (ROOT / "Packages/KeyboardCore/Sources/KeyboardCore/Engine/EngineTypes.swift").read_text()
        context = (ROOT / "Packages/KeyboardCore/Sources/KeyboardCore/Support/ProxyDocumentContext.swift").read_text()
        fields = section(source, "    var markedDocument:", "    /// The document this controller currently serves").replace("private ", "")
        methods = "\n".join(method(source, name) for name in (
            "observeMarkedEcho", "observeCancelledMarkedEcho", "writeProxy", "updateMarked",
            "commitOverEchoedMarked", "cancelOwnedMarked", "checkDocumentOwnership",
            "writableDocument", "adoptDocument", "stillOwns", "abandonDocumentOwnership",
            "forgetLocalDocumentState", "dispatchCommit", "noteHostTextFinalized",
            "textDidChange", "selectionDidChange"))
        mark = section(core, "    /// A display-only replacement", "    /// Conservative visibility")
        program = r'''
import Foundation
struct MarkedComposition: Equatable {
    let text: String
    let selection: NSRange
''' + mark + method(core, "isEchoed") + r'''
}
enum Evidence { case documentContextEcho }
enum Presentation { case idle, inline(evidence: Evidence), awaitingHost, keyboard(reason: String) }
final class Backend { var hostInputIsReady = true }
enum KeyboardLifecycleDiagnostics { static func emit(_ event: String, _ fields: [String: String] = [:]) {} }
final class QuickInsert {
    var commits: [String] = []
    func recordCommitted(_ text: String) { commits.append(text) }
}
final class Session {
    let backend: Backend? = Backend()
    let quickInsert = QuickInsert()
    var presentation = Presentation.idle
    func resetHostContext() {}
    func reportCompositionPresentation(_ value: Presentation) { presentation = value }
}
final class ScriptedProxy {
    var originalBefore = String(repeating: "原有正文", count: 256)
    var originalAfter = String(repeating: "原有尾文", count: 256)
    var documentContextBeforeInput: String?
    var documentContextAfterInput: String?
    var selectedText: String?
    var mark: String?
    var markSelection = NSRange(location: 0, length: 0)
    var resetsCaretOnUnmark = false
    var setMarkedCalls = 0
    var insertCalls = 0
    var delayed = false
    var window: Int? = 80
    var document: String { originalBefore + (mark ?? selectedText ?? "") + originalAfter }
    init() { flush() }
    func flush() {
        let marked = (mark ?? "") as NSString
        let before = originalBefore + marked.substring(to: markSelection.location)
        let after = marked.substring(from: NSMaxRange(markSelection)) + originalAfter
        if mark != nil { selectedText = marked.substring(with: markSelection) }
        documentContextBeforeInput = window.map { String(before.suffix($0)) } ?? before
        documentContextAfterInput = window.map { String(after.prefix($0)) } ?? after
    }
    func setMarkedText(_ text: String, selectedRange: NSRange) {
        setMarkedCalls += 1
        selectedText = nil
        mark = text
        markSelection = selectedRange
        if !delayed { flush() }
    }
    func unmarkText() {
        if let mark {
            let marked = mark as NSString
            // Model a host that restores the replacement start when composition ends.
            let caret = resetsCaretOnUnmark ? 0 : NSMaxRange(markSelection)
            originalBefore += marked.substring(to: caret)
            originalAfter = marked.substring(from: caret) + originalAfter
        }
        mark = nil
        markSelection = NSRange(location: 0, length: 0)
        selectedText = nil
        if !delayed { flush() }
    }
    func insertText(_ text: String) {
        insertCalls += 1
        // Native insertion replaces the whole marked range, including an interior caret.
        originalBefore += text
        mark = nil
        markSelection = NSRange(location: 0, length: 0)
        selectedText = nil
        if !delayed { flush() }
    }
}
protocol UITextInput {}
class InputController {
    func textDidChange(_ input: UITextInput?) {}
    func selectionDidChange(_ input: UITextInput?) {}
}
final class Subject: InputController {
    static weak var boundHost: Subject?
    var isBoundHost: Bool { Self.boundHost === self }
    let session = Session()
    let textDocumentProxy = ScriptedProxy()
    var identity: UUID? = UUID()
    var proxyWriteInProgress = false
    var hostDocumentAttachPending = false
    var expectedContext: ProxyDocumentContext?
    var activeDocumentID: UUID?
    var inlineCompositionEnabled = true
    var clears = 0
''' + fields + r'''
    override init() {
        super.init()
        Self.boundHost = self
        activeDocumentID = identity
        expectedContext = proxyContext
    }
    func documentIdentity() -> UUID? {
        if identity == nil { abandonDocumentOwnership() }
        return identity
    }
    func clearComposition() { clears += 1 }
    func refreshHostTraits() {}
    func attachToHostDocument() {}
    func scheduleHostTraitsRefresh() {}
''' + methods + r'''
}
// Each step below is a separate main-queue turn unless it says otherwise.
func nextTurn() { RunLoop.main.run(until: Date()) }
// An ordinary short mark in a long document: context lengths differ on each read.
let windowed = Subject()
let original = windowed.textDocumentProxy.document
windowed.textDocumentProxy.delayed = true
windowed.updateMarked(MarkedComposition(text: "ni hao"))
windowed.textDocumentProxy.window = 50
windowed.textDocumentProxy.flush()
windowed.textDidChange(nil)
precondition(windowed.clears == 0 && windowed.lastEchoedMarked != nil)
windowed.textDocumentProxy.window = 256
windowed.textDocumentProxy.flush()
windowed.selectionDidChange(nil)
precondition(windowed.clears == 0)
windowed.textDocumentProxy.delayed = false
precondition(windowed.dispatchCommit("你好"))
precondition(windowed.textDocumentProxy.document == original.replacingOccurrences(of: windowed.textDocumentProxy.originalAfter,
    with: "你好" + windowed.textDocumentProxy.originalAfter))
precondition(windowed.session.quickInsert.commits == ["你好"])
print("PASS short composition in long document with delayed 50/256-unit context windows")

// Crossing the inline budget cancels only the owned short mark. Its delayed
// cancellation acknowledgement must not cancel the still-live engine composition.
let growing = Subject()
let before = growing.textDocumentProxy.originalBefore
let after = growing.textDocumentProxy.originalAfter
let short = String(repeating: "n", count: 32)
growing.updateMarked(MarkedComposition(text: short))
growing.textDocumentProxy.delayed = true
let long = String(repeating: "长组合👩🏽‍💻", count: 256)
growing.updateMarked(MarkedComposition(text: long))
precondition(growing.keyboardOnlyComposition && growing.clears == 0)
growing.textDocumentProxy.window = 50
growing.textDocumentProxy.flush()
growing.textDidChange(nil)
precondition(growing.clears == 0 && growing.markedDocument == nil)
let calls = growing.textDocumentProxy.setMarkedCalls
growing.updateMarked(MarkedComposition(text: long + "继续输入"))
growing.updateMarked(MarkedComposition(text: "n"))
precondition(growing.textDocumentProxy.setMarkedCalls == calls, "remain keyboard-only for this composition")
growing.textDocumentProxy.delayed = false
precondition(growing.dispatchCommit(long))
precondition(growing.textDocumentProxy.document == before + long + after)
precondition(growing.textDocumentProxy.insertCalls == 1 && growing.session.quickInsert.commits == [long])
nextTurn()
growing.updateMarked(nil)
growing.updateMarked(MarkedComposition(text: "ni"))
precondition(growing.pendingMarked?.text == "ni", "next composition can use inline display again")
print("PASS long Unicode composition, delayed cancellation, whole single commit and subsequent input")

// A prefilled selection is replaced once; the next composition must append even
// when the host restores the replacement-start caret from unmarkText.
for reset in [false, true] {
    for commit in ["你好", "👩🏽‍💻e\u{301}", "ni hao"] {
        for (head, tail) in [("", ""), ("左👈", "👉右")] {
            let replacement = Subject()
            let proxy = replacement.textDocumentProxy
            proxy.originalBefore = head
            proxy.originalAfter = tail
            proxy.selectedText = "预填内容👋"
            proxy.resetsCaretOnUnmark = reset
            proxy.flush()
            replacement.expectedContext = replacement.proxyContext
            replacement.updateMarked(MarkedComposition(text: "ni hao"))
            precondition(replacement.dispatchCommit(commit))
            precondition(proxy.document == head + commit + tail && proxy.mark == nil)
            nextTurn()
            replacement.updateMarked(MarkedComposition(text: "ma"))
            precondition(replacement.dispatchCommit("吗"))
            precondition(proxy.document == head + commit + "吗" + tail, "replacement must leave the caret after committed text")
            precondition(proxy.documentContextBeforeInput == head + commit + "吗" && proxy.documentContextAfterInput == tail)
        }
    }
}
// Keep the insertion point inside an ordinary document and replace a marked
// range whose own caret is in the middle (UTF-16, including emoji).
let interior = Subject()
let interiorProxy = interior.textDocumentProxy
interiorProxy.originalBefore = "左👈"
interiorProxy.originalAfter = "👉右"
interiorProxy.flush()
interior.expectedContext = interior.proxyContext
interior.updateMarked(MarkedComposition(text: "👩🏽‍💻ni", selection: NSRange(location: 7, length: 0)))
precondition(interior.dispatchCommit("你"))
precondition(interiorProxy.document == "左👈你👉右" && interiorProxy.mark == nil)
precondition(interiorProxy.documentContextBeforeInput == "左👈你" && interiorProxy.documentContextAfterInput == "👉右")
print("PASS selected prefill replacement, subsequent append, equal commit, Unicode and interior composition caret")

// One turn of proxy writes reaches the host as one batch with its unmark applied
// last: a mark written in the turn of a commit would be finalized as typed text.
let burst = Subject()
let burstBefore = burst.textDocumentProxy.originalBefore
let burstAfter = burst.textDocumentProxy.originalAfter
burst.updateMarked(MarkedComposition(text: "ni"))
precondition(burst.dispatchCommit("你"))
let burstCalls = burst.textDocumentProxy.setMarkedCalls
burst.updateMarked(MarkedComposition(text: "g"))
burst.updateMarked(MarkedComposition(text: "gao"))
precondition(burst.textDocumentProxy.setMarkedCalls == burstCalls && burst.pendingMarked == nil)
nextTurn()
precondition(burst.textDocumentProxy.setMarkedCalls == burstCalls + 1 && burst.pendingMarked?.text == "gao")
precondition(burst.clears == 0)
precondition(burst.dispatchCommit("好"))
burst.updateMarked(MarkedComposition(text: "x"))
precondition(burst.dispatchCommit("x"))
nextTurn()
precondition(burst.pendingMarked == nil && burst.textDocumentProxy.setMarkedCalls == burstCalls + 1)
precondition(burst.textDocumentProxy.document == burstBefore + "你好x" + burstAfter && burst.clears == 0)
print("PASS a mark after a commit in the same turn waits for the next turn; a later commit drops it")

for change in 0..<4 {
    let external = Subject()
    external.updateMarked(MarkedComposition(text: "ni"))
    let calls = external.textDocumentProxy.setMarkedCalls
    switch change {
    case 0: external.textDocumentProxy.documentContextBeforeInput = "别处"
    case 1: external.textDocumentProxy.documentContextAfterInput = "别处"
    case 2: external.textDocumentProxy.selectedText = "选区"
    default: external.identity = UUID()
    }
    external.selectionDidChange(nil)
    precondition(external.clears > 0 && external.pendingMarked == nil)
    precondition(external.textDocumentProxy.setMarkedCalls == calls, "external move must not mutate the host")
}
let changed = Subject()
changed.updateMarked(MarkedComposition(text: "ni"))
changed.identity = UUID()
precondition(!changed.dispatchCommit("旧提交"))
precondition(changed.textDocumentProxy.insertCalls == 0 && changed.session.quickInsert.commits.isEmpty)
print("PASS external moves, selections and document changes still reject stale writes")
'''
        print(run_swift(context, program, prefix="marked-context"), end="")


if __name__ == "__main__":
    unittest.main()
