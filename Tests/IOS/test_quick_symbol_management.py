"""Host whole-list quick-symbol editing probes; no simulator or real App Group."""
import sys
import unittest

from swift_probe import ROOT, run_swift

MODEL = ROOT / "Apps/SharedKeyboard/T9QuickSymbolModel.swift"
VIEW = ROOT / "Apps/HostApp/T9QuickSymbolManagementView.swift"

MODEL_CHECKS = r'''
import Foundation
import Combine

enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = true
    static let groupID = "test.quick-symbol-management"
    static func sharedContainerURL() -> URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
}
enum KeyboardFeedbackPreferences { static var defaults: UserDefaults { .standard } }

@main struct Main {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaults = T9QuickSymbolStore.defaultSymbols
        let group = base.appendingPathComponent("shared")
        var notifications: [String] = []
        var model: T9QuickSymbolModel!
        model = T9QuickSymbolModel(sharedContainer: {
            precondition(!Thread.isMainThread, "container resolution must run off main")
            return group
        }, observesNotifications: false, postChange: { notifications.append(model.symbols) })
        await model.reload().value
        precondition(model.symbols == defaults && model.error == nil)
        let store = T9QuickSymbolStore(directory: group.appendingPathComponent("KeyboardQuickSymbols"))
        precondition(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let firstDefault = await model.replaceSymbols(defaults)
        precondition(firstDefault && FileManager.default.fileExists(atPath: store.fileURL.path))
        let firstSnapshot = try store.load()
        let firstBytes = try Data(contentsOf: store.fileURL)
        precondition(firstSnapshot.symbols == defaults)
        let repeatedDefault = await model.replaceSymbols(defaults)
        precondition(!repeatedDefault && model.error == nil)
        precondition(try! Data(contentsOf: store.fileURL) == firstBytes)
        precondition(notifications == [defaults], "no-op saves must not notify")
        print("PASS: an explicit default saves once; identical canonical value is a truthful no-op")

        notifications.removeAll()
        let first = model.beginReplaceSymbols("ABC")
        let read = model.reload()
        let second = model.beginReplaceSymbols("!?")
        let slot = model.beginReplaceSlot(1, with: "#")
        let firstWritten = await first.value
        await read.value
        let secondWritten = await second.value
        let slotWritten = await slot.value
        precondition(firstWritten && secondWritten && slotWritten)
        precondition(model.symbols == "!#")
        precondition(notifications == ["ABC", "!?", "!#"], "notifications follow accepted FIFO snapshots")
        precondition(try! store.load().symbols == "!#")
        _ = try store.replaceSlot(0, with: "=")
        let explicit = await model.replaceSymbols("[]{}")
        precondition(explicit && model.symbols == "[]{}")
        precondition(try! store.load().symbols == "[]{}", "explicit whole-list edit replaces the latest list")
        print("PASS: list saves, reads and slot edits share FIFO; notifications preserve accepted order")

        let short = await model.replaceSymbols("👍🏽")
        precondition(short && model.symbols.count == 1)
        precondition(try! store.load().symbols == "👍🏽", "display defaults must not expand saved short lists")
        let validBytes = try Data(contentsOf: store.fileURL)
        let broadcastCount = notifications.count
        for invalid in ["", "AA", "A B", "A\nB", "\u{0}", "abcdefghijklm"] {
            let wrote = await model.replaceSymbols(invalid)
            precondition(!wrote && model.error != nil)
            precondition(model.symbols == "👍🏽")
            precondition(try! Data(contentsOf: store.fileURL) == validBytes)
            precondition(notifications.count == broadcastCount)
        }
        let restored = await model.replaceSymbols(defaults)
        precondition(restored && model.error == nil && model.symbols == defaults)
        precondition(try! store.load().symbols == defaults)
        let repeatedRestore = await model.replaceSymbols(defaults)
        precondition(!repeatedRestore && model.error == nil)
        print("PASS: duplicate/invalid lists fail without changing data or notifying; default restore is a save")

        var unavailableBroadcasts = 0
        let unavailable = T9QuickSymbolModel(sharedContainer: { nil },
            observesNotifications: false, postChange: { unavailableBroadcasts += 1 })
        await unavailable.reload().value
        let unavailableWritten = await unavailable.replaceSymbols("[]{}")
        precondition(!unavailableWritten && unavailable.symbols == defaults)
        precondition(unavailable.error?.contains("无法访问共享数据") == true)
        precondition(unavailable.fileURL == nil && !unavailable.isShared && unavailableBroadcasts == 0)

        let corruptGroup = base.appendingPathComponent("corrupt")
        let corruptStore = T9QuickSymbolStore(directory: corruptGroup.appendingPathComponent("KeyboardQuickSymbols"))
        try FileManager.default.createDirectory(at: corruptStore.directory, withIntermediateDirectories: true)
        let damaged = Data("{broken-original-data".utf8)
        try damaged.write(to: corruptStore.fileURL)
        var corruptBroadcasts = 0
        let corrupt = T9QuickSymbolModel(sharedContainer: { corruptGroup },
            observesNotifications: false, postChange: { corruptBroadcasts += 1 })
        await corrupt.reload().value
        let corruptWritten = await corrupt.replaceSymbols("!?")
        precondition(!corruptWritten && corrupt.error != nil && corrupt.symbols == defaults)
        precondition(try! Data(contentsOf: corruptStore.fileURL) == damaged && corruptBroadcasts == 0)
        let corruptRestore = await corrupt.replaceSymbols(defaults)
        precondition(!corruptRestore && corrupt.error != nil)
        precondition(try! Data(contentsOf: corruptStore.fileURL) == damaged)
        print("PASS: missing group and corrupt canonical data fail explicitly and preserve original content")

        let readOnlyGroup = base.appendingPathComponent("read-only")
        var readOnlyBroadcasts = 0
        let readOnly = T9QuickSymbolModel(sharedContainer: { readOnlyGroup }, canWrite: { false },
            observesNotifications: false, postChange: { readOnlyBroadcasts += 1 })
        await readOnly.reload().value
        let readOnlyWritten = await readOnly.replaceSymbols("[]{}")
        precondition(!readOnlyWritten && readOnly.error?.contains("允许完全访问") == true)
        precondition(!FileManager.default.fileExists(atPath: readOnlyGroup.path) && readOnlyBroadcasts == 0)
        print("PASS: without Full Access nothing is written to the shared container")
    }
}
'''


