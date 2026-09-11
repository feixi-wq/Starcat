//
//  LocalAIModelsSection.swift
//  Starcat
//
//  AI 设置页的「本地 AI 模型」管理区。
//
//  设计：
//  - 独立 Section，不依赖内置 profile 的验证状态——用户必须能在这里下载模型，
//    之后 profile 才会被 `LocalAIModelManager.syncBuiltInProfile()` 标记为已验证。
//  - UI 只暴露「推荐 / Lite」与下载状态，不暴露量化格式；大小为 catalog 预估值。
//  - 硬件不满足（Intel）时整区隐藏（由宿主 `AISettingsView` 控制），这里不再重复判断。
//  - 遵循设置页规范：独立操作按钮右对齐、`.buttonStyle(.plain)` 必须配
//    `.focusEffectDisabled()`、危险操作二次确认、颜色只用 .primary/.secondary。
//

import AppKit
import SwiftUI

struct LocalAIModelsSection: View {

    @State private var manager = LocalAIModelManager.shared
    @State private var verifyMessage: String?
    @State private var pendingClearAllConfirm = false

    var body: some View {
        Section {
            ForEach(LocalAIModelCatalog.entries) { entry in
                modelRow(entry)
                if case .downloading(let progress) = manager.installState(for: entry.id) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .padding(.vertical, 2)
                }
            }

            HStack {
                Text(storageUsageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 12)

                Button {
                    verifyMessage = manager.verifyIntegrity()
                    if verifyMessage == nil {
                        verifyMessage = String.l10n("settings.localai.verify.ok")
                    }
                } label: {
                    Label("settings.localai.verify.button", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

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
                .disabled(manager.installedModels.isEmpty && !hasPartialDownloads)
            }

            if let verifyMessage {
                Text(verifyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private var hasPartialDownloads: Bool {
        LocalAIModelCatalog.entries.contains { entry in
            manager.installState(for: entry.id) != .installed && manager.installState(for: entry.id) != .idle
        }
    }

    private var storageUsageText: String {
        let usage = ByteCountFormatter.string(fromByteCount: manager.totalDiskUsage, countStyle: .file)
        return String(format: String.l10n("settings.localai.storage.usageFormat"), usage)
    }

    // MARK: - 单模型行

    @ViewBuilder
    private func modelRow(_ entry: LocalAIModelCatalogEntry) -> some View {
        let state = manager.installState(for: entry.id)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon(for: entry.type))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.displayName)
                        .foregroundStyle(.primary)
                    Text(entry.recommended
                        ? "settings.localai.model.badge.recommended"
                        : "settings.localai.model.badge.lite")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(sizeCaption(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            statusView(for: entry, state: state)
        }
        .padding(.vertical, 2)
        .help(String(format: String.l10n("settings.localai.model.memoryHelpFormat"),
                     ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file),
                     ByteCountFormatter.string(fromByteCount: Int64(entry.memoryRecommendation), countStyle: .file)))
    }

    @ViewBuilder
    private func statusView(
        for entry: LocalAIModelCatalogEntry,
        state: LocalAIInstallState
    ) -> some View {
        switch state {
        case .idle:
            Button {
                manager.install(entry: entry)
            } label: {
                Label("settings.localai.model.action.download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

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
            HStack(spacing: 6) {
                Label("settings.localai.model.status.installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        Button {
            manager.delete(entryID: entry.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("settings.localai.model.action.delete")
        .accessibilityLabel(Text("settings.localai.model.action.delete"))
    }

    private func icon(for type: LocalAIModelType) -> String {
        switch type {
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .reranker: return "arrow.up.arrow.down"
        case .llm: return "bubble.left.and.text.bubble.right"
        }
    }

    private func sizeCaption(for entry: LocalAIModelCatalogEntry) -> String {
        var parts: [String] = [String(
            format: String.l10n("settings.localai.model.sizeFormat"),
            ByteCountFormatter.string(fromByteCount: entry.estimatedDownloadSize, countStyle: .file))]
        if let dimension = entry.embeddingDimension {
            parts.append(String(
                format: String.l10n("settings.localai.model.dimensionFormat"), dimension))
        }
        parts.append(typeLabel(for: entry.type))
        return parts.joined(separator: " · ")
    }

    private func typeLabel(for type: LocalAIModelType) -> String {
        switch type {
        case .embedding: return String.l10n("settings.localai.model.type.embedding")
        case .reranker: return String.l10n("settings.localai.model.type.reranker")
        case .llm: return String.l10n("settings.localai.model.type.llm")
        }
    }

    private func revealModelsDirectory() {
        guard let url = manager.modelsRootURL else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
