import XCTest

@testable import KeyboardCore

/// `ProductionInputAvailability`: the built-in scheme's identities and the copy the keyboard shows
/// when nothing is published.
final class ProductionInputAvailabilityTests: XCTestCase {

    func testBuiltinResourceIdentityIsRecognizedIncludingNilRoute() {
        XCTAssertTrue(
            ProductionInputAvailability.isBuiltin(
                resourceID: ProductionInputAvailability.builtinResourceID))
        XCTAssertTrue(
            ProductionInputAvailability.isBuiltin(resourceID: nil),
            "no explicit resource set (the KeyboardPadSession default route) is treated as built-in")
        XCTAssertFalse(ProductionInputAvailability.isBuiltin(resourceID: "pkg-a"))
        XCTAssertFalse(ProductionInputAvailability.isBuiltin(resourceID: "user-pinyin"))
        // The installed built-in scheme publishes like any package, not as the bundled fallback.
        XCTAssertFalse(
            ProductionInputAvailability.isBuiltin(
                resourceID: ProductionInputAvailability.builtinPackageID))
    }

    func testInstallationSummaryCountsEveryInstalledScheme() {
        XCTAssertEqual(
            UserTerminology.installedSourceSummary(count: 0),
            ProductionInputAvailability.unconfiguredCountSummary)
        XCTAssertEqual(UserTerminology.installedSourceSummary(count: 1), "已安装 1 个输入方案")
    }

    func testRuntimeFallbackTextsNameTheBuiltinScheme() {
        XCTAssertEqual(ProductionInputAvailability.fallbackInputMethodName, "内置全拼")
        XCTAssertEqual(ProductionInputAvailability.runtimeUnconfiguredSchemeName, "内置输入方案")
        XCTAssertEqual(ProductionInputAvailability.runtimeUnconfiguredReason, "正在使用内置全拼")
        for text in [
            ProductionInputAvailability.runtimeUnconfiguredReason,
            ProductionInputAvailability.runtimeUnconfiguredNotice,
            ProductionInputAvailability.unconfiguredCountSummary,
        ] {
            XCTAssertFalse(text.contains("内置拼音"), text)
            XCTAssertFalse(text.contains("离线基础拼音"), text)
            XCTAssertNil(UserTerminology.leaksInternalTerminology(text), text)
        }
    }
}
