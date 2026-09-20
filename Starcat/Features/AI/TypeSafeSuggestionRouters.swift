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
//  - 标签:仅手动「纯标签批量」(generateBatchTagSuggestions)走 Jev;自动整理与摘要+标签
//    混合洞察(insight 任务)不接,避免自动写入链路使用实验 Provider，也避免双 Provider 串行调用;
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
        try ensureGenerationClientsReady(
            includeSummary: includeSummary,
            includeTags: includeTags,
            invocationMode: .manual
        )
    }

    func ensureGenerationClientsReady(
        includeSummary: Bool,
        includeTags: Bool,
        invocationMode: BatchAIInvocationMode
    ) throws {
        // 只有人工纯标签批量且 Jev 生效时才跳过 LLM 预检，让只配置 Jev Key 的用户
        // 也能生成建议；自动整理仍必须通过原 Provider 预检，不能借 UI 静默标志越界。
        if invocationMode == .manual,
           includeTags,
           !includeSummary,
           isTagsRoutingToTypesafe {
            return
        }
        try base.ensureGenerationClientsReady(
            includeSummary: includeSummary,
            includeTags: includeTags,
            invocationMode: invocationMode
        )
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        purpose: AITagSuggestionPurpose
    ) async throws -> [Int64: [AITagSuggestion]] {
        if purpose == .newOnly {
            return try await base.generateBatchTagSuggestions(
                for: repos,
                tagHintsByRepoID: tagHintsByRepoID,
                purpose: .newOnly
            )
        }
        return try await generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            invocationMode: .manual
        )
    }

    func generateBatchTagSuggestions(
        for repos: [Repo],
        tagHintsByRepoID: [Int64: AITagHints],
        invocationMode: BatchAIInvocationMode
    ) async throws -> [Int64: [AITagSuggestion]] {
        if invocationMode == .manual, isTagsRoutingToTypesafe {
            do {
                let reusableResults = try await typesafeProvider.generateBatchTagSuggestions(
                    for: repos,
                    tagHintsByRepoID: tagHintsByRepoID
                )
                let minimum = settings.clampedAITagSuggestionCounts.minimum
                let maximum = settings.clampedAITagSuggestionCounts.maximum
                let fallbackRepos = repos.filter { repo in
                    (reusableResults[repo.id]?.count ?? 0) < minimum
                }
                guard !fallbackRepos.isEmpty else { return reusableResults }

                // LLM 是“现有标签不足”的按需能力，不能在批次启动时强制预检，否则只配置
                // Jev 且能命中旧标签的用户也会被无关的 LLM 配置阻断。
                try base.ensureGenerationClientsReady(
                    includeSummary: false,
                    includeTags: true,
                    invocationMode: invocationMode
                )
                let fallbackHints = Dictionary(uniqueKeysWithValues: fallbackRepos.map { repo in
                    (repo.id, tagHintsByRepoID[repo.id] ?? .empty)
                })
                let generatedResults = try await base.generateBatchTagSuggestions(
                    for: fallbackRepos,
                    tagHintsByRepoID: fallbackHints,
                    purpose: .newOnly
                )

                var mergedResults = Dictionary(uniqueKeysWithValues: repos.map { repo in
                    (repo.id, reusableResults[repo.id] ?? [])
                })
                for repo in fallbackRepos {
                    let hints = fallbackHints[repo.id] ?? .empty
                    let reusable = reusableResults[repo.id] ?? []
                    let forbiddenKeys = Set(
                        (hints.repoTags + hints.libraryTags).map(AITagSuggestionPolicy.canonicalKey)
                    )
                    let reusableKeys = Set(reusable.map { AITagSuggestionPolicy.canonicalKey($0.name) })
                    let genuinelyNew = (generatedResults[repo.id] ?? []).filter { suggestion in
                        let key = AITagSuggestionPolicy.canonicalKey(suggestion.name)
                        return !key.isEmpty
                            && !forbiddenKeys.contains(key)
                            && !reusableKeys.contains(key)
                    }
                    // 输入顺序先放 Jev 结果，使现有标签先占 maximum 配额；策略层只在完成
                    // 选取后按置信度排序展示，不会让新标签挤掉可复用标签。
                    mergedResults[repo.id] = AITagSuggestionPolicy.normalizedSuggestions(
                        reusable + genuinelyNew,
                        vocabulary: hints.repoTags + hints.libraryTags,
                        maximumSuggestionCount: maximum
                    )
                }
                return mergedResults
            } catch let error as TypeSafeClientError {
                AppLog.ai.error(
                    "[typesafePOC] tag suggestions failed, surfacing error: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }
        return try await base.generateBatchTagSuggestions(
            for: repos,
            tagHintsByRepoID: tagHintsByRepoID,
            invocationMode: invocationMode
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
