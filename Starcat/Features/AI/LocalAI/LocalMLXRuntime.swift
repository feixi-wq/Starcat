//
//  LocalMLXRuntime.swift
//  Starcat
//
//  MLX 推理运行时：模型容器懒加载 + 卸载 + 三类推理（LLM / Embedding / Rerank）。
//
//  并发模型（关键约束）：
//  - actor 只负责「加载 / 卸载容器」的串行化：加载是重 GPU+内存操作，必须排队，
//    避免两个任务同时把同一个（或不同的）模型加载两次。
//  - 推理本身不占用 actor：`ModelContainer` / `EmbedderModelContainer` /
//    `RerankerContainer` 都是 Sendable 且内部自带串行访问（SerialAccessContainer），
//    调用方拿到容器后直接推理。否则一次长生成会把 actor 阻塞住，卸载永远排不上队。
//  - 同一时间最多各驻留一个 LLM / Embedding / Reranker 容器；目录变了就重载
//    （同一时刻系统里只有一个激活的本地模型版本）。
//  - 内存压力（`DispatchSourceMemoryPressure` .warning / .critical）触发 `unloadAll`。
//    测试环境（TestEnvironment）下 shared 是惰性 no-op：任何加载都会抛错而不是真的
//    去碰 MLX / Metal。
//

import Foundation
import MLXLMCommon
import MLXLLM
import MLXEmbedders
import MLXRerankers
import MLXHuggingFace
// 宏展开会直接引用 HuggingFace / Tokenizers 的类型（HubClient / AutoTokenizer），
// 仅 import MLXHuggingFace 不够，必须同时引入两个实现包。
import HuggingFace
import Tokenizers

actor LocalMLXRuntime {

    static let shared = LocalMLXRuntime()

    private var llmContainer: ModelContainer?
    private var llmDirectoryID: String?
    private var embedderContainer: EmbedderModelContainer?
    private var embedderDirectoryID: String?
    private var rerankerContainer: RerankerContainer?
    private var rerankerDirectoryID: String?

    private nonisolated(unsafe) var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    private init() {
        installMemoryPressureHandler()
    }

    // MARK: - 容器管理

    /// LLM 容器（懒加载 + 目录变化重载）。
    func llmContainer(directory: URL) async throws -> ModelContainer {
        if let container = llmContainer, llmDirectoryID == directory.path {
            return container
        }
        llmContainer = nil
        llmDirectoryID = nil
        try ensureRuntimeAvailable()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader)
        llmContainer = container
        llmDirectoryID = directory.path
        return container
    }

    /// Embedding 容器。
    func embedderContainer(directory: URL) async throws -> EmbedderModelContainer {
        if let container = embedderContainer, embedderDirectoryID == directory.path {
            return container
        }
        embedderContainer = nil
        embedderDirectoryID = nil
        try ensureRuntimeAvailable()
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader)
        embedderContainer = container
        embedderDirectoryID = directory.path
        return container
    }

    /// Reranker 容器。`RerankerModelFactory` 按 config.json 自动选择 encoder / qwen3 / jina 实现。
    func rerankerContainer(directory: URL) async throws -> RerankerContainer {
        if let container = rerankerContainer, rerankerDirectoryID == directory.path {
            return container
        }
        rerankerContainer = nil
        rerankerDirectoryID = nil
        try ensureRuntimeAvailable()
        let container = try await RerankerModelFactory.shared.loadContainer(
            from: directory,
            using: Self.tokenizerLoader,
            allowUnverifiedModel: false)
        rerankerContainer = container
        rerankerDirectoryID = directory.path
        return container
    }

    /// 卸载全部容器（内存压力 / 用户关闭 Local AI 时调用）。
    func unloadAll() {
        llmContainer = nil
        llmDirectoryID = nil
        embedderContainer = nil
        embedderDirectoryID = nil
        rerankerContainer = nil
        rerankerDirectoryID = nil
    }

    private func ensureRuntimeAvailable() throws {
        guard LocalAIHardwareSupport.isLocalAIAvailable else {
            throw LocalAIError.hardwareUnsupported
        }
        guard !TestEnvironment.isRunning else {
            throw LocalAIError.unavailableInTests
        }
    }

    /// 系统内存压力 → 全部卸载。容器释放依赖 ARC，置 nil 即可让 Metal 资源随释放回收。
    /// actor init 是 nonisolated 的，本函数也保持 nonisolated（只操作源对象自身）。
    private nonisolated func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { await self?.unloadAll() }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// TokenizerLoader：mlx-swift-lm 3.x 起不内置分词器实现，按官方文档用
    /// MLXHuggingFace 宏桥接 swift-transformers（模型权重由 Starcat 自己下载到本地，
    /// 因此永远不需要 Downloader）。
    nonisolated static let tokenizerLoader: any TokenizerLoader = #huggingFaceTokenizerLoader()
}

// MARK: - 生成流构造

extension LocalMLXRuntime {

