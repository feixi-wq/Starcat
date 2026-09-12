//
//  LocalAIModelCatalog.swift
//  Starcat
//
//  本地 AI 内置模型目录（编译期常量）。
//
//  设计：
//  - 普通用户不接触 HF / ModelScope Repo ID，只面对「Lite / 推荐」两档 Starcat Model；
//    UI 文案不暴露 FP16 / 4bit / 8bit / MXFP8 等量化概念。
//  - 目录只收录**逐个人工验证过**的仓库（2026-09-12 核验）：HF 仓库必须页面 / API 可达，
//    ModelScope 镜像必须 API `Code:200`。未验证的组合不入册——下载源 Picker 里选了
//    ModelScope 而某模型没有镜像时，该模型显示「当前下载源暂未收录」。
//  - ModelScope 镜像为社区同步（master 分支），revision 记录为 master 快照；
//    HF 为权威源（安装时解析 commit SHA）。
//  - 换默认模型 = 改这里，业务层无感。
//

import Foundation

/// 本地模型类型。与 `AIModelCapability` 对齐映射，见 `LocalAIModelCatalogEntry.capability`。
enum LocalAIModelType: String, Codable, Sendable, CaseIterable, Identifiable {
    case embedding
    case reranker
    case llm

    var id: String { rawValue }

    /// 安装目录 / 存储子目录名。
    var storagePathComponent: String {
        switch self {
        case .embedding: return "embedding"
        case .reranker: return "reranker"
        case .llm: return "llm"
        }
    }

    /// 设置页类别行的 SF Symbol。
    var systemImage: String {
        switch self {
        case .embedding: return "point.3.connected.trianglepath.dotted"
        case .reranker: return "arrow.up.arrow.down"
        case .llm: return "bubble.left.and.text.bubble.right"
        }
    }
}

/// 模型下载源。
struct LocalAIModelSource: Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case huggingFace
        case modelScope

        var id: String { rawValue }
    }

    var kind: Kind
    /// 模型仓库标识，如 `mlx-community/Qwen3-Embedding-0.6B-8bit`。
    var repo: String
    /// 固定 revision；nil = 安装时解析（HF 解析 main 的 commit SHA，ModelScope 固定 master）。
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
    /// 可用下载源。至少一项；按数组顺序视为优先级。
    let sources: [LocalAIModelSource]
    let files: [LocalAIModelFile]

    func source(for kind: LocalAIModelSource.Kind) -> LocalAIModelSource? {
        sources.first { $0.kind == kind }
    }

    /// 该模型是否在指定下载源可用。
    func isAvailable(on kind: LocalAIModelSource.Kind) -> Bool {
        source(for: kind) != nil
    }
}

enum LocalAIModelCatalog {

    /// 内置本地 AI profile 的固定 id。seed-if-missing，用户不可删除。
    static let builtInProfileID = "built-in.local-ai"

    private static let mlxConfigFiles: [LocalAIModelFile] = [
        .required("config.json"),
        .required("model.safetensors"),
        .required("tokenizer.json"),
        .required("tokenizer_config.json"),
        .optional("special_tokens_map.json"),
    ]

    private static let llmConfigFiles: [LocalAIModelFile] = [
        .required("config.json"),
        .required("model.safetensors"),
        .required("tokenizer.json"),
        .required("tokenizer_config.json"),
        .optional("generation_config.json"),
        .optional("special_tokens_map.json"),
    ]

    // MARK: - Embedding

    static let embedding = LocalAIModelCatalogEntry(
        id: "qwen3-embedding-0.6b-8bit",
        displayName: "Qwen3 Embedding 0.6B 8bit",
        type: .embedding,
        capability: .embedding,
        recommended: true,
        estimatedDownloadSize: 664_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: 1024,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Embedding-0.6B-8bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Embedding-0.6B-8bit", revision: nil),
        ],
        files: mlxConfigFiles)

    // MARK: - Reranker

    static let reranker = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-0.6b-4bit",
        displayName: "Qwen3 Reranker 0.6B 4bit",
        type: .reranker,
        capability: .rerank,
        recommended: true,
        estimatedDownloadSize: 350_000_000,
        memoryRecommendation: 1_000_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            // ModelScope 镜像未核验，v1 只收 Hugging Face。
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Reranker-0.6B-4bit", revision: nil),
        ],
        files: mlxConfigFiles)

    static let rerankerMXFP8 = LocalAIModelCatalogEntry(
        id: "qwen3-reranker-0.6b-mxfp8",
        displayName: "Qwen3 Reranker 0.6B MXFP8",
        type: .reranker,
        capability: .rerank,
        recommended: false,
        estimatedDownloadSize: 645_000_000,
        memoryRecommendation: 1_200_000_000,
        contextLength: 32_768,
        embeddingDimension: nil,
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-Reranker-0.6B-mxfp8", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-Reranker-0.6B-mxfp8", revision: nil),
        ],
        files: mlxConfigFiles)

    // MARK: - LLM

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
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: nil),
        ],
        files: llmConfigFiles)

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
        sources: [
            LocalAIModelSource(kind: .huggingFace, repo: "mlx-community/Qwen3-1.7B-4bit", revision: nil),
            LocalAIModelSource(kind: .modelScope, repo: "mlx-community/Qwen3-1.7B-4bit", revision: nil),
        ],
        files: llmConfigFiles)

    /// 全部目录项。
    static let entries: [LocalAIModelCatalogEntry] = [
        embedding,
        reranker,
        rerankerMXFP8,
        llm,
        llmLite,
    ]

    static func entry(id: String) -> LocalAIModelCatalogEntry? {
        entries.first { $0.id == id }
    }

    /// 某类别下的目录项（设置页分组下拉的顺序 = 数组顺序，推荐在前）。
    static func entries(of type: LocalAIModelType) -> [LocalAIModelCatalogEntry] {
        entries.filter { $0.type == type }
    }

    /// Catalog 内 repo 名是否声明为 reranker。`RerankerModelFactory` 依赖
    /// repo / 目录名包含 "rerank" 才肯加载 Qwen3 判别式权重，目录命名必须保持该约定。
    static func usesRerankerVerifiedNaming(_ id: String) -> Bool {
        id.localizedCaseInsensitiveContains("rerank")
    }
}
