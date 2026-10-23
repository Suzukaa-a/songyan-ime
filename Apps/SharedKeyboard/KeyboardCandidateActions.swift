import CandidateKit
import Foundation
import KeyboardCore

/// Process-wide renderer registration: the default renderer ("default") is the production render path.
/// Downstream developers can register their own at app/extension launch to replace rendering without touching EngineBackend.
public enum CandidateRenders {
    public static func installDefault() {
        CandidateRendererRegistry.register(
            CandidateRendererDescriptor(
                id: DefaultCandidateAreaRenderer.rendererID,
                makeCollapsed: { context in
                    DefaultCandidateAreaRenderer().collapsedView(context: context)
                },
                makeExpanded: { context in
                    DefaultCandidateAreaRenderer().expandedView(context: context)
                }))
    }
}

/// Maps candidate-area actions to the real session. Renderers only emit `CandidateAreaAction`;
/// this bridge is the single forwarding point, so select always carries the real `Candidate.index`.
@MainActor
extension KeyboardController: CandidateActionRecipient {
    public func candidateAreaSelect(index: Int) {
        selectCandidate(index)
    }

    /// Candidates accumulated across pages: page number + in-page index -> absolute engine index for commit.
    public func candidateAreaSelect(page: Int, index: Int) {
        selectCandidate(pageIndex: page, pageLocalIndex: index)
    }

    public func candidateAreaPageForward() {
        nextPage()
    }

    public func candidateAreaPageBackward() {
        previousPage()
    }

    public func candidateAreaLoadMore() {
        loadMoreCandidates()
    }
}

extension CandidateAreaActionSink {
    /// Production bridge: select/paging go to the real session; expand/collapse bypass it (render-time UI state).
    @MainActor
    static func live(
        controller: KeyboardController,
        onExpand: @escaping () -> Void,
        onCollapse: @escaping () -> Void
    ) -> CandidateAreaActionSink {
        CandidateAreaActionSink { action in
            MainActor.assumeIsolated {
                switch action {
                case .select(let index): controller.candidateAreaSelect(index: index)
                case .selectOnPage(let page, let index):
                    controller.candidateAreaSelect(page: page, index: index)
                case .pageForward: controller.candidateAreaPageForward()
                case .pageBackward: controller.candidateAreaPageBackward()
                case .loadMore: controller.candidateAreaLoadMore()
                case .expand: onExpand()
                case .collapse: onCollapse()
                case .highlightNext, .highlightPrevious: break
                }
            }
        }
    }
}
