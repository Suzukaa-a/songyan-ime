import SwiftUI
import XCTest

@testable import CandidateKit

final class KeyboardColdEntryLayoutTests: XCTestCase {
    @MainActor
    private func measuredHeight<V: View>(_ view: V, proposal: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 402, height: proposal)
        var measured: CGSize?
        // Run SwiftUI's real layout pipeline without creating a window or simulator.
        renderer.render { size, _ in measured = size }
        return try XCTUnwrap(measured).height
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在准备键盘…").font(.footnote)
            Text("首次使用可能需要一点时间").font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    func testOldLoadingAcceptsColdTallProposalButBudgetedLoadingDoesNot() async throws {
        let old = VStack(spacing: 4) { loading }
            .frame(maxWidth: .infinity, idealHeight: 300, maxHeight: .infinity)
        XCTAssertEqual(try measuredHeight(old, proposal: 509), 509, accuracy: 0.01)
        // Production budget = the **unified shell height** (including the candidate bar), identical for all layouts/pages/phases/states.
        let fixed = CGFloat(
            KeyboardPanelGeometry.presentationShellHeight(
                candidateHeight: 44, keyHeight: 54,
                readingRow: true))
        XCTAssertEqual(
            fixed, 306, accuracy: 0.01,
            "44 candidate budget - 2 (bonus minus cuts) + 32 reading row + 4x54 key rows (candidate area flush to the top) = 14-key shell height 306"
        )
        XCTAssertEqual(
            try measuredHeight(
                VStack(spacing: 4) { loading }.keyboardPanelHeight(fixed),
                proposal: 509), fixed, accuracy: 0.01)
    }

    @MainActor
    func testAllPhasesHaveSameExternalSizeAcrossProposalsAndRotation() async throws {
        let error = VStack {
            Text("键盘暂时无法使用")
            Button("重试") {}
            Button("错误详情") {}
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        let ready = GeometryReader { _ in Color.gray }
        // The extra system-switch row participates INSIDE the loading/error budget.
        let phases = [
            AnyView(
                VStack {
                    loading
                    Color.clear.frame(height: 44)
                }),
            AnyView(
                VStack {
                    error
                    Color.clear.frame(height: 44)
                }),
            AnyView(ready),
        ]
        for keyHeight in [44.0, 54.0] {
            // starting / failed / unconfigured share the same fixed budget as ready.
            let height = CGFloat(
                KeyboardPanelGeometry.fixedPanelHeight(
                    candidateHeight: 44,
                    keyHeight: keyHeight))
            for proposal in [180.0, 280.0, 509.0, 900.0] {
                for phase in phases {
                    XCTAssertEqual(
                        try measuredHeight(phase.keyboardPanelHeight(height), proposal: proposal),
                        height, accuracy: 0.01)
                }
            }
        }
    }

    /// Production contract: the cold-start outer height must equal the **fixed production budget** (same as ready/all phases),
    /// so "the candidate bar and key area own fixed vertical regions" holds end to end and nothing jumps on entering ready.
    /// The cold-start provider is aligned (`KeyboardAppearance.shellHeight` goes through `presentationShellHeight`).
    @MainActor
    func testColdStartBudgetMustEqualTheFixedProductionPlan() async throws {
        for keyHeight in [44.0, 54.0] {
            for candidateHeight in [36.0, 44.0, 56.0] {
                let geometry = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight,
                    keyHeight: keyHeight, selectedMainRows: 3)
                let fixed = CGFloat(
                    KeyboardPanelGeometry.fixedPanelHeight(
                        candidateHeight: candidateHeight, keyHeight: keyHeight))
                XCTAssertEqual(
                    fixed, CGFloat(geometry.layoutPlan(showsHeader: true).panelHeight),
                    accuracy: 0.01, "the fixed budget must be exactly the plan height including the header")
                XCTAssertEqual(
                    fixed,
                    CGFloat(
                        geometry.basePanelHeight + geometry.headerHeight
                            - KeyboardPanelGeometry.verticalPadding
                            + KeyboardPanelGeometry.candidateTopPadding),
                    accuracy: 0.01, "fixed budget == base height + one header - the omitted top padding")
                XCTAssertEqual(
                    CGFloat(
                        KeyboardPanelGeometry.presentationShellHeight(
                            candidateHeight: candidateHeight, keyHeight: keyHeight, readingRow: true)),
                    CGFloat(
                        KeyboardPanelGeometry.fixedPanelHeight(
                            candidateHeight: candidateHeight,
                            keyHeight: keyHeight,
                            readingRowReserved: true) + KeyboardPanelGeometry.candidateAreaBonus
                            - KeyboardPanelGeometry.readingLayoutBonusCut),
                    accuracy: 0.01,
                    "cold-start shell == the 14-key reading-row page's fixed budget + candidate area bonus")
                XCTAssertEqual(
                    try measuredHeight(
                        VStack(spacing: 4) { loading }.keyboardPanelHeight(fixed),
                        proposal: 509), fixed, accuracy: 0.01,
                    "loading and ready must have the same height under the fixed budget (\(candidateHeight)/\(keyHeight)）"
                )
            }
        }
    }
}