class QuickSymbolManagementStructureTests(unittest.TestCase):
    def test_preview_appends_defaults_without_changing_stored_list(self):
        view = VIEW.read_text(encoding="utf-8")
        # The preview delegates to the production ordering source (UX04 fix):
        # saved-first + defaults + ASCII mapping + dedup + trailing first-key
        # punctuation, all defined in one place (BuiltinLayouts).
        self.assertIn("BuiltinLayouts.t9QuickSymbolValues(saved: draftSymbols, ascii: false)", view)
        # The stored list is only the user's own draft — the preview never
        # feeds back into it.
        self.assertIn("previewSymbols.prefix(3)", view)
        self.assertIn("previewSymbols.dropFirst(3)", view)
        self.assertIn("Set(draftSymbols).count == draftSymbols.count", view)
        self.assertNotIn("replaceSymbols(previewSymbols", view)
        # The old hand-rolled duplication is gone.
        self.assertNotIn("draftSymbols + T9QuickSymbolStore.defaultSymbols", view)
        self.assertNotIn("seen.insert($0).inserted", view)


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class QuickSymbolManagementBehaviorTests(unittest.TestCase):
    def test_real_store_model_fifo_noop_validation_and_failure(self):
        model = MODEL.read_text(encoding="utf-8")
        print(run_swift(model, "import LayoutKit\n" + MODEL_CHECKS,
                        prefix="quick-symbol-management", library=True, dependencies=("LayoutKit",)), end="")


if __name__ == "__main__":
    unittest.main()
