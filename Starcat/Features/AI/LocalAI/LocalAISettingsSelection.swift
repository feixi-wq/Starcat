//
//  LocalAISettingsSelection.swift
//  Starcat
//
//  设置、状态面板与普通 AI 任务共用的本地模型选择口径。持久化选择是本地任务真源，
//  安装清单只补充默认值；远程任务及显式会话模型不经过此覆盖路径。
//

import Foundation

extension AppSettings {
    /// 每类只解析一个选中项；未下载的明确选择也必须保留，不能被其它已安装模型顶替。
    func selectedLocalAIModel(
        for type: LocalAIModelType, installedModels: [LocalAIInstalledModel]
    ) -> LocalAIModelCatalogEntry {
        selectedLocalAIModel(for: type, installedIDs: Set(installedModels.map(\.id)))
    }

    /// 请求解析只读取已同步的模型描述，不在主线程逐请求扫描权重目录。
    func selectedLocalAIModel(for type: LocalAIModelType) -> LocalAIModelCatalogEntry {
        let names = Set(aiProviderProfiles.filter { $0.provider == .localAI }.flatMap { $0.models.map(\.name) })
        let installedIDs = Set(LocalAIModelCatalog.entries.filter { names.contains($0.displayName) }.map(\.id))
        return selectedLocalAIModel(for: type, installedIDs: installedIDs)
    }

    private func selectedLocalAIModel(
        for type: LocalAIModelType, installedIDs: Set<String>
    ) -> LocalAIModelCatalogEntry {
        let entries = LocalAIModelCatalog.entries(of: type)
        if let id = localAIModelSelections[type.rawValue],
            let selected = entries.first(where: { $0.id == id })
        {
            return selected
        }
        // 延续设置页原有默认顺序；catalog 保证三类均非空，两处 UI 不再各自猜默认值。
        return entries.first { installedIDs.contains($0.id) }
            ?? entries.first { $0.recommended }
            ?? entries[0]
    }

    /// 保留任务的服务商与 Prompt；本地模型由类别选择决定，不能沿用历史 task.modelID。
    /// 返回值同时冻结参数，调用方须在第一次 await 前保存，之后不再重新解析设置。
    func resolvedAITask(
        _ task: AIModelTaskConfiguration, type: LocalAIModelType = .llm
    ) -> AIModelTaskConfiguration {
        var resolved = task
        if aiProviderProfiles.first(where: { $0.id == task.providerID })?.provider == .localAI {
            let entry = selectedLocalAIModel(for: type)
            resolved.modelID = entry.displayName
            resolved.customModelName = entry.displayName
            resolved.useCustomModel = false
        }
        resolved.parameters = effectiveParameters(for: resolved)
        return resolved
    }

    /// 各任务设置中的本地模型菜单也写同一个类别选择，避免产生第二个可见真源。
    func selectLocalAIModel(named name: String, providerID: String) {
        guard aiProviderProfiles.first(where: { $0.id == providerID })?.provider == .localAI,
              let entry = LocalAIModelCatalog.entries.first(where: { $0.displayName == name }) else { return }
        localAIModelSelections[entry.type.rawValue] = entry.id
    }

    /// 状态面板按设置页当前服务商门控，固定按向量化、重排序、生成各展示一项。
    func localAIStatusModels(installedModels: [LocalAIInstalledModel]) -> [LocalAIModelCatalogEntry] {
        let profile: AIProviderProfile?
        if aiSettingsSelectedProfileID.isEmpty {
            // 尚未打开设置页时，与 ensureSelection 的首启动默认服务商保持一致。
            profile = aiProviderProfiles.first { $0.provider == .localAI } ?? aiProviderProfiles.first
        } else {
            profile = aiProviderProfiles.first { $0.id == aiSettingsSelectedProfileID }
        }
        guard profile?.provider == .localAI else { return [] }
        return LocalAIModelType.allCases.map {
            selectedLocalAIModel(for: $0, installedModels: installedModels)
        }
    }
}
