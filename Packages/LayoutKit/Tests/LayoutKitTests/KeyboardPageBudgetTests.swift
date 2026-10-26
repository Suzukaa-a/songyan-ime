import XCTest

@testable import LayoutKit

/// Pages spend one budget for row and function keys. Unchanged built-in pages ship in code and
/// cost nothing; an edited built-in page is user content and counts like any other page.
final class KeyboardPageBudgetTests: XCTestCase {
    private func tinyPage(_ id: String) -> KeyboardPageDefinition {
        KeyboardPageDefinition(
            id: id, name: "小页面", kind: .numeric,
            rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])
    }

    func testEveryPresetAndItsEditableCopyFitThePageBudget() throws {
        for preset in KeyboardPagePresets.all {
            XCTAssertNoThrow(try preset.validate(), preset.id)
            for marks in KeyboardNumericMarks.allCases {
                for form in [KeyboardNumericForm.rows, .phoneDigitPad] {
                    let copy = preset.copy(numericMarks: marks, numericForm: form)
                    XCTAssertNoThrow(try copy.validate(), "\(preset.id) \(marks) \(form)")
                }
            }
        }
    }

    func testPresetIDsDoNotSpendTheUserPageAllowance() throws {
        let userPages = (0..<LayoutResourceBudget.pages).map { tinyPage("user.tiny.\($0)") }
        var registry = try LayoutRegistry(pages: userPages + KeyboardPagePresets.all)
        XCTAssertEqual(registry.pages.count, LayoutResourceBudget.pages + KeyboardPagePresets.all.count)
        XCTAssertThrowsError(try registry.savePage(tinyPage("user.over")))
    }

    func testEditedPresetsSpendTheCatalogBudget() throws {
        let userPages = (0..<LayoutResourceBudget.pages).map { tinyPage("user.tiny.\($0)") }
        var registry = try LayoutRegistry(pages: userPages + KeyboardPagePresets.all)
        var edited = KeyboardPagePresets.englishQwerty
        edited.name = "我改过的 ABC"
        XCTAssertThrowsError(try registry.savePage(edited), "an edited preset is a user page")
        // Restoring the preset gives the allowance back.
        XCTAssertNoThrow(try registry.savePage(KeyboardPagePresets.englishQwerty))

        // Totals: user pages already at the alternate cap leave no room for an edited preset's
        // extra long-press options.
        let options = (0..<LayoutResourceBudget.alternatesPerKey).map {
            LayoutOption(label: "o\($0)", action: .init(.literal, value: "o\($0)"))
        }
        let alternatePages = (0..<(LayoutResourceBudget.catalogAlternates / (LayoutResourceBudget.keysPerRegion * 16))).map {
            index in
            KeyboardPageDefinition(
                id: "user.alternates.\(index)", name: "长按页", kind: .numeric,
                rows: [
                    LayoutRow(
                        keys: (0..<LayoutResourceBudget.keysPerRegion).map {
                            LayoutKey(label: "k\($0)", action: .init(.literal, value: "k"), longPress: options)
                        })
                ])
        }
        var full = try LayoutRegistry(pages: alternatePages + KeyboardPagePresets.all)
        var withAlternate = KeyboardPagePresets.numericChinese
        withAlternate.rows[0] = LayoutRow(
            keys: [withAlternate.rows[0].keys[0].settingLongPress([options[0]])]
                + withAlternate.rows[0].keys.dropFirst())
        XCTAssertThrowsError(try full.savePage(withAlternate))
    }

    func testWireOmitsUnchangedPresetsAndKeepsAModifiedOne() throws {
        var registry = try LayoutRegistry()
        let userPage = tinyPage("user.1")
        try registry.savePage(userPage)
        var modifiedPreset = KeyboardPagePresets.symbolsSystem
        modifiedPreset.name = "我改过的符号页"
        try registry.savePage(modifiedPreset)

        let data = try JSONEncoder().encode(registry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wirePages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        XCTAssertEqual(Set(wirePages.compactMap { $0["id"] as? String }), [userPage.id, modifiedPreset.id])
        let reloaded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        XCTAssertEqual(reloaded, registry)
        XCTAssertEqual(reloaded.page(id: modifiedPreset.id)?.name, "我改过的符号页")
    }

    func testFunctionKeysSpendThePageBudget() throws {
        var page = KeyboardPagePresets.numericChinese.materialized()
        page.rows = (0..<(LayoutResourceBudget.keys / LayoutResourceBudget.keysPerRegion)).map { _ in
            LayoutRow(
                keys: (0..<LayoutResourceBudget.keysPerRegion).map {
                    LayoutKey(label: "k\($0)", action: .init(.literal, value: "k"))
                })
        }
        page.chrome = KeyboardPageChrome()
        XCTAssertNoThrow(try page.validate(), "exactly the key limit")
        page.chrome?.bottom = [LayoutKey(label: "清空", action: .init(.clearInput))]
        XCTAssertThrowsError(try page.validate(), "a function key is a key too")

        var longText = KeyboardPagePresets.numericChinese.materialized()
        longText.chrome?.bottom[0] = LayoutKey(label: String(repeating: "x", count: 300), action: .init(.languageSwitch))
        XCTAssertThrowsError(try longText.validate())

        var hugeRegion = KeyboardPagePresets.numericChinese.materialized()
        hugeRegion.chrome?.leading = Array(
            repeating: LayoutKey(label: "x", action: .init(.literal, value: "x")),
            count: LayoutResourceBudget.keysPerRegion + 1)
        XCTAssertThrowsError(try hugeRegion.validate())
    }

    /// A repeated page ID is corrupt input. The order list must not let a dictionary swallow one
    /// copy so that validate() turns a blind eye and the next save drops it forever.
    func testRepeatedPageIDsStayVisibleWithAndWithoutPageOrder() throws {
        let encodedPage = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tinyPage("dup.page")))
        let encodedLayouts = try JSONSerialization.jsonObject(with: JSONEncoder().encode([BuiltinLayouts.qwerty26]))
        for includeOrder in [false, true] {
            var object: [String: Any] = [
                "layouts": encodedLayouts,
                "enabledIDs": [BuiltinLayouts.qwerty26.id],
                "pages": [encodedPage, encodedPage],
            ]
            if includeOrder { object["pageOrder"] = ["dup.page"] }
            let data = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
            XCTAssertEqual(
                decoded.pages.filter { $0.id == "dup.page" }.count, 2,
                "both copies must remain visible to validation (pageOrder: \(includeOrder))")
            XCTAssertThrowsError(try decoded.validate())
        }
    }
}
