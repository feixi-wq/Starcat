//
//  LinuxDoView.swift
//  Starcat
//
//  发现下的 Linux.do 独立目录；选择仍交给现有 Discovery 详情，不创建第二套 README 页面。
//

import SwiftUI

struct LinuxDoView: View {
    let store: LinuxDoStore
    @Binding var selectedRepoID: Int64?
    @Binding var selectedRepo: DiscoveryRepoDTO?
    let onRepoCountChange: (Int) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession
    @State private var model = LinuxDoListModel()
    @State private var search = ""
    @State private var quickSearchDraft = ""
    @State private var isQuickSearchExpanded = false
    @State private var recentPromotionFirst = true
    @State private var libraryStates: [Int64: LibraryState] = [:]
    @State private var wikiAvailability: [Int64: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("linuxdo.catalog.description").font(.caption).foregroundStyle(.secondary)
                QuickSearchToolbarContent(
                    isExpanded: $isQuickSearchExpanded,
                    draft: $quickSearchDraft,
                    committedQuery: search,
                    placeholder: "list.quickSearch.placeholder",
                    onSubmit: { query in
                        let normalizedQuery = QuickSearchTextMatcher.normalized(query)
                        search = normalizedQuery
                        quickSearchDraft = normalizedQuery
                    },
                    onClear: { search = "" }
                ) {
                    Picker("linuxdo.catalog.recentPromotion", selection: $recentPromotionFirst) {
                        Text("linuxdo.catalog.recentPromotion").tag(true)
                        Text("explore.sort.stars").tag(false)
                    }
                    .labelsHidden()
                    .fixedSize()
                    SyncIconButton(isRefreshing: store.isRefreshingCatalog, disabled: store.isRefreshingCatalog, tooltip: String.l10n("explore.refresh.tooltip")) {
                        Task { await store.refreshCatalog(force: true) }
                    }
                    MultiSelectButton(isActive: dependencies.exploreMultiSelectionStore.isActive, action: { dependencies.exploreMultiSelectionStore.toggle() }, isDisabled: !authSession.state.isAuthenticated)
                }
            }
            .padding(12)
            Divider()
            if store.failed.contains(.catalog) {
                Text("linuxdo.cache.unavailable").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if store.catalog == nil && store.isRefreshingCatalog {
                RepoSkeletonListView(rowCount: 10)
            } else if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("linuxdo.catalog.empty", systemImage: "bubble.left.and.bubble.right")
                } description: { Text("linuxdo.catalog.emptyDescription") }
            } else {
                repoList
            }
        }
        .task {
            selectedRepoID = nil
            selectedRepo = nil
            libraryStates = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
            await store.refreshCatalog()
        }
        .task(id: queryIdentity) { rebuildList() }
        .onDisappear { resetQuickSearch() }
        .task(id: signalIdentity) {
            let repos = store.repositories
            let ids = repos.map(\.repoID)
            async let scores: Void = dependencies.openSSFScoreStore.loadCachedScores(for: ids)
            async let health: Void = dependencies.repoHealthStore.loadCachedSnapshots(for: ids)
            if settings.wikiAvailabilityFilter != .unknown {
                let snapshot = await WikiAvailabilitySnapshotLoader.load(requests: repos.map { WikiAvailabilityRequest(id: $0.repoID, owner: $0.owner, repo: $0.name) })
                guard !Task.isCancelled else { return }
                wikiAvailability = snapshot
            }
            _ = await (scores, health)
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: .repoLibraryStateDidChange) {
                guard !Task.isCancelled else { return }
                libraryStates = (try? await dependencies.repoNoteRepository.fetchAllLibraryStateMap()) ?? [:]
                rebuildList()
            }
        }
        .starcatRefreshCommand(pane: .list, identity: "linuxdo-\(queryIdentity)", title: String.l10n("commands.actions.refreshCurrentList"), isEnabled: !store.isRefreshingCatalog) {
            Task { await store.refreshCatalog(force: true) }
        }
    }

    private var repoList: some View {
        let selection = dependencies.exploreMultiSelectionStore
        return List {
            ForEach(Array(model.rows.enumerated()), id: \.element.repoID) { index, repo in
                Button {
                    if selection.isActive { selection.toggle(SelectionSnapshot(ghRepoId: repo.repoID, owner: repo.owner, name: repo.name)) }
                    else { selectedRepoID = repo.repoID; selectedRepo = repo }
                } label: {
                    UnifiedRepoRow(card: repo.asCardData(registry: dependencies.starredRegistry, isInLibrary: libraryStates[repo.repoID] == .inLibrary), isSelected: selection.isActive ? selection.contains(ghRepoId: repo.repoID) : selectedRepoID == repo.repoID)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .automaticListPagination(appearingIndex: index, visibleItemCount: model.rows.count, loadedItemCount: model.rows.count, hasMore: model.hasMore, isLoading: false, identity: model.identity) { model.loadMore() }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .automaticListPaginationFill(visibleItemCount: model.rows.count, loadedItemCount: model.rows.count, hasMore: model.hasMore, isLoading: false, identity: model.identity) { model.loadMore() }
        .refreshable { await store.refreshCatalog(force: true) }
    }

    /// 全局基础筛选在本地完整快照上执行；分页边界使用筛选后集合，不会因隐藏尾行而断页。
    private var filteredRepositories: [DiscoveryRepoDTO] {
        store.repositories.filter { repo in
            guard settings.starFilter.matches(isStarred: dependencies.starredRegistry.contains(ghRepoId: repo.repoID)) else { return false }
            if settings.hideArchived && repo.isArchived || settings.hideForks && repo.isFork { return false }
            if !settings.globalFilterLanguages.isEmpty && !settings.globalFilterLanguages.contains(where: { $0.caseInsensitiveCompare(repo.language ?? "") == .orderedSame }) { return false }
            if !matchesAvailability(wikiAvailability[repo.repoID] ?? false, filter: settings.wikiAvailabilityFilter) { return false }
            if !matchesAvailability(dependencies.repoHealthStore.snapshot(for: repo.repoID) != nil, filter: settings.healthAvailabilityFilter) { return false }
            if !matchesAvailability(dependencies.openSSFScoreStore.record(for: repo.repoID)?.badgeData != nil, filter: settings.openSSFAvailabilityFilter) { return false }
            switch settings.libraryFilter {
            case .all: return true
            case .inLibrary: return libraryStates[repo.repoID] == .inLibrary
            case .outsideLibrary: return libraryStates[repo.repoID] != .inLibrary
            }
        }
    }

    private var queryIdentity: String {
        "\(store.providerID):\(store.catalog?.payload.revision ?? -1):\(search):\(recentPromotionFirst):\(filteredRepositories.map(\.repoID))"
    }

    private var signalIdentity: String {
        "\(store.providerID):\(store.catalog?.payload.revision ?? -1):\(settings.wikiAvailabilityFilter.rawValue)"
    }

    private func matchesAvailability(_ available: Bool, filter: RepoSignalAvailabilityFilter) -> Bool {
        switch filter {
        case .unknown: return true
        case .available: return available
        case .missing: return !available
        }
    }

    private func rebuildList() {
        model.reset(repositories: filteredRepositories, promotionDates: store.catalog?.payload.promotionDates ?? [:], search: search, recentPromotionFirst: recentPromotionFirst, identity: queryIdentity)
        onRepoCountChange(model.total)
        if let id = selectedRepoID, let repo = model.rows.first(where: { $0.repoID == id }) { selectedRepo = repo; return }
        selectedRepo = settings.openFirstDetailOnCategoryChange ? model.rows.first : nil
        selectedRepoID = selectedRepo?.repoID
    }

    /// 离开 Linux.do 分类时清除搜索，下一次进入应恢复完整目录而不是沿用旧条件。
    private func resetQuickSearch() {
        isQuickSearchExpanded = false
        quickSearchDraft = ""
        search = ""
    }
}
