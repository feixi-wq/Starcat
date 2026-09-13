//
//  ForkRelationTests.swift
//  StarcatTests
//
//  Fork 详情分流、GraphQL compare 方向映射、Contribute URL。
//  这些是纯函数：方向一旦写反，Sync / Contribute 会跟 GitHub 网页横幅对不上。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Fork relation helpers")
struct ForkRelationTests {

    @Test("GraphQL compare 打在 fork 上时 ahead/behind 必须对调")
    func invertGraphQLCompare() {
        // 上游多 1217，fork 自己多 2 → GraphQL aheadBy=1217, behindBy=2
        let mapped = GitHubForkCompareMapping.uiAheadBehind(graphQLAheadBy: 1217, graphQLBehindBy: 2)
        #expect(mapped.ahead == 2)
        #expect(mapped.behind == 1217)
    }

    @Test("未登录或看别人的仓 → 打开 fork 页")
    func othersRepoOpensForkPage() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: true, repoOwner: "dong4j", currentLogin: nil)
            == .forkOthersRepo
        )
        #expect(
            RepoForkStatKindResolver.kind(isFork: false, repoOwner: "xuxueli", currentLogin: "dong4j")
            == .forkOthersRepo
        )
    }

    @Test("自己的原创仓 → 查看 forks 网络")
    func ownOriginalViewsNetwork() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: false, repoOwner: "Dong4j", currentLogin: "dong4j")
            == .viewOwnForks
        )
    }

    @Test("自己的 fork → 管理菜单")
    func ownForkShowsMenu() {
        #expect(
            RepoForkStatKindResolver.kind(isFork: true, repoOwner: "dong4j", currentLogin: "dong4j")
            == .manageOwnFork
        )
    }

    @Test("Contribute URL 使用 parent...fork 三段式 compare")
    func contributeURL() {
        let url = GitHubURLs.forkContribute(
            parentOwner: "xuxueli",
            parentRepo: "xxl-job",
            parentBranch: "master",
            forkOwner: "dong4j",
            forkRepo: "xxl-job",
            forkBranch: "master"
        )
        #expect(
            url.absoluteString
            == "https://github.com/xuxueli/xxl-job/compare/master...dong4j:xxl-job:master"
        )
    }

    @Test("落后时 needsSync，超前时 canContribute")
    func relationFlags() {
        let relation = GitHubForkRelation(
            parentFullName: "xuxueli/xxl-job",
            parentHTMLURL: GitHubURLs.repo(fullName: "xuxueli/xxl-job"),
            parentOwner: "xuxueli",
            parentRepoName: "xxl-job",
            parentDefaultBranch: "master",
            forkDefaultBranch: "master",
            aheadBy: 2,
            behindBy: 1217
        )
        #expect(relation.needsSync)
        #expect(relation.canContribute)
    }
}
