//
//  LocalAIStatusSection.swift
//  Starcat
//
//  Toolbar 状态面板里的本地模型驻留与快捷操作。只在面板可见时采样，每秒刷新值快照；
//  不把高频内存变化传到整个主窗口，也不因打开面板加载模型。
//

import SwiftUI

/// 模型状态与释放入口保持在同一分区，让用户区分「卸载内存」与「删除下载文件」。
struct LocalAIStatusSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var manager = LocalAIModelManager.shared
    @State private var snapshot = LocalAIRuntimeSnapshot()
    @State private var pending: Set<String> = []
    @State private var error: String?

    var body: some View {
        let models = settings.localAIStatusModels(installedModels: manager.installedModels)
        if LocalAIHardwareSupport.isLocalAIAvailable, !models.isEmpty {
            Divider()
            statusContent(models)
            Divider()
        }
    }

    /// 服务商切走时连同分隔线与采样 task 一起移除，不留空白区块。
    private func statusContent(_ models: [LocalAIModelCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("toolbar.localai.title", systemImage: "cpu")
                    .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                Spacer(minLength: 4)
                Button("toolbar.localai.unloadAll") {
                    run("all") { await LocalMLXRuntime.shared.unloadAll() }
                }
                .disabled(pending.contains("all") || !hasResidentModels)
                .controlSize(.small)
            }
            HStack(spacing: 12) {
                metric("toolbar.localai.active", bytes: snapshot.activeBytes)
                metric("toolbar.localai.cache", bytes: snapshot.cacheBytes)
                metric("toolbar.localai.budget", bytes: snapshot.budgetBytes)
            }
            ForEach(models) { model in
                modelRow(model)
            }
            HStack {
                Text(String(format: String.l10n("toolbar.localai.queued"), snapshot.queuedCount))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("toolbar.localai.clearCache") {
                    run("cache") { await LocalMLXRuntime.shared.clearMemoryCache() }
                }
                .controlSize(.small)
                .disabled(snapshot.cacheBytes == 0 || pending.contains("cache"))
            }
            Text("toolbar.localai.memoryHelp")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = error ?? snapshot.notice {
                Text(verbatim: message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(interfaceScale.font(.caption))
        .task {
            while !Task.isCancelled {
                snapshot = await LocalMLXRuntime.shared.snapshot()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private var hasResidentModels: Bool {
        snapshot.models.values.contains { [.loading, .ready, .running].contains($0.phase) }
    }

    private func metric(_ key: LocalizedStringKey, bytes: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).foregroundStyle(.secondary)
            Text(verbatim: format(bytes)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelRow(_ model: LocalAIModelCatalogEntry) -> some View {
        let installed = manager.installedModel(id: model.id)
        let resident = snapshot.models[model.type].flatMap {
            $0.directory.lastPathComponent == installed?.idWithRevision ? $0 : nil
        }
        let phase = resident?.phase ?? .notLoaded
        let canUnload = [.ready, .running, .loading].contains(phase)
        let actionKey = canUnload ? "toolbar.localai.unload" : "toolbar.localai.load"
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.modelTypeLabelKey(model.type))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Text(verbatim: model.displayName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.displayName)
                }
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(installed == nil ? "toolbar.localai.notDownloaded" : phase.localizationKey))
                    if let resident, resident.loadedBytes > 0 {
                        Text(
                            String(
                                format: String.l10n("toolbar.localai.loadedMemory"), format(resident.loadedBytes))
                        )
                        .monospacedDigit()
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let message = resident?.error, phase == .failed {
                    Text(verbatim: message).foregroundStyle(.secondary).lineLimit(2).help(message)
                }
            }
            Spacer(minLength: 0)
            Button(LocalizedStringKey(actionKey)) {
                run(model.id) {
                    if canUnload {
                        await LocalMLXRuntime.shared.unload(types: [model.type])
                    } else if let directory = manager.installedDirectoryURL(entryID: model.id)
                    {
                        try await LocalMLXRuntime.shared.preload(entry: model, directory: directory)
                    }
                }
            }
            .controlSize(.small)
            // 手动加载尚未返回时仍允许点卸载，由运行时取消加载并等待 GPU 收尾。
            .disabled(installed == nil || (pending.contains(model.id) && !canUnload) || pending.contains("all") || phase == .unloading)
            .accessibilityLabel("\(String.l10n(actionKey)) \(model.displayName)")
        }
    }

    /// 使用完整字面量 key；LocalizedStringKey 的直接插值会生成 %@ 格式键，无法命中类别翻译。
    static func modelTypeLabelKey(_ type: LocalAIModelType) -> LocalizedStringKey {
        switch type {
        case .embedding: return "settings.localai.model.type.embedding"
        case .reranker: return "settings.localai.model.type.reranker"
        case .llm: return "settings.localai.model.type.llm"
        }
    }

    /// 操作独立于面板的采样 task；关闭 popover 不应让手动卸载中途被取消。
    private func run(_ id: String, operation: @escaping @MainActor () async throws -> Void) {
        pending.insert(id)
        error = nil
        Task {
            defer { pending.remove(id) }
            do { try await operation() } catch is CancellationError {} catch {
                self.error = error.localizedDescription
            }
            snapshot = await LocalMLXRuntime.shared.snapshot()
        }
    }

    private func format(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory).locale(locale))
    }
}
