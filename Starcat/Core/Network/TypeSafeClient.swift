//
//  TypeSafeClient.swift
//  Starcat
//
//  TypeSafe AI(Jev "System One" 决策模型)REST 客户端 —— 实验性功能(Labs)。
//
//  设计约束:
//  - Jev 不是 LLM:不生成文本,只对结构化 state 回答类型化问题(Noul 二元概率 /
//    Choice 多选一),本客户端只覆盖 POC 需要的 Noul 原语与通用请求骨架;
//  - 官方只有 Python / TypeScript SDK,Swift 侧按 `OpenSSFScoreAPI` 的独立公开
//    API actor 模板手写:自带 URLSession、领域错误枚举,不复用 GitHubAPIClient;
//  - 官方文档要求 429 / 529 指数退避重试;项目没有通用 retry 层,因此退避逻辑
//    收口在本 actor 内,不外溢到调用方;
//  - API Key 按 BYOK 逐次传入而不是构造时固化:设置页改 Key 后无需热更新装配,
//    也避免 actor 持有可变凭据状态。
//
//  已知坑(来自官方 docs.typesafe.ai/models):
//  - `jev-latest` alias 会随版本漂移,阈值调好后行为可能被 silently 改变;
//    调用方应使用固定版本 ID(如 jev-1.13.0);
//  - 限流(429)动态变化且可能不经通知调整,重试必须尊重 Retry-After。
//

import Foundation

// MARK: - 错误

/// TypeSafe API 领域错误。
enum TypeSafeClientError: Error, Equatable {
    /// 未配置 API Key(调用前应先路由回退到 LLM 路径,这里是兜底)。
    case missingAPIKey
    case unauthorized
    /// 422:请求体校验失败,body 里通常指明出错字段。
    case validation(String)
    /// 429:限流;`retryAfterSeconds` 来自 Retry-After 头(可能为 nil)。
    case rateLimited(retryAfterSeconds: Double?)
    /// 529:服务暂时过载,官方建议与 429 同样退避重试。
    case overloaded(retryAfterSeconds: Double?)
    case server(statusCode: Int)
    case transport(String)
    case decoding(String)

    var isRetryableWithBackoff: Bool {
        switch self {
        case .rateLimited, .overloaded: return true
        default: return false
        }
    }
}

extension TypeSafeClientError: LocalizedError {
    /// 分组会话 / 批量队列的失败行直接取 `localizedDescription`;
    /// 枚举默认描述是毫无信息量的 "The operation could not be completed",
    /// 因此这里给出可读文本(技术诊断语义,与 NetworkError 的 detail 同层,不走本地化 key)。
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "TypeSafe API key is not configured"
        case .unauthorized:
            return "TypeSafe API rejected the key (401)"
        case let .validation(detail):
            return "TypeSafe API validation error (422): \(detail)"
        case let .rateLimited(seconds):
            return "TypeSafe API rate limited (429)\(seconds.map { " after \($0)s" } ?? "")"
        case let .overloaded(seconds):
            return "TypeSafe API overloaded (529)\(seconds.map { " after \($0)s" } ?? "")"
        case let .server(code):
            return "TypeSafe API server error (\(code))"
        case let .transport(message):
            return "TypeSafe API transport error: \(message)"
        case let .decoding(message):
            return "TypeSafe API response decoding failed: \(message)"
        }
    }
}

// MARK: - 请求 DTO

/// `POST /v1/systemone` 请求体。
/// 泛型放在类型上而不是函数内:Swift 不允许泛型函数嵌套类型。
private struct TypeSafeSystemOneRequestBody<State: Encodable>: Encodable {
    let state: State
    let model: String
    let questions: [String: TypeSafeQuestion]
}

/// Noul(true/false 语义)问题的可选判据。
///
/// criteria 不填时由模型按 instructions 自行解释;填上后概率语义被钉死,
/// 官方 cookbook(如 rerank)推荐显式给 true/false 描述以保证跨请求可比。
struct TypeSafeNoulCriteria: Encodable, Equatable {
    var `true`: String?
    var `false`: String?

    init(true: String?, false: String?) {
        self.true = `true`
        self.false = `false`
    }
}

/// 问题原语。POC 只实现 Noul(独立二元隶属判断,天然支持「零或多个」语义);
/// Choice / Score 留待后续按需补充,不预先铺代码。
enum TypeSafeQuestion: Encodable, Equatable {
    case noul(instructions: String, criteria: TypeSafeNoulCriteria?)

    private enum CodingKeys: String, CodingKey {
        case type
        case instructions
        case criteria
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noul(instructions, criteria):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            // criteria 整体可省;给出时 true/false 各自可省。
            if let criteria {
                try container.encode(criteria, forKey: .criteria)
            }
        }
    }
}

// MARK: - 响应 DTO

