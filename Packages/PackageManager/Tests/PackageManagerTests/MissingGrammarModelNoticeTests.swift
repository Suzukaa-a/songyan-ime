import XCTest

@testable import PackageManager

/// A scheme that needs grammar models must say so. Reporting a missing model as a corrupt
/// download sends the user looking for a different file instead of adding the model.
final class MissingGrammarModelNoticeTests: XCTestCase {
    func testMissingModelIsNotReportedAsACorruptFile() {
        let error = RecipeInstallError.missingGrammarModels(["wanxiang-lts-zh-hans.gram"])
        XCTAssertFalse(error.userFacingDescription.contains("不完整"))
        XCTAssertFalse(error.userFacingDescription.contains("格式不正确"))
    }

    func testMissingModelNamesTheNextStep() {
        let error = RecipeInstallError.missingGrammarModels(["wanxiang-lts-zh-hans.gram"])
        XCTAssertTrue(error.userFacingDescription.contains("语法模型"))
        XCTAssertTrue(error.userFacingDescription.contains("重试"))
    }

    func testModelPathStaysOutOfTheUserFacingCopy() {
        let path = "wanxiang-lts-zh-hans.gram"
        XCTAssertFalse(
            RecipeInstallError.missingGrammarModels([path]).userFacingDescription.contains(path),
            "package-relative paths belong in the developer log")
    }
}
