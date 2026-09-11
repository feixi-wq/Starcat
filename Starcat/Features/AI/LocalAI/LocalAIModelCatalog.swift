//
//  LocalAIModelCatalog.swift
//  Starcat
//
//  本地 AI 内置模型目录（编译期常量）。
//
//  设计：
//  - 普通用户不接触 HF / ModelScope Repo ID，只面对「Lite / 推荐」两档 Starcat Model；
//    UI 文案不暴露 FP16 / 4bit / 8bit / MXFP8 等量化概念。
//  - v1 目录只收录 mlx-community 上已经过 MLXEmbedders / MLXLLM 转换且与
//    mlx-swift-lm 内置 registry 匹配的模型。换默认模型 = 改这里，业务层无感。
//  - `revision` 可空：nil 表示安装时解析远端 main 分支当前 commit 并记录进 manifest
//    （保证可追溯），而不是写死一个我们离线无法预知的 SHA。
//  - ModelScope 源在 v1 只保留建模：catalog entry 未登记 modelscope 时，该源在
//    下载源选择器里显示「暂不可用」，禁止静默换源换权重。
//

import Foundation

/// 本地模型类型。与 `AIModelCapability` 对齐映射，见 `LocalAIModelCatalogEntry.capability`。
enum LocalAIModelType: String, Codable, Sendable, CaseIterable {
    case embedding
    case reranker
    case llm

    /// 安装目录 / 存储子目录名。
    var storagePathComponent: String {
        switch self {
        case .embedding: return "embedding"
        case .reranker: return "reranker"
        case .llm: return "llm"
        }
    }
}

/// 模型下载源。v1 只实现 Hugging Face；ModelScope 需要逐个验证镜像后才能进 catalog。
struct LocalAIModelSource: Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case huggingFace
        case modelScope
    }

    var kind: Kind
    /// 模型仓库标识，如 `mlx-community/Qwen3-Embedding-0.6B-8bit`。
    var repo: String
    /// 固定 revision（commit SHA）；nil = 安装时解析 main 并记录。
    var revision: String?
}

/// 待下载文件。`isRequired == false` 的文件（如 generation_config.json）404 时跳过。
struct LocalAIModelFile: Sendable, Equatable {
    var name: String
    var isRequired: Bool

    static func required(_ name: String) -> LocalAIModelFile { .init(name: name, isRequired: true) }
    static func optional(_ name: String) -> LocalAIModelFile { .init(name: name, isRequired: false) }
}

/// Catalog 单条记录。
struct LocalAIModelCatalogEntry: Identifiable, Sendable, Equatable {
    /// 稳定短 id（用于存储目录名 / 下载状态 key），如 `qwen3-embedding-0.6b-8bit`。
    let id: String
    let displayName: String
    let type: LocalAIModelType
    /// 下发到 `AIProviderProfile.models` 的能力标签。
    let capability: AIModelCapability
    /// true = 「推荐」档；false = 「Lite」档。
    let recommended: Bool
    /// 下载体积预估（字节），用于 UI 展示与磁盘预检。
    let estimatedDownloadSize: Int64
    /// 运行内存建议（字节），安装前提示。
    let memoryRecommendation: UInt64
    let contextLength: Int?
    /// embedding 专用：向量维度（写入 `repo_embeddings.dimensions` 口径）。
    let embeddingDimension: Int?
    let source: LocalAIModelSource
    let files: [LocalAIModelFile]
}

enum LocalAIModelCatalog {

    /// 内置本地 AI profile 的固定 id。seed-if-missing，用户不可删除。
    static let builtInProfileID = "built-in.local-ai"

    static let embedding: LocalAIModelCatalogEntry = LocalAIModelCatalogEntry(
        id: "qwen3-embedding-0.6b-8bit",
        displayName: "Qwen3 Embedding 0.6B 8bit",
        type: .embedding,
        capability: .embedding,
        recommended: true,
        estimatedDownloadSize: 664_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: 1024,
        source: LocalAIModelSource(
            kind: .huggingFace,
            repo: "mlx-community/Qwen3-Embedding-0.6B-8bit",
            revision: nil),
        files: [
            .required("config.json"),
            .required("model.safetensors"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .optional("special_tokens_map.json"),
        ])

    static let reranker: LocalAIModelCatalogEntry = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-0.6b-mxfp8",
        displayName: "Qwen3 Reranker 0.6B",
        type: .reranker,
        capability: .rerank,
        recommended: true,
        estimatedDownloadSize: 645_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        source: LocalAIModelSource(
            kind: .huggingFace,
            repo: "mlx-community/Qwen3-Reranker-0.6B-mxfp8",
            revision: nil),
        files: [
            .required("config.json"),
            .required("model.safetensors"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .optional("special_tokens_map.json"),
        ])

    static let llm: LocalAIModelCatalogEntry = LocalAIModelCatalogEntry(
        id: "qwen3-4b-instruct-2507-4bit",
        displayName: "Qwen3 4B Instruct 4bit",
        type: .llm,
        capability: .chat,
        recommended: true,
        estimatedDownloadSize: 2_500_000_000,
        memoryRecommendation: 4_000_000_000,
        contextLength: 262_144,
        embeddingDimension: nil,
        source: LocalAIModelSource(
            kind: .huggingFace,
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            revision: nil),
        files: [
            .required("config.json"),
            .required("model.safetensors"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .optional("generation_config.json"),
            .optional("special_tokens_map.json"),
        ])

    static let llmLite: LocalAIModelCatalogEntry = LocalAIModelCatalogEntry(
        id: "qwen3-1.7b-4bit",
        displayName: "Qwen3 1.7B 4bit",
        type: .llm,
        capability: .chat,
        recommended: false,
        estimatedDownloadSize: 1_100_000_000,
        memoryRecommendation: 2_200_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        source: LocalAIModelSource(
            kind: .huggingFace,
            repo: "mlx-community/Qwen3-1.7B-4bit",
            revision: nil),
        files: [
            .required("config.json"),
            .required("model.safetensors"),
            .required("tokenizer.json"),
            .required("tokenizer_config.json"),
            .optional("generation_config.json"),
            .optional("special_tokens_map.json"),
        ])

    /// 全部目录项。顺序即设置页展示顺序（Embedding → Reranker → LLM 推荐 → LLM Lite）。
    static let entries: [LocalAIModelCatalogEntry] = [
        embedding,
        reranker,
        llm,
        llmLite,
    ]

    static func entry(id: String) -> LocalAIModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// Catalog 内 repo 名是否声明为 reranker。`RerankerModelFactory` 依赖
    /// repo / 目录名包含 "rerank" 才肯加载 Qwen3 判别式权重，目录命名必须保持该约定。
    static func usesRerankerVerifiedNaming(_ id: String) -> Bool {
        id.localizedCaseInsensitiveContains("rerank")
    }
}
