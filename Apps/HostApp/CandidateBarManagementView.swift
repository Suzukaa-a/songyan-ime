import AppearanceKit
import CandidateKit
import SkinKit
import SwiftUI

// MARK: - Candidate bar layout editor (part of an appearance project, not a standalone config)

/// Candidate bar layout editor, embedded in the appearance project editor.
///
/// Production UI has **no** standalone candidate-bar config entry and **no** standalone Apply: the candidate bar only stores layout
/// behavior parameters (height, expanded arrangement, control positions) and always belongs to the current appearance project,
/// saved/applied together with it. Candidate text color and font size come from the same project's skin (edited in the skin section),
/// so no color settings are duplicated here.
struct CandidateAreaEditorSections: View {
    @Binding var document: AppearanceDocument

    private var bar: CandidateBarDefinition { document.candidateBar }

    var body: some View {
        Section {
            Picker("显示规则", selection: barBinding(\.compositionRow.visible)) {
                Text("仅输入时显示（推荐）").tag(CandidateBarDefinition.CompositionRow.Visibility.composingOnly)
                Text("始终显示").tag(CandidateBarDefinition.CompositionRow.Visibility.composingWithIdleRaw)
                Text("不显示").tag(CandidateBarDefinition.CompositionRow.Visibility.hidden)
            }
        } header: {
            Text("拼写行")
        }

        Section("单行") {
            slider("行高", value: barBinding(\.collapsed.height), range: 36...56)
            slider("候选项内边距", value: barBinding(\.collapsed.cellPaddingX), range: 4...24)
            slider("候选项间距", value: barBinding(\.collapsed.cellSpacing), range: 0...16)
            Toggle("候选较少时平分宽度", isOn: fillsWidth)
        }

        Section("展开") {
            Picker("模式", selection: barBinding(\.expanded.mode)) {
                Text("自适应（推荐）").tag(CandidateBarDefinition.Expanded.Mode.adaptive)
                Text("单列").tag(CandidateBarDefinition.Expanded.Mode.list)
                Text("网格").tag(CandidateBarDefinition.Expanded.Mode.grid)
            }
            if bar.expanded.mode == .grid {
                Stepper("列数：\(bar.expanded.columns)", value: barBinding(\.expanded.columns), in: 1...4)
            }
            slider("行间距", value: barBinding(\.expanded.rowSpacing), range: 0...16)
            slider("列间距", value: barBinding(\.expanded.columnSpacing), range: 0...16)
            slider(
                "长词单独成行（字数）",
                value: Binding(
                    get: { Double(bar.expanded.fullRowTextLength) },
                    set: { value in setBar { $0.expanded.fullRowTextLength = Int(value.rounded()) } }),
                range: 1...40)
        }

        Section("翻页与展开") {
            Picker("翻页按钮位置", selection: barBinding(\.controls.pagePosition)) {
                Text("两端（默认）").tag(CandidateBarDefinition.Controls.PagePosition.both)
                Text("右侧").tag(CandidateBarDefinition.Controls.PagePosition.trailing)
                Text("左侧").tag(CandidateBarDefinition.Controls.PagePosition.leading)
            }
            Toggle("显示展开与收起按钮", isOn: barBinding(\.controls.showsExpand))
        }
    }

    // MARK: Bindings (always written through the appearance document; the three identities stay in lockstep)

    private func setBar(_ mutate: (inout CandidateBarDefinition) -> Void) {
        var bar = document.candidateBar
        mutate(&bar)
        document = document.replacing(candidateBar: bar)
    }

    private func barBinding<T>(_ keyPath: WritableKeyPath<CandidateBarDefinition, T>) -> Binding<T> {
        Binding(
            get: { document.candidateBar[keyPath: keyPath] },
            set: { value in setBar { $0[keyPath: keyPath] = value } })
    }

    private var fillsWidth: Binding<Bool> {
        Binding(
            get: { document.candidateBar.collapsed.fillsAvailableWidth ?? true },
            set: { value in setBar { $0.collapsed.fillsAvailableWidth = value } })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)：\(value.wrappedValue, specifier: "%.0f")")
            Slider(value: value, in: range, step: 1)
                .accessibilityLabel(title)
                .accessibilityValue(String(Int(value.wrappedValue.rounded())))
        }
    }
}
