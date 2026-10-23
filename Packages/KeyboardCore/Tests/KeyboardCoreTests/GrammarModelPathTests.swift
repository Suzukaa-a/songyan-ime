import XCTest

@testable import KeyboardCore

final class GrammarModelPathTests: XCTestCase {
    func testSafeModelPathsPreserveUnicodeAndSubdirectories() {
        for path in ["model.gram", "模型.gram", "models/中文模型.gram", "models/my model.gram"] {
            XCTAssertTrue(GrammarModelPath.isValid(path), path)
            XCTAssertEqual(GrammarModelPath.path(for: String(path.dropLast(5))), path)
        }
    }

    func testUnsafeAndEmptyReferencesAreRejected() {
        for path in [
            ".gram", "..gram", "...gram", "", "model.txt", "/model.gram", "../model.gram", "models/../model.gram",
            "./model.gram", "models//model.gram", "models/\\model.gram", "C:model.gram",
            "models/\u{0}model.gram", "models/\nmodel.gram", "models/\u{7f}model.gram",
        ] {
            XCTAssertFalse(GrammarModelPath.isValid(path), path)
        }
        XCTAssertNil(GrammarModelPath.path(for: ""))
    }
}
