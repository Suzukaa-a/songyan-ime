import KeyboardCore
import XCTest

@testable import CandidateKit

/// Production vertical geometry tests: consume `KeyboardPanelGeometry` / `KeyboardPanelLayoutPlan` directly
/// (the real input of `KeyboardPanelView.panelBody`) and assert the exact frames of the header / first key row / control row /
/// bottom, plus that the key area stays fixed relative to the screen bottom under stateful real heights.
final class KeyboardPanelGeometryTests: XCTestCase {

    /// With a candidate area the top padding changes from `verticalPadding` (4) to `candidateTopPadding` (0),
    /// so "full height with header - base height without header" = header - this saving.
    private let headerTopPaddingSaving =
        KeyboardPanelGeometry.verticalPadding
        - KeyboardPanelGeometry.candidateTopPadding

    func testHeightPresetRejectsUnknownStoredValues() {
        XCTAssertEqual(KeyboardHeightPreset.resolve(nil), .standard)
        XCTAssertEqual(KeyboardHeightPreset.resolve("unbounded-999"), .standard)
        for preset in KeyboardHeightPreset.allCases {
            XCTAssertEqual(KeyboardHeightPreset.resolve(preset.rawValue), preset)
        }
    }

    func testHeightPresetsChangeOnlyPhysicalRowsAndPreserveRotationChoice() {
        let standard = KeyboardPanelPresentationBudget(
            candidateHeight: 44, candidateSize: 17,
            readingRow: false, candidateArea: true, compact: false)
        for preset in KeyboardHeightPreset.allCases {
            let budget = KeyboardPanelPresentationBudget(
                candidateHeight: 44, candidateSize: 17,
                readingRow: false, candidateArea: true, compact: false, heightPreset: preset)
            XCTAssertEqual(
                budget.shellHeight - standard.shellHeight,
                4 * (budget.keyHeight - standard.keyHeight), accuracy: 0.001)
            let rotated = budget.withCompact(true)
            XCTAssertEqual(rotated.keyHeight, 44)
            XCTAssertEqual(rotated.heightPreset, preset)
            XCTAssertEqual(rotated.withCompact(false), budget)
        }
    }

    func testHeightPresetFitsAllReadingAndCandidateCapabilities() {
        for preset in KeyboardHeightPreset.allCases {
            for compact in [false, true] {
                for reading in [false, true] {
                    for candidates in [false, true] {
                        let budget = KeyboardPanelPresentationBudget(
                            candidateHeight: 44, candidateSize: 17,
                            readingRow: reading, candidateArea: candidates, compact: compact, heightPreset: preset)
                        let fit = KeyboardPanelGeometry.fit(
                            shellHeight: budget.shellHeight,
                            candidateHeight: 44, standardKeyHeight: budget.keyHeight,
                            readingRowReserved: reading, candidateAreaReserved: candidates,
                            compactReadingRow: compact)
                        XCTAssertEqual(fit.keyHeight, budget.keyHeight, accuracy: 0.001)
                        XCTAssertGreaterThanOrEqual(fit.keyHeight, 44)
                        let plan = KeyboardPanelGeometry(
                            candidateHeight: 44, keyHeight: fit.keyHeight,
                            selectedMainRows: 3, readingRowReserved: reading && candidates,
                            compactReadingRow: compact, fittedHeaderHeight: fit.headerHeight,
                            topSlack: fit.topSlack, fittedReadingRowHeight: fit.readingRowHeight
                        )
                        .layoutPlan(showsHeader: candidates)
                        XCTAssertEqual(plan.panelHeight, budget.shellHeight, accuracy: 0.001)
                        XCTAssertTrue(plan.bandsAreContiguous)
                    }
                }
            }
        }
    }

    // MARK: - Composition contract: constant candidate bar x fixed tools button

