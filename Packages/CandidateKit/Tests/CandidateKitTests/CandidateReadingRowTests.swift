import KeyboardCore
import LayoutKit
import XCTest

@testable import CandidateKit

/// Standalone trusted reading row: eligibility (physical definition content), geometry (the top band granted by the host), host acceptance,
/// cold-start hint and content resolution. Geometry/policy are pure functions.
/// Appearance, hit testing and transitions still need acceptance on an installed keyboard/device.
final class CandidateReadingRowTests: XCTestCase {

    // MARK: Eligibility: physical definition content only

    func testOnlyNonPhoneCompactStructuresAreEligible() {
        XCTAssertTrue(
            CandidateReadingRowPolicy.isEligible(BuiltinLayouts.merged14),
            "a merged 14-key structure needs a standalone reading row")
        XCTAssertFalse(
            CandidateReadingRowPolicy.isEligible(BuiltinLayouts.qwerty26),
            "a 26-key full keyboard has no trusted reading source and needs no reading area")
        XCTAssertFalse(
            CandidateReadingRowPolicy.isEligible(BuiltinLayouts.phone9),
            "nine-key keeps its left rail and adds no top reading band")
        XCTAssertFalse(CandidateReadingRowPolicy.isEligible(nil), "no definition fails closed")
    }

    /// Eligibility comes from content, not id/name: the same physical structure with another id/name is judged the same;
    /// 26-key content never gets a reading row even if it borrows a 14-key builtin label.
    func testEligibilityFollowsContentNotIdentityOrBuiltinTag() {
        let diy14 = LayoutDefinition(
            id: "user-diy-merged", name: "我的 14 键",
            input: .init(schemaID: "some_schema"),
            rows: BuiltinLayouts.merged14.rows)
        XCTAssertTrue(CandidateReadingRowPolicy.isEligible(diy14))
        let mislabelled26 = LayoutDefinition(
            id: "merged14", name: "14 键",
            input: .init(builtinLayout: .merged14),
            rows: BuiltinLayouts.qwerty26.rows)
        XCTAssertFalse(
            CandidateReadingRowPolicy.isEligible(mislabelled26),
            "a 26-key physical structure must not get a reading row because of its label/name")
    }

    func testDeclaredReadingChoiceControlsEngineQueryWithoutChangingPhoneRail() throws {
        let wideReading = BuiltinLayouts.qwerty26.settingCandidateArea(.init(candidates: true, reading: true))
        try wideReading.validate()
        XCTAssertTrue(CandidateReadingRowPolicy.isEligible(wideReading))
        XCTAssertTrue(CandidateReadingRowPolicy.needsEngineSpelling(wideReading))
        let compactWithoutReading = BuiltinLayouts.merged14.settingCandidateArea(
            .init(candidates: true, reading: false))
        try compactWithoutReading.validate()
        XCTAssertFalse(CandidateReadingRowPolicy.isEligible(compactWithoutReading))
        XCTAssertFalse(CandidateReadingRowPolicy.needsEngineSpelling(compactWithoutReading))
        XCTAssertFalse(CandidateReadingRowPolicy.isEligible(BuiltinLayouts.phone9))
        XCTAssertTrue(CandidateReadingRowPolicy.needsEngineSpelling(BuiltinLayouts.phone9))
    }

