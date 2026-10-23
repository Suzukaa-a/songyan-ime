import PackageManager
import SwiftUI

/// Fuzzy pinyin settings: one page, the eight bounded confusion pairs, one save.
/// The draft is applied to the input method in use by `FuzzyPinyinCenter.save`; this view
/// shows only real states — loading, unsupported, user-managed, saved, saving, failure.
struct FuzzyPinyinSettingsView: View {
    @ObservedObject private var center = FuzzyPinyinCenter.shared

    var body: some View {
        List {
            Section {
                if center.working {
                    ProgressView("正在保存…")
                } else if let failure = center.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                } else if let notice = center.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                statusRow
            } header: {
                Text("当前输入方式")
            }
            pairSection
        }
        .navigationTitle("模糊音")
        .navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
        .refreshable { await center.refresh() }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch center.state {
        case .loading:
            Text("正在读取…").font(.footnote).foregroundStyle(.secondary)
        case .noSource:
            Text("未选择输入方案。").font(.footnote).foregroundStyle(.secondary)
        case .unavailable(let reason):
            Text(reason).font(.footnote).foregroundStyle(.secondary)
        case .userManaged:
            Text("模糊音由输入方案或你的自定义设置控制，无法在这里修改。").font(.footnote).foregroundStyle(.secondary)
        case .managed(let ids):
            Text(ids.isEmpty ? "已关闭。" : "已开启：\(labels(ids))。")
                .font(.footnote).foregroundStyle(.secondary)
        case .off:
            Text("已关闭。").font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// The pairs only exist where the input method can prove them; any other state is
    /// shown truthfully instead of offering switches that would never apply.
    @ViewBuilder
    private var pairSection: some View {
        switch center.state {
        case .off, .managed:
            Section {
                ForEach(FuzzyPinyin.allPairs) { pair in
                    Toggle(pair.label, isOn: binding(pair.id))
                        .disabled(center.working)
                        .accessibilityIdentifier("fuzzyPinyin.pair.\(pair.id)")
                }
                Button {
                    center.save()
                } label: {
                    Text("保存")
                        .frame(maxWidth: .infinity)
                }
                .disabled(center.working || !draftChanged)
                .accessibilityIdentifier("fuzzyPinyin.save")
            } header: {
                Text("可混用的读音")
            }
        case .loading, .noSource, .unavailable, .userManaged:
            EmptyView()
        }
    }

    private var draftChanged: Bool {
        switch center.state {
        case .managed(let ids): return ids != center.draft
        case .off: return !center.draft.isEmpty
        default: return false
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { center.draft.contains(id) },
            set: { enabled in
                if enabled { center.draft.insert(id) } else { center.draft.remove(id) }
            })
    }

    private func labels(_ ids: Set<String>) -> String {
        FuzzyPinyin.allPairs.filter { ids.contains($0.id) }.map(\.label).joined(separator: "、")
    }
}
