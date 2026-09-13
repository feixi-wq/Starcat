//
//  AnthropicEndpoint.swift
//  Starcat
//
//  把用户填写的 Anthropic / `*/anthropic` Base URL 归一成 messages 与 models 端点。
//
//  为什么单独抽出来：
//  - 官方入口是 `https://api.anthropic.com`，中转常见 `https://api.deepseek.com/anthropic`。
//  - 若把 `/anthropic` 误改成 OpenAI 的 `/v1`，请求会打到 Completions，连接测试必失败。
//
//  关键约束：
//  - 只剥末尾 `/`，不改写 path 中的 `/anthropic`。
//  - path 已以 `/v1` 结尾时只再拼 `/messages` 与 `/models`，避免 `/v1/v1/...`。
//

import Foundation

/// Anthropic Messages API 的归一化端点。
struct AnthropicEndpoint: Equatable, Sendable {
    let messagesURL: URL
    let modelsURL: URL
    let normalizedBaseURL: String

    /// 将用户输入的 Base URL 归一成可请求的 messages / models URL。
    ///
    /// - Throws: `AIClientError.invalidBaseURL`（空串、缺 scheme、缺 host、非 http(s)）。
    static func normalize(baseURL: String) throws -> AnthropicEndpoint {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              host.isEmpty == false
        else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        let path = url.path
        let alreadyV1 = path == "/v1" || path.hasSuffix("/v1")
        let messagesString = alreadyV1 ? "\(trimmed)/messages" : "\(trimmed)/v1/messages"
        let modelsString = alreadyV1 ? "\(trimmed)/models" : "\(trimmed)/v1/models"
        guard let messagesURL = URL(string: messagesString),
              let modelsURL = URL(string: modelsString)
        else {
            throw AIClientError.invalidBaseURL(baseURL)
        }

        return AnthropicEndpoint(
            messagesURL: messagesURL,
            modelsURL: modelsURL,
            normalizedBaseURL: trimmed
        )
    }
}
