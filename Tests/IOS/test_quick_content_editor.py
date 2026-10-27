"""Common phrase editor save path: only a confirmed write dismisses, failures keep the draft."""
import sys
import unittest

from swift_probe import ROOT, run, run_swift, scratch_directory, section

SERIAL_IO_QUEUE = ROOT / "Packages/KeyboardCore/Sources/KeyboardCore/Support/SerialIOQueue.swift"
SYMBOL_MODEL = ROOT / "Apps/SharedKeyboard/SymbolLibraryModel.swift"
LOCAL_MODEL = ROOT / "Apps/SharedKeyboard/LocalQuickContentModel.swift"
EDITOR = ROOT / "Apps/HostApp/SymbolCatalogManagementView.swift"
QUICK_CONTENT = ROOT / "Packages/QuickContentKit/Sources/QuickContentKit"

SAVE_PATH_MARK = "// MARK: - Common phrase editing"
VIEW_MARK = "\n// MARK: - Common phrase editor view"

# SharedQuickContentStorage and LocalQuickContentModel; the symbol panel views are not compiled.
STORAGE_MARK = "/// All local quick-content work uses a shared writable directory"
WRITE_QUEUE = ("enum SymbolLibraryWriteQueue {", "\nprivate final class SymbolLibraryIOWorker")

PROBE = r'''
import Foundation

// The panel resolves its storage through this seam; the probe points it at a scratch directory.
enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = true
    static var probeContainer: URL?
    static func sharedContainerURL() -> URL? { probeContainer }
}

@MainActor
func settle(_ model: LocalQuickContentModel) async {
    for _ in 0..<600 {
        if !model.isBusy { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    precondition(false, "the model never finished its background work")
}

@main struct Main {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let group = base.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        KeyboardRecipeStore.probeContainer = group
        let store = LocalQuickContentStore(directory: group.appendingPathComponent(LocalQuickContentStore.directoryName))

        // A new phrase: the draft is written and only then does the editor dismiss.
        let model = LocalQuickContentModel()
        model.reload()
        await settle(model)
        precondition(model.isAvailable, "a writable container must load")
        var dismissed = 0
        let draft = CommonPhraseDraft(phrase: CommonPhrase(text: "你好", shortcut: "nh")) { await model.savePhrase($0) }
        await draft.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 1 && draft.error == nil && draft.saving == false)
        let savedNew = try store.read()
        precondition(savedNew.phrases.map(\.text) == ["你好"])
        precondition(draft.phrase.text == "你好", "a successful save must not disturb the draft")
        print("PASS: a confirmed write dismisses the editor and the phrase is on disk")

        // Editing an existing phrase updates it in place instead of adding a second copy.
        let existing = try store.read().phrases[0]
        let edited = CommonPhrase(id: existing.id, text: "你好呀", shortcut: existing.shortcut)
        let editDraft = CommonPhraseDraft(phrase: edited) { await model.savePhrase($0) }
        dismissed = 0
        await editDraft.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 1 && editDraft.error == nil)
        let savedEdit = try store.read()
        precondition(savedEdit.phrases.map(\.text) == ["你好呀"])
        print("PASS: editing an existing phrase replaces it, one row stays one row")

        // A full list refuses the new phrase: the editor stays open with the reason and the text.
        let full = base.appendingPathComponent("full")
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        let fullStore = LocalQuickContentStore(directory: full.appendingPathComponent(LocalQuickContentStore.directoryName))
        for index in 0..<LocalQuickContentStore.maximumPhrases {
            try fullStore.savePhrase(CommonPhrase(text: "内容 \(index)"))
        }
        let beforeFull = try fullStore.read()
        KeyboardRecipeStore.probeContainer = full
        let fullModel = LocalQuickContentModel()
        fullModel.reload()
        await settle(fullModel)
        precondition(fullModel.content.phrases.count == LocalQuickContentStore.maximumPhrases)
        let overflow = CommonPhraseDraft(phrase: CommonPhrase(text: "第 101 条")) { await fullModel.savePhrase($0) }
        dismissed = 0
        await overflow.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 0, "a refused save must never dismiss")
        precondition(overflow.error == "常用语最多保存 100 条，请先删除一条再保存")
        precondition(overflow.phrase.text == "第 101 条", "the refused draft stays editable")
        precondition(fullModel.error != nil, "the list behind the editor reports the same reason")
        let afterOverflow = try fullStore.read()
        precondition(afterOverflow == beforeFull, "a refused save must not touch stored content")
        print("PASS: the 100-phrase limit keeps the draft, reports why, and changes nothing on disk")

        // Losing the shared container is a failure, not a silent success; retrying after it returns works.
        KeyboardRecipeStore.probeContainer = nil
        let offline = LocalQuickContentModel()
        offline.reload()
        await settle(offline)
        precondition(!offline.isAvailable)
        let offlineDraft = CommonPhraseDraft(phrase: CommonPhrase(text: "离线内容")) { await offline.savePhrase($0) }
        dismissed = 0
        await offlineDraft.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 0 && offlineDraft.saving == false)
        precondition(offlineDraft.error?.contains("允许完全访问") == true)
        precondition(offlineDraft.phrase.text == "离线内容")
        let baseEntries = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
        precondition(baseEntries == ["full", "group"], "no private fallback store may appear")
        KeyboardRecipeStore.probeContainer = group
        await offlineDraft.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 1 && offlineDraft.error == nil)
        let afterRetry = try store.read()
        precondition(afterRetry.phrases.contains { $0.text == "离线内容" })
        print("PASS: an unwritable container keeps the draft, writes nothing, and a retry succeeds")

        // Two taps while one write is in flight produce one write and one dismissal.
        var calls = 0
        dismissed = 0
        let repeated = CommonPhraseDraft(phrase: CommonPhrase(text: "重复保存")) { phrase in
            calls += 1
            try? await Task.sleep(nanoseconds: 80_000_000)
            return await model.savePhrase(phrase)
        }
        let first = Task { await repeated.save(dismiss: { dismissed += 1 }) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let second = Task { await repeated.save(dismiss: { dismissed += 1 }) }
        await first.value
        await second.value
        precondition(calls == 1 && dismissed == 1, "a second in-flight tap must be ignored")
        let afterRepeated = try store.read()
        precondition(afterRepeated.phrases.filter { $0.text == "重复保存" }.count == 1)
        print("PASS: repeated taps during one write save once and dismiss once")

        // The editor refuses drafts the store would reject, before any write is attempted.
        precondition(CommonPhraseDraft(phrase: CommonPhrase(text: "   "), persist: { _ in nil }).validationMessage != nil)
        precondition(CommonPhraseDraft(phrase: CommonPhrase(text: String(repeating: "a", count: LocalQuickContentStore.maximumTextBytes + 1)),
                                       persist: { _ in nil }).validationMessage != nil)
        precondition(CommonPhraseDraft(phrase: CommonPhrase(text: "好", shortcut: String(repeating: "s", count: 65)),
                                       persist: { _ in nil }).validationMessage != nil)
        let blank = CommonPhraseDraft(phrase: CommonPhrase(text: "   "), persist: { _ in nil })
        dismissed = 0
        await blank.save(dismiss: { dismissed += 1 })
        precondition(dismissed == 0)
        print("PASS: blank, oversized and long-shortcut drafts cannot be saved and never dismiss")

        // Without Full Access an explicit paste is never recorded into the shared history.
        _ = try store.setClipboardEnabled(true)
        KeyboardRecipeStore.canWriteSharedContainer = false
        let readOnlyNote = await SharedQuickContentStorage.recordExplicitPaste("只读粘贴")
        let afterReadOnly = try store.read()
        precondition(readOnlyNote == nil && afterReadOnly.clipboard.isEmpty, "a read-only paste must not be recorded")
        KeyboardRecipeStore.canWriteSharedContainer = true
        let writableNote = await SharedQuickContentStorage.recordExplicitPaste("可写粘贴")
        let afterWritable = try store.read()
        precondition(writableNote == nil && afterWritable.clipboard == ["可写粘贴"])
        print("PASS: without Full Access a paste leaves the clipboard history untouched")
    }
}
'''


