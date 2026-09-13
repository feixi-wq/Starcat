//
//  RepoContributorsStatItem.swift
//  Starcat
//
//  详情 Hero stats 行的贡献者列：top 3 重叠头像 + 溢出人数，点击弹出样本名单。
//
//  关键约束：
//  - 整列一个按钮，头像不各自跳 GitHub，避免和「点开看全部」抢手势。
//  - Popover 必须 `.appLocaleEnvironment()`，关闭钮走 `SheetCloseButton`。
//  - `+x` 相对 GitHub 前 12 人样本，不是仓库全量贡献者人数。
//  - Trending 详情已有本周贡献者 heroExtension，由调用方关掉本列，避免两套口径叠在一起。
//

import SwiftUI
import AppKit

/// Hero stats 行最末列的贡献者 facepile。
struct RepoContributorsStatItem: View {
    let repo: Repo

    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var viewModel: RepositoryContributorHeroViewModel
    @State private var isPopoverPresented = false
    @State private var hoveredContributorID: String?

    init(repo: Repo, service: any RepositoryContributorHeroServing) {
        self.repo = repo
        _viewModel = State(initialValue: RepositoryContributorHeroViewModel(service: service))
    }

    var body: some View {
        Group {
            if viewModel.shouldShowColumn {
                Button {
                    guard !viewModel.contributors.isEmpty else { return }
                    isPopoverPresented = true
                } label: {
                    VStack(alignment: .center, spacing: 2) {
                        facepile
                        Text("repo.contributors")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pressableHover()
                .help("repo.contributors.help")
                .disabled(viewModel.contributors.isEmpty)
                .accessibilityLabel(Text("repo.contributors"))
                .accessibilityValue(Text(verbatim: accessibilityValue))
                .fixedSize()
                .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                    contributorsPopover
                        .appLocaleEnvironment()
                }
            }
        }
        .task(id: repo.id) {
            isPopoverPresented = false
            hoveredContributorID = nil
            await viewModel.load(
                repo: repo,
                isAuthenticated: authSession.state.isAuthenticated
            )
        }
    }

    @ViewBuilder
    private var facepile: some View {
        HStack(spacing: 0) {
            HStack(spacing: -8) {
                if viewModel.contributors.isEmpty {
                    ForEach(0..<RepositoryContributorHeroViewModel.visibleAvatarLimit, id: \.self) { index in
                        placeholderAvatar
                            .zIndex(Double(RepositoryContributorHeroViewModel.visibleAvatarLimit - index))
                    }
                } else {
                    ForEach(Array(viewModel.visibleAvatars.enumerated()), id: \.element.id) { index, contributor in
                        contributorAvatar(contributor)
                            .zIndex(Double(viewModel.visibleAvatars.count - index))
                    }
                }
            }
            if viewModel.overflowCount > 0 {
                Text(verbatim: "+\(viewModel.overflowCount)")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 6)
            }
        }
        .frame(height: 22)
    }

    private var placeholderAvatar: some View {
        Circle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color(nsColor: .controlBackgroundColor).opacity(0.9), lineWidth: 2)
            )
    }

    private func contributorAvatar(_ contributor: RepositoryContributor) -> some View {
        RemoteAvatar(
            urlString: contributor.avatarURL?.absoluteString,
            size: 22,
            showBorder: false
        )
        .overlay(
            Circle()
                .stroke(Color(nsColor: .controlBackgroundColor).opacity(0.9), lineWidth: 2)
        )
        .help(Text(verbatim: contributor.login))
    }

    private var contributorsPopover: some View {
        let ranked = viewModel.contributors
        let maximum = ranked.map(\.commits).max() ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("repo.contributors")
                        .font(interfaceScale.font(.bodyEmphasis, weight: .semibold))
                    Text("repo.contributors.subtitle")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SheetCloseButton(
                    action: { isPopoverPresented = false },
                    iconFont: .system(size: 16, weight: .medium),
                    frameSize: 22
                )
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(ranked.enumerated()), id: \.element.id) { index, contributor in
                        contributorRow(
                            contributor,
                            rank: index + 1,
                            share: RepositoryContributorHeroViewModel.share(
                                commits: contributor.commits,
                                maximum: maximum
                            )
                        )
                    }
                }
            }
            .frame(maxHeight: 320)

            Text("repo.contributors.sampleFootnote")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func contributorRow(
        _ contributor: RepositoryContributor,
        rank: Int,
        share: Double
    ) -> some View {
        let isHovered = hoveredContributorID == contributor.id
        return Button {
            isPopoverPresented = false
            NSWorkspace.shared.open(profileURL(for: contributor))
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: "\(rank)")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 16, alignment: .trailing)

                RemoteAvatar(
                    urlString: contributor.avatarURL?.absoluteString,
                    size: 22,
                    showBorder: false
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: contributor.login)
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(
                            String(
                                format: String.l10n("insights.repo.contributor.commitsFormat"),
                                locale: locale,
                                contributor.commits
                            )
                        )
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.primary.opacity(0.08))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.85))
                                .frame(width: max(4, proxy.size.width * share))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("repo.contributors.openProfileHelp")
        .onHover { hovering in
            if hovering {
                hoveredContributorID = contributor.id
            } else if hoveredContributorID == contributor.id {
                hoveredContributorID = nil
            }
        }
    }

    private func profileURL(for contributor: RepositoryContributor) -> URL {
        if let profileHTMLURL = contributor.profileHTMLURL {
            return profileHTMLURL
        }
        return GitHubURLs.userProfile(login: contributor.login)
    }

    private var accessibilityValue: String {
        if viewModel.contributors.isEmpty {
            return ""
        }
        let names = viewModel.visibleAvatars.map(\.login).joined(separator: ", ")
        if viewModel.overflowCount > 0 {
            return "\(names) +\(viewModel.overflowCount)"
        }
        return names
    }
}
