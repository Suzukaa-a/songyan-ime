import KeyboardCore
import SwiftUI

/// Built-in scheme/resource check (Developer Options): confirms the built-in package (for development self-tests / dictionary templates)
/// is bundled with the app and locatable. In Release this package is not a product input scheme.
struct ResourceCheckView: View {
    private struct Row: Identifiable {
        let id: String
        let name: String
        let ok: Bool
        let note: String
    }

    @State private var rows: [Row] = []

    var body: some View {
        List {
            Section("内置输入方案与关键文件") {
                if rows.isEmpty {
                    Text("正在检查…")
                } else {
                    ForEach(rows) { row in
                        HStack {
                            Image(systemName: row.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(row.ok ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(row.name).font(.body.monospaced())
                                Text(row.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("内置资源检查")
        .task { rows = check() }
    }

    private func check() -> [Row] {
        var result: [Row] = []
        let base = BuiltinResources.packageDirectory()
        result.append(
            Row(
                id: "dir", name: "BuiltinPackages/Basic",
                ok: base != nil,
                note: base?.path ?? "未在 App 中找到"))
        guard let dir = base else { return result }
        let fm = FileManager.default
        for file in BuiltinResources.requiredFiles {
            let url = dir.appendingPathComponent(file)
            let ok = fm.fileExists(atPath: url.path)
            result.append(
                Row(
                    id: file, name: file, ok: ok,
                    note: ok ? "存在" : "缺失"))
        }
        return result
    }
}
