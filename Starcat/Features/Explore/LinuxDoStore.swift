//
//  LinuxDoStore.swift
//  Starcat
//
//  主窗口共享公共来源索引。列表行只做 O(1) ID 查询，绝不逐行联网或上传 Stars 清单。
//

import Foundation
import Observation

/// UI 只发布当前服务身份的数据；取消、断网、坏快照保留上次有效缓存。
@MainActor @Observable
final class LinuxDoStore {
    var selectedSource: DiscoverySource = .catalog
    private(set) var providerID = ""
    private(set) var catalog: LinuxDoCachedSnapshot?
    private(set) var provenance: LinuxDoCachedSnapshot?
    private(set) var topicSnapshots: [Int64: LinuxDoCachedSnapshot] = [:]
    private(set) var loading: Set<LinuxDoResource> = []
    private(set) var failed: Set<LinuxDoResource> = []
    private var origins: [Int64: LinuxDoOrigin] = [:]
    private var verifiedDates: [Int64: Date] = [:]
    private let repository: LinuxDoRepository

    init(repository: LinuxDoRepository) { self.repository = repository }

    var repositories: [DiscoveryRepoDTO] { catalog?.payload.repositories ?? [] }
    var isRefreshingCatalog: Bool { loading.contains(.catalog) }

    /// 超过七天未验证索引，或三十天未验证关系时，不把历史事实冒充当前来源。
    func origin(for repoID: Int64, now: Date = Date()) -> LinuxDoOrigin? {
        guard let provenance, now.timeIntervalSince(provenance.checkedAt) <= 7 * 86400,
              let verified = verifiedDates[repoID], now.timeIntervalSince(verified) <= 30 * 86400 else { return nil }
        return origins[repoID]
    }

    func refreshProvenance(force: Bool = false) async {
        await load(.provenance, force: force)
        if selectedSource == .linuxDo, let catalog, let provenance,
           catalog.payload.revision < provenance.payload.revision {
            await load(.catalog, force: true)
        }
    }
    func refreshCatalog(force: Bool = false) async {
        async let index: Void = load(.provenance, force: force)
        await load(.catalog, force: force)
        await index
        // 两个端点独立缓存，但不能把已知较旧的目录/来源索引继续当作最新结果。
        if let catalog, let provenance {
            if catalog.payload.revision < provenance.payload.revision { await load(.catalog, force: true) }
            if provenance.payload.revision < catalog.payload.revision { await load(.provenance, force: true) }
        }
    }
    func refreshTopics(repoID: Int64, force: Bool = false) async { await load(.topics(repoID), force: force) }

    /// 设置页热切换立即清除 UI 旧身份，再加载新服务的磁盘缓存。旧请求仍由仓储合并收口。
    func providerDidChange() async {
        let identity = await repository.providerIdentity()
        adoptProvider(identity)
        await refreshProvenance()
    }

    private func adoptProvider(_ identity: String) {
        guard providerID != identity else { return }
        providerID = identity
        catalog = nil
        provenance = nil
        topicSnapshots = [:]
        origins = [:]
        verifiedDates = [:]
        loading = []
        failed = []
    }

    private func load(_ resource: LinuxDoResource, force: Bool) async {
        let identity = await repository.providerIdentity()
        guard !Task.isCancelled else { return }
        adoptProvider(identity)
        guard !loading.contains(resource) else { return }
        loading.insert(resource)
        defer { if providerID == identity { loading.remove(resource) } }
        var requiresRevalidation = force
        if let cached = await repository.cached(resource, providerID: identity), providerID == identity {
            if case .topics = resource, cached.payload.revision < (provenance?.payload.revision ?? -1) { requiresRevalidation = true }
            apply(cached, resource: resource)
        }
        do {
            let fresh = try await repository.refresh(resource, providerID: identity, force: requiresRevalidation)
            try Task.checkCancellation()
            guard providerID == identity else { return }
            if case .topics = resource, fresh.payload.revision < (provenance?.payload.revision ?? -1) { throw LinuxDoCacheError.obsoleteRevision }
            apply(fresh, resource: resource)
            failed.remove(resource)
        } catch {
            guard !Task.isCancelled, providerID == identity, !(error is CancellationError) else { return }
            failed.insert(resource)
        }
    }

    private func apply(_ snapshot: LinuxDoCachedSnapshot, resource: LinuxDoResource) {
        switch resource {
        case .catalog:
            guard snapshot.payload.revision >= (catalog?.payload.revision ?? -1) else { return }
            catalog = snapshot
        case .provenance:
            guard snapshot.payload.revision >= (provenance?.payload.revision ?? -1) else { return }
            provenance = snapshot
            origins = Dictionary(uniqueKeysWithValues: (snapshot.payload.origins ?? []).map { ($0.repoID, $0) })
            verifiedDates = origins.compactMapValues { LinuxDoPayload.date($0.verifiedAt) }
            // 已明确撤回的来源立即退出详情缓存，不等下一次点击刷新。
            topicSnapshots = topicSnapshots.filter { origins[$0.key] != nil && $0.value.payload.revision >= snapshot.payload.revision }
        case .topics(let id):
            guard snapshot.payload.revision >= max(topicSnapshots[id]?.payload.revision ?? -1, provenance?.payload.revision ?? -1) else { return }
            topicSnapshots[id] = snapshot
            if topicSnapshots.count > 64, let oldest = topicSnapshots.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key { topicSnapshots[oldest] = nil }
        }
    }
}

/// 本地分页状态独立于网络刷新；搜索/排序/来源身份改变后重新建立稳定 ID 顺序。
@MainActor @Observable
final class LinuxDoListModel {
    private(set) var rows: [DiscoveryRepoDTO] = []
    private(set) var total = 0
    private(set) var identity = ""
    private var matching: [DiscoveryRepoDTO] = []
    var hasMore: Bool { rows.count < matching.count }

    func reset(repositories: [DiscoveryRepoDTO], promotionDates: [String: String], search: String, recentPromotionFirst: Bool, identity: String) {
        self.identity = identity
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        matching = repositories.filter { term.isEmpty || $0.fullName.localizedCaseInsensitiveContains(term) || ($0.description?.localizedCaseInsensitiveContains(term) ?? false) }
        matching.sort { a, b in
            if recentPromotionFirst, promotionDates[String(a.repoID)] != promotionDates[String(b.repoID)] {
                return (promotionDates[String(a.repoID)] ?? "") > (promotionDates[String(b.repoID)] ?? "")
            }
            if a.stars != b.stars { return a.stars > b.stars }
            return a.repoID > b.repoID
        }
        total = matching.count
        rows = Array(matching.prefix(40))
    }

    func loadMore() {
        guard hasMore else { return }
        rows.append(contentsOf: matching.dropFirst(rows.count).prefix(40))
    }
}
