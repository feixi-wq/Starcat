//
//  TypeSafeDecisionServiceTests.swift
//  StarcatTests
//
//  覆盖 Labs POC 的 TypeSafe(Jev)链路:
//  - TypeSafeClient 的 wire contract(请求体 / 鉴权 / 错误映射 / 429 重试);
//  - TypeSafeDecisionService 的 Noul 扇出 → 建议映射(阈值过滤 / 避重 / 封闭集校验);
//  - 两个路由器的分流矩阵(手动走 Jev、自动与关闭走 LLM、Key 缺失回退)。
//
//  所有网络均由 URLProtocolStub 拦截,不依赖 api.typesafe.ai 实时状态。
//

import Testing
import Foundation
@testable import Starcat

// MARK: - Client wire contract

@Suite("TypeSafeClient", .serialized)
struct TypeSafeClientTests {
    private let baseURL = URL(string: "https://typesafe.test.invalid")!

    private func makeClient() -> TypeSafeClient {
        URLProtocolStub.reset()
        return TypeSafeClient(baseURL: baseURL, session: URLProtocolStub.ephemeralSession())
    }

    private func response(
        for request: URLRequest,
        status: Int,
        body: String,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    private let successBody = """
    {
      "model": "jev-1.13.0",
      "answers": {
        "q1": { "type": "noul", "noul": 0.87 },
        "q2": { "type": "choice", "choice": "b", "probabilities": { "a": 0.2, "b": 0.8 }, "confidence": 0.9 }
      },
      "usage": { "input_tokens": 312, "output_tokens": 48 }
    }
    """

    @Test("请求体携带 state/model/questions 与 Bearer Key")
    func requestContract() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        struct State: Encodable { let name: String }
        _ = try await client.evaluate(
            state: State(name: "starcat"),
            model: "jev-1.13.0",
            questions: [
                "q1": .noul(instructions: "Is it software?", criteria: TypeSafeNoulCriteria(true: "yes", false: "no"))
            ],
            apiKey: "tsk-test"
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.absoluteString == "https://typesafe.test.invalid/v1/systemone")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tsk-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let bodyObject = try #require(body)
        #expect((bodyObject["state"] as? [String: Any])?["name"] as? String == "starcat")
        #expect(bodyObject["model"] as? String == "jev-1.13.0")
        let questions = try #require(bodyObject["questions"] as? [String: Any])
        let q1 = try #require(questions["q1"] as? [String: Any])
        #expect(q1["type"] as? String == "noul")
        #expect(q1["instructions"] as? String == "Is it software?")
        let criteria = try #require(q1["criteria"] as? [String: Any])
        #expect(criteria["true"] as? String == "yes")
        #expect(criteria["false"] as? String == "no")
    }

    @Test("无 criteria 的 Noul 问题不编码 criteria 键")
    func noulCriteriaOptional() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        _ = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )

        let request = try #require(URLProtocolStub.receivedRequests.first)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let questions = try #require(body?["questions"] as? [String: Any])
        let q1 = try #require(questions["q1"] as? [String: Any])
        #expect(q1["criteria"] == nil)
    }

    @Test("空 API Key 直接抛 missingAPIKey,不发网络请求")
    func emptyKeyRejected() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }
        await #expect(throws: TypeSafeClientError.missingAPIKey) {
            _ = try await client.evaluate(
                state: "demo",
                model: "jev-1.13.0",
                questions: [:],
                apiKey: "   "
            )
        }
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("响应解码 Noul 概率 / Choice 分布 / usage")
    func responseDecoding() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 200, body: self.successBody)
        }

        let response = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )

        #expect(response.answers["q1"]?.noul == 0.87)
        #expect(response.answers["q2"]?.probabilities?["b"] == 0.8)
        #expect(response.usage?.inputTokens == 312)
    }

    @Test("401 映射为 unauthorized")
    func unauthorizedMapping() async throws {
        let client = makeClient()
        URLProtocolStub.requestHandler = { request in
            self.response(for: request, status: 401, body: #"{"error":"invalid key"}"#)
        }
        await #expect(throws: TypeSafeClientError.unauthorized) {
            _ = try await client.evaluate(
                state: "demo", model: "jev-1.13.0", questions: [:], apiKey: "tsk-test"
            )
        }
    }

    @Test("429 后按退避重试,恢复后成功")
    func retriesAfterRateLimit() async throws {
        let client = makeClient()
        let counter = RequestCounter()
        URLProtocolStub.requestHandler = { request in
            counter.increment()
            if counter.value <= 1 {
                return self.response(for: request, status: 429, body: "{}")
            }
            return self.response(for: request, status: 200, body: self.successBody)
        }

        let response = try await client.evaluate(
            state: "demo",
            model: "jev-1.13.0",
            questions: ["q1": .noul(instructions: "demo", criteria: nil)],
            apiKey: "tsk-test"
        )
        #expect(response.answers["q1"]?.noul == 0.87)
        #expect(URLProtocolStub.receivedRequests.count == 2)
    }
}