    func testNoCandidateLayoutHasFixedBaseHeightAcrossInputStates() {
        let base = KeyboardPanelGeometry.fixedPanelHeight(
            candidateHeight: 44, keyHeight: 54,
            candidateAreaReserved: false)
        XCTAssertEqual(base, 236)
        XCTAssertEqual(
            base,
            KeyboardPanelGeometry(
                candidateHeight: 44, keyHeight: 54,
                selectedMainRows: 3
            ).layoutPlan(showsHeader: false).panelHeight)
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(
                candidateHeight: 44, keyHeight: 54,
                candidateAreaReserved: true), 276)
    }

    // MARK: Geometry: granting adds 32pt above the header and the key area does not move relative to the bottom

    func testReservedGeometryAddsOneCompactBandAboveTheCandidateRow() {
        let geometry = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54, selectedMainRows: 3,
            readingRowReserved: true)
        let plan = geometry.layoutPlan(showsHeader: true)
        XCTAssertEqual(plan.readingRowHeight, 32)
        XCTAssertEqual(
            plan.readingRowFrame, PanelVerticalFrame(top: 0, height: 32),
            "the reading row is flush to the top (top padding is 0 with a candidate area)")
        XCTAssertEqual(
            plan.headerFrame, PanelVerticalFrame(top: 32, height: 44),
            "the word candidate row is still the full 44pt and is not squeezed by the reading row")
        XCTAssertEqual(plan.firstKeyRowTop, 76)
        XCTAssertEqual(plan.panelHeight, 308)
        XCTAssertTrue(plan.bandsAreContiguous)
        XCTAssertFalse(plan.readingRowFrame.intersects(plan.headerFrame))
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(
                candidateHeight: 44, keyHeight: 54,
                readingRowReserved: true), 308)
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(
                candidateHeight: 44, keyHeight: 44,
                readingRowReserved: true),
            KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 44) + 32)
    }

    func testUnreservedGeometryIsUnchangedForTwentySixAndNineKey() {
        for keyHeight in [44.0, 54.0] {
            let plain = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: keyHeight, selectedMainRows: 3)
            let plan = plain.layoutPlan(showsHeader: true)
            XCTAssertEqual(plan.readingRowHeight, 0)
            XCTAssertEqual(plan.readingRowFrame.height, 0)
            XCTAssertEqual(
                plan.headerFrame.minY, KeyboardPanelGeometry.candidateTopPadding,
                "without a grant the header starts at the candidate area's top padding (0)")
            XCTAssertEqual(
                KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: keyHeight),
                keyHeight == 54 ? 276 : 236,
                "the 26/9-key shell height does not change with the reading row")
        }
    }

    /// Granting/revoking changes only the top; with bottom-anchored hosting the key area, control row and candidate row do not move relative to the bottom.
    func testBottomRelativeFramesDoNotMoveWhenTheRowIsGranted() {
        for candidateHeight in [36.0, 44.0, 56.0] {
            for keyHeight in [44.0, 54.0] {
                let plain = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight, keyHeight: keyHeight,
                    selectedMainRows: 3
                ).layoutPlan(showsHeader: true)
                let reserved = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight, keyHeight: keyHeight,
                    selectedMainRows: 3, readingRowReserved: true
                )
                .layoutPlan(showsHeader: true)
                XCTAssertEqual(
                    reserved.panelHeight - plain.panelHeight,
                    CandidateReadingRowPolicy.height(reserved: true), accuracy: 0.001)
                for band in [\KeyboardPanelLayoutPlan.headerFrame, \.mainAreaFrame, \.controlRowFrame] {
                    XCTAssertEqual(
                        plain.distanceFromPanelBottom(toTopOf: plain[keyPath: band]),
                        reserved.distanceFromPanelBottom(toTopOf: reserved[keyPath: band]),
                        accuracy: 0.001)
                }
                XCTAssertTrue(reserved.bandsAreContiguous)
            }
        }
    }

    /// When the reading row and word row show together their text moves closer: only the drawing position moves and the content stays fully inside its own row.
    func testStackedRowsTightenTheirSharedGapInsideTheirOwnRows() {
        let block = CandidateCollapsedFlow.estimatedBlockHeight(
            typography: CandidateTypography(candidateSize: 21, secondarySize: 10), hasComment: false)
        let budget = CGFloat(CandidateBarDefinition.systemDefault.collapsed.height)
        XCTAssertEqual(
            CandidateCollapsedFlow.clampedLift(
                CandidateReadingRowPolicy.candidateLift,
                blockHeight: block, budget: budget),
            CGFloat(CandidateReadingRowPolicy.candidateLift), accuracy: 0.001,
            "the default 40pt word row accommodates the lift")
        XCTAssertEqual(
            CandidateCollapsedFlow.clampedLift(40, blockHeight: block, budget: budget),
            (budget - block) / 2, accuracy: 0.001, "the lift does not exceed the row top")
        XCTAssertEqual(CandidateCollapsedFlow.clampedLift(-3, blockHeight: block, budget: budget), 0)
        XCTAssertEqual(CandidateCollapsedFlow.clampedLift(.nan, blockHeight: block, budget: budget), 0)
        // A 16pt reading row box (about 1.2x line height) still fits inside the 32pt row after the drop.
        let line = CandidateReadingRowPolicy.fontSize * 1.2
        XCTAssertLessThanOrEqual(line + CandidateReadingRowPolicy.textDrop * 2, CandidateReadingRowPolicy.height)
        XCTAssertGreaterThanOrEqual(
            CandidateReadingRowPolicy.height, 32, "the reading row does not sacrifice hit height to save space")
    }

    func testMathBaseBranchNeverCarriesTheRow() {
        let geometry = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54, selectedMainRows: 3,
            readingRowReserved: true)
        let base = geometry.layoutPlan(showsHeader: false)
        XCTAssertEqual(base.readingRowHeight, 0)
        XCTAssertEqual(base.panelHeight, geometry.basePanelHeight)
        XCTAssertEqual(
            geometry.panelHeight,
            geometry.basePanelHeight + 44 + CandidateReadingRowPolicy.height
                - KeyboardPanelGeometry.verticalPadding + KeyboardPanelGeometry.candidateTopPadding)
    }

    // MARK: Host acceptance

    func testHostAcceptsOnlySettledReportsFromTheCurrentSource() {
        let builtin = CandidateReadingRowReport(eligible: true, definitionID: "merged14", resolvedFromRegistry: false)
        let registry = CandidateReadingRowReport(eligible: false, definitionID: "diy", resolvedFromRegistry: true)
        XCTAssertFalse(
            CandidateReadingRowGrant.accepts(builtin, layoutSourceSettled: false, registryAvailable: false),
            "registry loading: the built-in fallback is only a guess, keep the last grant")
        XCTAssertFalse(
            CandidateReadingRowGrant.accepts(builtin, layoutSourceSettled: true, registryAvailable: true),
            "registry available: do not accept the built-in fallback report")
        XCTAssertTrue(
            CandidateReadingRowGrant.accepts(builtin, layoutSourceSettled: true, registryAvailable: false),
            "read failed / no full access: the built-in is the real source")
        XCTAssertTrue(CandidateReadingRowGrant.accepts(registry, layoutSourceSettled: true, registryAvailable: true))
        XCTAssertFalse(CandidateReadingRowGrant.accepts(registry, layoutSourceSettled: false, registryAvailable: true))
    }

    // MARK: Cold-start hint

    func testHintRoundTripsAndOnlyAppliesToTheSameSelection() throws {
        let key = CandidateReadingRowHint.selectionKey(layoutKind: "merged14", definitionID: "diy-14")
        let hint = CandidateReadingRowHint(selection: key, eligible: true)
        let decoded = try XCTUnwrap(CandidateReadingRowHint(storedValue: hint.storedValue))
        XCTAssertEqual(decoded, hint)
        XCTAssertTrue(decoded.resolve(currentSelection: key))
        XCTAssertFalse(
            decoded.resolve(
                currentSelection:
                    CandidateReadingRowHint.selectionKey(layoutKind: "qwerty26", definitionID: "diy-14")),
            "a physical layout kind change invalidates it")
        XCTAssertFalse(
            decoded.resolve(
                currentSelection:
                    CandidateReadingRowHint.selectionKey(layoutKind: "merged14", definitionID: nil)),
            "an explicit definition change invalidates it")
        XCTAssertFalse(CandidateReadingRowHint(selection: key, eligible: false).resolve(currentSelection: key))
    }

    func testMissingOrCorruptHintFailsClosed() {
        XCTAssertFalse(CandidateReadingRowHint.resolve(storedValue: nil, currentSelection: "|"))
        XCTAssertFalse(CandidateReadingRowHint.resolve(storedValue: "merged14", currentSelection: "|"))
        XCTAssertFalse(CandidateReadingRowHint.resolve(storedValue: ["selection": "|"], currentSelection: "|"))
        XCTAssertFalse(
            CandidateReadingRowHint.resolve(
                storedValue: ["selection": 1, "eligible": true],
                currentSelection: "|"))
        XCTAssertTrue(
            CandidateReadingRowHint.resolve(
                storedValue: ["selection": "|", "eligible": true],
                currentSelection: "|"))
    }

    func testCandidateAreaHintOnlySuppressesMatchingLayoutSelection() {
        let hint = CandidateReadingRowHint(
            selection: "literal|custom", eligible: false,
            candidateAreaRequired: false)
        XCTAssertFalse(hint.resolveCandidateArea(currentSelection: "literal|custom"))
        XCTAssertTrue(hint.resolveCandidateArea(currentSelection: "qwerty26|custom"))
        XCTAssertFalse(
            CandidateReadingRowHint.resolveCandidateArea(
                storedValue: hint.storedValue,
                currentSelection: "literal|custom"))
        XCTAssertTrue(
            CandidateReadingRowHint.resolveCandidateArea(
                storedValue: nil,
                currentSelection: "literal|custom"))
        XCTAssertTrue(
            CandidateReadingRowHint(storedValue: ["selection": "literal|custom", "eligible": false])?
                .candidateAreaRequired == true, "old stored hints preserve the candidate area")
    }

    // MARK: Content: draw only engine-trusted lockable items, no placeholder text

    private func report(options: [String], input: String = "ug") -> AmbiguitySpellingsReport {
        AmbiguitySpellingsReport(
            revisionInput: input, segment: 0..<input.utf8.count,
            options: options, allSpellings: options,
            lockMode: .tokenAlias, isComplete: true)
    }

    func testContentIsEmptyUnlessReservedEligibleAndThePickerHasTrustedOptions() {
        var picker = AmbiguitySpellingPicker()
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker), .empty, "idle draws nothing")
        picker.update(report: report(options: ["chang", "cheng"]), revision: 1, isEligible: true)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker), .options(["chang", "cheng"]))
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: false, eligible: true, usesPickerUI: true,
                picker: picker), .empty, "nothing is drawn without a granted height")
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: false, usesPickerUI: true,
                picker: picker), .empty, "nothing is drawn for a transiently ineligible definition")
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: false,
                picker: picker), .empty, "nothing is drawn for English / non-compact")
    }

    func testSingleOrTruncatedSpellingsAreNeverShown() {
        var single = AmbiguitySpellingPicker()
        single.update(report: report(options: ["chang"]), revision: 1, isEligible: true)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: single), .empty)
        var truncated = AmbiguitySpellingPicker()
        truncated.update(
            report: AmbiguitySpellingsReport(
                revisionInput: "ug", segment: 0..<2,
                options: ["a", "b"], allSpellings: ["a", "b"],
                lockMode: .tokenAlias, isComplete: false),
            revision: 1, isEligible: true)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: truncated), .empty)
    }

    private func readings(_ paths: [[String]], complete: Bool = true) -> CandidateReadingFilter {
        var filter = CandidateReadingFilter()
        filter.reset(revision: 7)
        filter.append(
            paths.enumerated().map {
                ReadingCandidate(
                    index: $0.offset, text: "词\($0.offset)",
                    readingPaths: [$0.element],
                    readingsComplete: complete)
            },
            requested: 32, revision: 7)
        return filter
    }

    /// Regression case: 14-key `bu gao` has candidates but no readings. Disambiguation reports only cover single-syllable segments,
    /// so for multi-syllable input the engine readings of real candidates take over and give the next syllable, the more common first.
    func testMultiSyllableCompositionShowsRealCandidateReadings() {
        let picker = AmbiguitySpellingPicker()
        var filter = readings([["ni", "hao"], ["bu", "hao"], ["bu", "gao"]])
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker, readings: filter),
            .readings(selected: [], options: ["bu", "ni"]))
        filter.select("bu")
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker, readings: filter),
            .readings(selected: ["bu"], options: ["hao", "gao"]),
            "the selected syllables keep the undo entry and list only the next syllables of really matching candidates")
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: false, usesPickerUI: true,
                picker: picker, readings: filter), .empty)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: false,
                picker: picker, readings: filter), .empty,
            "English mode draws no readings")
    }

    func testLockablePickerWinsAndUnprovenReadingsStayEmpty() {
        var picker = AmbiguitySpellingPicker()
        picker.update(report: report(options: ["bi", "bu", "ni", "nu"]), revision: 1, isEligible: true)
        let filter = readings([["ni"], ["bu"]])
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker, readings: filter),
            .options(["bi", "bu", "ni", "nu"]), "a single syllable still prefers the lockable full spelling set")
        var unproven = CandidateReadingFilter()
        unproven.reset(revision: 1)
        unproven.append([ReadingCandidate(index: 0, text: "你好")], requested: 32, revision: 1)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: AmbiguitySpellingPicker(), readings: unproven),
            .empty, "no reading is fabricated when the candidates have no provable reading")
    }

    func testLockedShowsTheActuallyLockedSpelling() {
        var picker = AmbiguitySpellingPicker()
        picker.update(report: report(options: ["chang", "cheng"]), revision: 1, isEligible: true)
        picker.markLocked(
            option: "cheng", originalInput: "ug", originalSegment: 0..<2,
            rewrittenInput: "cheng", rewrittenSegment: 0..<5)
        XCTAssertEqual(
            CandidateReadingRowContent.resolve(
                reserved: true, eligible: true, usesPickerUI: true,
                picker: picker), .locked(chosen: "cheng"))
    }
}
