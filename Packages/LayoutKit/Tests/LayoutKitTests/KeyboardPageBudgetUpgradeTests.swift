import XCTest

@testable import LayoutKit

/// Upgrading a catalog that already sits at a resource limit must not fail because a release
/// added a code-owned preset, and the wire form must not pay for those presets again.
final class KeyboardPageBudgetUpgradeTests: XCTestCase {
    private func alternatePage(id: String) -> KeyboardPageDefinition {
        let options = (0..<LayoutResourceBudget.alternatesPerKey).map { index in
            LayoutOption(label: "o\(index)", action: .init(.literal, value: "o\(index)"))
        }
        let keys = (0..<(LayoutResourceBudget.keysPerRegion * 2)).map { index in
            LayoutKey(
                label: "k\(index)", action: .init(.literal, value: "k\(index)"), longPress: options)
        }
        return KeyboardPageDefinition(
            id: id, name: "副键页", kind: .numeric,
            rows: [
                LayoutRow(keys: Array(keys[0..<LayoutResourceBudget.keysPerRegion])),
                LayoutRow(keys: Array(keys[LayoutResourceBudget.keysPerRegion...])),
            ])
    }

    func testFullAlternateCatalogSurvivesTheAddedPresets() throws {
        let userPages = (0..<16).map { alternatePage(id: "user.page.\($0)") }
        XCTAssertEqual(
            userPages.reduce(0) { $0 + $1.allKeys.reduce(0) { $0 + ($1.longPress?.count ?? 0) } },
            LayoutResourceBudget.catalogAlternates,
            "the fixture must sit exactly on the old alternate cap")
        let previousPresets = KeyboardPagePresets.all.filter {
            $0.id != KeyboardPagePresets.numericAutomatic.id && $0.id != KeyboardPagePresets.numericKeypad.id
        }
        let wire = try JSONSerialization.data(withJSONObject: [
            "layouts": try JSONSerialization.jsonObject(with: JSONEncoder().encode([BuiltinLayouts.qwerty26])),
            "enabledIDs": [BuiltinLayouts.qwerty26.id],
            "pages": try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(userPages + previousPresets)),
        ])
        let loaded = try JSONDecoder().decode(LayoutRegistry.self, from: wire)
        try loaded.validate()
        XCTAssertNotNil(loaded.page(id: KeyboardPagePresets.numericKeypad.id))
        XCTAssertEqual(loaded.pages.filter { $0.id.hasPrefix("user.page.") }.count, 16)
        XCTAssertEqual(
            loaded.pages.filter { KeyboardPagePresets.codeOwnedIDs.contains($0.id) }.count,
            KeyboardPagePresets.all.count)
    }

    func testPresetIDsDoNotSpendTheUserPageAllowance() throws {
        let userPages = (0..<LayoutResourceBudget.pages).map { index in
            KeyboardPageDefinition(
                id: "user.tiny.\(index)", name: "小页面", kind: .numeric,
                rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])
        }
        let registry = try LayoutRegistry(pages: userPages + KeyboardPagePresets.all)
        try registry.validate()
        XCTAssertEqual(registry.pages.count, LayoutResourceBudget.pages + KeyboardPagePresets.all.count)
        var tooMany = try LayoutRegistry(pages: userPages + KeyboardPagePresets.all)
        XCTAssertThrowsError(
            try tooMany.savePage(
                KeyboardPageDefinition(
                    id: "user.over", name: "多一页", kind: .numeric,
                    rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])))
    }

    func testWireOmitsUnchangedPresetsAndKeepsAModifiedOne() throws {
        var registry = try LayoutRegistry()
        let userPage = KeyboardPageDefinition(
            id: "user.1", name: "我的页", kind: .numeric,
            rows: [LayoutRow(keys: [LayoutKey(label: "1", action: .init(.literal, value: "1"))])])
        try registry.savePage(userPage)
        var modifiedPreset = KeyboardPagePresets.symbolsSystem
        modifiedPreset.name = "我改过的符号页"
        try registry.savePage(modifiedPreset)

        let data = try JSONEncoder().encode(registry)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wirePages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        XCTAssertEqual(
            Set(wirePages.compactMap { $0["id"] as? String }), [userPage.id, modifiedPreset.id])
        let reloaded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        XCTAssertEqual(reloaded, registry)
        XCTAssertEqual(reloaded.page(id: modifiedPreset.id)?.name, "我改过的符号页")
        XCTAssertEqual(
            reloaded.pages.filter { KeyboardPagePresets.codeOwnedIDs.contains($0.id) }.count,
            KeyboardPagePresets.all.count)
    }

    func testChromeKeysSpendThePageBudget() throws {
        func fullRowKeys(_ count: Int) -> [LayoutKey] {
            (0..<count).map { LayoutKey(label: "k\($0)", action: .init(.literal, value: "k\($0)")) }
        }
        var page = KeyboardPagePresets.numericChinese.materialized()
        page.rows = stride(
            from: 0, to: LayoutResourceBudget.keys, by: LayoutResourceBudget.keysPerRegion
        ).map { offset in
            LayoutRow(keys: fullRowKeys(min(LayoutResourceBudget.keysPerRegion, LayoutResourceBudget.keys - offset)))
        }
        // 256 row keys plus the bounded materialisation allowance still leaves no room for an
        // unbounded function area: these extra author keys exceed the per-page allowance.
        page.chrome?.bottom += (0..<12).map { index in
            LayoutKey(label: "extra\(index)", action: .init(.clearInput))
        }
        XCTAssertThrowsError(try page.validate())

        var longText = KeyboardPagePresets.numericChinese.materialized()
        longText.chrome?.bottom[0] = LayoutKey(
            label: String(repeating: "x", count: 300), action: .init(.languageSwitch))
        XCTAssertThrowsError(try longText.validate())

        var hugeRegion = KeyboardPagePresets.numericChinese.materialized()
        hugeRegion.chrome?.leading = Array(
            repeating: LayoutKey(label: "x", action: .init(.literal, value: "x")), count: 33)
        XCTAssertThrowsError(try hugeRegion.validate())
    }

    private func literalKeys(_ count: Int, label: String = "k") -> [LayoutKey] {
        (0..<count).map { _ in LayoutKey(label: label, action: .init(.literal, value: "a")) }
    }

    /// A page saved under the legacy limits already contains content at a cap; materialising the
    /// controls the renderer used to synthesize must not force deleting it to open/save/copy.
    func testMaterialisedLegacyPagesAtRegionAndTotalLimitsStaySavable() throws {
        // 32 keys in the last row (the legacy per-region limit) becomes 34 after Shift + Delete.
        let rowLimited = KeyboardPageDefinition(
            id: "old.row32", name: "旧满行", kind: .english,
            rows: [
                LayoutRow(keys: literalKeys(10)), LayoutRow(keys: literalKeys(9)),
                LayoutRow(keys: literalKeys(32)),
            ])
        try rowLimited.validate()
        let materialisedRow = rowLimited.materialized()
        XCTAssertEqual(materialisedRow.rows[2].keys.count, 34)
        try materialisedRow.validate()
        try assertRegistryRoundTrip(materialisedRow)

        // 256 row keys (the legacy total) plus the footer and the inserted Delete.
        let rowPage = KeyboardPageDefinition(
            id: "old.rows256", name: "旧满键", kind: .numeric,
            rows: (0..<8).map { _ in LayoutRow(keys: literalKeys(32)) })
        try rowPage.validate()
        let materialisedRows = rowPage.materialized()
        XCTAssertEqual(materialisedRows.rows.flatMap(\.keys).count, 257)
        try materialisedRows.validate()
        try materialisedRows.copy().validate()
        try assertRegistryRoundTrip(materialisedRows)

        // 4096 category keys (the legacy categorised page cap) plus the footer and rail.
        let categorized = KeyboardPageDefinition(
            id: "old.cat4096", name: "旧满分类", kind: .symbols, rows: [],
            symbolPresentation: .categorized,
            categories: [
                KeyboardPageCategory(id: "c1", name: "一", keys: literalKeys(2048)),
                KeyboardPageCategory(id: "c2", name: "二", keys: literalKeys(2048)),
            ])
        try categorized.validate()
        let materialisedCategories = categorized.materialized()
        XCTAssertEqual(materialisedCategories.chrome?.allKeys.count, 8)
        try materialisedCategories.validate()
        try assertRegistryRoundTrip(materialisedCategories)

        // Text at the legacy byte cap plus the small default function labels.
        let longLabel = String(repeating: "x", count: 250)
        let textPage = KeyboardPageDefinition(
            id: "old.text", name: "旧满文本", kind: .numeric,
            rows: (0..<8).map { _ in
                LayoutRow(keys: literalKeys(32, label: longLabel))
            })
        try textPage.validate()
        let materialisedText = textPage.materialized()
        try materialisedText.validate()
        try assertRegistryRoundTrip(materialisedText)
    }

    private func assertRegistryRoundTrip(
        _ page: KeyboardPageDefinition, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var registry = try LayoutRegistry()
        try registry.savePage(page)
        let data = try JSONEncoder().encode(registry)
        let reloaded = try JSONDecoder().decode(LayoutRegistry.self, from: data)
        try reloaded.validate()
        XCTAssertEqual(
            reloaded.page(id: page.id), page, file: file, line: line)
    }

    /// The allowance is bounded: an authored page that adds even more function keys still fails.
    func testMaterialisedPageOverTheControlAllowanceStillFails() throws {
        let page = KeyboardPageDefinition(
            id: "old.over", name: "超量", kind: .numeric,
            rows: (0..<8).map { _ in LayoutRow(keys: literalKeys(32)) })
        var over = page.materialized()
        over.chrome?.bottom += (0..<12).map { index in
            LayoutKey(label: "x\(index)", action: .init(.clearInput))
        }
        XCTAssertThrowsError(try over.validate())
    }

    /// A repeated page ID is corrupt external input. The order list must not let a dictionary
    /// swallow one copy so that validate() turns a blind eye and the next save drops it forever.
    func testRepeatedPageIDsStayVisibleWithAndWithoutPageOrder() throws {
        let page = KeyboardPageDefinition(
            id: "dup.page", name: "重复页", kind: .numeric,
            rows: [LayoutRow(keys: literalKeys(1))])
        let encodedPage = try JSONSerialization.jsonObject(with: JSONEncoder().encode(page))
        let encodedLayouts = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([BuiltinLayouts.qwerty26]))
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

    /// A legacy row page whose text already sits on the old 64 KiB cap still materialises: the
    /// inserted Shift/Delete labels are covered by the function-area allowance.
    func testMaterialisedRowPageAtTheLegacyTextCapStaysSavable() throws {
        let rows = (0..<8).map { row in
            LayoutRow(
                keys: (0..<32).map { column in
                    let isLast = row == 7 && column == 31
                    return LayoutKey(
                        label: String(repeating: "x", count: 250),
                        action: .init(.literal, value: isLast ? String(repeating: "v", count: 1000) : "v"))
                })
        }
        let page = KeyboardPageDefinition(id: "old.rowtext", name: "旧满行文本", kind: .numeric, rows: rows)
        try page.validate()
        let materialised = page.materialized()
        try materialised.validate()
        try assertRegistryRoundTrip(materialised)
    }

    /// A legacy page at the alternate cap still copies, because the default footer's punctuation
    /// menu (one Chinese mark, two ASCII marks) has a bounded allowance.
    func testMaterialisedPageAtTheAlternateCapStaysSavable() throws {
        func materialisedAlternatePage(marks: KeyboardNumericMarks) -> KeyboardPageDefinition {
            let options = (0..<LayoutResourceBudget.alternatesPerKey).map { index in
                LayoutOption(label: "o\(index)", action: .init(.literal, value: "o\(index)"))
            }
            let keys = (0..<(LayoutResourceBudget.keysPerRegion * 2)).map { index in
                LayoutKey(
                    label: "k\(index)", action: .init(.literal, value: "k\(index)"),
                    longPress: options)
            }
            let page = KeyboardPageDefinition(
                id: "old.alt", name: "旧满副键", kind: .numeric,
                rows: [
                    LayoutRow(keys: Array(keys[0..<LayoutResourceBudget.keysPerRegion])),
                    LayoutRow(keys: Array(keys[LayoutResourceBudget.keysPerRegion...])),
                ])
            return page.materialized(numericMarks: marks)
        }
        let ascii = materialisedAlternatePage(marks: .ascii)
        // The frozen default footer no longer carries a punctuation long-press menu, so a page at
        // the legacy alternate cap keeps exactly its own list.
        XCTAssertEqual(
            ascii.allKeys.reduce(0) { $0 + ($1.longPress?.count ?? 0) },
            LayoutResourceBudget.alternates)
        try ascii.validate()
        try assertRegistryRoundTrip(ascii)

        var over = ascii
        var bottom = over.chrome?.bottom ?? []
        bottom[4] = bottom[4].settingLongPress(
            (0..<(LayoutResourceBudget.pageControlAlternates + 1)).map { index in
                LayoutOption(label: "×\(index)", action: .init(.literal, value: "×"))
            })
        over.chrome?.bottom = bottom
        XCTAssertThrowsError(try over.validate())
    }

    func testFullAlternateCatalogStillValidatesAfterMaterialisingEveryPage() throws {
        let options = (0..<LayoutResourceBudget.alternatesPerKey).map { index in
            LayoutOption(label: "o\(index)", action: .init(.literal, value: "o\(index)"))
        }
        let keys = (0..<(LayoutResourceBudget.keysPerRegion * 2)).map { index in
            LayoutKey(label: "k\(index)", action: .init(.literal, value: "k\(index)"), longPress: options)
        }
        let pages = (0..<16).map { index in
            KeyboardPageDefinition(
                id: "user.alt.\(index)", name: "满副键", kind: .numeric,
                rows: [
                    LayoutRow(keys: Array(keys[0..<LayoutResourceBudget.keysPerRegion])),
                    LayoutRow(keys: Array(keys[LayoutResourceBudget.keysPerRegion...])),
                ]
            ).materialized(numericMarks: .ascii)
        }
        let registry = try LayoutRegistry(pages: pages + KeyboardPagePresets.all)
        try registry.validate()
    }

    /// The categorised page's text cap is separate from a row page's: content that sits near the
    /// 1 MiB categorised limit still materialises its fixed function area without deleting keys.
    func testMaterialisedCategorizedPageAtTheTextCapStaysSavable() throws {
        let longLabel = String(repeating: "x", count: 250)
        func category(id: String, name: String) -> KeyboardPageCategory {
            KeyboardPageCategory(
                id: id, name: name,
                keys: (0..<LayoutResourceBudget.categoryKeys).map { _ in
                    LayoutKey(label: longLabel, action: .init(.literal, value: "v"))
                })
        }
        let page = KeyboardPageDefinition(
            id: "old.cattext", name: "旧满分类文本", kind: .symbols, rows: [],
            symbolPresentation: .categorized,
            categories: [category(id: "c1", name: "一"), category(id: "c2", name: "二")])
        try page.validate()
        let materialised = page.materialized()
        XCTAssertEqual(materialised.categories?.count, 2)
        XCTAssertEqual(materialised.chrome?.allKeys.count, 8)
        try materialised.validate()
        try materialised.copy().validate()
    }
}
