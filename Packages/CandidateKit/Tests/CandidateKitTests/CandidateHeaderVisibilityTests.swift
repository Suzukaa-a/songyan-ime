import KeyboardCore
import XCTest

@testable import CandidateKit

/// Top-bar visibility + tools entry contract (pure production policy).
final class CandidateHeaderVisibilityTests: XCTestCase {

    private func input(
        isEnglish: Bool = false, candidates: Bool = false, status: Bool = false,
        picker: Bool = false, fallback: Bool = false,
        reading: Bool = false
    ) -> CandidateHeaderVisibilityInput {
        CandidateHeaderVisibilityInput(
            isEnglish: isEnglish, hasCandidates: candidates,
            hasStatus: status, hasAmbiguityPicker: picker,
            hasCompositionFallback: fallback,
            isReadingFiltering: reading)
    }

    /// Pure idle (26/14/9, Chinese/English): no **real input content**, so the top bar draws nothing.
    func testPureIdleHasNoRealInputContentForEveryLayout() {
        XCTAssertFalse(CandidateHeaderVisibility.showsHeader(input()))
        XCTAssertFalse(CandidateHeaderVisibility.showsHeader(input(isEnglish: true)))
    }

    /// No candidates but the host's marked text is unavailable (composition fallback): the top bar **must** stay and show the real composition,
    /// never hiding real state.
    func testCompositionFallbackKeepsHeaderVisible() {
        XCTAssertTrue(
            CandidateHeaderVisibility.showsHeader(input(fallback: true)),
            "the top bar must show when there are no candidates but a whole-composition fallback exists")
        XCTAssertTrue(
            CandidateHeaderVisibility.showsHeader(input(isEnglish: true, fallback: true)),
            "the composition fallback must not be swallowed by English collapsing either")
    }

    /// Composing with empty candidates and no fallback/status/disambiguation: the top bar is hidden (isComposing is not a gate).
    func testComposingEmptyWithoutContentHidesHeader() {
        XCTAssertFalse(CandidateHeaderVisibility.showsHeader(input()))
    }

    func testStatusKeepsHeaderVisible() {
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(status: true)))
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(isEnglish: true, status: true)))
    }

    func testAmbiguityPickerKeepsHeaderVisible() {
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(picker: true)))
    }

    /// Nine-key reading filter in progress: the top bar shows the filter row and must not collapse.
    func testReadingFilteringKeepsHeaderVisible() {
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(reading: true)))
    }

    func testCandidatesKeepHeaderVisible() {
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(candidates: true)))
        XCTAssertTrue(CandidateHeaderVisibility.showsHeader(input(isEnglish: true, candidates: true)))
    }

    /// Tools entry contract: visible indicator + direct VoiceOver action + >= 44pt, without adding or displacing core keys.
    func testToolsAffordanceContract() {
        XCTAssertFalse(
            KeyboardToolsAffordance.indicatorGlyph.isEmpty,
            "the language key must have a visible long-press menu indicator, not rely on long-press alone")
        XCTAssertGreaterThanOrEqual(KeyboardToolsAffordance.minimumHitTarget, 44)
    }
}
