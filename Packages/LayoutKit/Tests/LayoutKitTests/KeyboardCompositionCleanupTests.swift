import Foundation
import XCTest

@testable import LayoutKit

/// Page pairings must not outlive the input methods that provide them, and must survive
/// everything else: a scheme that is merely disabled or unused keeps its pairing.
final class KeyboardCompositionCleanupTests: XCTestCase {
    /// A registry holding one default pairing per keyboard id, with a main layout that really
    /// serves that input method's layout capability (the catalog validates the pairing).
    private func registry(withKeyboardIDs ids: [String]) throws -> LayoutRegistry {
        var registry = try LayoutRegistry()
        for id in ids {
            let separator = id.lastIndex(of: ":")!
            let methodID = String(id[..<separator])
            let kind = LayoutInput.Builtin(rawValue: String(id[id.index(after: separator)...]))!
            let main = BuiltinLayouts.all.first {
                $0.supportsComposition(inputMethodID: methodID, layout: kind)
            }!
            try registry.setComposition(.init(mainLayoutID: main.id), for: id)
        }
        return registry
    }

    func testRemovingTheLastProviderDropsThePairing() throws {
        var registry = try registry(withKeyboardIDs: ["removed_method:qwerty26"])
        let removed = registry.pruneCompositions { $0 == "removed_method" }
        XCTAssertEqual(removed, 1)
        XCTAssertNil(registry.compositions["removed_method:qwerty26"])
        XCTAssertNoThrow(try registry.validate())
    }

    func testPairingSurvivesWhileAnotherProviderStillOffersTheInputMethod() throws {
        var registry = try registry(withKeyboardIDs: ["shared_method:qwerty26", "shared_method:merged14"])
        let providers: Set<String> = ["shared_method"]
        let removed = registry.pruneCompositions { !providers.contains($0) }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(registry.compositions.count, 2)
    }

    /// Disabling or not using a keyboard changes no pairing: cleanup only reacts to a
    /// provider set that no longer contains the input method.
    func testDisabledOrUnusedKeyboardKeepsItsPairing() throws {
        var registry = try registry(withKeyboardIDs: ["kept_method:qwerty26"])
        let providers: Set<String> = ["kept_method"]
        let removed = registry.pruneCompositions { !providers.contains($0) }
        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(registry.compositions["kept_method:qwerty26"])
    }

    /// The reported bug: a pairing left by a deleted scheme used to block removal forever.
    func testPageAndLayoutBecomeRemovableAfterCleanup() throws {
        var registry = try LayoutRegistry()
        let page = KeyboardPagePresets.numericChinese.copy(name: "我的数字")
        try registry.savePage(page)
        let layout = BuiltinLayouts.qwerty26.copy(name: "我的布局")
        try registry.install(layout.encoded())
        try registry.setComposition(
            .init(mainLayoutID: layout.id, numericPageID: page.id), for: "gone_method:qwerty26")
        XCTAssertThrowsError(try registry.removePage(id: page.id))
        XCTAssertThrowsError(try registry.remove(id: layout.id))

        let removed = registry.pruneCompositions { $0 == "gone_method" }
        XCTAssertEqual(removed, 1)
        XCTAssertNoThrow(try registry.removePage(id: page.id))
        XCTAssertNoThrow(try registry.remove(id: layout.id))
        XCTAssertNil(registry.page(id: page.id))
        XCTAssertNil(registry.layout(id: layout.id))
    }

    func testPruningKeepsUnattributableAndUnrelatedPairings() throws {
        var registry = try registry(withKeyboardIDs: ["unrelated_method:qwerty26"])
        let removed = registry.pruneCompositions { $0 == "gone_method" }
        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(registry.compositions["unrelated_method:qwerty26"])
    }

    /// The same input method on another layout goes only when that method has no provider.
    func testEveryLayoutOfTheSameInputMethodIsCleanedTogether() throws {
        var registry = try registry(withKeyboardIDs: ["gone_method:qwerty26", "gone_method:merged14"])
        let removed = registry.pruneCompositions { $0 == "gone_method" }
        XCTAssertEqual(removed, 2)
        XCTAssertTrue(registry.compositions.isEmpty)
    }

    /// An empty result is not a write: calling cleanup with every provider present is a no-op.
    func testCleanupWithNoObsoleteInputMethodChangesNothing() throws {
        var registry = try registry(withKeyboardIDs: ["present_method:qwerty26"])
        let before = registry
        let removed = registry.pruneCompositions { _ in false }
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(registry, before)
    }
}
