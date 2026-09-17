//
//  RepoFileDownloadTests.swift
//  StarcatTests
//
//  详情页按文件勾选下载：扁平 git tree → 嵌套节点、勾选传播、blob 落盘、路径穿越防护。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepoFileTreeBuilder")
struct RepoFileTreeBuilderTests {

    @Test("扁平 tree 收成目录优先的嵌套节点，并跳过子模块和符号链接")
    func buildsNestedTreeAndSkipsSubmodules() throws {
        let entries = [
            entry(path: "README.md", type: "blob", mode: "100644", sha: "readme", size: 12),
            entry(path: "src", type: "tree", mode: "040000", sha: "srcdir"),
            entry(path: "src/main.swift", type: "blob", mode: "100644", sha: "main", size: 40),
            entry(path: "src/util.swift", type: "blob", mode: "100644", sha: "util", size: 8),
            entry(path: "vendor/lib", type: "commit", mode: "160000", sha: "sub"),
            entry(path: "link", type: "blob", mode: "120000", sha: "lnk", size: 20),
            entry(path: "secret/../passwd", type: "blob", mode: "100644", sha: "bad", size: 1),
        ]

        let roots = RepoFileTreeBuilder.build(from: entries)
        #expect(roots.map(\.name) == ["src", "README.md"])

        let src = try #require(roots.first)
        #expect(src.isDirectory)
        #expect(src.children?.map(\.name) == ["main.swift", "util.swift"])
        #expect(RepoFileTreeBuilder.descendantFilePaths(of: src) == ["src/main.swift", "src/util.swift"])
        #expect(!roots.contains { $0.name == "vendor" || $0.name == "link" || $0.name == "secret" })
    }

    @Test("勾选文件夹会选中全部子孙文件，再点一次清空")
    func togglingDirectorySelectsDescendants() throws {
        let roots = RepoFileTreeBuilder.build(from: [
            entry(path: "src", type: "tree", mode: "040000", sha: "d"),
            entry(path: "src/a.swift", type: "blob", mode: "100644", sha: "a", size: 1),
            entry(path: "src/b.swift", type: "blob", mode: "100644", sha: "b", size: 1),
            entry(path: "README.md", type: "blob", mode: "100644", sha: "r", size: 1),
        ])
        let src = try #require(roots.first)
        var selected: Set<String> = []

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(selected == ["src/a.swift", "src/b.swift"])
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        selected.insert("README.md")
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        selected.remove("src/b.swift")
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .mixed)

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(selected.contains("src/a.swift"))
        #expect(selected.contains("src/b.swift"))
        #expect(selected.contains("README.md"))
        #expect(RepoFileTreeBuilder.checkState(of: src, selected: selected) == .on)

        RepoFileTreeBuilder.toggle(src, in: &selected)
        #expect(!selected.contains("src/a.swift"))
        #expect(!selected.contains("src/b.swift"))
        #expect(selected.contains("README.md"))
    }

    private func entry(
        path: String,
        type: String,
        mode: String,
        sha: String,
        size: Int? = nil
    ) -> GitHubGitTreeEntryDTO {
        GitHubGitTreeEntryDTO(path: path, mode: mode, type: type, sha: sha, size: size, url: nil)
    }
}

@Suite("GitHubGitTreeDTO 解码")
struct GitHubGitTreeDTOTests {
    @Test("recursive tree 响应解码 truncated 与 blob size")
    func decodesTree() throws {
        let json = #"""
        {
            "sha": "abc123",
            "url": "https://api.github.com/repos/o/r/git/trees/abc123",
            "tree": [
                {
                    "path": "README.md",
                    "mode": "100644",
                    "type": "blob",
                    "sha": "def",
                    "size": 42,
                    "url": "https://api.github.com/repos/o/r/git/blobs/def"
                }
            ],
            "truncated": true
        }
        """#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let dto = try decoder.decode(GitHubGitTreeDTO.self, from: json)
        #expect(dto.sha == "abc123")
        #expect(dto.truncated)
        #expect(dto.tree.count == 1)
        #expect(dto.tree[0].path == "README.md")
        #expect(dto.tree[0].size == 42)
    }
}

@Suite("RepoFileDownloader", .serialized)
struct RepoFileDownloaderTests {

    @Test("blob 200：按相对路径写入仓库子目录")
    func writesRelativePath() async throws {
        URLProtocolStub.reset()
        let payload = Data("hello files".utf8)
        URLProtocolStub.requestHandler = { request in
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let downloader = RepoFileDownloader(
            session: URLProtocolStub.ephemeralSession(),
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        let saved = try await downloader.download(
            owner: "octocat",
            repo: "Hello-World",
            sha: "abc",
            relativePath: "src/hello.txt",
            toRoot: root
        )
        #expect(saved.lastPathComponent == "hello.txt")
        #expect(try Data(contentsOf: saved) == payload)
        #expect(saved.path.hasSuffix("Hello-World/src/hello.txt"))
    }

    @Test("拒绝路径穿越")
    func rejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp")
        #expect(RepoFileDownloader.destinationURL(root: root, repoName: "repo", relativePath: "../secret") == nil)
        #expect(RepoFileDownloader.destinationURL(root: root, repoName: "repo/../x", relativePath: "a.swift") == nil)
        #expect(RepoFileTreeBuilder.isSafeRelativePath("src/../main.swift") == false)
    }
}

@Suite("RepoFileBrowserViewModel")
@MainActor
struct RepoFileBrowserViewModelTests {

    @Test("loadTree 成功后可以勾选并下载到指定目录")
    func loadAndDownload() async throws {
        let mock = MockGitHubAPIClient()
        mock.repositoryGitTreeHandler = { _, _, ref in
            #expect(ref == "main")
            return GitHubGitTreeDTO(
                sha: "tree",
                truncated: false,
                tree: [
                    GitHubGitTreeEntryDTO(
                        path: "README.md",
                        mode: "100644",
                        type: "blob",
                        sha: "blob1",
                        size: 4,
                        url: nil
                    )
                ]
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = RepoFileBrowserViewModel(
            target: RepoFileBrowserTarget(owner: "o", name: "demo", fullName: "o/demo", ref: "main"),
            apiClient: mock,
            downloader: InlineRepoFileDownloader(),
            folderPicker: FixedFolderPicker(url: root)
        )
        await viewModel.loadTree()
        #expect(viewModel.nodes.map(\.name) == ["README.md"])

        viewModel.selectAll()
        #expect(viewModel.selectedCount == 1)
        viewModel.startDownload()
        try await waitUntilFinished(viewModel)

        if case .finished(let saved, let failed, let folder) = viewModel.phase {
            #expect(saved == 1)
            #expect(failed == 0)
            #expect(folder.lastPathComponent == "demo")
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        } else {
            Issue.record("expected finished phase, got \(String(describing: viewModel.phase))")
        }
    }

    private func waitUntilFinished(_ viewModel: RepoFileBrowserViewModel) async throws {
        for _ in 0..<50 {
            if case .finished = viewModel.phase { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("download did not finish")
    }
}

private struct FixedFolderPicker: RepoFileFolderPicking {
    let url: URL?
    @MainActor func pickFolder() -> URL? { url }
}

private struct InlineRepoFileDownloader: RepoFileDownloading {
    func download(
        owner: String,
        repo: String,
        sha: String,
        relativePath: String,
        toRoot root: URL,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard let destination = RepoFileDownloader.destinationURL(
            root: root,
            repoName: repo,
            relativePath: relativePath
        ) else {
            throw RepoFileDownloadError.unsafePath
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: destination)
        onProgress?(1)
        return destination
    }
}