/// URLProtocol 的 handler 闭包是 @Sendable,用锁计数器跨隔离记录次数。
private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

// MARK: - Service 映射

@MainActor
@Suite("TypeSafeDecisionService", .serialized)
struct TypeSafeDecisionServiceTests {

    private var defaults: UserDefaults {
        let suite = UserDefaults(suiteName: "TypeSafeDecisionServiceTests")!
        suite.removePersistentDomain(forName: "TypeSafeDecisionServiceTests")
        return suite
    }

    private func makeService(
        settings: AppSettings,
        keychain: InMemoryKeychain
    ) throws -> TypeSafeDecisionService {
        URLProtocolStub.reset()
        let database = try InMemoryDatabaseManager()
        return TypeSafeDecisionService(
            client: TypeSafeClient(
                baseURL: URL(string: "https://typesafe.test.invalid")!,
                session: URLProtocolStub.ephemeralSession()
            ),
            settings: settings,
            readmeRepository: ReadmeRepository(database: database),
            keychain: keychain
        )
    }

    private func storeKey(_ key: InMemoryKeychain) throws {
        try key.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
    }

    private func stubAnswers(_ json: String) {
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    private func questionKeysOfLastRequest() throws -> [String] {
        let request = try #require(URLProtocolStub.receivedRequests.last)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        return Array((body?["questions"] as? [String: Any])?.keys ?? [:].keys)
    }

    private func makeCandidate(id: String, name: String, instruction: String) -> GitHubStarListAIContext {
        GitHubStarListAIContext(listId: id, name: name, instruction: instruction, autoApplyEnabled: false)
    }

    // MARK: 分组

    @Test("分组:过阈值概率生成建议,低概率被过滤,产出经封闭集校验")
    func groupingMapsProbabilities() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "list::ml": { "type": "noul", "noul": 0.9 },
            "list::web": { "type": "noul", "noul": 0.4 }
          },
          "usage": { "input_tokens": 100, "output_tokens": 2 }
        }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [
                makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools"),
                makeCandidate(id: "web", name: "Web", instruction: "frontend projects")
            ],
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )

        let suggestions = try #require(results[1])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].listId == "ml")
        #expect(abs(suggestions[0].confidence - 0.9) < 0.0001)
        #expect(suggestions[0].reason.hasPrefix("Jev P="))
    }

    @Test("分组:已有 membership 的 List 不进入问题集")
    func groupingSkipsExistingMemberships() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        { "model": "jev-1.13.0", "answers": { "list::ml": { "type": "noul", "noul": 0.9 } } }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [
                makeCandidate(id: "ml", name: "ML", instruction: "machine learning tools"),
                makeCandidate(id: "web", name: "Web", instruction: "frontend projects")
            ],
            existingListIDsByRepo: [1: ["ml"]],
            existingListNamesByRepo: [1: ["ML"]]
        )

        let keys = try questionKeysOfLastRequest()
        #expect(keys == ["list::web"])
    }

    @Test("分组:空 instruction 的 List 不是候选")
    func groupingIgnoresEmptyInstruction() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        // 全部候选 instruction 为空:直接返回空结果,不发网络请求。
        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateGitHubListSuggestions(
            for: [repo],
            candidates: [makeCandidate(id: "ml", name: "ML", instruction: "  ")],
            existingListIDsByRepo: [1: []],
            existingListNamesByRepo: [1: []]
        )
        #expect(results.isEmpty)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    // MARK: 标签

    @Test("标签:按概率生成建议并截断到数量上限")
    func tagsMapAndCap() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        {
          "model": "jev-1.13.0",
          "answers": {
            "tag::ai": { "type": "noul", "noul": 0.9 },
            "tag::cli": { "type": "noul", "noul": 0.8 },
            "tag::unrelated": { "type": "noul", "noul": 0.3 },
            "tag::swift": { "type": "noul", "noul": 0.7 }
          },
          "usage": { "input_tokens": 100, "output_tokens": 4 }
        }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [
                1: AITagHints(repoTags: [], libraryTags: ["ai", "cli", "unrelated", "swift"])
            ]
        )

        let suggestions = try #require(results[1])
        // 默认上限 3:ai(0.9)/cli(0.8)/swift(0.7) 入选;unrelated(0.3) 低于 0.5 下限被过滤。
        #expect(suggestions.map(\.name) == ["ai", "cli", "swift"])
        #expect(suggestions.map(\.confidence) == [0.9, 0.8, 0.7])
    }

    @Test("标签:repo 已有标签不再进入问题集")
    func tagsExcludeRepoOwnTags() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        stubAnswers("""
        { "model": "jev-1.13.0", "answers": { "tag::cli": { "type": "noul", "noul": 0.9 } } }
        """)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        _ = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [
                1: AITagHints(repoTags: ["AI"], libraryTags: ["ai", "cli"])
            ]
        )

        // "AI" 与 "ai" 是同一 canonical key,视为 repo 已有,不再询问。
        #expect(try questionKeysOfLastRequest() == ["tag::cli"])
    }

    @Test("标签:词表为空时返回空建议且不发请求")
    func tagsEmptyVocabulary() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        try storeKey(keychain)

        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        let results = try await service.generateBatchTagSuggestions(
            for: [repo],
            tagHintsByRepoID: [1: .empty]
        )
        #expect(results[1] == [])
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("Key 未配置时 canResolveAPIKey 为 false")
    func keyResolution() async throws {
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        let service = try makeService(settings: settings, keychain: keychain)
        #expect(!service.canResolveAPIKey())
        try storeKey(keychain)
        #expect(service.canResolveAPIKey())
    }
}

