import Darwin
import Foundation
import KeyboardCore
import LayoutKit

/// The exercised rows copy path never reads categories: only the categorised branch calls this
/// seam. Keeping the stub here lets the real production copy function below compile unchanged.
enum KeyboardPageDraftProbe {
    static func authoredCategories() async throws -> [KeyboardPageCategory] {
        throw LayoutError.invalid("分类快照不应在 rows 复制里读取")
    }

    static func numericCopyName(marks: KeyboardNumericMarks, form: KeyboardNumericForm) -> String {
        "副本"
    }

    /* PRODUCTION_COPY_FUNCTION */

    /* PRODUCTION_EDITABLE_DRAFT_FUNCTION */
}

/// The real face-update members of LayoutKeyFields, injected below, exercised as data.
struct KeyFaceProbeSupport {
    let key: LayoutKey
    var allowsTitleMode = true

    private var isFunctionKey: Bool { key.action.type != .code && key.action.type != .literal }

    /* PRODUCTION_SUPPORTS_LIVE_TITLE */

    /* PRODUCTION_DISPLAYED_TITLE_MODE */

    /* PRODUCTION_UPDATING_ACTION */

    /* PRODUCTION_UPDATING_LABEL */
}

@main
struct Probe {
    static var failures: [String] = []

    static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func keys(_ rows: [LayoutRow]) -> [LayoutKey] {
        rows.flatMap(\.keys)
    }

