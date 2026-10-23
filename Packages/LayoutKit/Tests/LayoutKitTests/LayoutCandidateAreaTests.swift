import XCTest

@testable import LayoutKit

final class LayoutCandidateAreaTests: XCTestCase {
    func testDefinitionsWithoutAreaInferNeedsFromPhysicalContent() {
        XCTAssertEqual(
            BuiltinLayouts.qwerty26.effectiveCandidateArea,
            .init(candidates: true, reading: false))
        XCTAssertEqual(
            BuiltinLayouts.merged14.effectiveCandidateArea,
            .init(candidates: true, reading: true))
        XCTAssertEqual(
            BuiltinLayouts.phone9.effectiveCandidateArea,
            .init(candidates: true, reading: false))
        let literal = LayoutDefinition(
            id: "literal", name: "Literal", input: .init(schemaID: "literal"),
            rows: [
                LayoutRow(keys: [
                    LayoutKey(label: "!", action: .init(.literal, value: "!"))
                ])
            ])
        XCTAssertEqual(
            literal.effectiveCandidateArea,
            .init(candidates: false, reading: false))
        XCTAssertNoThrow(try literal.validate())
    }

    func testExplicitReadingIsIndependentOfLayoutNameAndSurvivesEdits() throws {
        let area = LayoutCandidateArea(candidates: true, reading: true)
        let custom = BuiltinLayouts.qwerty26.settingCandidateArea(area)
        XCTAssertNoThrow(try custom.validate())
        XCTAssertEqual(custom.effectiveCandidateArea, area)
        XCTAssertEqual(custom.copy().effectiveCandidateArea, area)
        XCTAssertEqual(custom.renamed("Custom").effectiveCandidateArea, area)
        let changed = custom.replacingKey(at: .row(0, key: 0), with: custom.rows[0].keys[0])
        XCTAssertEqual(changed.effectiveCandidateArea, area)
        let decoded = try LayoutDefinition.decode(JSONEncoder().encode(custom))
        XCTAssertEqual(decoded.effectiveCandidateArea, area)
        XCTAssertFalse(custom.runtimeIdentity.isProvablySame(as: BuiltinLayouts.qwerty26.runtimeIdentity))
    }

    func testEngineCodeCannotSilentlyLoseCandidates() {
        let disabled = LayoutCandidateArea(candidates: false, reading: false)
        XCTAssertThrowsError(try BuiltinLayouts.qwerty26.settingCandidateArea(disabled).validate())
        let alternate = LayoutDefinition(
            id: "alternate", name: "Alternate", input: .init(),
            rows: [
                LayoutRow(keys: [
                    LayoutKey(
                        label: "!", action: .init(.literal, value: "!"),
                        longPress: [.init(label: "a", action: .init(.code, value: "a"))])
                ])
            ],
            candidateArea: disabled)
        XCTAssertTrue(alternate.sendsEngineCode)
        XCTAssertThrowsError(try alternate.validate())
        XCTAssertThrowsError(
            try BuiltinLayouts.phone9.settingCandidateArea(.init(candidates: true, reading: true)).validate())
        XCTAssertThrowsError(
            try BuiltinLayouts.merged14.settingCandidateArea(.init(candidates: false, reading: true)).validate())
    }
}