// MARK: - 路由矩阵

@MainActor
@Suite("TypeSafeSuggestionRouters", .serialized)
struct TypeSafeSuggestionRoutersTests {

    private final class RecordingListProvider: GitHubStarListSuggestionProviding {
        private(set) var callCount = 0
        func generateGitHubListSuggestions(
            for repos: [Repo],
            candidates: [GitHubStarListAIContext],
            existingListIDsByRepo: [Int64: Set<String>],
            existingListNamesByRepo: [Int64: [String]]
        ) async throws -> [Int64: [GitHubStarListAISuggestion]] {
            callCount += 1
            return [:]
        }
    }

    private final class RecordingBatchProvider: BatchAIInsightProviding {
        private(set) var tagCallCount = 0
        private(set) var insightCallCount = 0
        var preflightShouldThrow = false

        func ensureGenerationClientsReady(includeSummary: Bool, includeTags: Bool) throws {
            if preflightShouldThrow { throw CocoaError(.userActivityConnectionUnavailable) }
        }

        func generateBatchTagSuggestions(
            for repos: [Repo],
            tagHintsByRepoID: [Int64: AITagHints]
        ) async throws -> [Int64: [AITagSuggestion]] {
            tagCallCount += 1
            return [:]
        }

        func generateBatchInsight(
            for repo: Repo,
            existingTagHints: AITagHints,
            includeSummary: Bool,
            includeTags: Bool,
            codeContextEnabledOverride: Bool?,
            externalContextEnabledOverride: Bool?
        ) async throws -> RepoAIInsightGeneration {
            insightCallCount += 1
            throw CocoaError(.userActivityConnectionUnavailable)
        }
    }

    private func makeSettings(
        keychain: InMemoryKeychain,
        enabled: Bool,
        grouping: Bool,
        tags: Bool
    ) -> AppSettings {
        let suite = UserDefaults(suiteName: "TypeSafeSuggestionRoutersTests")!
        suite.removePersistentDomain(forName: "TypeSafeSuggestionRoutersTests")
        let settings = AppSettings(defaults: suite, keychain: keychain)
        settings.typesafeDecisionEnabled = enabled
        settings.typesafeGroupingSuggestionsEnabled = grouping
        settings.typesafeTagSuggestionsEnabled = tags
        return settings
    }

