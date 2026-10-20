//
//  RepoLicenseFilterChip.swift
//  Starcat
//
//  许可证筛选的纯展示按钮；与左侧标签共享胶囊外观，不持有额外的选择状态。
//

import SwiftUI

/// 许可证没有独立的业务颜色，统一使用强调色；字号、图标和留白与左侧标签一致。
struct RepoLicenseFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelected && differentiateWithoutColor ? "checkmark" : "tag.fill")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 11)
                    // 与左侧标签一致：未选中图标保留颜色，选中后与实色底形成对比。
                    .foregroundStyle(isSelected ? TagChipSurface.selectedForeground(for: .accentColor) : .accentColor)
                Text(verbatim: title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .modifier(TagChipSurface(color: .accentColor, isSelected: isSelected))
            .contentShape(RoundedRectangle(cornerRadius: TagChipSurface.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .pressableHover(scale: 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
    }
}