def production_source():
    symbol_model = SYMBOL_MODEL.read_text(encoding="utf-8")
    local_model = LOCAL_MODEL.read_text(encoding="utf-8")
    editor = EDITOR.read_text(encoding="utf-8")
    pieces = [
        SERIAL_IO_QUEUE.read_text(encoding="utf-8").replace("import Foundation\n", ""),
        section(symbol_model, *WRITE_QUEUE),
        local_model[local_model.index(STORAGE_MARK):],
        section(editor, SAVE_PATH_MARK, VIEW_MARK),
        # SwiftPM synthesises Bundle.module for the package; the probe supplies it.
        "import Foundation\nextension Bundle { static var module: Bundle { .main } }\n",
    ]
    return ("import SwiftUI\nimport Combine\n"
            + "\n".join(pieces)
            + "\n".join(path.read_text(encoding="utf-8")
                         for path in sorted(QUICK_CONTENT.glob("*.swift"))))


# Just the names the editor reads, so the save path and view typecheck for iOS.
IOS_STUBS = r'''
import SwiftUI

struct CommonPhrase {
    var id = UUID()
    var text: String
    var shortcut = ""
}

enum LocalQuickContentStore { static let maximumTextBytes = 4096 }
'''


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class QuickContentEditorTargetTests(unittest.TestCase):
    def test_save_path_and_editor_typecheck_for_an_ios_host(self):
        sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).strip()
        editor = EDITOR.read_text(encoding="utf-8")
        with scratch_directory("quick-content-editor-ios") as directory:
            source = directory / "Editor.swift"
            source.write_text(IOS_STUBS + "\n" + editor[editor.index(SAVE_PATH_MARK):], encoding="utf-8")
            run(["xcrun", "swiftc", "-swift-version", "5", "-typecheck", "-parse-as-library",
                 "-target", "arm64-apple-ios17.0-simulator", "-sdk", sdk,
                 "-module-cache-path", str(directory / "module-cache"), str(source)])


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class QuickContentEditorTests(unittest.TestCase):
    def test_save_path_keeps_the_draft_unless_the_phrase_reached_disk(self):
        print(run_swift(production_source(), PROBE, prefix="quick-content-editor", library=True), end="")


if __name__ == "__main__":
    unittest.main()
