import XCTest

@testable import CandidateKit

final class KeyboardPanelHeightStateTests: XCTestCase {
    private func budget(
        height: Double = 40, size: Double = 21,
        reading: Bool = false, compact: Bool = false
    ) -> KeyboardPanelPresentationBudget {
        KeyboardPanelPresentationBudget(
            candidateHeight: height, candidateSize: size,
            readingRow: reading, candidateArea: true, compact: compact)
    }

    func testSameShellAdoptsChangedCandidateHeightBeforeCallbacks() {
        let first = budget(height: 56)
        let second = budget(height: 40)
        XCTAssertEqual(first.readingRow, second.readingRow)
        XCTAssertEqual(first.candidateArea, second.candidateArea)
        XCTAssertNotEqual(first, second)
        var state = KeyboardPanelHeightState(height: first.shellHeight)
        state.beginPresentation(height: first.shellHeight)
        state.endPresentation()
        state.beginPresentation(height: second.shellHeight)
        XCTAssertEqual(state.panelHeight, second.shellHeight)
        XCTAssertEqual(state.requestedHeights, [second.shellHeight])
    }

    func testFullBudgetIncludesFontAndSizeClass() {
        let first = budget(height: 36, size: 17)
        let largerFont = budget(height: 36, size: 30)
        let compact = first.withCompact(true)
        XCTAssertNotEqual(first, largerFont)
        XCTAssertGreaterThan(largerFont.shellHeight, first.shellHeight)
        XCTAssertNotEqual(first, compact)
        XCTAssertEqual(first.shellHeight - compact.shellHeight, 40)
        XCTAssertEqual(compact.candidateHeight, first.candidateHeight)
        XCTAssertEqual(compact.candidateSize, first.candidateSize)
    }

    func testLayoutChangeOnlyRefitsUntilTheNextPresentation() {
        let first = budget(reading: true)
        let next = budget(reading: false)
        var state = KeyboardPanelHeightState(height: first.shellHeight)
        state.beginPresentation(height: first.shellHeight)
        let fit = KeyboardPanelGeometry.fit(
            shellHeight: state.panelHeight,
            candidateHeight: first.candidateHeight,
            standardKeyHeight: first.keyHeight,
            readingRowReserved: false, candidateAreaReserved: true)
        XCTAssertEqual(state.panelHeight, first.shellHeight)
        XCTAssertEqual(fit.keyHeight, 54)
        XCTAssertEqual(fit.headerHeight, 70)
        state.endPresentation()
        state.beginPresentation(height: next.shellHeight)
        XCTAssertEqual(state.panelHeight, next.shellHeight)
        XCTAssertEqual(first.shellHeight - next.shellHeight, 28)
    }

    func testDisplayedSnapshotFitsTheFrozenShellWhenColdCacheDiffers() {
        let frozen = budget(height: 36, size: 17)
        let renderedHeight = CandidateBarDefinition.systemDefault.collapsed.height
        func plan(_ fit: KeyboardPanelFit) -> KeyboardPanelGeometry {
            KeyboardPanelGeometry(
                candidateHeight: renderedHeight, keyHeight: fit.keyHeight,
                selectedMainRows: 3, readingRowReserved: true, candidateSize: 21,
                fittedHeaderHeight: fit.headerHeight,
                fittedReadingRowHeight: fit.readingRowHeight)
        }
        let oldFit = KeyboardPanelGeometry.fit(
            shellHeight: frozen.shellHeight,
            candidateHeight: frozen.candidateHeight,
            standardKeyHeight: frozen.keyHeight,
            readingRowReserved: true, candidateAreaReserved: true,
            candidateSize: frozen.candidateSize)
        XCTAssertEqual(plan(oldFit).panelHeight, frozen.shellHeight + 4)
        let fit = KeyboardPanelGeometry.fit(
            shellHeight: frozen.shellHeight,
            candidateHeight: renderedHeight,
            standardKeyHeight: frozen.keyHeight,
            readingRowReserved: true, candidateAreaReserved: true,
            candidateSize: 21)
        XCTAssertEqual(plan(fit).panelHeight, frozen.shellHeight)
    }