    /// **Idle must also have a header band**, otherwise a tools entry fixed in the candidate bar would vanish with the bar.
    ///
    /// Production height converges on an entry that always includes the header; this holds on the composed tree and is
    /// pinned here as a pure-function geometry contract: the idle plan with `showsHeader: true` must have
    /// `headerHeight` > 0 and equal to the configured budget (after lifting to the minimum interactive height).
    func testCombinedTargetKeepsHeaderBandPresentWhenIdle() {
        let geometry = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54,
            selectedMainRows: 3)
        let idle = geometry.layoutPlan(showsHeader: true)
        XCTAssertGreaterThan(
            idle.headerHeight, 0,
            "idle must have a header band so the tools entry is reachable")
        XCTAssertEqual(idle.headerHeight, geometry.headerHeight, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(
            idle.headerHeight, 44,
            "the header band is lifted to the minimum interactive height")
        // A plan with header is taller than the mathematical no-header base by one header, minus the omitted top padding.
        let withoutHeader = geometry.layoutPlan(showsHeader: false)
        XCTAssertEqual(
            idle.panelHeight - withoutHeader.panelHeight,
            idle.headerHeight - headerTopPaddingSaving, accuracy: 0.0001)
        XCTAssertEqual(idle.contentTop, KeyboardPanelGeometry.candidateTopPadding)
        XCTAssertEqual(withoutHeader.contentTop, KeyboardPanelGeometry.verticalPadding)
    }

    private let layouts: [KeyboardLayoutKind] = [.qwerty26, .merged14, .phone9]

