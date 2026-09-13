//
//  LocalAISettingsSelectionTests.swift
//  StarcatTests
//
//  回归验证 toolbar 按设置页选择显示模型，而非枚举下载清单。全部使用临时偏好域和
//  安装元数据，不访问真实模型目录，也不触发 MLX 加载。
//

import Foundation
import SwiftUI
import Testing

@testable import Starcat

/// 设置页和状态面板必须复用同一解析结果，关闭页面或重启不能丢失明确选择。
@Suite("LocalAISettingsSelection")
@MainActor
struct LocalAISettingsSelectionTests {
    @Test("三类标签使用完整的本地化键而非插值格式键", arguments: LocalAIModelType.allCases)
    func modelTypeUsesExactLocalizationKey(type: LocalAIModelType) {
        // 先构造普通 String，避免测试期望值也走到相同的 LocalizedStringKey 插值错误。
        let key = "settings.localai.model.type." + type.rawValue
        #expect(LocalAIStatusSection.modelTypeLabelKey(type) == LocalizedStringKey(key))
    }

    @Test("三类标签在产物中均有中英文翻译", arguments: ["en", "zh-Hans"])
    func modelTypeTranslationsExist(language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let expected = language == "en" ? ["Embedding", "Reranker", "Generation"] : ["向量化", "重排序", "生成"]
        // 直接读目标语言资源，不改用户语言偏好，也不启动或操作任何应用界面。
        for (type, label) in zip(LocalAIModelType.allCases, expected) {
            let key = "settings.localai.model.type." + type.rawValue
            #expect(bundle.localizedString(forKey: key, value: nil, table: "Localizable") == label)
        }
    }

    @Test("下载了多个模型时仍只展示三类选中项")
    func onlyShowsSelectedModels() {
        withSettings { settings, _ in
            let selected = LocalAIModelType.allCases.map { LocalAIModelCatalog.entries(of: $0).last! }
            settings.localAIModelSelections = Dictionary(uniqueKeysWithValues: selected.map { ($0.type.rawValue, $0.id) })
            let installed = LocalAIModelCatalog.entries.map(installedModel)
            #expect(installed.count > 3)
            let displayed = settings.localAIStatusModels(installedModels: installed)
            #expect(displayed.map(\.id) == selected.map(\.id))
            #expect(displayed.map(\.type) == [.embedding, .reranker, .llm])
        }
    }

    @Test("非本地服务商及失效选择不展示本地模型", arguments: ["api", "removed-profile"])
    func hidesForOtherProviders(profileID: String) {
        withSettings { settings, _ in
            settings.aiSettingsSelectedProfileID = profileID
            #expect(settings.localAIStatusModels(installedModels: LocalAIModelCatalog.entries.map(installedModel)).isEmpty)
        }
    }

    @Test("未下载的选中项不会被其它已下载模型替代")
    func keepsUndownloadedSelection() {
        withSettings { settings, _ in
            let selected = LocalAIModelCatalog.entries(of: .llm).last!
            let downloaded = LocalAIModelCatalog.entries(of: .llm)[0]
            settings.localAIModelSelections[LocalAIModelType.llm.rawValue] = selected.id
            let models = settings.localAIStatusModels(installedModels: [installedModel(downloaded)])
            #expect(models.last?.id == selected.id)
            #expect(models.count == 3)
        }
    }

    @Test("服务商与三类模型选择跨 AppSettings 重建保留")
    func persistsSelections() {
        withSettings { settings, defaults in
            settings.aiSettingsSelectedProfileID = "api"
            settings.localAIModelSelections = [
                "embedding": LocalAIModelCatalog.entries(of: .embedding).last!.id,
                "reranker": LocalAIModelCatalog.entries(of: .reranker).last!.id,
                "llm": LocalAIModelCatalog.entries(of: .llm).last!.id,
            ]
            let restored = AppSettings(defaults: defaults)
            #expect(restored.localAIModelSelections == settings.localAIModelSelections)
            #expect(restored.aiSettingsSelectedProfileID == "api")
            // 沿用旧 @AppStorage key，不让升级后的设置页突然换回默认服务商。
            #expect(defaults.string(forKey: "settings.ai.lastSelectedProfileID") == "api")
        }
    }

    @Test("空选择使用设置页相同的默认模型", arguments: LocalAIModelType.allCases)
    func sharesDefaultSelection(type: LocalAIModelType) {
        withSettings { settings, _ in
            settings.aiSettingsSelectedProfileID = ""
            let downloaded = LocalAIModelCatalog.entries(of: type).last!
            let installed = [installedModel(downloaded)]
            let settingSelection = settings.selectedLocalAIModel(for: type, installedModels: installed)
            let statusSelection = settings.localAIStatusModels(installedModels: installed).first { $0.type == type }
            #expect(settingSelection.id == downloaded.id)
            #expect(statusSelection?.id == settingSelection.id)
        }
    }

    @Test("错误类别的 ID 不会让同一类显示另一类模型")
    func rejectsWrongCategory() {
        withSettings { settings, _ in
            settings.localAIModelSelections["embedding"] = LocalAIModelCatalog.reranker.id
            let embedding = settings.selectedLocalAIModel(for: .embedding, installedModels: [])
            #expect(embedding.type == .embedding)
            #expect(embedding.recommended)
        }
    }

    @Test("更新展示选择不改变实际任务路由")
    func doesNotChangeTaskRouting() {
        withSettings { settings, _ in
            let tasks = [settings.aiChatTask, settings.aiSummaryTask, settings.aiTranslationTask, settings.aiEmbeddingTask]
            settings.aiSettingsSelectedProfileID = "api"
            settings.localAIModelSelections["llm"] = LocalAIModelCatalog.entries(of: .llm).last!.id
            #expect([settings.aiChatTask, settings.aiSummaryTask, settings.aiTranslationTask, settings.aiEmbeddingTask] == tasks)
        }
    }

    /// 每个用例独立持久化域，避免碰到用户正在使用的服务商配置。
    private func withSettings(_ body: (AppSettings, UserDefaults) -> Void) {
        let suite = "LocalAISettingsSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.aiProviderProfiles = [
            AIProviderProfile(id: "local", provider: .localAI, models: [], lastTestStatus: .notTested),
            AIProviderProfile(id: "api", provider: .openAICompatible, models: [], lastTestStatus: .notTested),
        ]
        settings.aiSettingsSelectedProfileID = "local"
        body(settings, defaults)
    }

    /// 安装清单夹具只提供身份信息，真实文件与内存状态都不参与选择解析。
    private func installedModel(_ entry: LocalAIModelCatalogEntry) -> LocalAIInstalledModel {
        LocalAIInstalledModel(
            id: entry.id, displayName: entry.displayName, type: entry.type, revision: "test",
            installedAt: Date(), sourceKind: .huggingFace, files: [],
            embeddingDimension: entry.embeddingDimension, totalBytes: 0)
    }
}
