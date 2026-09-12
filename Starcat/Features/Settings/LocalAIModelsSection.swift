//
//  LocalAIModelsSection.swift
//  Starcat
//
//  AI 设置页的「本地 AI 模型」管理区。
//
//  结构：
//  - 顶部「下载源」Picker（Hugging Face / 魔塔 ModelScope），只影响新下载；
//  - 每个模型类别一行：类别图标 + 模型下拉（该类已收录模型）+ 选中模型的
//    大小 / 状态 / 进度（4pt 细条 + 速度 / 百分比 / 字节）与操作按钮；
//  - 底部：存储占用、检查模型、在 Finder 中显示、清除全部（二次确认）。
//
//  约束：
//  - 独立 Section，不依赖内置 profile 的验证状态——用户必须能在这里下载模型，
//    之后 profile 才会被 `LocalAIModelManager.syncBuiltInProfile()` 标记为已验证。
//  - UI 只暴露「推荐 / Lite」与下载状态，不暴露量化格式。
//  - 遵循设置页规范：独立操作按钮右对齐、`.buttonStyle(.plain)` 必须配
//    `.focusEffectDisabled()`、危险操作二次确认、颜色只用 .primary/.secondary。
//

import AppKit
import SwiftUI

struct LocalAIModelsSection: View {

    let settings: AppSettings

    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var manager = LocalAIModelManager.shared
    @State private var pendingClearAllConfirm = false
    /// 每个类别当前在下拉里选中的 entry id；nil = 用默认（已安装优先，其次推荐）。
    @State private var selectedIDs: [LocalAIModelType: String] = [:]

    /// 下拉顺序固定，避免设置页刷新时选项跳动。
    private let displayedTypes: [LocalAIModelType] = [.embedding, .reranker, .llm]

    /// 本区块行内 icon 的统一口径（设置页 15pt / 28×28）：下载、绿色对勾、删除共用，
    /// 保证同一行里图标大小完全一致（dong4j 2026-09-12）。
    private static let rowIconFont = Font.system(size: 15, weight: .medium)
    private static let rowIconFrameSize: CGFloat = 28

