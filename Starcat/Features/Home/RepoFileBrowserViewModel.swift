//
//  RepoFileBrowserViewModel.swift
//  Starcat
//
//  详情页「下载文件」Sheet 的状态机：拉树、勾选、选目录、按 blob SHA 并发下载。
//
//  关键约束：
//  - 树请求和下载都挂在 View 的 `.task` / 本类 Task 上，关 Sheet 必须取消，避免写到已失效的安全作用域目录；
//  - 并发上限 4：GitHub 对 raw/blob 也计 REST 配额，不能按文件数无界 fan-out；
//  - 单文件失败不中断整批，结束时用部分失败文案。App Store 沙盒必须 `startAccessingSecurityScopedResource`。
//

import AppKit
import Foundation
import SwiftUI

protocol RepoFileFolderPicking: Sendable {
    @MainActor func pickFolder() -> URL?
}

struct NSOpenPanelRepoFileFolderPicker: RepoFileFolderPicking {
    @MainActor
    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String.l10n("repo.files.chooseFolder.prompt")
        panel.message = String.l10n("repo.files.chooseFolder.message")
        panel.title = String.l10n("repo.files.chooseFolder.title")
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.url
    }
}

@MainActor
@Observable
final class RepoFileBrowserViewModel {

    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
        case downloading(completed: Int, total: Int)
        case finished(saved: Int, failed: Int, folder: URL)
    }

    let target: RepoFileBrowserTarget
    private(set) var phase: Phase = .loading
    private(set) var nodes: [RepoFileNode] = []
    private(set) var isTruncated = false
    var selectedPaths: Set<String> = []
    var toastMessage: String?
    var toastFileURL: URL?

    private let apiClient: any GitHubAPIClientProtocol
    private let downloader: any RepoFileDownloading
    private let folderPicker: any RepoFileFolderPicking
    private var downloadTask: Task<Void, Never>?

    var selectedCount: Int { selectedPaths.count }

    var canDownload: Bool {
        switch phase {
        case .ready, .finished: return !selectedPaths.isEmpty
        default: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    init(
        target: RepoFileBrowserTarget,
        apiClient: any GitHubAPIClientProtocol,
        downloader: (any RepoFileDownloading)? = nil,
        folderPicker: any RepoFileFolderPicking = NSOpenPanelRepoFileFolderPicker()
    ) {
        self.target = target
        self.apiClient = apiClient
        self.downloader = downloader ?? RepoFileDownloader()
        self.folderPicker = folderPicker
    }

    func loadTree() async {
        phase = .loading
        selectedPaths = []
        do {
            let dto = try await apiClient.repositoryGitTree(
                owner: target.owner,
                repo: target.name,
                ref: target.ref
            )
            nodes = RepoFileTreeBuilder.build(from: dto.tree)
            isTruncated = dto.truncated
            phase = .ready
        } catch is CancellationError {
            return
        } catch let error as NetworkError {
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed(String.l10n("repo.files.failed"))
        }
    }

    func toggle(_ node: RepoFileNode) {
        guard !isDownloading else { return }
        RepoFileTreeBuilder.toggle(node, in: &selectedPaths)
    }

    func selectAll() {
        guard !isDownloading else { return }
        selectedPaths = Set(nodes.flatMap(RepoFileTreeBuilder.descendantFilePaths(of:)))
    }

    func deselectAll() {
        guard !isDownloading else { return }
        selectedPaths = []
    }

    func startDownload() {
        guard canDownload, downloadTask == nil else { return }
        guard let folder = folderPicker.pickFolder() else { return }

        let files = selectedFiles()
        guard !files.isEmpty else { return }

        downloadTask = Task { [weak self] in
            await self?.runDownload(files: files, folder: folder)
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = phase {
            phase = .ready
        }
    }

    func stop() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private struct PendingFile {
        let path: String
        let sha: String
    }

    private func selectedFiles() -> [PendingFile] {
        nodes.flatMap(RepoFileTreeBuilder.descendantFilePaths(of:)).compactMap { path in
            guard selectedPaths.contains(path) else { return nil }
            guard let sha = blobSHA(path: path, in: nodes) else { return nil }
            return PendingFile(path: path, sha: sha)
        }
    }

    private func blobSHA(path: String, in nodes: [RepoFileNode]) -> String? {
        for node in nodes {
            if node.path == path { return node.blobSHA }
            if let children = node.children, let sha = blobSHA(path: path, in: children) {
                return sha
            }
        }
        return nil
    }

    private func runDownload(files: [PendingFile], folder: URL) async {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                folder.stopAccessingSecurityScopedResource()
            }
            downloadTask = nil
        }

        phase = .downloading(completed: 0, total: files.count)
        let destinationRoot = folder
        var saved = 0
        var failed = 0
        var firstSavedURL: URL?

        await withTaskGroup(of: FileOutcome.self) { group in
            var nextIndex = 0
            let limit = min(4, files.count)

            func enqueue() {
                guard nextIndex < files.count else { return }
                let file = files[nextIndex]
                nextIndex += 1
                let owner = target.owner
                let repo = target.name
                let downloader = downloader
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let url = try await downloader.download(
                            owner: owner,
                            repo: repo,
                            sha: file.sha,
                            relativePath: file.path,
                            toRoot: destinationRoot
                        )
                        return FileOutcome.saved(url)
                    } catch is CancellationError {
                        return .cancelled
                    } catch {
                        return .failed
                    }
                }
            }

            for _ in 0..<limit {
                enqueue()
            }

            for await outcome in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                switch outcome {
                case .saved(let url):
                    saved += 1
                    if firstSavedURL == nil { firstSavedURL = url }
                case .failed:
                    failed += 1
                case .cancelled:
                    group.cancelAll()
                    phase = .ready
                    return
                }
                phase = .downloading(completed: saved + failed, total: files.count)
                enqueue()
            }
        }

        if Task.isCancelled {
            phase = .ready
            return
        }

        let folderURL = destinationRoot.appendingPathComponent(target.name, isDirectory: true)
        phase = .finished(saved: saved, failed: failed, folder: folderURL)
        if saved > 0 {
            toastFileURL = firstSavedURL ?? folderURL
            if failed > 0 {
                toastMessage = String(format: String.l10n("repo.files.partialFailedFormat"), saved, failed)
            } else {
                let displayPath = (folderURL.path as NSString).abbreviatingWithTildeInPath
                toastMessage = String(format: String.l10n("repo.files.savedToFormat"), displayPath)
            }
        } else {
            toastFileURL = nil
            toastMessage = String.l10n("repo.files.downloadFailed")
        }
    }

    private enum FileOutcome {
        case saved(URL)
        case failed
        case cancelled
    }

    private static func message(for error: NetworkError) -> String {
        switch error {
        case .unauthorized:
            return String.l10n("repo.files.error.unauthorized")
        case .rateLimited:
            return String.l10n("repo.files.error.rateLimited")
        case .notFound:
            return String.l10n("repo.files.error.notFound")
        case .cancelled:
            return String.l10n("repo.files.cancelled")
        default:
            return error.localizedDescription
        }
    }
}
