//
//  GitHubGitTreeAPI.swift
//  Starcat
//
//  `GET /repos/{owner}/{repo}/git/trees/{ref}?recursive=1`
//
//  详情页「下载文件」需要整棵可勾选的文件树。Contents API 只能按目录懒加载，
//  勾选一个未展开的文件夹还得再打 N 次请求。Trees recursive 一次拿齐路径，
//  代价是超过约 10 万条目会被截断（DTO.truncated），UI 必须提示而不是静默缺文件。
//

import Foundation

extension GitHubAPIClient {

    /// 递归拉取指定 ref 的 git tree。
    func repositoryGitTree(owner: String, repo: String, ref: String) async throws -> GitHubGitTreeDTO {
        let response: APIResponse<GitHubGitTreeDTO> = try await get(
            path: AppEndpoints.GitHubREST.Paths.repoGitTree(owner: owner, repo: repo, ref: ref),
            queryItems: [URLQueryItem(name: "recursive", value: "1")]
        )
        return response.value
    }
}
