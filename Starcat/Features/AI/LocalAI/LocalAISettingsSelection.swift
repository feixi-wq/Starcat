//
//  LocalAISettingsSelection.swift
//  Starcat
//
//  设置页与 toolbar 共用的本地模型选择口径。选择决定展示哪个模型，安装清单仅补充
//  安装状态与未选择时的默认值；不能反过来把所有已下载模型当作当前选择。
//

import Foundation

extension AppSettings {
    /// 每类只解析一个选中项；未下载的明确选择也必须保留，不能被其它已安装模型顶替。
    func selectedLocalAIModel(
        for type: LocalAIModelType, installedModels: [LocalAIInstalledModel]
    ) -> LocalAIModelCatalogEntry {
        let entries = LocalAIModelCatalog.entries(of: type)
        if let id = localAIModelSelections[type.rawValue],
            let selected = entries.first(where: { $0.id == id })
        {
            return selected
        }
        // 延续设置页原有默认顺序；catalog 保证三类均非空，两处 UI 不再各自猜默认值。
        return entries.first { entry in installedModels.contains { $0.id == entry.id } }
            ?? entries.first { $0.recommended }
            ?? entries[0]
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