    private func makeJevStubService(settings: AppSettings, keychain: InMemoryKeychain) throws -> TypeSafeDecisionService {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"model":"jev-1.13.0","answers":{}}"#.utf8))
        }
        let database = try InMemoryDatabaseManager()
        return TypeSafeDecisionService(
            client: TypeSafeClient(
                baseURL: URL(string: "https://typesafe.test.invalid")!,
                session: URLProtocolStub.ephemeralSession()
            ),
            settings: settings,
            readmeRepository: ReadmeRepository(database: database),
            keychain: keychain
        )
    }

    private var sampleRepos: [Repo] {
        var repo = Repo.makeMinimal(owner: "acme", name: "r1")
        repo.id = 1
        return [repo]
    }

    // MARK: 分组路由

    @Test("手动 + 总开关开 + 有 Key → 分组走 Jev")
    func groupingRoutesToTypesafeWhenManualAndEnabled() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let llm = RecordingListProvider()
        let router = TypeSafeGitHubListSuggestionRouter(
            llmProvider: llm,
            typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
            settings: settings,
            isManualInvocation: { true }
        )

        _ = try await router.generateGitHubListSuggestions(
            for: sampleRepos,
            candidates: [
                GitHubStarListAIContext(
                    listId: "ml", name: "ML", instruction: "machine learning tools", autoApplyEnabled: false
                )
            ],
            existingListIDsByRepo: [:],
            existingListNamesByRepo: [:]
        )
        #expect(llm.callCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("非手动上下文(自动整理) → 分组走 LLM")
    func groupingFallsBackWhenAutomatic() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let llm = RecordingListProvider()
        let router = TypeSafeGitHubListSuggestionRouter(
            llmProvider: llm,
            typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
            settings: settings,
            isManualInvocation: { false }
        )

        _ = try await router.generateGitHubListSuggestions(
            for: sampleRepos, candidates: [], existingListIDsByRepo: [:], existingListNamesByRepo: [:]
        )
        #expect(llm.callCount == 1)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("总开关关 / Key 缺失 → 分组走 LLM")
    func groupingFallsBackWhenDisabledOrKeyless() async throws {
        // 关:开关关但 Key 在
        do {
            let keychain = InMemoryKeychain()
            try keychain.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
            let settings = makeSettings(keychain: keychain, enabled: false, grouping: true, tags: true)
            let llm = RecordingListProvider()
            let router = TypeSafeGitHubListSuggestionRouter(
                llmProvider: llm,
                typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings,
                isManualInvocation: { true }
            )
            _ = try await router.generateGitHubListSuggestions(
                for: sampleRepos, candidates: [], existingListIDsByRepo: [:], existingListNamesByRepo: [:]
            )
            #expect(llm.callCount == 1)
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }

        // 无 Key:开关开但没有 Key
        do {
            let keychain = InMemoryKeychain()
            let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
            let llm = RecordingListProvider()
            let router = TypeSafeGitHubListSuggestionRouter(
                llmProvider: llm,
                typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings,
                isManualInvocation: { true }
            )
            _ = try await router.generateGitHubListSuggestions(
                for: sampleRepos, candidates: [], existingListIDsByRepo: [:], existingListNamesByRepo: [:]
            )
            #expect(llm.callCount == 1)
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }
    }

    // MARK: 批量洞察路由

    @Test("纯标签批量 + Jev 生效 → 走 Jev 且跳过 LLM 预检")
    func batchTagsRouteAndPreflightBypass() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
        let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
        let base = RecordingBatchProvider()
        base.preflightShouldThrow = true
        let router = TypeSafeBatchAIInsightRouter(
            base: base,
            typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
            settings: settings
        )

        // LLM Provider 未就绪(会抛错)时,纯标签预检被跳过,不再阻断批量启动。
        #expect(throws: Never.self) {
            try router.ensureGenerationClientsReady(includeSummary: false, includeTags: true)
        }
        // 含摘要的组合仍透传既有预检语义。
        #expect(throws: CocoaError.self) {
            try router.ensureGenerationClientsReady(includeSummary: true, includeTags: true)
        }
    }

    @Test("标签批量路由到 Jev;开关关回退 LLM")
    func batchTagsRoutingMatrix() async throws {
        // 开:走 Jev
        do {
            let keychain = InMemoryKeychain()
            try keychain.storeServiceAPIKey("tsk-test", forService: TypeSafeDecisionService.keychainServiceID)
            let settings = makeSettings(keychain: keychain, enabled: true, grouping: true, tags: true)
            let base = RecordingBatchProvider()
            let router = TypeSafeBatchAIInsightRouter(
                base: base,
                typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateBatchTagSuggestions(for: sampleRepos, tagHintsByRepoID: [1: .empty])
            #expect(base.tagCallCount == 0)
            #expect(URLProtocolStub.receivedRequests.isEmpty) // 空词表短路,未发请求
        }

        // 关:走 LLM
        do {
            let keychain = InMemoryKeychain()
            let settings = makeSettings(keychain: keychain, enabled: false, grouping: false, tags: false)
            let base = RecordingBatchProvider()
            let router = TypeSafeBatchAIInsightRouter(
                base: base,
                typesafeProvider: try makeJevStubService(settings: settings, keychain: keychain),
                settings: settings
            )
            _ = try await router.generateBatchTagSuggestions(for: sampleRepos, tagHintsByRepoID: [1: .empty])
            #expect(base.tagCallCount == 1)
            #expect(URLProtocolStub.receivedRequests.isEmpty)
        }
    }
}