    /// 把一次 AIChatRequest 变成 ChatSession 流。
    ///
    /// 每次 request 独立 ChatSession：Starcat 的业务层把每次调用当独立请求（多轮靠
    /// 显式 history），不复用 KV cache；这样最简单也最不容易串会话。
    ///
    /// `nonisolated`：session / stream 在调用方上下文创建与迭代，避免把长生成挂在
    /// actor 上（见文件头「并发模型」）。
    nonisolated static func makeChatStream(
        container: ModelContainer,
        request: AIChatRequest
    ) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if !request.tools.isEmpty {
                        throw LocalAIError.toolsUnsupported
                    }
                    let reasoningConfiguration = await container.configuration.reasoningConfig
                    let reasoningSetup = Self.reasoningSetup(
                        configuration: reasoningConfiguration,
                        disableThinking: request.disableThinking)
                    var systemPrompt = request.systemPrompt
                    if request.responseFormat == .jsonObject {
                        // v1 无 guided generation：JSON 输出靠 prompt 约束（Qwen3 指令跟随足够稳定），
                        // 真正的结构化解码留给 MLXGuidedGeneration 后续版本。
                        systemPrompt +=
                            "\n\nIMPORTANT: Respond with a single valid JSON value only. No markdown fences, no commentary."
                    }
                    let parameters = GenerateParameters(
                        maxTokens: min(request.parameters.maxCompletionTokens, 8_192),
                        temperature: Float(request.parameters.temperature),
                        topP: Float(request.parameters.topP),
                        topK: request.parameters.topK)
                    // 注意：Starcat 模块里已有内部的 `ChatSession`（RepoAIChatViewModel 的
                    // 聊天历史模型），它在本文件作用域里遮蔽 MLXLMCommon.ChatSession，
                    // 必须用模块限定名。
                    let session = MLXLMCommon.ChatSession(
                        container,
                        instructions: systemPrompt.isEmpty ? nil : systemPrompt,
                        generateParameters: parameters,
                        additionalContext: reasoningSetup.additionalContext)

                    let messages = try Self.chatMessages(for: request)
                    var output = ""
                    var reasoningOutput = ""
                    var reasoningRouter = AIStreamReasoningNormalizer(
                        openingTag: reasoningConfiguration?.startDelimiter ?? "<think>",
                        closingTag: reasoningConfiguration?.endDelimiter ?? "</think>",
                        startsInsideReasoning: reasoningSetup.startsInsideReasoning)
                    for try await chunk in session.streamResponse(to: messages) {
                        for event in reasoningRouter.ingest(content: chunk, nativeReasoning: nil) {
                            switch event {
                            case .reasoningDelta(let text):
                                reasoningOutput += text
                            case .delta(let text):
                                output += text
                            default:
                                break
                            }
                            continuation.yield(event)
                        }
                    }
                    for event in reasoningRouter.finish() {
                        switch event {
                        case .reasoningDelta(let text):
                            reasoningOutput += text
                        case .delta(let text):
                            output += text
                        default:
                            break
                        }
                        continuation.yield(event)
                    }
                    continuation.yield(.completed(AIChatResponse(
                        content: output,
                        reasoningContent: reasoningOutput.isEmpty ? nil : reasoningOutput,
                        toolCalls: [],
                        usage: nil,
                        model: request.model,
                        finishReason: "stop")))
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

    /// 把请求级 `disableThinking` 映射到模型自己的 chat-template 开关。
    ///
    /// 可关闭模型（例如 Qwen 的 `enable_thinking`）直接关闭；强制思考模型不能因为短任务
    /// 请求关闭思考就整次失败，此时继续生成并依赖下游 router 隔离 reasoning。这样翻译、
    /// 评论等任务优先走快速路径，同时仍兼容 always-on reasoning 模型。
    private nonisolated static func reasoningSetup(
        configuration: ReasoningConfig?,
        disableThinking: Bool
    ) -> (additionalContext: [String: any Sendable]?, startsInsideReasoning: Bool) {
        guard let configuration else { return (nil, false) }

        if disableThinking {
            do {
                let context = try configuration.promptStrategy.additionalContext(
                    forThinkingEnabled: false)
                return (context, false)
            } catch ReasoningError.cannotDisableReasoning {
                // 强制思考不是请求失败条件；思考内容仍会被分流，业务层只收到最终答案。
                return (nil, true)
            } catch {
                // ReasoningPromptStrategy 当前只有上述 typed error。保留安全兜底，避免未来
                // 依赖新增错误时把模型原始思考误当正文；继续按 reasoning 模型处理。
                return (nil, true)
            }
        }

        let context = try? configuration.promptStrategy.additionalContext(
            forThinkingEnabled: nil)
        let startsInsideReasoning: Bool
        switch configuration.promptStrategy {
        case .templateFlag(_, let defaultOn):
            startsInsideReasoning = defaultOn
        case .alwaysOn, .none:
            startsInsideReasoning = true
        }
        return (context, startsInsideReasoning)
    }

    /// AIChatRequest → Chat.Message 数组。本地 v1 只支持 user/assistant 历史；
    /// tool 消息链（Agent Runtime）明确报不支持。
    private static func chatMessages(for request: AIChatRequest) throws -> [Chat.Message] {
        var messages: [Chat.Message] = []
        for historyMessage in request.history {
            switch historyMessage.role {
            case .user:
                messages.append(.user(historyMessage.content))
            case .assistant:
                messages.append(.assistant(historyMessage.content))
            case .tool:
                throw LocalAIError.toolsUnsupported
            }
        }
        messages.append(.user(request.userPrompt))
        return messages
    }
}

// MARK: - 错误

/// 本地 AI 专用错误。`errorDescription` 走设置页 / AI 错误弹层通用文案通道。
enum LocalAIError: LocalizedError, Equatable {
    case hardwareUnsupported
    case unavailableInTests
    case modelNotInstalled(String)
    case toolsUnsupported
    case embeddingDimensionMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .hardwareUnsupported:
            return String.l10n("settings.localai.error.hardwareUnsupported")
        case .unavailableInTests:
            return "Local AI is unavailable in tests"
        case .modelNotInstalled(let name):
            return String(
                format: String.l10n("settings.localai.error.modelNotInstalledFormat"), name)
        case .toolsUnsupported:
            return String.l10n("settings.localai.error.toolsUnsupported")
        case .embeddingDimensionMismatch(let expected, let actual):
            return String(
                format: String.l10n("settings.localai.error.embeddingDimensionMismatchFormat"),
                expected, actual)
        }
    }
}
