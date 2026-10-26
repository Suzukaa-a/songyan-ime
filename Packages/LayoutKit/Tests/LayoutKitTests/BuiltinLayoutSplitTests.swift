import XCTest

@testable import LayoutKit

/// Default split of the merged letter pads: wide surfaces only, while saved layouts (including
/// an explicit off and a custom break) stay exactly as the author stored them.
final class BuiltinLayoutSplitTests: XCTestCase {
    func testMergedLayoutsSplitByDefaultOnlyOnWideSurfaces() throws {
        for layout in [BuiltinLayouts.merged14, BuiltinLayouts.merged18] {
            let split = try XCTUnwrap(layout.split, layout.id)
            XCTAssertEqual(split.activation, .automatic)
            XCTAssertNoThrow(try layout.validate())

            for width in [0.0, 320, 466, KeyboardSurfaceWidth.phoneMaximum] {
                XCTAssertFalse(split.isActive(width: width), "\(layout.id) at \(width)")
                XCTAssertNil(split.resolved(forWidth: width))
            }
            for width in [601.0, 834, 1024, 1366] {
                XCTAssertTrue(split.isActive(width: width), "\(layout.id) at \(width)")
                let resolved = try XCTUnwrap(split.resolved(forWidth: width))
                XCTAssertEqual(resolved.breakIndex(row: 0, keyCount: 5), 3)
                XCTAssertGreaterThan(resolved.gap(width: width, keyCount: 5), 0)
            }
        }
    }

    func testPhoneAndQwertyKeepNoDefaultSplit() {
        for layout in [BuiltinLayouts.qwerty26, BuiltinLayouts.phone9] {
            XCTAssertNil(layout.split, layout.id)
            XCTAssertNil(layout.split?.resolved(forWidth: 1366))
        }
    }

    func testSavedExplicitOffOverridesTheBuiltinDefault() throws {
        let off = LayoutSplitConfiguration(activation: .off)
        let saved = BuiltinLayouts.merged14.settingSplit(off)
        let storedSplit = try XCTUnwrap(saved.split)
        XCTAssertFalse(storedSplit.isActive(width: 1366))
        XCTAssertNil(storedSplit.resolved(forWidth: 1366))

        // A stored catalog keeps the saved definition as-is; loading it must not turn the
        // builtin default back on.
        let registry = try LayoutRegistry(layouts: [
            saved, BuiltinLayouts.merged18, BuiltinLayouts.qwerty26, BuiltinLayouts.phone9,
        ])
        let decoded = try JSONDecoder().decode(LayoutRegistry.self, from: JSONEncoder().encode(registry))
        let restored = try XCTUnwrap(decoded.layout(id: "merged14"))
        XCTAssertEqual(restored.split, off)
    }

    func testSavedCustomSplitConfigurationRoundtripsUnchanged() throws {
        let custom = LayoutSplitConfiguration(rowBreaks: [2, 2, 1], gapFraction: 0.2)
        let saved = BuiltinLayouts.merged14.settingSplit(custom)
        let decoded = try LayoutDefinition.decode(try saved.encoded())
        XCTAssertEqual(decoded.split, custom)
        XCTAssertEqual(decoded.split?.rowBreaks, [2, 2, 1])
        XCTAssertEqual(decoded.split?.gapFraction, 0.2)
    }
}
