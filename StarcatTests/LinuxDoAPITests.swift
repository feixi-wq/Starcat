//
//  LinuxDoAPITests.swift
//  StarcatTests
//
//  离线验证 Discovery 路由、条件请求、协议版本和本地来源分页，不连接真实服务。
//

import Foundation
import Testing
@testable import Starcat

@Suite(.serialized)
struct LinuxDoAPITests {
    @Test func conditionalRequestAndProviderIsolation() async throws {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = { request in
            #expect(request.url?.path == "/api/v1/discovery/linuxdo/provenance")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "If-None-Match") == "version-one")
            return (HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: [:])!, Data())
        }
        let api = DiscoveryAPI(baseURL: URL(string: "https://linuxdo-api.test.invalid")!, apiKey: "test-key", session: URLProtocolStub.ephemeralSession())
        let provider = await api.linuxDoProviderIdentity()
        #expect(!provider.contains("test-key"))
        let response = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: "version-one")
        #expect(response.payload == nil)
        #expect(response.etag == "version-one")
        await api.updateAPIKey("other-key")
        #expect(await api.linuxDoProviderIdentity() != provider)
        await #expect(throws: CancellationError.self) { _ = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: nil) }
    }

    @Test func rejectsPartialAndUnsupportedResponses() async throws {
        for body in [
            #"{"schema_version":1,"data":{"revision":1,"generated_at":"","complete":true}}"#,
            #"{"schema_version":2,"data":{"revision":1,"generated_at":"","complete":true,"origins":[]}}"#,
            "<html>challenge</html>"
        ] {
            URLProtocolStub.reset()
            URLProtocolStub.requestHandler = { request in
                (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!, Data(body.utf8))
            }
            let api = DiscoveryAPI(baseURL: URL(string: "https://linuxdo-api.test.invalid")!, session: URLProtocolStub.ephemeralSession())
            let provider = await api.linuxDoProviderIdentity()
            await #expect(throws: (any Error).self) { _ = try await api.fetchLinuxDo(.provenance, providerID: provider, ifNoneMatch: nil) }
        }
    }

    @Test @MainActor func paginationAndPromotionOrderResetWithQueryIdentity() throws {
        let repos = try (1...95).map { id in
            let data = try JSONSerialization.data(withJSONObject: ["repo_id": id, "owner": "test", "name": "repo-\(id)", "full_name": "test/repo-\(id)", "stars": id, "forks": 0, "watchers": 0, "subscribers": 0, "open_issues": 0, "is_archived": false, "is_fork": false, "release_download_count": 0])
            return try JSONDecoder().decode(DiscoveryRepoDTO.self, from: data)
        }
        let model = LinuxDoListModel()
        model.reset(repositories: repos, promotionDates: ["1": "2026-10-15T00:00:00Z"], search: "", recentPromotionFirst: true, identity: "one")
        #expect(model.rows.count == 40)
        #expect(model.rows.first?.repoID == 1)
        model.loadMore(); model.loadMore(); model.loadMore()
        #expect(model.rows.count == 95)
        #expect(!model.hasMore)
        #expect(Set(model.rows.map(\.repoID)).count == 95)
        model.reset(repositories: repos, promotionDates: [:], search: "repo-9", recentPromotionFirst: false, identity: "two")
        #expect(model.rows.count == 7)
        #expect(model.rows.first?.repoID == 95)
        #expect(model.identity == "two")
    }
}
