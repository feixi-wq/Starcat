//
//  RepositoryContributorHeroViewModelTests.swift
//  StarcatTests
//
//  验证详情 Hero 贡献者列的 cache-first、溢出人数与占比条口径。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Repository contributor hero")
struct RepositoryContributorHeroViewModelTests {
    @Test("超过 3 人时溢出人数是样本人数减 3")
    func overflowCountUsesSampleMinusVisible() {
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 0) == 0)
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 3) == 0)
        #expect(RepositoryContributorHeroViewModel.overflowCount(total: 12) == 9)
    }

    @Test("占比条以样本内最高 commits 为 100%")
    func shareScalesToMaximumInSample() {
        #expect(RepositoryContributorHeroViewModel.share(commits: 50, maximum: 100) == 0.5)
        #expect(RepositoryContributorHeroViewModel.share(commits: 100, maximum: 100) == 1)
        #expect(RepositoryContributorHeroViewModel.share(commits: 10, maximum: 0) == 0)
    }

    @Test("新鲜缓存直接上屏且不刷新网络")
    func freshCacheSkipsRefresh() async {
        let cachedPeople = [
            contributor("alpha", commits: 20),
            contributor("beta", commits: 8),
            contributor("gamma", commits: 3),
            contributor("delta", commits: 1)
        ]
        let service = ContributorHeroServiceStub(
            cached: cachedInsight(cachedPeople, isStale: false),
            refreshed: insight([contributor("network", commits: 99)])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 11), isAuthenticated: true)

        #expect(viewModel.contributors.map(\.login) == ["alpha", "beta", "gamma", "delta"])
        #expect(viewModel.visibleAvatars.map(\.login) == ["alpha", "beta", "gamma"])
        #expect(viewModel.overflowCount == 1)
        #expect(await service.refreshCount == 0)
    }

    @Test("过期缓存先上屏再被网络结果替换")
    func staleCacheRefreshes() async {
        let service = ContributorHeroServiceStub(
            cached: cachedInsight([contributor("old", commits: 1)], isStale: true),
            refreshed: insight([
                contributor("fresh", commits: 40),
                contributor("other", commits: 2)
            ])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 12), isAuthenticated: true)

        #expect(viewModel.contributors.map(\.login) == ["fresh", "other"])
        #expect(await service.refreshCount == 1)
    }

    @Test("门禁拒绝时不发请求并隐藏列")
    func accessDeniedHidesColumn() async {
        let service = ContributorHeroServiceStub(
            allowLoad: false,
            cached: cachedInsight([contributor("hidden", commits: 9)], isStale: false),
            refreshed: insight([contributor("network", commits: 1)])
        )
        let viewModel = RepositoryContributorHeroViewModel(service: service)

        await viewModel.load(repo: makeRepo(id: 13), isAuthenticated: false)

        #expect(viewModel.contributors.isEmpty)
        #expect(viewModel.shouldShowColumn == false)
        #expect(await service.refreshCount == 0)
        #expect(await service.cacheCount == 0)
    }

    private func contributor(_ login: String, commits: Int) -> RepositoryContributor {
        RepositoryContributor(
            id: login,
            login: login,
            commits: commits,
            colorName: "purple"
        )
    }

    private func insight(_ contributors: [RepositoryContributor]) -> RepositoryContributorsInsight {
        RepositoryContributorsInsight(contributors: contributors, generatedAt: Date(timeIntervalSince1970: 1_000))
    }

    private func cachedInsight(
        _ contributors: [RepositoryContributor],
        isStale: Bool
    ) -> RepositoryCachedContributorsInsight {
        RepositoryCachedContributorsInsight(
            value: insight(contributors),
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            isStale: isStale
        )
    }

    private func makeRepo(id: Int64) -> Repo {
        Repo(
            id: id,
            owner: "tasselx",
            name: "Keyden",
            fullName: "tasselx/Keyden",
            description: nil,
            language: "Swift",
            starsCount: 1,
            forksCount: 0,
            watchersCount: 1,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/tasselx/Keyden",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }
}

private actor ContributorHeroServiceStub: RepositoryContributorHeroServing {
    let allowLoad: Bool
    let cached: RepositoryCachedContributorsInsight?
    let refreshed: RepositoryContributorsInsight
    private(set) var refreshCount = 0
    private(set) var cacheCount = 0

    init(
        allowLoad: Bool = true,
        cached: RepositoryCachedContributorsInsight?,
        refreshed: RepositoryContributorsInsight
    ) {
        self.allowLoad = allowLoad
        self.cached = cached
        self.refreshed = refreshed
    }

    func allowsLoad(repo: Repo, isAuthenticated: Bool) async -> Bool {
        allowLoad
    }

    func cachedContributors(repoID: Int64) async throws -> RepositoryCachedContributorsInsight? {
        cacheCount += 1
        return cached
    }

    func refreshContributors(
        repository: RepoIdentity,
        ifNoneMatch: String?
    ) async throws -> RepositoryContributorsInsight {
        refreshCount += 1
        return refreshed
    }
}
