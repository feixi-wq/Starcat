//
//  RepoFileDownloader.swift
//  Starcat
//
//  按 git blob SHA 把仓库文件写到用户选中的目录。
//
//  与 Release 资产下载器同构：`URLSession.downloadTask` 落临时文件再 move，
//  避免大文件整包进内存。必须挂 `GitHubAuthRedirectDelegate`，否则 GitHub 301
//  改名仓库时会丢掉 Authorization，被 AuthSession 误判成 token 失效。
//
//  下载走 `GET /repos/{owner}/{repo}/git/blobs/{sha}` + raw Accept，而不是
//  Contents JSON：后者对超过 1MB 的文件会截断 content 字段。
//

import Foundation

enum RepoFileDownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsafePath
    case httpStatus(Int)
    case emptyResponse
    case moveFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("repo.files.error.invalidURL")
        case .unsafePath:
            return String.l10n("repo.files.error.unsafePath")
        case .httpStatus(let code):
            return String(format: String.l10n("repo.files.error.httpFormat"), code)
        case .emptyResponse:
            return String.l10n("repo.files.error.empty")
        case .moveFailed:
            return String.l10n("repo.files.error.moveFailed")
        }
    }
}

protocol RepoFileDownloading: Sendable {
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL
}

extension RepoFileDownloading {
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL
    ) async throws -> URL {
        try await download(
            owner: owner,
            repo: repo,
            sha: sha,
            relativePath: relativePath,
            toRoot: root,
            onProgress: nil
        )
    }
}

/// 无状态 actor：每次调用独立，进度回调可能来自 URLSession 私有队列。
actor RepoFileDownloader: RepoFileDownloading {

    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding

    init(
        session: URLSession? = nil,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.session = session ?? Self.makeDefaultSession()
        self.tokenProvider = tokenProvider
    }

    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard RepoFileTreeBuilder.isSafeRelativePath(relativePath) else {
            throw RepoFileDownloadError.unsafePath
        }
        guard let destination = Self.destinationURL(root: root, repoName: repo, relativePath: relativePath) else {
            throw RepoFileDownloadError.unsafePath
        }
        let url = AppEndpoints.GitHubREST.url(
            AppEndpoints.GitHubREST.Paths.repoGitBlob(owner: owner, repo: repo, sha: sha)
        )

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await downloadFile(for: request, onProgress: onProgress)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            throw NetworkError.transport(underlying: error)
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let http = response as? HTTPURLResponse else {
            throw RepoFileDownloadError.emptyResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RepoFileDownloadError.httpStatus(http.statusCode)
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            AppLog.network.error("Repo file move failed: \(error.localizedDescription, privacy: .public)")
            throw RepoFileDownloadError.moveFailed
        }

        onProgress?(1)
        return destination
    }

    static func destinationURL(root: URL, repoName: String, relativePath: String) -> URL? {
        guard RepoFileTreeBuilder.isSafeRelativePath(relativePath) else { return nil }
        let trimmedName = repoName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              !trimmedName.contains("/"),
              trimmedName != "." && trimmedName != ".." else {
            return nil
        }
        var url = root.appendingPathComponent(trimmedName, isDirectory: true)
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(component)
            guard part != ".." && part != "." else { return nil }
            url.appendPathComponent(part)
        }
        return url
    }

    private static func makeDefaultSession() -> URLSession {
        URLSession(
            configuration: .default,
            delegate: GitHubAuthRedirectDelegate(),
            delegateQueue: nil
        )
    }

    private func downloadFile(
        for request: URLRequest,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            final class ObservationBox: @unchecked Sendable {
                var observation: NSKeyValueObservation?
            }
            let box = ObservationBox()

            let task = session.downloadTask(with: request) { tempURL, response, error in
                box.observation?.invalidate()
                box.observation = nil

                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL, let response else {
                    continuation.resume(throwing: RepoFileDownloadError.emptyResponse)
                    return
                }
                let ownedTemp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("starcat-repo-file-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: ownedTemp)
                    continuation.resume(returning: (ownedTemp, response))
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let onProgress {
                onProgress(0)
                box.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    onProgress(min(1, max(0, progress.fractionCompleted)))
                }
            }

            task.resume()
        }
    }
}
