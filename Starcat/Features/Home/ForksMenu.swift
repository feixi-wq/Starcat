//
//  ForksMenu.swift
//  Starcat
//
//  详情页 Forks 数字的点击分流，以及 fork 仓的「Forked from」行。
//
//  为什么跟 WatchersMenu 分文件：
//  - Watchers 只有订阅三态；Forks 要按所有权分成三种点击，自己的 fork 还要
//    拉 parent + ahead/behind，并可能 POST merge-upstream。
//  - 会话缓存必须让菜单和 “Forked from” 行共用同一次请求，避免点进详情打两遍。
//
//  关键约束：
//  - 私仓走 `projectGitHubAPIClient`（GitHub App token）；公开仓走 OAuth。
//  - Sync 409/422 打开 GitHub 网页，不在 App 里丢弃用户提交。
//  - ahead/behind 不入库，只放进程内缓存。
//

import SwiftUI
import AppKit

/// 详情页 Forks 统计列。别人的仓直接打开 fork 页；自己的原创仓打开网络页；自己的 fork 出菜单。
struct ForksMenu: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.colorScheme) private var colorScheme

    @State private var store = ForkRelationSessionStore.shared
    @State private var loadFailed = false
    @State private var isSyncing = false

    private var relation: GitHubForkRelation? {
        store.relation(for: repo.id)
    }

    private var kind: RepoForkStatKind {
        RepoForkStatKindResolver.kind(
            isFork: repo.isFork,
            repoOwner: repo.owner,
            currentLogin: authSession.state.user?.login
        )
    }

    private var forkTint: Color {
        if relation?.needsSync == true {
            return .orange
        }
        return StatSemanticColor.fork.resolved(colorScheme: colorScheme)
    }

    var body: some View {
        Group {
            switch kind {
            case .forkOthersRepo:
                forkPageButton(helpKey: "repo.forkAction")
            case .viewOwnForks:
                networkButton
            case .manageOwnFork:
                ownForkMenu
            }
        }
        .task(id: repo.id) {
            await loadRelationIfNeeded()
        }
    }

    private var networkButton: some View {
        Button {
            NSWorkspace.shared.open(GitHubURLs.repoNetworkMembers(owner: repo.owner, repo: repo.name))
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.fork.ownRepoHelp")
    }

    private func forkPageButton(helpKey: LocalizedStringKey) -> some View {
        Button {
            NSWorkspace.shared.open(GitHubURLs.repoFork(owner: repo.owner, repo: repo.name))
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(helpKey)
    }

    private var ownForkMenu: some View {
        Menu {
            if let relation {
                Button {
                    NSWorkspace.shared.open(relation.parentHTMLURL)
                } label: {
                    Label(
                        String(format: String.l10n("repo.fork.forkedFromFormat"), relation.parentFullName),
                        systemImage: "arrow.turn.up.left"
                    )
                }

                if let statusLine = Self.statusLine(for: relation) {
                    Text(statusLine)
                }

                Divider()

                Button {
                    NSWorkspace.shared.open(Self.contributeURL(repo: repo, relation: relation))
                } label: {
                    Label("repo.fork.contribute", systemImage: "plus.bubble")
                }
                .disabled(!relation.canContribute)

                Button {
                    Task { await syncFork(relation) }
                } label: {
                    Label("repo.fork.sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!relation.needsSync || isSyncing)

                Divider()

                Button {
                    NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
                } label: {
                    Label("repo.fork.viewOnGitHub", systemImage: "safari")
                }
            } else if loadFailed {
                Button("action.retry") {
                    Task { await loadRelationIfNeeded(force: true) }
                }
            } else {
                Text("repo.fork.loading")
            }
        } label: {
            statLabel
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help("repo.fork.ownForkHelp")
    }

    private var statLabel: some View {
        RepoStatItem(
            label: "repo.forks",
            value: repo.forksCount,
            systemImage: "tuningfork",
            tint: forkTint
        )
    }

    private func githubClient() -> any GitHubAPIClientProtocol {
        repo.isPrivate ? dependencies.projectGitHubAPIClient : dependencies.apiClient
    }

    private func loadRelationIfNeeded(force: Bool = false) async {
        guard repo.isFork else { return }
        if !force, store.relation(for: repo.id) != nil {
            loadFailed = false
            return
        }

        let requestedId = repo.id
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }

        let loaded = await store.load(repoId: requestedId, force: force) {
            do {
                return try await githubClient().forkRelation(owner: repo.owner, repo: repo.name)
            } catch {
                AppLog.network.error(
                    "Fork relation load failed for \(self.repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
        guard repo.id == requestedId else { return }
        loadFailed = loaded == nil
    }

    private func syncFork(_ current: GitHubForkRelation) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            _ = try await githubClient().mergeUpstream(
                owner: repo.owner,
                repo: repo.name,
                branch: current.forkDefaultBranch
            )
            store.clear(repo.id)
            await loadRelationIfNeeded(force: true)
        } catch {
            if case NetworkError.clientError(let statusCode, _) = error,
               statusCode == 409 || statusCode == 422 {
                NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
            } else {
                AppLog.network.error(
                    "Sync fork failed for \(self.repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                NSWorkspace.shared.open(GitHubURLs.repo(fullName: repo.fullName))
            }
        }
    }

    static func contributeURL(repo: Repo, relation: GitHubForkRelation) -> URL {
        GitHubURLs.forkContribute(
            parentOwner: relation.parentOwner,
            parentRepo: relation.parentRepoName,
            parentBranch: relation.parentDefaultBranch,
            forkOwner: repo.owner,
            forkRepo: repo.name,
            forkBranch: relation.forkDefaultBranch
        )
    }

    static func statusLine(for relation: GitHubForkRelation) -> String? {
        switch (relation.aheadBy, relation.behindBy) {
        case (nil, nil):
            return nil
        case (0, 0):
            return String.l10n("repo.fork.upToDate")
        case (let ahead?, 0):
            return String(format: String.l10n("repo.fork.aheadFormat"), ahead)
        case (0, let behind?):
            return String(format: String.l10n("repo.fork.behindFormat"), behind)
        case (let ahead?, let behind?):
            return String(format: String.l10n("repo.fork.aheadBehindFormat"), ahead, behind)
        default:
            if let ahead = relation.aheadBy {
                return String(format: String.l10n("repo.fork.aheadFormat"), ahead)
            }
            if let behind = relation.behindBy {
                return String(format: String.l10n("repo.fork.behindFormat"), behind)
            }
            return nil
        }
    }
}

/// 详情标题下的 “Forked from owner/repo”，自己的 fork 还会带 ahead/behind。
struct ForkedFromCaption: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    @State private var store = ForkRelationSessionStore.shared
    @State private var didFinishLoad = false

    private var relation: GitHubForkRelation? {
        store.relation(for: repo.id)
    }

    var body: some View {
        Group {
            if let relation {
                HStack(spacing: 6) {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(relation.needsSync ? Color.orange : Color.secondary)
                    Button {
                        NSWorkspace.shared.open(relation.parentHTMLURL)
                    } label: {
                        Text(String(format: String.l10n("repo.fork.forkedFromFormat"), relation.parentFullName))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .pressableHover(scale: 1.0)
                    .help("repo.fork.openParent")

                    if let status = ForksMenu.statusLine(for: relation) {
                        Text(verbatim: "·")
                            .foregroundStyle(.secondary)
                        Text(verbatim: status)
                            .foregroundStyle(relation.needsSync ? Color.orange : Color.secondary)
                    }
                }
                .font(interfaceScale.font(.captionSmall))
                .lineLimit(1)
            } else if didFinishLoad {
                HStack(spacing: 6) {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(.secondary)
                    Text("repo.fork.parentUnavailable")
                        .foregroundStyle(.secondary)
                }
                .font(interfaceScale.font(.captionSmall))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "tuningfork")
                        .foregroundStyle(.secondary)
                    Text("repo.fork.loading")
                        .foregroundStyle(.secondary)
                }
                .font(interfaceScale.font(.captionSmall))
            }
        }
        .task(id: repo.id) {
            await loadRelation()
        }
    }

    private func githubClient() -> any GitHubAPIClientProtocol {
        repo.isPrivate ? dependencies.projectGitHubAPIClient : dependencies.apiClient
    }

    private func loadRelation() async {
        didFinishLoad = false
        let requestedId = repo.id
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        _ = await store.load(repoId: requestedId) {
            do {
                return try await githubClient().forkRelation(owner: repo.owner, repo: repo.name)
            } catch {
                return nil
            }
        }
        guard repo.id == requestedId else { return }
        didFinishLoad = true
    }
}

/// 进程内 fork 快照。`@Observable` 是为了 Sync 成功后标题行和菜单同时刷新。
@MainActor
@Observable
final class ForkRelationSessionStore {
    static let shared = ForkRelationSessionStore()

    private(set) var snapshots: [Int64: GitHubForkRelation] = [:]
    @ObservationIgnored private var inFlight: [Int64: Task<GitHubForkRelation?, Never>] = [:]

    func relation(for repoId: Int64) -> GitHubForkRelation? {
        snapshots[repoId]
    }

    func clear(_ repoId: Int64) {
        snapshots[repoId] = nil
        inFlight[repoId]?.cancel()
        inFlight[repoId] = nil
    }

    func load(
        repoId: Int64,
        force: Bool = false,
        loader: @escaping () async -> GitHubForkRelation?
    ) async -> GitHubForkRelation? {
        if !force, let cached = snapshots[repoId] {
            return cached
        }
        if let existing = inFlight[repoId] {
            return await existing.value
        }
        let task = Task { await loader() }
        inFlight[repoId] = task
        let result = await task.value
        inFlight[repoId] = nil
        if let result {
            snapshots[repoId] = result
        }
        return result
    }
}
