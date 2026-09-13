//
//  AnthropicMessagesCodecTests.swift
//  StarcatTests
//
//  覆盖历史 tool 合并、jsonObject 强制 tool、max_tokens 钳制、stop_reason 映射。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnthropicMessagesCodec")
struct AnthropicMessagesCodecTests {
    @Test("system 为空则省略，单轮 user 进入 messages")
    func systemAndSingleUser() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "You are helpful",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        #expect(object["system"] as? String == "You are helpful")
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "hi")
    }

    @Test("相邻两条 tool 结果合并成一条 user 含两个 tool_result")
    func mergesConsecutiveToolResults() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "",
                history: [
                    .init(role: .user, content: "search"),
                    .init(
                        role: .assistant,
                        toolCalls: [
                            .init(id: "call-1", name: "external_search", arguments: "{\"query\":\"Swift\"}"),
                            .init(id: "call-2", name: "external_search", arguments: "{\"query\":\"Combine\"}")
                        ]
                    ),
                    .init(role: .tool, content: "{\"items\":[]}", toolCallID: "call-1"),
                    .init(role: .tool, content: "{\"items\":[1]}", toolCallID: "call-2")
                ],
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.contains { $0["role"] as? String == "tool" } == false)
        let userWithTools = try #require(messages.last)
        #expect(userWithTools["role"] as? String == "user")
        let blocks = try #require(userWithTools["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["type"] as? String == "tool_result")
        #expect(blocks[0]["tool_use_id"] as? String == "call-1")
        #expect(blocks[1]["tool_use_id"] as? String == "call-2")
    }

    @Test("tool 缺 id 抛 invalidChatHistory")
    func missingToolCallID() {
        #expect(throws: AIClientError.self) {
            _ = try AnthropicMessagesCodec.requestJSONObject(
                AIChatRequest(
                    systemPrompt: "",
                    userPrompt: "",
                    history: [.init(role: .tool, content: "{}")],
                    model: "claude-sonnet-4-5",
                    parameters: .summaryDefault
                ),
                stream: false
            )
        }
    }

    @Test("jsonObject 注入 starcat_json_result 并强制 tool_choice")
    func jsonObjectForcedTool() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "return json",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault,
                responseFormat: .jsonObject
            ),
            stream: false
        )
        let tools = try #require(object["tools"] as? [[String: Any]])
        #expect(tools.contains { $0["name"] as? String == AnthropicMessagesCodec.jsonResultToolName })
        let choice = try #require(object["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == AnthropicMessagesCodec.jsonResultToolName)
    }

    @Test("max_tokens 128K 被钳成 32768")
    func clampsMaxTokens() throws {
        let object = try AnthropicMessagesCodec.requestJSONObject(
            AIChatRequest(
                systemPrompt: "",
                userPrompt: "hi",
                model: "claude-sonnet-4-5",
                parameters: .summaryDefault
            ),
            stream: false
        )
        #expect(object["max_tokens"] as? Int == 32_768)
    }

    @Test("stop_reason=max_tokens 映射 responseTruncated")
    func truncatedStopReason() throws {
        let data = Data(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens","model":"claude-sonnet-4-5"}"#.utf8)
        #expect(throws: AIClientError.responseTruncated) {
            _ = try AnthropicMessagesCodec.decodeMessageResponse(data, fallbackModel: "claude-sonnet-4-5")
        }
    }

    @Test("starcat_json_result 进入 content 而不进入 toolCalls")
    func jsonResultUnwrapped() throws {
        let data = Data(#"""
        {
          "content": [
            {
              "type": "tool_use",
              "id": "toolu-1",
              "name": "starcat_json_result",
              "input": {"hello": "world"}
            }
          ],
          "stop_reason": "tool_use",
          "model": "claude-sonnet-4-5",
          "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """#.utf8)
        let response = try AnthropicMessagesCodec.decodeMessageResponse(
            data,
            fallbackModel: "claude-sonnet-4-5"
        )
        #expect(response.toolCalls.isEmpty)
        #expect(response.content.contains("hello"))
        #expect(response.usage?.totalTokens == 15)
    }
}
