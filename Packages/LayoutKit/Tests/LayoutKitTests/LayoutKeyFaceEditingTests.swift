import XCTest

@testable import LayoutKit

final class LayoutKeyFaceEditingTests: XCTestCase {
    func testPairingAndClearingALegacyFixedLiteralKeepsItsAuthorFace() {
        let fixed = LayoutKey(label: "笑脸", action: .init(.literal, value: "☺"))
        XCTAssertFalse(fixed.supportsLiveTitle)
        let paired = fixed.editingAction(LayoutAction(.literal, value: "☺", asciiValue: ":)"), allowsTitleMode: true)
        XCTAssertNil(paired.titleMode, "first pairing keeps the legacy nil title mode")
        XCTAssertEqual(paired.displayedTitleMode, .custom)
        XCTAssertTrue(paired.supportsLiveTitle)
        XCTAssertNil(paired.editingAction(LayoutAction(.literal, value: "☺"), allowsTitleMode: true).titleMode)

        let custom = paired.settingTitleMode(.custom)
        let clearedCustom = custom.editingAction(LayoutAction(.literal, value: "☺"), allowsTitleMode: true)
        XCTAssertEqual(clearedCustom.titleMode, .custom, "clearing the pair keeps an authored custom face")
        let repaired = clearedCustom.editingAction(
            LayoutAction(.literal, value: "☺", asciiValue: ":)"), allowsTitleMode: true)
        XCTAssertEqual(repaired.titleMode, .custom, "re-pairing never promotes the face to automatic")
    }

    func testSwitchingBetweenFunctionAndLiteralResetsTheLiveFace() {
        let function = LayoutKey(label: "中英", action: .languageSwitch(), titleMode: .automatic)
        XCTAssertNil(function.editingAction(LayoutAction(.literal, value: "。"), allowsTitleMode: true).titleMode)
        let fixed = LayoutKey(label: "笑脸", action: .init(.literal, value: "☺"))
        XCTAssertEqual(fixed.editingAction(.languageSwitch(), allowsTitleMode: true).titleMode, .automatic)
        XCTAssertNil(
            function.editingAction(LayoutAction(.code, value: "a"), allowsTitleMode: true).titleMode,
            "a character key carries no title class")
    }

    func testRenamingALiveKeySwitchesItToTheAuthorsTitleAndKeepsEveryOtherField() {
        let digit = LayoutKey(
            label: "1", width: 2, action: .init(.literal, value: "1"),
            longPress: [LayoutOption(label: "一", action: .init(.literal, value: "一"))], titleMode: .automatic)
        XCTAssertTrue(digit.supportsLiveTitle)
        XCTAssertEqual(digit.displayedTitleMode, .automatic)
        let renamed = digit.editingLabel("壹", allowsTitleMode: true)
        XCTAssertEqual(renamed.label, "壹")
        XCTAssertEqual(renamed.titleMode, .custom)
        XCTAssertEqual(renamed.action.value, "1")
        XCTAssertEqual(renamed.width, 2)
        XCTAssertEqual(renamed.longPress?.first?.label, "一")

        let pairedAutomatic = LayoutKey(
            label: "，", width: 2.5, action: .init(.literal, value: "，", asciiValue: ","), titleMode: .automatic)
        let cleared = pairedAutomatic.editingAction(LayoutAction(.literal, value: "，"), allowsTitleMode: true)
        XCTAssertEqual(cleared.titleMode, .automatic, "clearing a pair keeps its automatic face")
        XCTAssertTrue(cleared.supportsLiveTitle)
        XCTAssertEqual(cleared.editingLabel("逗", allowsTitleMode: true).titleMode, .custom)
    }

    func testLegacyFixedLiteralsAndEditorsWithoutTitleModesKeepTheStoredFace() {
        let legacy = LayoutKey(label: "☺", action: .init(.literal, value: "☺"))
        let renamed = legacy.editingLabel("作者笑脸", allowsTitleMode: true)
        XCTAssertEqual(renamed.label, "作者笑脸")
        XCTAssertNil(renamed.titleMode)

        let enter = LayoutKey(label: "换行", action: LayoutAction(.enter))
        XCTAssertNil(enter.editingLabel("发送", allowsTitleMode: false).titleMode)
        XCTAssertNil(enter.editingAction(LayoutAction(.space), allowsTitleMode: false).titleMode)
        XCTAssertEqual(LayoutKey(label: "空格", action: LayoutAction(.space)).displayedTitleMode, .custom)
        XCTAssertEqual(enter.displayedTitleMode, .automatic)
    }
}