    func testPreviousPresentationHeightIsNotARetainedReceipt() {
        var state = KeyboardPanelHeightState(height: 316)
        state.beginPresentation(height: 316)
        state.endPresentation()
        state.beginPresentation(height: 288)
        XCTAssertNil(state.retainedHeight(boundsHeight: 316, attachedToWindow: true))
        XCTAssertNil(state.retainedHeight(boundsHeight: 288, attachedToWindow: true))
    }

    func testAnEarlierRequestWithinThisPresentationCanBeRetained() {
        var state = KeyboardPanelHeightState(height: 288)
        state.beginPresentation(height: 288)
        state.setPanelHeight(304)
        XCTAssertEqual(state.retainedHeight(boundsHeight: 288, attachedToWindow: true), 288)
        XCTAssertNil(state.retainedHeight(boundsHeight: 288, attachedToWindow: false))
        XCTAssertNil(state.retainedHeight(boundsHeight: 509, attachedToWindow: true))
        XCTAssertNil(state.retainedHeight(boundsHeight: .nan, attachedToWindow: true))
        state.endPresentation()
        XCTAssertNil(state.retainedHeight(boundsHeight: 288, attachedToWindow: true))
    }

    func testQueuedReceiptCannotCrossDisappearReappearABA() {
        var state = KeyboardPanelHeightState(height: 288)
        state.beginPresentation(height: 288)
        state.setPanelHeight(304)
        let oldRevision = state.revision
        let oldReceipt = state.retainedHeight(boundsHeight: 288, attachedToWindow: true)
        XCTAssertTrue(state.accepts(revision: oldRevision))
        state.endPresentation()
        XCTAssertFalse(state.accepts(revision: oldRevision))
        state.beginPresentation(height: 288)
        state.setPanelHeight(304)
        XCTAssertEqual(state.retainedHeight(boundsHeight: 288, attachedToWindow: true), oldReceipt)
        XCTAssertFalse(state.accepts(revision: oldRevision))
        XCTAssertTrue(state.accepts(revision: state.revision))
    }

    func testPreparingAnotherControllerCannotChangeVisibleGeometry() {
        var active = KeyboardPanelHeightState(height: 316)
        active.beginPresentation(height: 316)
        active.setPanelHeight(320)
        var successor = KeyboardPanelHeightState(height: 288)
        successor.beginPresentation(height: 288)
        successor.endPresentation()
        XCTAssertEqual(active.panelHeight, 320)
        XCTAssertEqual(active.retainedHeight(boundsHeight: 316, attachedToWindow: true), 316)
        XCTAssertTrue(active.accepts(revision: active.revision))
    }

    func testHistoryStaysBoundedWithinAnEpochAndIsResetForTheNext() {
        var state = KeyboardPanelHeightState(height: 280)
        state.beginPresentation(height: 280)
        for height in 281...292 { state.setPanelHeight(Double(height)) }
        XCTAssertEqual(state.requestedHeights.count, 8)
        XCTAssertNil(state.retainedHeight(boundsHeight: 280, attachedToWindow: true))
        XCTAssertEqual(state.retainedHeight(boundsHeight: 290, attachedToWindow: true), 290)
        state.beginPresentation(height: 288)
        XCTAssertEqual(state.requestedHeights, [288])
        XCTAssertNil(state.retainedHeight(boundsHeight: 290, attachedToWindow: true))
    }

    func testInvalidRequestsCannotRotateThePresentationOrCorruptItsBudget() {
        var state = KeyboardPanelHeightState(height: 288)
        state.beginPresentation(height: 288)
        let revision = state.revision
        state.beginPresentation(height: .infinity)
        state.beginPresentation(height: -1)
        XCTAssertFalse(state.setPanelHeight(.nan))
        XCTAssertFalse(state.setPanelHeight(0))
        XCTAssertEqual(state.revision, revision)
        XCTAssertEqual(state.panelHeight, 288)
        XCTAssertEqual(state.requestedHeights, [288])
    }
}
