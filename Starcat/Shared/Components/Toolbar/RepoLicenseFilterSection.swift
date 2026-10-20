//
//  RepoLicenseFilterSection.swift
//  Starcat
//
//  现有全局筛选浮层内的许可证多选区；不新增顶栏控件，长选项列表在区内滚动。
//

import SwiftUI

/// 只负责编辑共享值类型，不在视图里请求网络或读取仓库分页。
struct RepoLicenseFilterSection: View {
    let options: [String]
    @Binding var selection: RepoLicenseFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("list.filter.license.title", systemImage: "doc.text")
                .foregroundStyle(.secondary)
            Button("list.filter.license.all") { selection = .all }
                .disabled(!selection.isActive)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(RepoLicenseFilter.options(options.map { Optional($0) }, including: selection), id: \.self) { key in
                        Toggle(isOn: binding(for: key)) {
                            if key == RepoLicenseFilter.unknownKey {
                                Text("list.filter.license.unknown")
                            } else {
                                Text(verbatim: RepoLicenseFilter.displayName(for: key))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: CGFloat(min(Set(options).union(selection.selections).union([RepoLicenseFilter.unknownKey]).count, 7)) * 24)
        }
    }

    /// 每次写入都从当前选择生成新值，快速连续勾选不会用旧捕获值覆盖前一项。
    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selection.selections.contains(key) },
            set: { selected in
                var keys = selection.selections
                if selected { keys.insert(key) } else { keys.remove(key) }
                selection = RepoLicenseFilter(Array(keys))
            }
        )
    }
}
