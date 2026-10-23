import Combine
import Foundation

enum KeyboardRecipeStore {
    nonisolated(unsafe) static var canWriteSharedContainer = true
    static let groupID = "test.t9.symbols"
    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    static func sharedDefaults() -> UserDefaults? { UserDefaults(suiteName: groupID) }
}
enum KeyboardFeedbackPreferences { static var defaults: UserDefaults { .standard } }
@MainActor final class UIProbe {
    let quickSymbols: T9QuickSymbolModel
    var feedback = 0
    init(_ model: T9QuickSymbolModel) { quickSymbols = model }
    func emitSelectionFeedback() { feedback += 1 }
    // The exact contract the Panel must adopt: await the async save and emit
    // selection feedback only when the model reports a real successful write.
    func choose(_ symbol: String, index: Int = 0) async {
        if await quickSymbols.replaceSlot(index, with: symbol) { emitSelectionFeedback() }
    }
}
@main struct Main {
    @MainActor static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaultSymbols = T9QuickSymbolStore.defaultSymbols
        precondition(defaultSymbols == "，。？！、…", "the shipped default must be the reviewed Chinese punctuation set")
        var shared: URL? = nil
        var broadcasts = 0
        let unavailable = T9QuickSymbolModel(
            sharedContainer: { shared },
            observesNotifications: false, postChange: { broadcasts += 1 })
        await unavailable.reload().value
        let ui = UIProbe(unavailable)
        precondition(unavailable.symbols == defaultSymbols)
        await ui.choose("#")
        precondition(unavailable.symbols == defaultSymbols)
        precondition(unavailable.error?.contains("无法访问共享数据") == true)
        precondition(!unavailable.isShared && unavailable.fileURL == nil && ui.feedback == 0 && broadcasts == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: base.path)
        precondition(files.isEmpty, "a missing container must never write a private fallback file")
        shared = base.appendingPathComponent("group")
        await unavailable.reload().value
        await ui.choose("#")
        let edited = "#" + defaultSymbols.dropFirst()
        precondition(unavailable.symbols == edited && unavailable.error == nil && ui.feedback == 1)
        shared = nil
        let previousBroadcasts = broadcasts
        await unavailable.reload().value
        await ui.choose("!")
        precondition(unavailable.symbols == edited && ui.feedback == 1 && broadcasts == previousBroadcasts)
        print(
            "PASS async UI contract: missing group keeps old value, visible model error, no success feedback, no writes or broadcast"
        )

        let group = base.appendingPathComponent("baseline")
        let model = T9QuickSymbolModel(
            sharedContainer: { group },
            observesNotifications: false, postChange: {})
        await model.reload().value
        precondition(model.symbols == defaultSymbols)
        precondition(!FileManager.default.fileExists(atPath: model.fileURL!.path))
        let editor = UIProbe(model)
        await editor.choose(String(defaultSymbols.first!))
        precondition(editor.feedback == 1 && FileManager.default.fileExists(atPath: model.fileURL!.path))
        let other = T9QuickSymbolModel(
            sharedContainer: { group },
            observesNotifications: false, postChange: {})
        await other.reload().value
        precondition(other.symbols == defaultSymbols)
        print("PASS async UI contract: same default selection persists canonical baseline before reporting success")

        // Latest request wins: concurrent slot saves and duplicate reloads must
        // never drop a user edit, and a stale read must not clobber a newer save.
        let concurrent = base.appendingPathComponent("concurrent")
        let live = T9QuickSymbolModel(
            sharedContainer: { concurrent },
            observesNotifications: false, postChange: {})
        await live.reload().value
        async let saveA = live.replaceSlot(0, with: "A")
        async let saveB = live.replaceSlot(1, with: "B")
        let (okA, okB) = await (saveA, saveB)
        precondition(okA && okB, "both concurrent slot saves must report success")
        precondition(live.symbols.count == defaultSymbols.count)
        precondition(live.symbols.contains("A") && live.symbols.contains("B"))
        async let saveC = live.replaceSlot(2, with: "C")
        async let reload1 = live.reload().value
        async let reload2 = live.reload().value
        _ = await (saveC, reload1, reload2)
        precondition(live.symbols.contains("C"), "a duplicate reload must not drop a concurrent save")
        let fresh = T9QuickSymbolModel(
            sharedContainer: { concurrent },
            observesNotifications: false, postChange: {})
        await fresh.reload().value
        precondition(
            fresh.symbols.contains("A") && fresh.symbols.contains("B") && fresh.symbols.contains("C"),
            "all concurrent edits must survive on disk")
        print("PASS async model: latest request wins; concurrent saves and duplicate reloads never lose user edits")

        // Real UI touches enqueue synchronously before yielding to a Task.
        // Two edits to the same slot must keep the *last gesture*, not the
        // arbitrary order in which unstructured Tasks happen to start.
        let firstTouch = live.beginReplaceSlot(0, with: "甲")
        let lastTouch = live.beginReplaceSlot(0, with: "乙")
        let firstSaved = await firstTouch.value
        let lastSaved = await lastTouch.value
        precondition(firstSaved && lastSaved)
        precondition(live.symbols.first == "乙")
        await fresh.reload().value
        precondition(fresh.symbols.first == "乙")
        print("PASS touch-order writes to one slot: the last visible choice survives")
    }
}
