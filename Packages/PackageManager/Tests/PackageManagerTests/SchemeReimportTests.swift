import XCTest

@testable import PackageManager

final class SchemeReimportTests: XCTestCase {
    private let wanxiang = InstalledSchemeIdentity(id: "scheme-a", name: "万象拼音", entrySchemaID: "wanxiang")
    private let rimeIce = InstalledSchemeIdentity(id: "scheme-b", name: "雾凇拼音", entrySchemaID: "rime_ice")

    func testNewerFilesOfTheSameSchemeReplaceIt() {
        // Newer files hash to another ID, so only the entry input method can identify the scheme.
        XCTAssertEqual(
            SchemeReimport.replacing(
                entrySchemaID: "wanxiang", importedID: "scheme-newer",
                installed: [wanxiang, rimeIce]), wanxiang)
    }

    func testTheSameBytesAreNotAReplacement() {
        XCTAssertNil(
            SchemeReimport.replacing(
                entrySchemaID: "wanxiang", importedID: "scheme-a",
                installed: [wanxiang, rimeIce]))
    }

    func testAnotherEntryInputMethodInstallsSeparately() {
        XCTAssertNil(
            SchemeReimport.replacing(
                entrySchemaID: "double_pinyin", importedID: "scheme-newer",
                installed: [wanxiang, rimeIce]))
    }

    func testAnUnknownEntryNeverMatches() {
        // Without a provable identity the import must stay a new package, not overwrite a scheme.
        XCTAssertNil(
            SchemeReimport.replacing(
                entrySchemaID: "", importedID: "scheme-newer",
                installed: [wanxiang, rimeIce]))
    }

    func testFirstInstallHasNothingToReplace() {
        XCTAssertNil(SchemeReimport.replacing(entrySchemaID: "wanxiang", importedID: "scheme-a", installed: []))
    }
}
