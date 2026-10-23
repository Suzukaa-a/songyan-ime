"""Execute the production symbol tables, including phone-rail reachability."""
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
        checks = r'''
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

    // Nine-key symbol page: the category grid must contain every symbol of the other layouts' 123/#+= pages (- / @ etc. must not be reachable only elsewhere).
    let categories = SymbolPageTable.phoneSymbolCategories()
    precondition(categories.first?.id == "common", "the page opens on the common symbols")
    precondition(literalValues(categories[0].caps).allSatisfy { $0 == "…" || $0 == "¥" || $0.allSatisfy(\.isASCII) },
                 "common is the half-width set in both punctuation modes")
    precondition(Set(categories.map(\.id)).count == categories.count, "unique category identity")
    let categoryCaps = categories.flatMap(\.caps)
    precondition(Set(categoryCaps.map(\.id)).count == categoryCaps.count, "unique symbol key identity")
    let categoryValues = Set(literalValues(categoryCaps))
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
