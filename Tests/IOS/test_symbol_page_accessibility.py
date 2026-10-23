"""Execute the production symbol tables, including phone-rail reachability."""
import json
import sys
import unittest

from swift_probe import ROOT, production_modules, run, scratch_directory


@unittest.skipUnless(sys.platform == "darwin", "requires the macOS Swift toolchain")
class SymbolPageAccessibilityTests(unittest.TestCase):
    def test_punctuation_actions_and_phone_numeric_rail(self):
        tables = (ROOT / "Apps/SharedKeyboard/SymbolPageTable.swift").read_text()
        # Extract the real SymbolPageTable. It derives the order of "three left-rail items +
        # first-key rotation" from LayoutKit's BuiltinLayouts, so the probe below must compile the REAL
        # LayoutKit/KeyboardCore modules; a stand-in would not test the production ordering rules.
        table = tables[tables.index("enum SymbolPageTable {"):]
        catalog = json.loads((ROOT / "Packages/QuickContentKit/Sources/QuickContentKit/Resources/default-symbols.json")
                             .read_text(encoding="utf-8"))
        order = sorted(catalog["categories"], key=lambda c: (c["order"], c["id"]))
        library = ",\n".join(
            "SymbolPageTable.LibraryCategory(id: %s, title: %s, symbols: [%s])" % (
                json.dumps(c["id"]), json.dumps(c["name"], ensure_ascii=False),
                ", ".join(json.dumps(i["text"], ensure_ascii=False) for i in catalog["items"]
                          if i["category"] == c["id"]))
            for c in order)
        checks = "let defaultLibrary = [\n" + library + "\n]\n" + r'''
func literalValues(_ caps: [KeyCap]) -> [String] {
    caps.map { cap in
        guard case .literal(let text) = cap.action else {
            fatalError("symbol \(cap.title) must be directly insertable, not an engine code")
        }
        precondition(cap.title == text, "the visible symbol and inserted text must agree")
        return text
    }
}

for ascii in [false, true] {
    let required = ascii ? [".", "?", "!"] : ["。", "？", "！"]
    let numeric = SymbolPageTable.numericRows(ascii: ascii)
    let symbols = SymbolPageTable.symbolRows(ascii: ascii)
    for (name, rows) in [("123", numeric), ("#+=", symbols)] {
        let caps = rows.flatMap(\.caps)
        let values = literalValues(caps)
        for punctuation in required {
            precondition(values.contains(punctuation),
                         "\(name) ascii=\(ascii) must expose \(punctuation) without long press")
        }
        precondition(Set(rows.map(\.id)).count == rows.count, "unique row identity")
        precondition(Set(caps.map(\.id)).count == caps.count, "unique key identity")
    }
    let numericValues = literalValues(numeric.flatMap(\.caps))
    precondition(numericValues.contains("."), "decimal separator must survive both modes")
    precondition(numericValues.filter { $0.count == 1 && $0.first!.isNumber } == "1234567890".map(String.init))

    let rail = SymbolPageTable.phoneNumericRail(ascii: ascii)
    let railValues = literalValues(rail)
    let expectedFirstScreen = ascii ? [".", "?", "!"] : [".", "？", "！"]
    precondition(Array(railValues.prefix(3)) == expectedFirstScreen,
                 "the three fixed phone slots must expose decimal, question and exclamation")
    precondition(Set(railValues).count == railValues.count, "rail must deduplicate values")
    precondition(Set(rail.map(\.id)).count == rail.count, "rail must deduplicate key identity")
    let originalNonDigits = Set(numericValues.filter { !$0.allSatisfy(\.isNumber) })
    precondition(originalNonDigits.isSubset(of: Set(railValues)),
                 "prioritizing punctuation must preserve every original numeric-page symbol")
    precondition(railValues.allSatisfy { !$0.allSatisfy(\.isNumber) }, "phone rail contains symbols only")
    precondition(rail == SymbolPageTable.phoneNumericRail(ascii: ascii), "stable identities across recomputation")

    // Nine-key symbol page: the built-in tabs alone must contain every symbol of the other layouts' 123/#+= pages
    // (- / @ etc. must not be reachable only elsewhere), whatever the user's symbol library holds.
    let builtIn = SymbolPageTable.phoneSymbolCategories(ascii: ascii)
    precondition(builtIn.map(\.id) == ["common", "chinese", "english", "brackets"], "built-in tab order")
    let commonValues = literalValues(builtIn[0].caps)
    let firstScreen = Array(commonValues.prefix(12))
    let expectedLead = ascii ? [",", ".", "?", "!"] : ["，", "。", "？", "！"]
    precondition(Array(firstScreen.prefix(4)) == expectedLead, "常用 leads with the sentence marks of the current width")
    if ascii {
        precondition(commonValues.allSatisfy { $0.allSatisfy(\.isASCII) }, "ASCII 常用 is half-width")
    } else {
        precondition(firstScreen.allSatisfy { !$0.allSatisfy(\.isASCII) }, "Chinese 常用 opens on full-width marks")
    }
    precondition(literalValues(builtIn[1].caps).allSatisfy { !$0.allSatisfy(\.isASCII) }, "中文 is full-width")
    precondition(literalValues(builtIn[2].caps).allSatisfy { $0.unicodeScalars.allSatisfy { $0.value < 0x3000 } },
                 "英文 is half-width")

    // The default library adds themed tabs; a set already covered by built-in tabs (标点) is not repeated.
    let categories = SymbolPageTable.phoneSymbolCategories(ascii: ascii, recents: ["→", "，"], library: defaultLibrary)
    precondition(Array(categories.map(\.id).prefix(5)) == ["common", "recent", "chinese", "english", "brackets"],
                 "最近 follows 常用 once there is something to show")
    precondition(literalValues(categories[1].caps) == ["→", "，"], "最近 keeps the most-recent-first order")
    let themedTitles = categories.dropFirst(5).map(\.title)
    precondition(Array(themedTitles.prefix(3)) == ["数学", "序号", "箭头"], "themed tabs follow the library order: \(themedTitles)")
    precondition(!themedTitles.contains("标点"), "a fully covered library set is not repeated")
    precondition(categories.first { $0.title == "颜文字" }?.columns == 2, "kaomoji use two wide columns")
    precondition(categories.first { $0.title == "数学" }?.columns == 4)
    precondition(Set(categories.map(\.id)).count == categories.count, "unique category identity")
    let categoryCaps = categories.filter { $0.id != "recent" }.flatMap(\.caps)
    precondition(Set(categoryCaps.map(\.id)).count == categoryCaps.count, "unique symbol key identity")
    let categoryValues = Set(literalValues(builtIn.flatMap(\.caps)))
    let shared = Set(literalValues((numeric + symbols).flatMap(\.caps))).filter { !$0.allSatisfy(\.isNumber) }
    precondition(shared.isSubset(of: categoryValues),
                 "9-key categories miss \(shared.subtracting(categoryValues).sorted()) (ascii=\(ascii))")
    for category in categories {
        precondition(!category.caps.isEmpty, "\(category.title) has symbols")
        precondition(Set(literalValues(category.caps)).count == category.caps.count, "\(category.title) deduplicates")
    }

    // Quick symbols: the first three are typed directly (left rail); item 4 onward rotates on repeated taps of the main-area first key.
    // The two kinds of reachability must EXACTLY partition the same ordered list, and the first three must not reappear in the rotation.
    let defaults = SymbolPageTable.quickRail(symbols: T9QuickSymbolStore.defaultSymbols, ascii: ascii)
    let defaultValues = literalValues(defaults)
    let defaultCycle = SymbolPageTable.quickCycle(symbols: T9QuickSymbolStore.defaultSymbols, ascii: ascii)
    let defaultOrdered = BuiltinLayouts.t9QuickSymbolValues(saved: T9QuickSymbolStore.defaultSymbols,
                                                           ascii: ascii)
    let defaultRailExpected = ascii ? [",", ".", "?"] : ["，", "。", "？"]
    let defaultCycleExpected = ascii
        ? ["!", "...", "@", "/", ":", "_", "-"]
        : ["！", "、", "…", "@", "/", ".", ":", "_", "-"]
    precondition(defaultValues == defaultRailExpected, "default rail is exactly the first three")
    precondition(defaultCycle == defaultCycleExpected, "default cycle starts at the fourth item")
    precondition(defaultValues + defaultCycle == defaultOrdered, "rail and cycle must partition the order")
    precondition(Set(defaultValues).isDisjoint(with: Set(defaultCycle)), "the first three must not repeat")
    precondition(Set(defaultValues).count == defaultValues.count)
    precondition(Set(defaults.map(\.id)).count == defaults.count)
    precondition(Set(defaultCycle).count == defaultCycle.count, "cycle must deduplicate")
    // The address/URL marks are not in the default quick set; the cycle tail keeps them reachable.
    for mark in BuiltinLayouts.t9PunctuationSymbols() {
        precondition(defaultOrdered.contains(mark), "\(mark) must stay reachable")
    }
    precondition(defaultCycle.contains("@") && defaultCycle.contains("/"),
                 "the address marks must live in the cycle")

    // The fullwidth->halfwidth map must cover the management page's default sequence (including ：；【】), otherwise ASCII fields would get fullwidth characters.
    let managed = "，。？！、…：；（）【】"
    let managedOrdered = BuiltinLayouts.t9QuickSymbolValues(saved: managed, ascii: ascii)
    if ascii {
        precondition(Array(managedOrdered.prefix(12)) ==
            [",", ".", "?", "!", "...", ":", ";", "(", ")", "[", "]", "@"],
            "ASCII must map every managed full-width punctuation and then deduplicate")
        precondition(managedOrdered.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } },
                     "ASCII order must not keep any full-width punctuation")
    } else {
        precondition(Array(managedOrdered.prefix(12)) ==
            ["，", "。", "？", "！", "、", "…", "：", "；", "（", "）", "【", "】"],
            "Chinese mode must preserve the user's characters verbatim")
    }

    let custom = "@（，,、。.?？!！）…@"
    let customCaps = SymbolPageTable.quickRail(symbols: custom, ascii: ascii)
    let customValues = literalValues(customCaps)
    let customCycle = SymbolPageTable.quickCycle(symbols: custom, ascii: ascii)
    let customOrdered = BuiltinLayouts.t9QuickSymbolValues(saved: custom, ascii: ascii)
    if ascii {
        precondition(customOrdered == ["@", "(", ",", ".", "?", "!", ")", "...", "/", ":", "_", "-"],
                     "ASCII adapts full-width punctuation and deduplicates collisions without reordering")
        precondition(customValues == ["@", "(", ","], "ASCII rail keeps the first three in order")
    } else {
        precondition(customOrdered == ["@", "（", "，", ",", "、", "。", ".", "?", "？", "!", "！", "）",
                                       "…", "/", ":", "_", "-"],
                     "Chinese mode preserves the user's full/half-width characters in order")
        precondition(customValues == ["@", "（", "，"], "Chinese rail keeps the first three in order")
    }
    precondition(customValues + customCycle == customOrdered, "custom rail and cycle must partition")
    precondition(Set(customValues).isDisjoint(with: Set(customCycle)))
    precondition(Set(customOrdered).count == customOrdered.count)
    precondition(Set(customCaps.map(\.id)).count == customCaps.count)

    let short = SymbolPageTable.quickRail(symbols: "@#@", ascii: ascii)
    let shortValues = literalValues(short)
    let shortOrdered = BuiltinLayouts.t9QuickSymbolValues(saved: "@#@", ascii: ascii)
    precondition(Array(shortValues.prefix(2)) == ["@", "#"], "saved user order is retained")
    precondition(shortValues + SymbolPageTable.quickCycle(symbols: "@#@", ascii: ascii) == shortOrdered)
    precondition(Set(shortOrdered).count == shortOrdered.count)
    precondition(short == SymbolPageTable.quickRail(symbols: "@#@", ascii: ascii),
                 "quick rail identities are stable")
}
print("symbol page and fixed phone rail behavior checks passed")
'''
        with scratch_directory("symbol-page-accessibility") as directory:
            modules = production_modules()
            production = directory / "Production.swift"
            production.write_text("import Foundation\nimport KeyboardCore\nimport LayoutKit\n" + table)
            main = directory / "main.swift"
            main.write_text("import KeyboardCore\nimport LayoutKit\n" + checks)
            binary = directory / "probe"
            run(["xcrun", "swiftc", "-swift-version", "5",
                 "-I", str(modules), "-L", str(modules),
                 "-module-cache-path", str(directory / "module-cache"),
                 "-lKeyboardCore", "-lLayoutKit",
                 "-Xlinker", "-rpath", "-Xlinker", str(modules),
                 str(production), str(main), "-o", str(binary)])
            print(run([str(binary)]), end="")


if __name__ == "__main__":
    unittest.main()