    var body: some View {
        Section {
            sourcePickerRow

            ForEach(displayedTypes) { type in
                typeGroup(type)
            }

            HStack {
                Text(storageUsageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Button {
                    revealModelsDirectory()
                } label: {
                    Label("settings.localai.storage.reveal", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(manager.modelsRootURL == nil)

                Button(role: .destructive) {
                    pendingClearAllConfirm = true
                } label: {
                    Label("settings.localai.storage.clearAll", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(manager.installedModels.isEmpty)
            }
        } header: {
            SettingsSectionHeader(
                "settings.localai.section.title",
                systemImage: "cpu",
                style: .prominent
            )
        } footer: {
            Text("settings.localai.section.footer")
        }
        .alert(
            "settings.localai.storage.clearAll.confirmTitle",
            isPresented: $pendingClearAllConfirm
        ) {
            Button("settings.localai.storage.clearAll.confirm", role: .destructive) {
                manager.deleteAll()
            }
            Button("settings.common.cancel", role: .cancel) {}
        } message: {
            Text("settings.localai.storage.clearAll.confirmMessage")
        }
    }

    // MARK: - 下载源

    private var sourcePickerRow: some View {
        HStack {
            Text("settings.localai.source.label")
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Picker("settings.localai.source.label", selection: sourceBinding) {
                Text("settings.localai.source.huggingface").tag(LocalAIModelSource.Kind.huggingFace)
                Text("settings.localai.source.modelscope").tag(LocalAIModelSource.Kind.modelScope)
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }

    private var sourceBinding: Binding<LocalAIModelSource.Kind> {
        Binding(
            get: { settings.localAIDownloadSource },
            set: { settings.localAIDownloadSource = $0 })
    }

    // MARK: - 类别分组行

    @ViewBuilder
    private func typeGroup(_ type: LocalAIModelType) -> some View {
        let entry = selectedEntry(for: type)
        let state = manager.installState(for: entry.id)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: type.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                Picker(selection: selectionBinding(for: type)) {
                    ForEach(LocalAIModelCatalog.entries(of: type)) { candidate in
                        Text(pickerTitle(candidate)).tag(Optional(candidate.id))
                    }
                } label: {
                    Text(typeLabel(type))
                }
                .pickerStyle(.menu)

                Spacer(minLength: 12)

                statusView(for: entry, state: state)
            }

            HStack(spacing: 6) {
                Text(entry.recommended
                    ? "settings.localai.model.badge.recommended"
                    : "settings.localai.model.badge.lite")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())

                Text(sizeCaption(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 30)

            if case .downloading(let progress, let completedBytes, let totalBytes, let speed) = state {
                thinProgressBar(progress)
                    .padding(.leading, 30)
                Text(progressCaption(
                    progress: progress,
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    speedBytesPerSecond: speed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 2)
        .help(String(format: String.l10n("settings.localai.model.memoryHelpFormat"),
                     ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file),
                     ByteCountFormatter.string(fromByteCount: Int64(entry.memoryRecommendation), countStyle: .file)))
    }

    private func pickerTitle(_ entry: LocalAIModelCatalogEntry) -> String {
        // 安装状态已由行尾的「已安装」徽标表达，下拉里不再重复（dong4j 2026-09-12 反馈）。
        entry.displayName
    }

    /// 当前类别选中的模型：显式选择 > 已安装 > 推荐 > 首个。
    private func selectedEntry(for type: LocalAIModelType) -> LocalAIModelCatalogEntry {
        let entries = LocalAIModelCatalog.entries(of: type)
        guard !entries.isEmpty else {
            // catalog 保证每类非空；防御性兜底避免强制解包。
            return LocalAIModelCatalog.entries[0]
        }
        if let id = selectedIDs[type], let entry = entries.first(where: { $0.id == id }) {
            return entry
        }
        return entries.first { manager.installedModel(id: $0.id) != nil }
            ?? entries.first { $0.recommended }
            ?? entries[0]
    }

    private func selectionBinding(for type: LocalAIModelType) -> Binding<String> {
        Binding(
            get: { selectedEntry(for: type).id },
            set: { selectedIDs[type] = $0 })
    }

    private func typeLabel(_ type: LocalAIModelType) -> String {
        switch type {
        case .embedding: return String.l10n("settings.localai.model.type.embedding")
        case .reranker: return String.l10n("settings.localai.model.type.reranker")
        case .llm: return String.l10n("settings.localai.model.type.llm")
        }
    }

    // MARK: - 状态与操作

    @ViewBuilder
    private func statusView(
        for entry: LocalAIModelCatalogEntry,
        state: LocalAIInstallState
    ) -> some View {
        switch state {
        case .idle:
            if entry.isAvailable(on: settings.localAIDownloadSource) {
                Button {
                    manager.install(entry: entry)
                } label: {
                    // icon-only（dong4j 2026-09-12）：文案由行内徽标与下方信息承担。
                    Image(systemName: "arrow.down.circle")
                        .font(Self.rowIconFont)
                        .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("settings.localai.model.action.download")
                .accessibilityLabel(Text("settings.localai.model.action.download"))
            } else {
                // catalog 未收录该模型在当前下载源的镜像（白名单制，禁止静默换源）。
                Image(systemName: "arrow.down.circle")
                    .font(Self.rowIconFont)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                Text("settings.localai.source.unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 120, alignment: .trailing)
                    .lineLimit(2)
            }

        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("settings.localai.model.status.preparing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                pauseButton(entry)
            }

        case .downloading:
            pauseButton(entry)

        case .loading:
            // MLX 不暴露权重加载的字节进度：给不确定进度条（薄荷色，与下载蓝色区分）+ 文案。
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Text("settings.localai.model.status.loading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                indeterminateBar
                    .frame(width: 140)
            }

        case .loadFailed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    manager.retryLoad(entry: entry)
                } label: {
                    Label("settings.localai.model.action.retryLoad", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 240, alignment: .trailing)
            }

        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    manager.install(entry: entry)
                } label: {
                    Label("settings.localai.model.action.retry", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 240, alignment: .trailing)
            }

        case .installed:
            // 只保留绿色对勾 + 删除两个同规格图标（15pt / 28pt 命中，dong4j 2026-09-12）；
            // 安装状态语义由对勾颜色与位置承担，无障碍标签保留「已安装」。
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(Self.rowIconFont)
                    .foregroundStyle(.green)
                    .frame(width: Self.rowIconFrameSize, height: Self.rowIconFrameSize)
                    .accessibilityLabel(Text("settings.localai.model.status.installed"))
                deleteButton(entry)
            }
        }
    }

    private func pauseButton(_ entry: LocalAIModelCatalogEntry) -> some View {
        Button {
            manager.pause(entryID: entry.id)
        } label: {
            Label("settings.localai.model.action.pause", systemImage: "pause.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func deleteButton(_ entry: LocalAIModelCatalogEntry) -> some View {
        DestructiveIconButton(
            help: Text("settings.localai.model.action.delete"),
            font: Self.rowIconFont,
            frameSize: Self.rowIconFrameSize
        ) {
            manager.delete(entryID: entry.id)
        }
    }

    // MARK: - 进度展示

    /// 加载中的不确定进度条：薄荷色滑块往复运动；开启「减弱动态效果」时静态半格。
    @ViewBuilder
    private var indeterminateBar: some View {
        if reduceMotion {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.mint).frame(width: geo.size.width * 0.5)
                }
            }
            .frame(height: 4)
        } else {
            IndeterminateCapsuleBar()
        }
    }

    /// 4pt 细进度条：macOS 默认 `.linear` 样式过粗；自定义 Capsule 保证粗细一致。
    private func thinProgressBar(_ progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.25), value: progress)
        .accessibilityLabel(Text("settings.localai.section.title"))
        .accessibilityValue(Text("\(Int(progress * 100))%"))
    }

    /// 「128.4 MB / 664 MB · 19% · 45.2 MB/s」；首个采样窗口速度未出时省略速度段。
    private func progressCaption(
        progress: Double,
        completedBytes: Int64,
        totalBytes: Int64,
        speedBytesPerSecond: Double?
    ) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let downloaded = formatter.string(fromByteCount: completedBytes)
        let total = formatter.string(fromByteCount: totalBytes)
        let percent = String(format: "%d%%", Int((max(0, min(1, progress)) * 100).rounded()))
        if let speed = speedBytesPerSecond, speed > 0 {
            let speedText = formatter.string(fromByteCount: Int64(speed))
            return String(
                format: String.l10n("settings.localai.model.progressFormat"),
                downloaded, total, percent, speedText)
        }
        return String(
            format: String.l10n("settings.localai.model.progressNoSpeedFormat"),
            downloaded, total, percent)
    }

    private func sizeCaption(for entry: LocalAIModelCatalogEntry) -> String {
        // 直接显示体积，不加「下载约」前缀（dong4j 2026-09-12 反馈）。
        var parts: [String] = [
            ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file)
        ]
        if let dimension = entry.embeddingDimension {
            parts.append(String(
                format: String.l10n("settings.localai.model.dimensionFormat"), dimension))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 其它动作

    private var storageUsageText: String {
        let usage = ByteCountFormatter.string(fromByteCount: manager.totalDiskUsage, countStyle: .file)
        return String(format: String.l10n("settings.localai.storage.usageFormat"), usage)
    }

    private func revealModelsDirectory() {
        guard let url = manager.modelsRootURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}


/// 薄荷色往复滑块：加载阶段 MLX 不暴露字节进度，用不确定动画表达「正在进行」。
private struct IndeterminateCapsuleBar: View {
    @State private var trailing: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(.mint)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: trailing ? geo.size.width * 0.65 : 0)
            }
        }
        .frame(height: 4)
        .accessibilityLabel(Text("settings.localai.model.status.loading"))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                trailing = true
            }
        }
    }
}
