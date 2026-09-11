//
//  LocalMLXClient.swift
//  Starcat
//
//  本地 AI（MLX）的 AIClientProtocol 适配层。
//
//  定位：与 `OpenAIClient`（HTTP）、`RAGCLIModelClient`（外部 CLI）并列的第三个
//  Starcat AI 后端。业务层（摘要 / 标签 / 对话 / 向量化 / RAG）只认协议，不感知
//  本地推理的存在；`AIClient.swift` 头注释预留的「Apple 本地模型只需替换 adapter」
//  由本文件兑现。
//
//  关键约束：
//  - 无 Key、无 baseURL：`AIClientConfiguration` 仅用于 providerID / 归因 / 超时口径，
//    网络相关字段被忽略。
//  - 本类型可以在任意执行上下文使用（业务服务多为 @MainActor，但流式迭代不在），
//    因此模型目录解析走 `LocalAIModelStorage` 的磁盘查询（非隔离），不触碰
//    @MainActor 的 `LocalAIModelManager`。
//  - embedding 维度在运行时校验 catalog 声明，防止 mlx-swift-lm 的 pooling 回归
//    （issue #36 曾输出 16384 维）污染向量库。
//

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon

struct LocalMLXClient: AIClientProtocol {

    private let runtime: LocalMLXRuntime
    /// 模型展示名（= catalog displayName）→ 安装目录。未安装抛 `LocalAIError.modelNotInstalled`。
    private let directoryForModelName: @Sendable (String) throws -> URL

    init(
        runtime: LocalMLXRuntime = .shared,
        directoryForModelName: @escaping @Sendable (String) throws -> URL
    ) {
        self.runtime = runtime
        self.directoryForModelName = directoryForModelName
    }

    /// 装配入口：按 catalog 展示名校验已安装并构造客户端。
    ///
    /// 与 `OpenAIClient(configuration:)` 同级——由各业务的 makeClient 工厂分支调用；
    /// 这里即时校验 chat 模型已下载（fail fast），embedding 模型在调用时校验。
    public static func makeClient(modelName: String) throws -> LocalMLXClient {
        try validateModelInstalled(displayName: modelName)
        return LocalMLXClient(directoryForModelName: Self.directoryResolver)
    }

    /// 展示名 → 安装目录。任何线程可用（磁盘扫描即真源）。
    static let directoryResolver: @Sendable (String) throws -> URL = { name in
        guard let entry = LocalAIModelCatalog.entries.first(where: { $0.displayName == name }),
            let directory = LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)
        else {
            throw LocalAIError.modelNotInstalled(name)
        }
        return directory
    }

    private static func validateModelInstalled(displayName: String) throws {
        _ = try directoryResolver(displayName)
    }

    // MARK: - AITextGenerating

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        let events = chatStream(request: request)
        var finalResponse: AIChatResponse?
        for try await event in events {
            if case .completed(let response) = event {
                finalResponse = response
            }
        }
        guard let finalResponse else {
            throw AIClientError.emptyResponse
        }
        return finalResponse
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let directory = try directoryForModelName(request.model)
                    let container = try await runtime.llmContainer(directory: directory)
                    let stream = LocalMLXRuntime.makeChatStream(
                        container: container, request: request)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - AIClientProtocol

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        let response = try await chat(request: AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model ?? "",
            parameters: .defaults(for: .chat)))
        return response.content
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        let vectors = try await embeddings(inputs: [input], model: model)
        guard let vector = vectors.first else {
            throw AIClientError.emptyResponse
        }
        return vector
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        let modelName = model ?? ""
        let directory = try directoryForModelName(modelName)
        let expectedDimension = LocalAIModelCatalog.entries
            .first { $0.displayName == modelName }?
            .embeddingDimension

        let container = try await runtime.embedderContainer(directory: directory)
        let vectors = try await Self.embed(container: container, inputs: inputs)

        if let expectedDimension, vectors.contains(where: { $0.count != expectedDimension }) {
            // pooling 回归的向量绝不能写进向量库。
            throw LocalAIError.embeddingDimensionMismatch(
                expected: expectedDimension, actual: vectors.first?.count ?? 0)
        }
        return vectors
    }

    func listModels() async throws -> [AIModelDescriptor] {
        let installedIDs = Set(
            ((try? LocalAIModelStorage.listInstalled()) ?? []).map(\.id))
        return LocalAIModelCatalog.entries.compactMap { entry in
            guard installedIDs.contains(entry.id) else { return nil }
            return AIModelDescriptor(
                providerID: LocalAIModelCatalog.builtInProfileID,
                name: entry.displayName,
                ownedBy: "Starcat Local AI",
                capability: entry.capability,
                isEnabled: true)
        }
    }

    func testConnection() async throws {
        // 本地「连接测试」= 完整性检查：manifest 声明的文件都真实存在。
        let installed = (try? LocalAIModelStorage.listInstalled()) ?? []
        for manifest in installed {
            guard let entry = LocalAIModelCatalog.entry(id: manifest.id) else { continue }
            guard let directory = LocalAIModelStorage.installedDirectoryURL(entryID: entry.id)
            else { continue }
            for file in manifest.files
            where !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(file.name).path) {
                throw LocalAIError.modelNotInstalled(entry.displayName)
            }
        }
    }

    // MARK: - Embedding 推理

    /// 批量 embedding：右填充 + attention mask（Qwen3 是 last-token pooling，
    /// mask 决定取哪个 token，批次推理时必须传）。
    static func embed(
        container: EmbedderModelContainer, inputs: [String]
    ) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }
        return try await container.perform { context in
            let tokenizer = context.tokenizer
            let tokenized = inputs.map { text -> [Int] in
                let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
                // 单条超长截断：embedding 输入上限远小于 LLM 上下文，8K token 覆盖
                // 任何 README chunk（chunker 目标 700 token）。
                return Array(encoded.prefix(8_192))
            }
            let maxLength = tokenized.map(\.count).max() ?? 1

            var inputIDs: [Int32] = []
            var attentionMask: [Int32] = []
            inputIDs.reserveCapacity(inputs.count * maxLength)
            attentionMask.reserveCapacity(inputs.count * maxLength)
            for ids in tokenized {
                let padding = maxLength - ids.count
                inputIDs.append(contentsOf: ids.map(Int32.init))
                inputIDs.append(contentsOf: [Int32](repeating: 0, count: padding))
                attentionMask.append(contentsOf: [Int32](repeating: 1, count: ids.count))
                attentionMask.append(contentsOf: [Int32](repeating: 0, count: padding))
            }

            let inputArray = MLXArray(inputIDs).reshaped([inputs.count, maxLength])
            let maskArray = MLXArray(attentionMask).reshaped([inputs.count, maxLength])
            let output = context.model(
                inputArray, positionIds: nil, tokenTypeIds: nil, attentionMask: maskArray)
            let pooled = context.pooling(
                output, mask: maskArray, normalize: true, applyLayerNorm: true)
            pooled.eval()
            let rows = pooled.shape[0]
            return (0..<rows).map { row in
                Array(pooled[row].asArray(Float.self))
            }
        }
    }
}