#if canImport(UIKit)
    import UIKit

    final class KeyboardInputViewLayoutTests: XCTestCase {
        /// The production **fixed outer budget** (same source as `KeyboardPanelGeometry.fixedPanelHeight`; all host
        /// phases and the panel content height use it).
        private func fixedHeight(keyHeight: Double) -> CGFloat {
            CGFloat(KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: keyHeight))
        }

        @MainActor
        func testNativeFittingAndHostingLoadingShareBudgetBeforeFirstAppearance() async throws {
            let budget = fixedHeight(keyHeight: 54)
            XCTAssertEqual(budget, 276, accuracy: 0.01)
            let parent = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 900))
            let input = KeyboardPanelInputView(
                frame: CGRect(x: 0, y: 0, width: 402, height: budget),
                inputViewStyle: .default)
            let hosting = UIHostingController(
                rootView:
                    VStack {
                        Text("正在准备键盘…")
                        Spacer()
                    }.keyboardPanelHeight(budget))
            hosting.sizingOptions = []
            input.translatesAutoresizingMaskIntoConstraints = false
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(input)
            input.addSubview(hosting.view)
            NSLayoutConstraint.activate([
                input.topAnchor.constraint(equalTo: parent.topAnchor),
                input.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                input.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                hosting.view.topAnchor.constraint(equalTo: input.topAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: input.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: input.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            ])
            parent.layoutIfNeeded()
            XCTAssertEqual(input.bounds.height, budget, accuracy: 0.01)
            XCTAssertEqual(hosting.view.bounds.height, budget, accuracy: 0.01)
            XCTAssertEqual(input.intrinsicContentSize.height, budget)
            XCTAssertTrue(input.allowsSelfSizing)
            XCTAssertEqual(input.budgetHeightConstraint.priority, UILayoutPriority(999))
            for proposed in [0.0, 509.0, 900.0] {
                XCTAssertEqual(input.systemLayoutSizeFitting(CGSize(width: 402, height: proposed)).height, budget)
                XCTAssertEqual(input.sizeThatFits(CGSize(width: 402, height: proposed)).height, budget)
                XCTAssertEqual(
                    input.systemLayoutSizeFitting(
                        CGSize(width: 402, height: proposed),
                        withHorizontalFittingPriority: .required,
                        verticalFittingPriority: .fittingSizeLevel
                    ).height, budget)
            }
            input.setPanelHeight(240)
            hosting.rootView = VStack {
                Text("正在准备键盘…")
                Spacer()
            }.keyboardPanelHeight(240)
            parent.layoutIfNeeded()
            XCTAssertEqual(input.bounds.height, 240, accuracy: 0.01)
            XCTAssertEqual(hosting.view.bounds.height, 240, accuracy: 0.01)
            for height in [280.0, 316.0, 280.0] as [CGFloat] {
                input.setPanelHeight(height)
                hosting.rootView = VStack {
                    Text("正在准备键盘…")
                    Spacer()
                }.keyboardPanelHeight(height)
                parent.setNeedsUpdateConstraints()
                parent.updateConstraintsIfNeeded()
                parent.layoutIfNeeded()
                XCTAssertEqual(input.bounds.height, height, accuracy: 0.01)
                XCTAssertEqual(hosting.view.bounds.height, height, accuracy: 0.01)
                XCTAssertEqual(
                    input.systemLayoutSizeFitting(CGSize(width: 402, height: 874)).height,
                    height, accuracy: 0.01)
            }
        }

        /// Replicates the actual production hierarchy installed by
        /// `KeyboardViewController.loadView` + `viewDidLoad` (transparent root,
        /// bottom-anchored required fixed-height content, no top constraint) instead
        /// of the four-edge pinning used above. A regression in this layer lets the
        /// late one-frame band reappear.
        @MainActor
        func testProductionTransparentRootKeepsBottomAnchoredContentFixedDuringOversizedPlacement() async throws {
            let budget = fixedHeight(keyHeight: 54)
            let screen = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let root = KeyboardPanelInputView(
                frame: CGRect(x: 0, y: 0, width: 402, height: budget),
                inputViewStyle: .default)
            // loadView(): the root stays transparent; the skin is painted by content.
            root.backgroundColor = .clear
            root.clipsToBounds = true
            let hosting = UIHostingController(
                rootView:
                    VStack {
                        Text("正在准备键盘…")
                        Spacer()
                    }.keyboardPanelHeight(budget))
            hosting.sizingOptions = []
            hosting.view.backgroundColor = .clear
            root.translatesAutoresizingMaskIntoConstraints = false
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(root)
            root.addSubview(hosting.view)

            // viewDidLoad(): leading / trailing / bottom + REQUIRED exact height.
            // Deliberately NO top constraint: the bottom edge is the stable anchor.
            let hostingHeight = hosting.view.heightAnchor.constraint(equalToConstant: budget)
            hostingHeight.priority = .required
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
                root.topAnchor.constraint(equalTo: screen.topAnchor),
                root.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                hostingHeight,
            ])
            screen.layoutIfNeeded()

            // Transparent root: an oversized root frame cannot paint a slab.
            XCTAssertEqual(root.backgroundColor, .clear)
            XCTAssertTrue(root.clipsToBounds)
            // Content is not top-pinned, so it cannot be stretched by an oversized root.
            XCTAssertFalse(root.constraints.contains { $0.firstAttribute == .top })

            // The system's transient oversized placement changes only the root height.
            // The content must keep its exact height and stay anchored to the bottom.
            for oversized in [874.0, 508.0, 874.0, 280.0] {
                screen.frame = CGRect(x: 0, y: 0, width: 402, height: oversized)
                screen.layoutIfNeeded()
                XCTAssertEqual(root.bounds.height, oversized, accuracy: 0.01)
                XCTAssertEqual(
                    hosting.view.bounds.height, budget, accuracy: 0.01,
                    "content must not be stretched by an oversized root (\(oversized))")
                XCTAssertEqual(
                    hosting.view.frame.maxY, root.bounds.maxY, accuracy: 0.01,
                    "content must stay anchored to the root's bottom edge (\(oversized))")
            }

            // Budget changes propagate to the content without relying on the top edge.
            root.setPanelHeight(240)
            hosting.rootView = VStack {
                Text("正在准备键盘…")
                Spacer()
            }.keyboardPanelHeight(240)
            hostingHeight.constant = 240
            screen.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            screen.layoutIfNeeded()
            XCTAssertEqual(hosting.view.bounds.height, 240, accuracy: 0.01)
            XCTAssertEqual(hosting.view.frame.maxY, root.bounds.maxY, accuracy: 0.01)
        }

        /// Fixed budget: the production update path (`onPanelHeightChange` -> `setPanelHeight`) does
        /// **not change** the outer height between candidate states; hosting stays bottom-anchored, so the first key row does not move relative to the screen bottom.
        @MainActor
        func testFixedBudgetKeepsHostingBottomAnchoredAndHeightStableAcrossStates() async throws {
            let geometry = KeyboardPanelGeometry(candidateHeight: 44, keyHeight: 54, selectedMainRows: 3)
            let fixed = geometry.layoutPlan(showsHeader: true)
            // Production host and cold start must use the **same** fixed budget.
            XCTAssertEqual(
                CGFloat(KeyboardPanelGeometry.fixedPanelHeight(candidateHeight: 44, keyHeight: 54)),
                CGFloat(fixed.panelHeight), accuracy: 0.01,
                "the fixed budget must equal the production plan including the header")
            let screen = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let root = KeyboardPanelInputView(
                frame: CGRect(
                    x: 0, y: 0, width: 402,
                    height: fixed.panelHeight),
                inputViewStyle: .default)
            root.backgroundColor = .clear
            root.clipsToBounds = true

            var height = CGFloat(fixed.panelHeight)
            let hosting = UIHostingController(rootView: VStack { Color.clear }.keyboardPanelHeight(height))
            hosting.sizingOptions = []
            hosting.view.backgroundColor = .clear
            root.translatesAutoresizingMaskIntoConstraints = false
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            screen.addSubview(root)
            root.addSubview(hosting.view)
            let hostingHeight = hosting.view.heightAnchor.constraint(equalToConstant: height)
            hostingHeight.priority = .required
            NSLayoutConstraint.activate([
                root.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
                root.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
                root.topAnchor.constraint(equalTo: screen.topAnchor),
                root.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
                hosting.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                hosting.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                hosting.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                hostingHeight,
            ])
            screen.layoutIfNeeded()

            /// Production update path: the host reports only the **fixed** height, independent of candidate state.
            var appliedHeights: [CGFloat] = []
            func apply(_ plan: KeyboardPanelLayoutPlan) {
                height = CGFloat(plan.panelHeight)
                appliedHeights.append(height)
                root.setPanelHeight(height)
                hosting.rootView = VStack { Color.clear }.keyboardPanelHeight(height)
                hostingHeight.constant = height
                screen.layoutIfNeeded()
            }

            // Repeated production updates: the height stays at the fixed budget with no accumulation and no extra frames.
            for _ in 0..<5 {
                apply(fixed)
                XCTAssertEqual(
                    root.panelHeight, CGFloat(fixed.panelHeight), accuracy: 0.01,
                    "panelHeight must equal the fixed budget exactly, with no accumulation")
                XCTAssertEqual(hosting.view.bounds.height, CGFloat(fixed.panelHeight), accuracy: 0.01)
                XCTAssertEqual(
                    hosting.view.frame.maxY, root.bounds.maxY, accuracy: 0.01,
                    "hosting must be bottom-anchored")
                XCTAssertEqual(root.intrinsicContentSize.height, CGFloat(fixed.panelHeight), accuracy: 0.01)
            }
            XCTAssertEqual(
                Set(appliedHeights.map { Int($0.rounded()) }).count, 1,
                "a production update must not produce any non-fixed height")

            // The first key row's position relative to the screen bottom is independent of the candidate budget (the header cancels out in the difference).
            for candidateHeight in [36.0, 44.0, 56.0] {
                let other = KeyboardPanelGeometry(
                    candidateHeight: candidateHeight, keyHeight: 54,
                    selectedMainRows: 3)
                let otherPlan = other.layoutPlan(showsHeader: true)
                XCTAssertEqual(
                    otherPlan.distanceFromPanelBottom(toTopOf: otherPlan.mainAreaFrame),
                    fixed.distanceFromPanelBottom(toTopOf: fixed.mainAreaFrame), accuracy: 0.01,
                    "candidate budget \(candidateHeight) must not make the first key row drift relative to the screen bottom"
                )
            }

            // The constraint count does not change with state (no accumulating constraints).
            let constraintCount = root.constraints.count
            apply(fixed)
            apply(fixed)
            XCTAssertEqual(
                root.constraints.count, constraintCount,
                "a state switch must not accumulate constraints")
        }
        @MainActor
        func testAttachedWindowRetainedHeightIsScopedToOnePresentation() {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let root = KeyboardPanelInputView(
                frame: CGRect(x: 0, y: 0, width: 402, height: 316),
                inputViewStyle: .default)
            controller.view.addSubview(root)
            XCTAssertNotNil(root.window)
            root.beginPresentation(height: 316)
            root.setPanelHeight(320)
            root.bounds.size.height = 316
            XCTAssertEqual(root.retainedPresentedHeight, 316)
            let oldRevision = root.presentationRevision
            root.endPresentation()
            root.beginPresentation(height: 288)
            root.bounds.size.height = 316
            XCTAssertNil(root.retainedPresentedHeight)
            XCTAssertFalse(root.acceptsPresentation(oldRevision))
            root.setPanelHeight(304)
            root.bounds.size.height = 288
            XCTAssertEqual(root.retainedPresentedHeight, 288)
            root.bounds.size.height = 509
            XCTAssertNil(root.retainedPresentedHeight)
        }
    }
#endif
