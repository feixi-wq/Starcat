//
//  ForkAPI.swift
//  Starcat
//
//  自己的 fork：上游身份、主分支差距、Sync fork。
//
//  为什么单独拆文件：
//  - 详情页 Forks 数字不能再一律打开 `/fork`。自己的仓无法再 fork 给自己；
//    自己的 fork 需要「上游 + Contribute + Sync」，和 Watch 订阅不是同一组端点。
//  - parent 只出现在 `GET /repos/{owner}/{repo}`。列表同步拿到的只有 `is_fork`，
//    不能靠本地库判断 fork 自谁，必须打开详情后再拉。
//  - ahead/behind 不用 REST compare：落后上千 commit 时 REST 会带 files + commits，
//    payload 可能到数十 MB。GraphQL `ref.compare` 只取两个整数。
//
//  GraphQL 方向（必须写进注释，避免以后改反）：
//  查询打在 **fork** 上，`headRef` 是上游 `owner:repo:branch`。此时
//  `aheadBy` = 上游比 fork 多的 commit = UI 的 behind；
//  `behindBy` = fork 比上游多的 commit = UI 的 ahead。
//  映射见 `GitHubForkCompareMapping`。
//

import Foundation

/// 详情页 Forks 数字该干什么。按「当前用户是不是这个仓的 owner」分流，不按侧栏。
enum RepoForkStatKind: Equatable, Sendable {
    /// 别人的仓：打开 GitHub fork 向导。
    case forkOthersRepo
    /// 自己的原创仓：打开 forks 网络页，不再 fork 自己。
    case viewOwnForks
    /// 自己的、fork 自别人的仓：弹出上游 / Contribute / Sync 菜单。
    case manageOwnFork
}

/// 一次详情打开拿到的 fork 快照。ahead/behind 失败时为 nil，上游身份仍可用。
struct GitHubForkRelation: Equatable, Sendable {
    let parentFullName: String
    let parentHTMLURL: URL
    let parentOwner: String
    let parentRepoName: String
    let parentDefaultBranch: String
    let forkDefaultBranch: String
    let aheadBy: Int?
    let behindBy: Int?

    var needsSync: Bool { (behindBy ?? 0) > 0 }
    var canContribute: Bool { (aheadBy ?? 0) > 0 }
}

/// `POST .../merge-upstream` 成功体。
struct GitHubMergeUpstreamResult: Equatable, Sendable {
    let message: String
    let mergeType: String
    let baseBranch: String?
}

enum GitHubForkRelationError: Error, Equatable {
    /// GET /repos 成功但不是 fork，或 parent 缺失（上游已删 / 变成不可见）。
    case parentUnavailable
}

/// 把 GraphQL compare 转成 GitHub 网页那句 “N commits ahead / behind”。
enum GitHubForkCompareMapping {
    static func uiAheadBehind(graphQLAheadBy: Int, graphQLBehindBy: Int) -> (ahead: Int, behind: Int) {
        (ahead: graphQLBehindBy, behind: graphQLAheadBy)
    }
}

enum RepoForkStatKindResolver {
    /// owner login 与当前用户大小写不敏感；未登录按「别人的仓」处理。
    static func kind(isFork: Bool, repoOwner: String, currentLogin: String?) -> RepoForkStatKind {
        guard let currentLogin,
              repoOwner.compare(currentLogin, options: .caseInsensitive) == .orderedSame else {
            return .forkOthersRepo
        }
        return isFork ? .manageOwnFork : .viewOwnForks
    }
}

extension GitHubAPIClient {

    func forkRelation(owner: String, repo: String) async throws -> GitHubForkRelation {
        let dto = try await self.repo(owner: owner, repo: repo)
        guard dto.fork, let parent = dto.parent else {
            throw GitHubForkRelationError.parentUnavailable
        }
        let parentOwner = parent.ownerLogin
        let parentRepoName = parent.repoName
        guard !parentOwner.isEmpty, !parentRepoName.isEmpty else {
            throw GitHubForkRelationError.parentUnavailable
        }

        let parentURL = URL(string: parent.htmlUrl) ?? GitHubURLs.repo(fullName: parent.fullName)
        let forkBranch = dto.defaultBranch ?? parent.defaultBranch ?? "main"
        let parentBranch = parent.defaultBranch ?? forkBranch

        var aheadBy: Int?
        var behindBy: Int?
        do {
            let payload = try await graphql(
                query: Self.forkCompareQuery,
                variables: [
                    "owner": owner,
                    "name": repo,
                    "headRef": "\(parentOwner):\(parentRepoName):\(parentBranch)"
                ],
                as: ForkCompareGraphQL.self
            )
            if let comparison = payload.repository?.defaultBranchRef?.compare {
                let mapped = GitHubForkCompareMapping.uiAheadBehind(
                    graphQLAheadBy: comparison.aheadBy,
                    graphQLBehindBy: comparison.behindBy
                )
                aheadBy = mapped.ahead
                behindBy = mapped.behind
            }
        } catch {
            // 上游私有、默认分支改名、空仓库都会让 compare 失败；身份仍然要展示。
            AppLog.network.error(
                "Fork compare failed for \(owner, privacy: .public)/\(repo, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }

        return GitHubForkRelation(
            parentFullName: parent.fullName,
            parentHTMLURL: parentURL,
            parentOwner: parentOwner,
            parentRepoName: parentRepoName,
            parentDefaultBranch: parentBranch,
            forkDefaultBranch: forkBranch,
            aheadBy: aheadBy,
            behindBy: behindBy
        )
    }

    func mergeUpstream(
        owner: String,
        repo: String,
        branch: String
    ) async throws -> GitHubMergeUpstreamResult {
        let response: APIResponse<GitHubMergeUpstreamDTO> = try await post(
            path: AppEndpoints.GitHubREST.Paths.repoMergeUpstream(owner: owner, repo: repo),
            body: GitHubMergeUpstreamRequest(branch: branch)
        )
        return GitHubMergeUpstreamResult(
            message: response.value.message ?? "",
            mergeType: response.value.mergeType ?? "",
            baseBranch: response.value.baseBranch
        )
    }

    /// 查询打在 fork 上，head 是上游。整数含义见文件头。
    private static let forkCompareQuery = """
    query ForkCompare($owner: String!, $name: String!, $headRef: String!) {
      repository(owner: $owner, name: $name) {
        defaultBranchRef {
          compare(headRef: $headRef) {
            aheadBy
            behindBy
          }
        }
      }
    }
    """
}

private struct GitHubMergeUpstreamRequest: Encodable {
    let branch: String
}

private struct GitHubMergeUpstreamDTO: Decodable {
    let message: String?
    let mergeType: String?
    let baseBranch: String?
}

private struct ForkCompareGraphQL: Decodable {
    let repository: Repository?

    struct Repository: Decodable {
        let defaultBranchRef: Ref?
    }

    struct Ref: Decodable {
        let compare: Comparison?
    }

    struct Comparison: Decodable {
        let aheadBy: Int
        let behindBy: Int
    }
}