    func testBuiltinsShareLanguageBudgetButRotationStillChangesHeight() {
        let portrait = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let landscape = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 44, selectedMainRows: 3)
        XCTAssertEqual(portrait.panelHeight, 276)
        XCTAssertEqual(landscape.panelHeight, 236)
    }

    func testShortDIYReservesLatinRowsAndLongDIYUsesViewport() {
        let short = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 1)
        let long = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 5)
        XCTAssertEqual(short.mainAreaHeight, 170)
        XCTAssertEqual(short.panelHeight, long.panelHeight)
        let tallerViewport = KeyboardPanelGeometry(
            candidateHeight: 44, keyHeight: 54,
            selectedMainRows: 5, maximumVisibleRows: 4)
        XCTAssertEqual(tallerViewport.mainAreaHeight, 228)
    }

    func testCandidateConfigurationStillControlsHeaderBudget() {
        let configured = KeyboardPanelGeometry(candidateHeight: 60, keyHeight: 54, selectedMainRows: 3)
        XCTAssertEqual(configured.headerHeight, CandidateBarDefinition.Collapsed.effectiveHeight(60))
        XCTAssertEqual(configured.panelHeight - configured.headerHeight, 232)
        XCTAssertEqual(configured.basePanelHeight, 236)
    }

    // MARK: Mathematical base-height branch (non-production path) and the fixed production budget

    /// With content: the header fills the budget flush to the top (top padding 0); panel height = base + header - 4.
    func testPlanWithHeaderPinsExactFrames() {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let plan = geometry.layoutPlan(showsHeader: true)
        XCTAssertEqual(plan.headerHeight, 44)
        XCTAssertEqual(plan.contentTop, 0)
        XCTAssertEqual(plan.headerFrame, PanelVerticalFrame(top: 0, height: 44))
        XCTAssertEqual(plan.firstKeyRowTop, 44)
        XCTAssertEqual(plan.mainAreaFrame, PanelVerticalFrame(top: 44, height: 170))
        XCTAssertEqual(plan.controlRowFrame, PanelVerticalFrame(top: 218, height: 54))
        XCTAssertEqual(plan.contentBottom, 276, accuracy: 0.001)
        XCTAssertEqual(plan.panelHeight, 276)
    }

    /// `showsHeader: false` = the **mathematical base-height branch** (no header), used only for difference proofs and regressions;
    /// production always takes `fixedPanelHeight` (with header) in every state and does **not** go through here.
    func testBasePlanHasNoHeaderForMathDifferenceOnly() {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        let plan = geometry.layoutPlan(showsHeader: false)
        XCTAssertEqual(plan.headerHeight, 0, "the base-height branch must have no header")
        XCTAssertEqual(
            plan.headerFrame, PanelVerticalFrame(top: 4, height: 0),
            "the base-height branch headerFrame has zero height (non-production path)")
        XCTAssertEqual(plan.panelHeight, geometry.basePanelHeight)
        XCTAssertEqual(
            plan.panelHeight, 236, "base height = 236 (fixed production height minus header plus the 4pt top padding)")
        XCTAssertEqual(plan.mainAreaFrame, PanelVerticalFrame(top: 4, height: 170))
        XCTAssertEqual(plan.controlRowFrame, PanelVerticalFrame(top: 178, height: 54))
        XCTAssertEqual(plan.contentBottom, 236, accuracy: 0.001)
        // Difference from the fixed production height = header - omitted top padding; production uses `fixedPanelHeight`.
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54)
                - plan.panelHeight,
            geometry.headerHeight - headerTopPaddingSaving, accuracy: 0.001)
    }

    /// Fixed production height = base height + candidateHeight - 4 (candidate area flush to the top). There is **no** reserve.
    func testFixedProductionHeightExceedsBaseExactlyByHeader() {
        for candidateHeight in [36.0, 44.0, 56.0] {
            for keyHeight in [44.0, 54.0] {
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                let base = geometry.layoutPlan(showsHeader: false)
                let fixed = geometry.layoutPlan(showsHeader: true)
                XCTAssertEqual(
                    fixed.panelHeight,
                    KeyboardPanelGeometry.fixedPanelHeight(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight),
                    accuracy: 0.001)
                XCTAssertEqual(base.panelHeight, geometry.basePanelHeight)
                XCTAssertEqual(
                    fixed.panelHeight,
                    base.panelHeight + geometry.headerHeight - headerTopPaddingSaving,
                    "the fixed height must equal base height + candidateHeight - the omitted top padding exactly")
            }
        }
    }

    /// **Touch targets do not drift**: hosting is bottom-anchored, so the first key row, main area and control row keep the same
    /// distance **from the panel bottom** in both states; candidates appearing only add height at the top and never push keys down.
    func testBottomRelativeFramesAreIdenticalAcrossStates() {
        for candidateHeight in [36.0, 44.0, 56.0] {
            for keyHeight in [44.0, 54.0] {
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                let idle = geometry.layoutPlan(showsHeader: false)
                let shown = geometry.layoutPlan(showsHeader: true)
                for (name, band) in [
                    ("main", { (p: KeyboardPanelLayoutPlan) in p.mainAreaFrame }),
                    ("control", { (p: KeyboardPanelLayoutPlan) in p.controlRowFrame }),
                ] {
                    XCTAssertEqual(
                        idle.distanceFromPanelBottom(toTopOf: band(idle)),
                        shown.distanceFromPanelBottom(toTopOf: band(shown)),
                        accuracy: 0.001,
                        "\(name) top distance from the panel bottom must be constant (no drift)")
                    XCTAssertEqual(
                        idle.distanceFromPanelBottom(toBottomOf: band(idle)),
                        shown.distanceFromPanelBottom(toBottomOf: band(shown)),
                        accuracy: 0.001,
                        "\(name) bottom distance from the panel bottom must be constant (no drift)")
                }
            }
        }
    }

    /// Matrix: 26/14/9 all follow the same geometry contract; the production fixed plan always has a header and the base-height branch is only a difference.
    func testReproductionMatrixGeometryForEveryLayout() {
        for layout in layouts {
            let geometry = KeyboardPanelGeometry(
                candidateHeight: 44, keyHeight: 54,
                selectedMainRows: 3)
            XCTAssertEqual(geometry.headerHeight, 44)
            XCTAssertEqual(
                geometry.layoutPlan(showsHeader: false).headerHeight, 0,
                "\(layout) the base-height branch must not keep a header")
            XCTAssertEqual(
                geometry.layoutPlan(showsHeader: true).headerHeight, 44,
                "\(layout) the production fixed plan must have a fixed header")
            XCTAssertEqual(
                geometry.layoutPlan(showsHeader: false).panelHeight,
                geometry.basePanelHeight)
            XCTAssertEqual(
                geometry.layoutPlan(showsHeader: true).panelHeight,
                geometry.panelHeight)
        }
    }

    /// Bands do not overlap, frames are self-consistent, and there is no "bottom reserve" band.
    func testBandsNeverOverlapAndNoReserveBand() {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        for plan in [geometry.layoutPlan(showsHeader: false), geometry.layoutPlan(showsHeader: true)] {
            XCTAssertFalse(plan.headerFrame.intersects(plan.mainAreaFrame))
            XCTAssertFalse(plan.mainAreaFrame.intersects(plan.controlRowFrame))
            XCTAssertEqual(plan.contentBottom, plan.panelHeight, accuracy: 0.001)
            // The plan type has no bottomReserve property (enforced at compile time, so there is no transparent-hole scheme).
        }
    }

    /// Compatibility contract with the nine-key shared slot/top alignment branch: panel geometry does not depend on the layout family.
    func testPanelGeometryIsLayoutFamilyIndependentForMergeSafety() {
        let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
        XCTAssertEqual(
            geometry.layoutPlan(showsHeader: false),
            geometry.layoutPlan(showsHeader: false))
        XCTAssertEqual(
            geometry.layoutPlan(showsHeader: true),
            geometry.layoutPlan(showsHeader: true))
        XCTAssertEqual(
            geometry.layoutPlan(showsHeader: false).firstKeyRowTop,
            KeyboardPanelGeometry.verticalPadding)
        XCTAssertEqual(geometry.layoutPlan(showsHeader: false).headerHeight, 0)
    }

    // MARK: Unified height budget (explicit config 36...56pt, larger fonts add as needed)

    /// Configs of 36...43 keep their height; the surface, reported height and candidate vertical budget share one source.
    func testConfiguredHeightsKeepTheirBudgetUnlessFontNeedsMore() {
        for configured in [36.0, 40.0, 43.0, 44.0] {
            let geometry = KeyboardPanelGeometry(
                candidateHeight: configured, keyHeight: 54,
                selectedMainRows: 3)
            XCTAssertEqual(geometry.headerHeight, configured)
            XCTAssertEqual(CandidateHeaderSurfacePolicy.surfaceHeight(configured: configured), configured)
            var bar = CandidateBarDefinition(id: "probe", name: "probe")
            bar.collapsed.height = configured
            XCTAssertEqual(bar.collapsedHeightBudget, configured)
            XCTAssertEqual(
                CandidateBarDefinition.Collapsed.clampedHeight(configured), configured,
                "the config range itself is still kept as-is at 36...56")
        }
        XCTAssertEqual(
            KeyboardPanelGeometry(
                candidateHeight: 60, keyHeight: 54,
                selectedMainRows: 3
            ).headerHeight, 56)
        XCTAssertEqual(CandidateBarDefinition.Collapsed.effectiveHeight(36, candidateSize: 30), 41)
    }

    func testCandidateFontSizePropagatesThroughPanelHeightEntries() {
        let candidateSize = 30.0
        let expectedHeader = 41.0
        let geometry = KeyboardPanelGeometry(
            candidateHeight: 36, keyHeight: 54,
            selectedMainRows: 3, candidateSize: candidateSize)
        XCTAssertEqual(geometry.headerHeight, expectedHeader)
        XCTAssertEqual(
            CandidateHeaderSurfacePolicy.surfaceHeight(
                configured: 36,
                candidateSize: candidateSize),
            expectedHeader)
        XCTAssertEqual(
            KeyboardPanelGeometry.panelHeight(
                candidateHeight: 36, keyHeight: 54,
                selectedMainRows: 3, showsHeader: true,
                candidateSize: candidateSize),
            geometry.panelHeight)
        XCTAssertEqual(
            KeyboardPanelGeometry.panelHeight(
                candidateHeight: 36, keyHeight: 54,
                showsHeader: true, candidateSize: candidateSize),
            geometry.panelHeight)
        XCTAssertEqual(
            KeyboardPanelGeometry.fixedPanelHeight(
                candidateHeight: 36, keyHeight: 54,
                candidateSize: candidateSize),
            geometry.panelHeight)
        XCTAssertEqual(
            KeyboardPanelGeometry.idlePanelHeight(
                candidateHeight: 36, keyHeight: 54,
                candidateSize: candidateSize),
            geometry.basePanelHeight)
        for configured in [44.0, 50.0, 56.0] {
            XCTAssertEqual(
                CandidateBarDefinition.Collapsed.effectiveHeight(
                    configured,
                    candidateSize: 17), configured)
        }
    }

    /// Lifting adds height only at the **top**: the key area/control row keep their distance from the panel bottom (host bottom-anchored),
    /// and the content bottom always equals the panel height (no transparent hole).
    func testLiftedHeaderKeepsKeyAreaBottomRelativeAndLeavesNoHole() {
        let reference = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
            .layoutPlan(showsHeader: true)
        for configured in [36.0, 40.0, 43.0, 44.0] {
            let plan = KeyboardPanelGeometry(
                candidateHeight: configured, keyHeight: 54,
                selectedMainRows: 3
            )
            .layoutPlan(showsHeader: true)
            for (name, band) in [
                ("main", { (p: KeyboardPanelLayoutPlan) in p.mainAreaFrame }),
                ("control", { (p: KeyboardPanelLayoutPlan) in p.controlRowFrame }),
            ] {
                XCTAssertEqual(
                    plan.distanceFromPanelBottom(toTopOf: band(plan)),
                    reference.distanceFromPanelBottom(toTopOf: band(reference)),
                    accuracy: 0.001, "\(configured) \(name) top distance from the panel bottom must be unchanged")
                XCTAssertEqual(
                    plan.distanceFromPanelBottom(toBottomOf: band(plan)),
                    reference.distanceFromPanelBottom(toBottomOf: band(reference)),
                    accuracy: 0.001, "\(configured) \(name) bottom distance from the panel bottom must be unchanged")
            }
            XCTAssertEqual(
                plan.contentBottom, plan.panelHeight, accuracy: 0.001,
                "\(configured) no transparent hole: content bottom == panel height")
        }
    }

    // MARK: Host / panel shared height entry (single owner; the two sides must not each assemble it)

    /// The host's 3-row entry and the panel's definition-row-count entry are **necessarily identical** (`visibleMainRows` is always clamped to 3).
    func testSharedPanelHeightEntryAgreesForEverySelectedMainRowCount() {
        for candidateHeight in [36.0, 44.0, 56.0] {
            for keyHeight in [44.0, 54.0] {
                for showsHeader in [false, true] {
                    let shared = KeyboardPanelGeometry.panelHeight(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight,
                        showsHeader: showsHeader)
                    let direct = KeyboardPanelGeometry(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight, selectedMainRows: 3
                    )
                    .layoutPlan(showsHeader: showsHeader).panelHeight
                    XCTAssertEqual(
                        shared, direct, accuracy: 0.001,
                        "the shared entry must equal the directly constructed plan (\(candidateHeight)/\(keyHeight)/\(showsHeader)）"
                    )
                    for rows in 1...6 {
                        let explicit = KeyboardPanelGeometry.panelHeight(
                            candidateHeight: candidateHeight,
                            keyHeight: keyHeight,
                            selectedMainRows: rows,
                            showsHeader: showsHeader)
                        XCTAssertEqual(
                            explicit, shared, accuracy: 0.001,
                            " row count \(rows) must match the standard three-row budget (host and panel must not diverge)"
                        )
                    }
                }
            }
        }
    }

    /// The `idlePanelHeight` entry = `basePanelHeight` (the **base height without header**, only a mathematical difference;
    /// the production shell is always the fixed budget), and the fixed full height == base height + header - the omitted top padding.
    func testIdlePanelHeightEntryIsHeaderFree() {
        for candidateHeight in [36.0, 44.0, 56.0] {
            for keyHeight in [44.0, 54.0] {
                let idle = KeyboardPanelGeometry.idlePanelHeight(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight)
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                XCTAssertEqual(idle, geometry.basePanelHeight, accuracy: 0.001)
                XCTAssertEqual(
                    idle, geometry.layoutPlan(showsHeader: false).panelHeight,
                    accuracy: 0.001)
                XCTAssertEqual(
                    KeyboardPanelGeometry.panelHeight(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight,
                        showsHeader: true),
                    idle + geometry.headerHeight - headerTopPaddingSaving, accuracy: 0.001,
                    "the full height must be exactly idle + header (no transparent reserve)")
            }
        }
    }

    // MARK: Fixed production budget (the candidate bar and key area own non-overlapping fixed vertical regions)

    /// The `fixedPanelHeight` entry == the plan height with header == base + header - 4, with all three bands meeting exactly.
    /// The header and the first key row **share no pixel row** (header bottom == key top).
    func testFixedPanelHeightIsTheProductionBudgetAndBandsAreContiguous() {
        for candidateHeight in [36.0, 40.0, 44.0, 56.0, 60.0] {
            for keyHeight in [44.0, 54.0] {
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                let plan = geometry.layoutPlan(showsHeader: true)
                XCTAssertEqual(
                    KeyboardPanelGeometry.fixedPanelHeight(
                        candidateHeight: candidateHeight,
                        keyHeight: keyHeight),
                    plan.panelHeight, accuracy: 0.001)
                XCTAssertEqual(
                    plan.panelHeight,
                    geometry.basePanelHeight + geometry.headerHeight - headerTopPaddingSaving,
                    accuracy: 0.001)
                XCTAssertTrue(plan.bandsAreContiguous, "\(candidateHeight)/\(keyHeight) the three bands must meet")
                XCTAssertEqual(
                    plan.headerFrame.maxY, plan.firstKeyRowTop, accuracy: 0.001,
                    "the header bottom must be exactly the first key row top (no shared pixel row)")
                XCTAssertFalse(plan.headerFrame.intersects(plan.mainAreaFrame))
                XCTAssertFalse(plan.mainAreaFrame.intersects(plan.controlRowFrame))
                XCTAssertEqual(
                    plan.firstKeyRowTop,
                    KeyboardPanelGeometry.candidateTopPadding + geometry.headerHeight,
                    accuracy: 0.001)
                XCTAssertEqual(plan.contentBottom, plan.panelHeight, accuracy: 0.001)
            }
        }
    }

    /// The production plan is **invariant** to candidate state input: repeatedly taking the fixed plan from the same geometry must give identical fields
    /// (candidates appearing/disappearing is not a geometry input).
    func testFixedProductionPlanIsInvariantAcrossRepeatedReads() {
        for layout in layouts {
            let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
            let first = geometry.layoutPlan(showsHeader: true)
            let second = geometry.layoutPlan(showsHeader: true)
            XCTAssertEqual(first, second, "\(layout) the fixed plan must not depend on read count/state")
            XCTAssertEqual(
                first.panelHeight,
                KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54),
                accuracy: 0.001)
            XCTAssertGreaterThan(first.headerHeight, 0, "\(layout) the fixed plan must keep the candidate bar budget")
        }
    }

    // MARK: Presentation shell height (iOS fixes the extension height per presentation; all pages in a presentation share one shell)

    /// Default (candidate 40 / key 54 / system candidate size 17): the shell budgets the selected definition's main page at
    /// 54pt key rows at the start of the presentation; 14-key is one reading row taller than 26/9. Switching to another layout/page
    /// within the same presentation only redistributes inside the shell: key rows never exceed 54, extra height goes to the candidate area (or stays at the top without one),
    /// and key rows shrink when the shell is short. Every page's plan exactly fills the shell.
    func testFitFillsThePresentationShellWithoutStretchingKeys() {
        let candidateHeight = 40.0
        let fourteen = KeyboardPanelGeometry.presentationShellHeight(
            candidateHeight: candidateHeight,
            keyHeight: 54, readingRow: true)
        let standard = KeyboardPanelGeometry.presentationShellHeight(
            candidateHeight: candidateHeight,
            keyHeight: 54, readingRow: false)
        XCTAssertEqual(fourteen, 309)
        XCTAssertEqual(
            fourteen - standard, CandidateReadingRowPolicy.height - KeyboardPanelGeometry.readingLayoutBonusCut)
        let reading = CandidateReadingRowPolicy.height
        let bonus = KeyboardPanelGeometry.candidateAreaBonus
        let share = KeyboardPanelGeometry.readingRowSpareShare
        let cut = KeyboardPanelGeometry.readingLayoutBonusCut
        let squeezed = CandidateReadingRowPolicy.minimumHeight
        // The host-gap cut is laid out and then taken off the top of the topmost band:
        // the 14-key reading row keeps its `share` of the untrimmed spare height, minus the trim.
        let trim = KeyboardPanelGeometry.hostGapWorkaroundCut
        let readingSpare = share - trim
        let cases:
            [(
                name: String, shell: Double, reading: Bool, candidateArea: Bool, key: Double, header: Double,
                slack: Double
            )] = [
                ("14-key shell / 14-key reading row", fourteen, true, true, 54, 40 + bonus + trim - cut - share, 0),
                ("14-key shell / 26-key", fourteen, false, true, 54, 40 + bonus - cut + reading, 0),
                (
                    "14-key shell / 123 without candidate area", fourteen, false, false, 54, 0,
                    40 + bonus - cut + reading - 4
                ),
                ("26-key shell / 26-key", standard, false, true, 54, 40 + bonus, 0),
                ("26-key shell / 14-key reading row", standard, true, true, 54 - (squeezed - bonus) / 4, 40, 0),
                ("26-key shell / 123 without candidate area", standard, false, false, 54, 0, 40 + bonus - 4),
            ]
        for page in cases {
            let fit = KeyboardPanelGeometry.fit(
                shellHeight: page.shell, candidateHeight: candidateHeight,
                standardKeyHeight: 54,
                readingRowReserved: page.reading,
                candidateAreaReserved: page.candidateArea)
            XCTAssertEqual(fit.keyHeight, page.key, accuracy: 0.001, "\(page.name) key height")
            XCTAssertEqual(fit.headerHeight, page.header, accuracy: 0.001, "\(page.name) candidate area")
            XCTAssertEqual(fit.topSlack, page.slack, accuracy: 0.001, "\(page.name) top slack")
            // Only the squeezed reading row (no room above its text) and pages without a candidate area skip the trim.
            let trimmed = page.candidateArea && !(page.reading && page.shell == standard)
            XCTAssertEqual(fit.topTrim, trimmed ? trim : 0, "\(page.name) top trim")
            let plan = KeyboardPanelGeometry(
                candidateHeight: candidateHeight, keyHeight: fit.keyHeight,
                selectedMainRows: 3, readingRowReserved: page.reading,
                fittedHeaderHeight: fit.headerHeight, topSlack: fit.topSlack,
                fittedReadingRowHeight: fit.readingRowHeight
            )
            .layoutPlan(showsHeader: page.candidateArea)
            XCTAssertEqual(
                fit.readingRowHeight, page.reading ? (page.shell == fourteen ? reading + readingSpare : squeezed) : 0,
                accuracy: 0.001,
                "\(page.name) reading row's share of spare height (when the shell is short, the reading row is squeezed first)"
            )
            XCTAssertEqual(plan.panelHeight, page.shell, accuracy: 0.001, "\(page.name) must exactly fill the shell")
            XCTAssertTrue(plan.bandsAreContiguous, "\(page.name) bands must meet")
        }
    }

    /// A shell shorter than a page needs (e.g. iOS kept an earlier budget) shrinks the keys.
    func testShortShellShrinksKeysInsteadOfTheCandidateArea() {
        let fit = KeyboardPanelGeometry.fit(
            shellHeight: 260, candidateHeight: 40, standardKeyHeight: 54,
            readingRowReserved: false, candidateAreaReserved: true)
        XCTAssertEqual(fit.headerHeight, 40)
        XCTAssertEqual(fit.keyHeight, (260 - 40 - 16) / 4, accuracy: 0.001)
    }

    /// iOS kept the 9/26-key height while a 14-key page is shown (an earlier presentation's
    /// budget): the reading row gives up height before the keys, so 14-key keys stay as
    /// tall as possible instead of dropping below the 9-key ones.
    func testShortShellSqueezesTheReadingRowBeforeTheKeys() {
        let standard = KeyboardPanelGeometry.presentationShellHeight(
            candidateHeight: 40, keyHeight: 54,
            readingRow: false)
        let slightlyShort =
            KeyboardPanelGeometry.presentationShellHeight(
                candidateHeight: 40, keyHeight: 54,
                readingRow: true) - 4
        let squeezedOnly = KeyboardPanelGeometry.fit(
            shellHeight: slightlyShort, candidateHeight: 40,
            standardKeyHeight: 54, readingRowReserved: true,
            candidateAreaReserved: true)
        XCTAssertEqual(squeezedOnly.keyHeight, 54, accuracy: 0.001, "the row absorbs a small shortfall alone")
        XCTAssertGreaterThan(squeezedOnly.readingRowHeight, CandidateReadingRowPolicy.minimumHeight)

        let fit = KeyboardPanelGeometry.fit(
            shellHeight: standard, candidateHeight: 40, standardKeyHeight: 54,
            readingRowReserved: true, candidateAreaReserved: true)
        XCTAssertEqual(fit.readingRowHeight, CandidateReadingRowPolicy.minimumHeight, accuracy: 0.001)
        XCTAssertEqual(
            fit.keyHeight,
            54 - (CandidateReadingRowPolicy.minimumHeight - KeyboardPanelGeometry.candidateAreaBonus) / 4,
            accuracy: 0.001, "only what the row cannot give comes from the keys")
        XCTAssertEqual(
            CandidateReadingRowPolicy.textTopPadding(rowHeight: fit.readingRowHeight), 0,
            "a squeezed row centres its text instead of clipping it")
        XCTAssertEqual(
            CandidateReadingRowPolicy.textTopPadding(rowHeight: CandidateReadingRowPolicy.height),
            CandidateReadingRowPolicy.textDrop * 2)
    }

    func testLandscapeShellUsesTheCompactReadingRow() {
        let shell = KeyboardPanelGeometry.presentationShellHeight(
            candidateHeight: 40, keyHeight: 44,
            readingRow: true, compactReadingRow: true)
        let fit = KeyboardPanelGeometry.fit(
            shellHeight: shell, candidateHeight: 40, standardKeyHeight: 44,
            readingRowReserved: true, candidateAreaReserved: true,
            compactReadingRow: true)
        XCTAssertEqual(fit.keyHeight, 44, accuracy: 0.001)
        let plan = KeyboardPanelGeometry(
            candidateHeight: 40, keyHeight: fit.keyHeight, selectedMainRows: 3,
            readingRowReserved: true, compactReadingRow: true,
            fittedHeaderHeight: fit.headerHeight,
            fittedReadingRowHeight: fit.readingRowHeight
        )
        .layoutPlan(showsHeader: true)
        XCTAssertEqual(plan.panelHeight, shell, accuracy: 0.001)
        XCTAssertEqual(
            plan.readingRowHeight,
            CandidateReadingRowPolicy.compactHeight + KeyboardPanelGeometry.readingRowSpareShare
                - KeyboardPanelGeometry.hostGapWorkaroundCut)
        XCTAssertEqual(fit.topTrim, KeyboardPanelGeometry.hostGapWorkaroundCut)
    }
}
