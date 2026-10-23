import XCTest

@testable import KeyboardCore

/// UI/layout invariants for the ambiguity picker: the 14-key rows are unchanged
/// and the picker is a separate composition-area control, never a candidate row.
final class AmbiguityLayoutTests: XCTestCase {

    func testFlypy14RowsUnchangedByPicker() {
        let rows = KeyboardLayoutTable.mainRows(for: .merged14)
        XCTAssertEqual(rows.count, 3, "14-key keeps three main rows")
        XCTAssertEqual(rows.map { $0.caps.count }, [5, 4, 5], "14-key row widths unchanged")
        // Every 14-key key is a grouped logical code, never an ambiguity option.
        let titles = rows.flatMap { $0.caps.map(\.title) }
        XCTAssertEqual(titles, ["q", "e", "t", "u", "o", "a", "d", "g", "j", "l", "z", "c", "b", "m"])
        // The ambiguity picker is not a candidate and never adds a main row.
        XCTAssertFalse(rows.flatMap(\.caps).contains { $0.action == .code("拼音组合") })
    }

    func testT9RowsUnchangedByPicker() {
        let rows = KeyboardLayoutTable.mainRows(for: .phone9)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].caps.map(\.title), ["1", "2", "3"])
        XCTAssertEqual(rows[2].caps.map(\.title), ["7", "8", "9"])
    }

    func testPickerUIGateExcludes26AndEnglish() {
        // A representative 14-key composer reports reduced display; a 26-key does not.
        XCTAssertTrue(KeyboardLayoutKind.merged14.requiresSpellingDisplay)
        XCTAssertTrue(KeyboardLayoutKind.phone9.requiresSpellingDisplay)
        XCTAssertFalse(KeyboardLayoutKind.qwerty26.requiresSpellingDisplay)
    }
}
