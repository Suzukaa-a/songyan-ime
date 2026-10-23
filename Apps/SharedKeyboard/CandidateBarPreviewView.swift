import CandidateKit
import KeyboardCore
import LayoutKit
import SkinKit
import SwiftUI

/// Candidate-area preview without an engine: same default renderer and same skin resolution
/// (KeyboardAppearance -> CandidateSkinToken); the sample candidates are clearly labeled and produce no input or learning.
/// Used by the appearance editor/details; creates no session/controller.
///
/// Skin and candidate-area layout come from the **same appearance item**: the preview must pass the
/// same skin, or "candidate color/size derived from the skin" would be wrong in the preview.
public struct CandidateBarPreviewView: View {
    public let bar: CandidateBarDefinition
    public var skin: SkinDefinition
    public var expanded: Bool
    public var dark: Bool
    @State private var highlightIndex = 0
    private var sampleState: CandidatePresentationState {
        CandidatePresentationState(
            preedit: "ni hao",
            rawInput: "nihao",
            candidates: [
                Candidate(index: 0, text: "你好"),
                Candidate(index: 1, text: "您好", comment: "nín hǎo"),
                Candidate(index: 2, text: "你 好"),
                Candidate(index: 3, text: "你好世界今天天气不错", comment: "cháng jù · 长注释示例"),
                Candidate(index: 4, text: "尼奥"),
            ],
            highlightedIndex: highlightIndex,
            pageIndex: 0,
            canPageBackward: false,
            canPageForward: true,
            isComposing: true)
    }
    private var previewActions: CandidateAreaActionSink {
        CandidateAreaActionSink { [self] action in
            switch action {
            case .select(let index): highlightIndex = index
            case .selectOnPage(_, let index): highlightIndex = index
            case .highlightNext: highlightIndex = min(highlightIndex + 1, 4)
            case .highlightPrevious: highlightIndex = max(highlightIndex - 1, 0)
            case .expand, .collapse, .pageForward, .pageBackward, .loadMore: break
            }
        }
    }
    public init(
        bar: CandidateBarDefinition, skin: SkinDefinition = .systemDefault,
        expanded: Bool = false, dark: Bool = false
    ) {
        self.bar = bar
        self.skin = skin
        self.expanded = expanded
        self.dark = dark
    }
    public var body: some View {
        let appearance = KeyboardAppearance(skin: skin, dark: dark)
        let typography = CandidateTypography(
            candidateSize: skin.typography.candidateSize,
            secondarySize: skin.typography.secondarySize)
        let context = CandidateAreaContext(
            state: sampleState, bar: bar,
            actions: previewActions, typography: typography)
        VStack(alignment: .leading, spacing: 4) {
            Text("示例候选（ni hao）").font(.caption2).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text("ni hao")
                    .font(.system(size: skin.typography.secondarySize))
                    .foregroundStyle(.secondary)
            }.frame(height: 20)
            if expanded {
                CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                    .makeExpanded(context)
                    .frame(height: 180)
            } else {
                CandidateRendererRegistry.renderer(id: DefaultCandidateAreaRenderer.rendererID)
                    .makeCollapsed(context)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
        // Same skin derivation as the production panel: candidate color/size come from the same SkinDefinition.
        .environment(
            \.candidateSkinToken,
            CandidateSkinToken(
                candidateColor: Color(uiColor: appearance.text(on: "panel")),
                secondaryColor: Color(uiColor: appearance.text(on: "panel", secondary: true)),
                accentColor: appearance.accentForeground, panelColor: appearance.color("panel"),
                fontFamily: skin.typography.family, fontWeight: skin.typography.weight)
        )
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