/// `POST /v1/systemone` 响应。
///
/// answers 以调用方自定义的 question id 为键;usage 用于诊断,POC 不做计费统计。
struct TypeSafeSystemOneResponse: Decodable, Equatable {
    let model: String?
    let answers: [String: TypeSafeAnswer]
    let usage: TypeSafeUsage?
}

/// 单个问题的答案。
///
/// Noul 答案只有概率数值;官方文档注明 confidence 仅 Choice / Score 返回,
/// 因此这里全部按可选解码,读取方各自判空。
struct TypeSafeAnswer: Decodable, Equatable {
    let type: String?
    let noul: Double?
    let choice: String?
    let probabilities: [String: Double]?
    let confidence: Double?
}

struct TypeSafeUsage: Decodable, Equatable {
    let inputTokens: Int?
    let outputTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

// MARK: - 客户端

/// TypeSafe API 独立 actor 客户端。
///
/// 并发安全:actor 隔离;无共享可变状态(URLSession / decoder 均为不可变引用),
/// 真正的并发控制由上层(分组会话的 5 Worker、批量队列)负责。
actor TypeSafeClient {
    private static let timeout: TimeInterval = 20
    private static let maxRetries = 3
    /// 退避基数 0.5s(0.5 / 1 / 2):Jev 单次调用 70–500ms,过长退避会拖垮
    /// 分组会话的 worker 吞吐;官方同时要求尊重更大的 Retry-After。
    private static let backoffBaseSeconds: Double = 0.5

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = AppEndpoints.TypeSafe.productionURL,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: configuration)
        }
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// 评估一次结构化决策请求。
    ///
    /// - Parameters:
    ///   - state: 任意 Encodable(对象 / 字符串 / 数组);调用方用小结构体描述
    ///     被判断对象,只带该问题需要的上下文(官方「Decompose state」原则)。
    ///   - model: 固定版本模型 ID,由 `TypeSafeDecisionService` 统一解析。
    ///   - questions: question id → 问题;共享同一 state,一次请求并行评估。
    ///   - apiKey: BYOK,逐次传入。
    func evaluate<State: Encodable>(
        state: State,
        model: String,
        questions: [String: TypeSafeQuestion],
        apiKey: String
    ) async throws -> TypeSafeSystemOneResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw TypeSafeClientError.missingAPIKey }

        let data = try encoder.encode(
            TypeSafeSystemOneRequestBody(state: state, model: model, questions: questions)
        )

        // path 常量来自 AppEndpoints(单一来源);基底用注入的 baseURL,
        // 测试可注入假域名拦截,不碰生产端点。
        let url = AppEndpoints.appendPath(
            AppEndpoints.TypeSafe.Paths.systemOne,
            to: baseURL
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        return try await sendWithRetry(request)
    }

    // MARK: - 传输与重试

    private func sendWithRetry(_ request: URLRequest) async throws -> TypeSafeSystemOneResponse {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request)
            } catch let error as TypeSafeClientError where error.isRetryableWithBackoff {
                guard attempt < Self.maxRetries else { throw error }
                let delay = Self.backoffDelay(after: attempt, retryHint: retryHint(from: error))
                attempt += 1
                // Task.sleep 抛 CancellationError 直接向上传播,
                // 让分组会话 / 批量队列的协作式取消立即生效。
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> TypeSafeSystemOneResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TypeSafeClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TypeSafeClientError.transport(String.l10n("network.error.invalidResponse"))
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(TypeSafeSystemOneResponse.self, from: data)
            } catch {
                throw TypeSafeClientError.decoding(error.localizedDescription)
            }
        case 401:
            throw TypeSafeClientError.unauthorized
        case 422:
            throw TypeSafeClientError.validation(Self.errorDetail(from: data))
        case 429:
            throw TypeSafeClientError.rateLimited(retryAfterSeconds: Self.retryAfter(from: http))
        case 529:
            throw TypeSafeClientError.overloaded(retryAfterSeconds: Self.retryAfter(from: http))
        default:
            throw TypeSafeClientError.server(statusCode: http.statusCode)
        }
    }

    private func retryHint(from error: TypeSafeClientError) -> Double? {
        switch error {
        case let .rateLimited(seconds), let .overloaded(seconds):
            return seconds
        default:
            return nil
        }
    }

    private static func backoffDelay(after attempt: Int, retryHint: Double?) -> Double {
        let exponential = backoffBaseSeconds * pow(2, Double(attempt))
        guard let retryHint, retryHint > exponential else { return exponential }
        return min(retryHint, 60)
    }

    /// Retry-After 只按秒数解析(官方返回秒);HTTP-date 形式退回指数退避。
    private static func retryAfter(from http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

    private static func errorDetail(from data: Data) -> String {
        struct ErrorBody: Decodable {
            let detail: String?
            let message: String?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return String(decoding: data.prefix(240), as: UTF8.self)
        }
        return body.detail ?? body.message ?? body.error ?? String(decoding: data.prefix(240), as: UTF8.self)
    }
}
