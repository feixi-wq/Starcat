//
//  LinuxDoRepositoryTests.swift
//  StarcatTests
//
//  离线验证来源缓存与分页契约；所有文件都在临时目录，不连接 Linux.do 或真实后端。
//

import Foundation
import Testing
@testable import Starcat

struct LinuxDoRepositoryTests {
    @Test func conditionalRefreshPersistsValidEmptySnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        let first = try await repository.refresh(.provenance, providerID: "one")
        #expect(first.payload.origins == [])
        await api.setResponse(LinuxDoResponse(payload: nil, etag: "v1"))
        let second = try await repository.refresh(.provenance, providerID: "one", force: true)
        #expect(second.payload.revision == 1)
        #expect(await api.lastETag == "v1")
        let restored = LinuxDoRepository(api: api, directory: directory)
        #expect(await restored.cached(.provenance, providerID: "one")?.payload.origins == [])
    }

    @Test func concurrentRefreshCoalescesAndTTLDoesNotRequestAgain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        async let a = repository.refresh(.provenance, providerID: "one")
        async let b = repository.refresh(.provenance, providerID: "one")
        _ = try await (a, b)
        _ = try await repository.refresh(.provenance, providerID: "one")
        #expect(await api.calls == 1)
    }

    @Test func failureAndOlderRevisionKeepLastGoodBodyAndETag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let repository = LinuxDoRepository(api: api, directory: directory)
        _ = try await repository.refresh(.provenance, providerID: "one")
        await api.setFailure(true)
        do { _ = try await repository.refresh(.provenance, providerID: "one", force: true); Issue.record("Expected failure") } catch {}
        await api.setFailure(false)
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 0, generatedAt: "", complete: true, origins: []), etag: "old"))
        do { _ = try await repository.refresh(.provenance, providerID: "one", force: true); Issue.record("Accepted older revision") } catch {}
        #expect(await repository.cached(.provenance, providerID: "one")?.etag == "v1")
        #expect(await repository.cached(.provenance, providerID: "two") == nil)
    }

    @Test func missingAndPartialBodiesCannotEraseSnapshot() throws {
        let partial = LinuxDoPayload(revision: 2, generatedAt: "", complete: false, origins: [])
        #expect(throws: (any Error).self) { try partial.validate(for: .provenance) }
        let absent = LinuxDoPayload(revision: 2, generatedAt: "", complete: true)
        #expect(throws: (any Error).self) { try absent.validate(for: .provenance) }
        let badURL = LinuxDoTopic(id: 1, url: "https://evil.example/", title: "Spoof", publishedAt: "", verifiedAt: "")
        #expect(badURL.safeURL == nil)
    }

    @Test @MainActor func switchingProviderClearsOldOriginsWithoutNetworkFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = LinuxDoAPIFake()
        let verified = ISO8601DateFormatter.shared.string(from: Date())
        await api.setResponse(LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: [LinuxDoOrigin(repoID: 42, topicCount: 2, verifiedAt: verified)]), etag: "v1"))
        let store = LinuxDoStore(repository: LinuxDoRepository(api: api, directory: directory))
        await store.refreshProvenance()
        #expect(store.origin(for: 42)?.topicCount == 2)
        await api.switchProvider("two")
        await api.setFailure(true)
        await store.providerDidChange()
        #expect(store.origin(for: 42) == nil)
        #expect(store.providerID == "two")
    }
}

/// 可控异步替身，用短暂挂起制造真实 actor 重入窗口，不依赖外部网络时序。
private actor LinuxDoAPIFake: LinuxDoAPIProtocol {
    var calls = 0
    var lastETag: String?
    private var provider = "one"
    private var fails = false
    private var response = LinuxDoResponse(payload: LinuxDoPayload(revision: 1, generatedAt: "", complete: true, origins: []), etag: "v1")
    func linuxDoProviderIdentity() -> String { provider }
    func setResponse(_ response: LinuxDoResponse) { self.response = response }
    func setFailure(_ value: Bool) { fails = value }
    func switchProvider(_ value: String) { provider = value }
    func fetchLinuxDo(_ resource: LinuxDoResource, providerID: String, ifNoneMatch: String?) async throws -> LinuxDoResponse {
        calls += 1
        lastETag = ifNoneMatch
        try await Task.sleep(nanoseconds: 30_000_000)
        if fails { throw URLError(.notConnectedToInternet) }
        return response
    }
}
