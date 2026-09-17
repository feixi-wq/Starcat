//
//  TypeSafeSuggestionRouters.swift
//  Starcat
//
//  Jev 决策服务的两个装配路由器 —— 实验性功能(Labs)POC。
//
//  为什么用路由器而不是直接替换 Provider:
//  - 现有 LLM 路径必须一行不动地保留为默认路径:开关关闭、Key 未配置、后台自动
//    整理时,路由器原样透传,行为与接入前逐字节等价;
//  - Jev 是实验特性,后续可能整体下线 —— 下线时只需从 AppDependencies 摘掉这两层
//    路由,业务文件(会话 / 队列 / 服务)零改动。
//
//  路由边界(POC 安全边界):
//  - 分组:仅 `session.mode == .manual`(用户手动整理 / 多选批量整理 / 手动草稿恢复)
//    走 Jev;AutoTidyScheduler 的自动整理与 auto-apply 继续走 LLM,自动写入链路
//    完全不接触 Jev;
//  - 标签:仅「纯标签批量」(generateBatchTagSuggestions)走 Jev;摘要+标签混合
//    洞察(insight 任务)不接,避免一次任务拆两个 Provider 串行调用;
//  - 失败语义:Jev 失败不静默回退 LLM(双跑烧两份钱 + 加倍延迟),错误沿既有
//    失败分类上抛,由会话 / 队列现有的重试与展示语义接管。
//

import Foundation

// MARK: - 分组建议路由

/// `GitHubStarListAIGroupingSession` 的 Provider 路由层。
///
/// 会话在 AppDependencies 里只构造一次,手动窗口与 AutoTidyScheduler 共享同一
/// 实例,因此「只让手动整理走 Jev」必须在 Provider 层按会话当前 mode 分流:
/// AppDependencies 构造完会话后调用 `attachSession(_:)` 回填探针。
@MainActor
final class TypeSafeGitHubListSuggestionRouter: GitHubStarListSuggestionProviding {
    private let llmProvider: any GitHubStarListSuggestionProviding
    private let typesafeProvider: TypeSafeDecisionService
    private let settings: AppSettings
    /// 当前调用是否发生在手动整理上下文。默认 false(未挂接 → 一律 LLM,安全侧)。
    private var isManualInvocation: () -> Bool

    init(
        llmProvider: any GitHubStarListSuggestionProviding,
        typesafeProvider: TypeSafeDecisionService,
        settings: AppSettings,
        isManualInvocation: @escaping () -> Bool = { false }
    ) {
        self.llmProvider = llmProvider
        self.typesafeProvider = typesafeProvider
        self.settings = settings
        self.isManualInvocation = isManualInvocation
    }

    /// AppDependencies 构造会话后回填;weak 引用避免路由器与会话互相持有。
    func attachSession(_ session: GitHubStarListAIGroupingSession) {
        isManualInvocation = { [weak session] in session?.mode == .manual }
    }

    private var shouldRouteToTypesafe: Bool {
        settings.typesafeDecisionEnabled
            && settings.typesafeGroupingSuggestionsEnabled
            && typesafeProvider.canResolveAPIKey()
    }

    func generateGitHubListSuggestions(
        for repos: [Repo],
        candidates: [GitHubStarListAIContext],
        existingListIDsByRepo: [Int64: Set<String>],
        existingListNamesByRepo: [Int64: [String]]
    ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
        if isManualInvocation() && shouldRouteToTypesafe {
            do {
                return try await typesafeProvider.generateGitHubListSuggestions(
                    for: repos,
                    candidates: candidates,
                    existingListIDsByRepo: existingListIDsByRepo,
                    existingListNamesByRepo: existingListNamesByRepo
                )
            } catch let error as TypeSafeClientError {
                AppLog.ai.error(
                    "[typesafePOC] grouping suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        return try await llmProvider.generateGitHubListSuggestions(
            for: repos,
            candidates: candidates,
            existingListIDsByRepo: existingListIDsByRepo,
            existingListNamesByRepo: existingListNamesByRepo
        )
    }
}

// MARK: - 批量洞察路由

/// `BatchAIQueueService` 的 `BatchAIInsightProviding` 路由层。
@MainActor
final class TypeSafeBatchAIInsightRouter: BatchAIInsightProviding {
    private let base: any BatchAIInsightProviding
    private let typesafeProvider: TypeSafeDecisionService
    private let settings: AppSettings

    init(
        base: any BatchAIInsightProviding,
        typesafeProvider: TypeSafeDecisionService,
        settings: AppSettings
    ) {
        self.base = base
        self.typesafeProvider = typesafeProvider
        self.settings = settings
    }

    private var isTagsRoutingToTypesafe: Bool {
        settings.typesafeDecisionEnabled
            && settings.typesafeTagSuggestionsEnabled
            && typesafeProvider.canResolveAPIKey()
    }

    func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {
        // 纯标签批量且 Jev 生效时,标签生成不依赖任何 LLM Provider,
        // 跳过既有预检让「只配了 Jev Key」的用户也能跑标签整理;
        // 其余组合(含摘要)透传,预检语义不变。
        if includeTags && !includeSummary && isTagsRoutingToTypesafe { return }
        try base.ensureGenerationClientsReady(includeSummary: includeSummary, includeTags: includeTags)
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints]
    ) async throws -> [Int64: [AITagSuggestion]] {
        if isTagsRoutingToTypesafe {
            do {
                return try await typesafeProvider.generateBatchTagSuggestions(
                    for: repos,
                    tagHintsByRepoID: tagHintsByRepoID
                )
            } catch let error as TypeSafeClientError {
                AppLog.ai.error(
                    "[typesafePOC] tag suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        return try await base.generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID
        )
    }

    /// 摘要 + 标签混合洞察不接 Jev(POC 边界):一次任务拆两个 Provider 会串行
    /// 双调用,延迟与失败面都翻倍,等标签路径验证价值后再考虑。
    func generateBatchInsight(
        for repo: Repo,
        existingTagHints: AITagHints,
        includeSummary: Bool,
        includeTags: Bool,
        codeContextEnabledOverride: Bool?,
        externalContextEnabledOverride: Bool?
    ) async throws -> RepoAIInsightGeneration {
        try await base.generateBatchInsight(
            for: repo,
            existingTagHints: existingTagHints,
            includeSummary: includeSummary,
            includeTags: includeTags,
            codeContextEnabledOverride: codeContextEnabledOverride,
            externalContextEnabledOverride: externalContextEnabledOverride
        )
    }
}
