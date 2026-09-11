//
//  LocalMLXRAGReranker.swift
//  Starcat
//
//  知识库 RAG 的本地重排序：进程内 MLX 加载 Qwen3-Reranker，不发起任何网络请求。
//
//  定位：`RAGReranking` 的第三个实现（前两个是 TEI / Cohere 远程 HTTP）。遵循既有
//  RAG 检索配置语义——`RAGRerankConfiguration.isEnabled` 默认关闭，用户在检索设置里
//  显式开启；模型未下载时抛 `LocalAIError.modelNotInstalled`，由检索管线把错误上抛。
//
//  关键约束：
//  - 候选截断、文档拼装、下标映射保持与 TEI/Cohere 相同的「同一快照」纪律
//    （见 `RAGRerankCandidateSnapshot` 注释）；本地实现自持一份等价逻辑。
//  - Qwen3-Reranker 是判别式 causal 打分（yes/no logits → normalizedRelevance 0...1），
//    mlx-swift-lm 的 `RerankerContainer` 已封装该协议；score 直接可用，无需归一化。
//

import Foundation
import MLXLMCommon

struct LocalMLXRAGReranker: RAGReranking {

    let provider: RAGRerankProvider = .localMLX

    private let configuration: RAGRerankConfiguration
    private let runtime: LocalMLXRuntime

    var debugCandidateLimit: Int? { configuration.candidateLimit }
    /// Debug Trace 显示当前安装的本地 reranker 名；未安装为 nil。
    var debugModel: String? {
        LocalAIModelCatalog.reranker.displayName
    }

    init(
        configuration: RAGRerankConfiguration,
        runtime: LocalMLXRuntime = .shared
    ) {
        self.configuration = configuration.normalized
        self.runtime = runtime
    }

    /// Qwen3-Reranker 官方建议指令：与 query 一起进 prompt 提升判别质量。
    private static let instruction =
        "Given a user query, retrieve relevant repository passages that answer the query."

    func rerank(
        query: String, candidates: [RAGChildHit]
    ) async throws -> [(hit: RAGChildHit, score: Double)] {
        let hits = Array(candidates.prefix(configuration.candidateLimit))
        guard !hits.isEmpty else { return [] }

        guard let directory = LocalAIModelStorage.installedDirectoryURL(
            entryID: LocalAIModelCatalog.reranker.id)
        else {
            throw LocalAIError.modelNotInstalled(LocalAIModelCatalog.reranker.displayName)
        }

        // 与远程 Provider 的文档拼装口径一致：标题 + 路径 + 正文前 6000 字符。
        let documents = hits.map { hit in
            [hit.chunk.title, hit.chunk.sectionPath, String(hit.chunk.content.prefix(6_000))]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        let container = try await runtime.rerankerContainer(directory: directory)
        // score 类型由 config.json 决定（Qwen3 判别式 → normalizedRelevance 0...1）。
        let response = try await container.scores(
            query: query,
            documents: documents,
            instruction: Self.instruction,
            options: RerankExecutionOptions(maxBatchSize: 4, maxBatchTokens: 8_192))

        var scored: [(hit: RAGChildHit, score: Double)] = []
        scored.reserveCapacity(hits.count)
        for result in response.results where hits.indices.contains(result.index) {
            scored.append((hits[result.index], result.score))
        }
        return scored.sorted { $0.score > $1.score }
    }
}