    static func main() async throws {
        var modified = KeyboardPagePresets.symbolsSystem
        modified.name = "作者符号页"
        let authorKey = LayoutKey(
            label: "笑脸", secondaryLabel: "副", width: 2.5,
            action: LayoutAction(.literal, value: "☺", asciiValue: ":)"),
            longPress: [LayoutOption(label: "长按", action: LayoutAction(.literal, value: "开心"))],
            titleMode: .custom)
        var firstRow = modified.rows[0].keys
        firstRow[0] = authorKey
        modified.rows[0] = LayoutRow(keys: firstRow)
        modified.split = LayoutSplitConfiguration(
            rowBreaks: [3, 3], gapFraction: 0.4, activation: .always)

        let rowsCopy = try await KeyboardPageDraftProbe.copy(modified, presentation: .rows)
        check(rowsCopy.id != modified.id, "copy gets a new id")
        check(rowsCopy.name == "作者符号页 副本", "copy keeps the author page name")
        check(rowsCopy.symbolPresentation == .rows, "automatic symbol page copies as authored rows")
        check(rowsCopy.defaultSymbolMarks == nil, "copy without a chosen branch follows the keyboard")
        let copiedKey = keys(rowsCopy.rows).first { $0.label == "笑脸" }
        check(copiedKey?.action.value == "☺", "author literal value survives")
        check(copiedKey?.action.asciiValue == ":)", "author ASCII value survives")
        check(copiedKey?.width == 2.5, "author width survives")
        check(copiedKey?.secondaryLabel == "副", "author secondary label survives")
        check(copiedKey?.titleMode == .custom, "author title mode survives")
        check(copiedKey?.longPress?.first?.label == "长按", "author long press survives")
        check(copiedKey?.longPress?.first?.action.value == "开心", "author long press action survives")
        check(rowsCopy.split?.enabled == true, "author split stays enabled")
        check(rowsCopy.split?.gapFraction == 0.4, "author split gap survives")
        check(rowsCopy.split?.activation == .always, "author split activation survives")
        check(modified.rows[0].keys[0].label == "笑脸", "the source page is not mutated")

        let untouched = KeyboardPagePresets.symbolsSystem
        let asciiCopy = try await KeyboardPageDraftProbe.copy(
            untouched, presentation: .rows, numericMarks: .ascii)
        let asciiExpected = KeyboardPagePresets.symbolsEnglish.materialized(numericMarks: .ascii)
        check(
            asciiCopy.rows == asciiExpected.rows,
            "untouched automatic copy takes the ASCII label and long-press snapshot")
        check(asciiCopy.defaultSymbolMarks == .ascii, "untouched ASCII copy pins the ASCII branch")
        check(asciiCopy.rows != untouched.rows, "ASCII snapshot differs from the Chinese canonical rows")

        let chineseCopy = try await KeyboardPageDraftProbe.copy(
            untouched, presentation: .rows, numericMarks: .chinese)
        check(chineseCopy.defaultSymbolMarks == .chinese, "explicit Chinese copy pins Chinese")
        check(
            chineseCopy.rows == KeyboardPagePresets.symbolsChinese.materialized(numericMarks: .chinese).rows,
            "untouched Chinese copy matches the canonical Chinese rows")

        // Editing an automatic page that pins a branch must keep that author choice.
        var explicitAutomatic = KeyboardPagePresets.numericAutomatic
        explicitAutomatic.defaultSymbolMarks = .ascii
        let explicitDraft = try await KeyboardPageDraftProbe.editableDraft(explicitAutomatic)
        check(explicitDraft.defaultSymbolMarks == .ascii, "editing keeps an explicit automatic branch")
        check(
            explicitDraft.rows == explicitAutomatic.materialized(numericMarks: .ascii).rows,
            "an explicit branch materializes with its own snapshot")
        var explicitSymbols = KeyboardPagePresets.symbolsSystem
        explicitSymbols.defaultSymbolMarks = .ascii
        let symbolsDraft = try await KeyboardPageDraftProbe.editableDraft(explicitSymbols)
        check(symbolsDraft.defaultSymbolMarks == .ascii, "editing keeps an explicit symbol branch")
        let followDraft = try await KeyboardPageDraftProbe.editableDraft(KeyboardPagePresets.numericAutomatic)
        check(followDraft.defaultSymbolMarks == nil, "editing a follow-input page keeps nil")

        // Editing a legacy fixed literal must keep its author label face, not promote it.
        let fixed = KeyFaceProbeSupport(key: LayoutKey(label: "笑脸", action: .init(.literal, value: "☺")))
        check(!fixed.supportsLiveTitle, "fixed literal keeps its author label without a face picker")
        let pairedKey = fixed.updatingAction(LayoutAction(.literal, value: "☺", asciiValue: ":)"))
        check(pairedKey.titleMode == nil, "first pairing keeps the legacy nil title mode")
        let paired = KeyFaceProbeSupport(key: pairedKey)
        check(paired.displayedTitleMode == .custom, "paired legacy literal displays custom")
        check(paired.supportsLiveTitle, "paired literal exposes the face picker")
        let clearedKey = paired.updatingAction(LayoutAction(.literal, value: "☺"))
        check(clearedKey.titleMode == nil, "clearing the pair keeps nil")
        let custom = KeyFaceProbeSupport(key: pairedKey.settingTitleMode(.custom))
        let clearedCustom = custom.updatingAction(LayoutAction(.literal, value: "☺"))
        check(clearedCustom.titleMode == .custom, "clearing the pair keeps an authored custom face")
        let repaired = KeyFaceProbeSupport(key: clearedCustom).updatingAction(
            LayoutAction(.literal, value: "☺", asciiValue: ":)"))
        check(repaired.titleMode == .custom, "re-pairing keeps custom instead of promoting automatic")
        let fromFunction = KeyFaceProbeSupport(
            key: LayoutKey(label: "中英", action: .languageSwitch(), titleMode: .automatic))
        let switched = fromFunction.updatingAction(LayoutAction(.literal, value: "。"))
        check(switched.titleMode == nil, "switching a function key to fixed literal clears the live face")
        let backToFunction = KeyFaceProbeSupport(key: fixed.key).updatingAction(.languageSwitch())
        check(backToFunction.titleMode == .automatic, "switching a literal to a function follows the live face")

        // New built-in rows carry an explicit automatic face on digits: renaming must actually
        // switch to the author's custom face instead of being reset to automatic.
        let digitKey = LayoutKey(
            label: "1", width: 2, action: .init(.literal, value: "1"),
            longPress: [LayoutOption(label: "一", action: .init(.literal, value: "一"))],
            titleMode: .automatic)
        let digit = KeyFaceProbeSupport(key: digitKey)
        check(digit.supportsLiveTitle, "automatic literal digit exposes the face picker")
        check(digit.displayedTitleMode == .automatic, "new digit starts on the live face")
        let renamedDigit = digit.updatingLabel("RootLabel")
        check(renamedDigit.label == "RootLabel", "renaming a digit keeps the author text")
        check(renamedDigit.titleMode == .custom, "renaming a digit really switches to custom")
        check(renamedDigit.action.value == "1", "renaming a digit keeps the action value")
        check(renamedDigit.width == 2, "renaming a digit keeps the width")
        check(renamedDigit.longPress?.first?.label == "一", "renaming a digit keeps long press")

        // A paired literal that was on the live face, then cleared, must still allow a face rename.
        let pairedAutomatic = LayoutKey(
            label: "，", width: 2.5,
            action: .init(.literal, value: "，", asciiValue: ","),
            longPress: [LayoutOption(label: "长按", action: .init(.literal, value: "逗号"))],
            titleMode: .automatic)
        let clearedAutomatic = KeyFaceProbeSupport(key: pairedAutomatic).updatingAction(
            LayoutAction(.literal, value: "，"))
        check(clearedAutomatic.titleMode == .automatic, "clearing a pair keeps its automatic face")
        let clearedFace = KeyFaceProbeSupport(key: clearedAutomatic)
        check(clearedFace.supportsLiveTitle, "cleared pair still exposes the face picker")
        let renamedCleared = clearedFace.updatingLabel("RootLabel")
        check(renamedCleared.label == "RootLabel", "renaming a cleared pair keeps the text")
        check(renamedCleared.titleMode == .custom, "renaming a cleared pair switches to custom")
        check(renamedCleared.action.value == "，", "renaming a cleared pair keeps its value")
        check(renamedCleared.width == 2.5, "renaming a cleared pair keeps its width")

        // A legacy fixed literal without any title mode still edits its text as before.
        let legacyFixed = KeyFaceProbeSupport(key: LayoutKey(label: "☺", action: .init(.literal, value: "☺")))
        check(!legacyFixed.supportsLiveTitle, "legacy fixed literal keeps no face picker")
        let renamedLegacy = legacyFixed.updatingLabel("作者笑脸")
        check(renamedLegacy.label == "作者笑脸", "legacy fixed literal keeps its text")
        check(renamedLegacy.titleMode == nil, "legacy fixed literal keeps its legacy title mode")

        if failures.isEmpty {
            print("keyboard-page-drafts: ok")
        } else {
            for failure in failures { print("FAIL: " + failure) }
            Darwin.exit(1)
        }
    }
}
