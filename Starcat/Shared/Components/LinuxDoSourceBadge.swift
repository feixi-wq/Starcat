//
//  LinuxDoSourceBadge.swift
//  Starcat
//
//  来源事实与 Weekly/Activity 当前场景徽章并列显示。列表是纯本地标识，只有详情点击才加载帖子。
//

import SwiftUI

struct LinuxDoSourceBadge: View {
    let repoID: Int64
    var interactive = false
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isPresented = false

    var body: some View {
        if dependencies.linuxDoStore.origin(for: repoID) != nil {
            Group {
                if interactive {
                    Button { isPresented = true } label: { badge }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .popover(isPresented: $isPresented) {
                            LinuxDoTopicsPopover(repoID: repoID, store: dependencies.linuxDoStore)
                                .appLocaleEnvironment()
                        }
                } else { badge }
            }
            .help(Text("linuxdo.source.help"))
            .accessibilityLabel(Text("linuxdo.source.help"))
        }
    }

    private var badge: some View {
        Text(verbatim: "Linux.do")
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.35), in: Capsule())
            .fixedSize()
    }
}

/// 详情按需显示多帖回链，离线时保留原有帖子快照并明确提示。
private struct LinuxDoTopicsPopover: View {
    let repoID: Int64
    let store: LinuxDoStore
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("linuxdo.source.discussions").font(.headline)
                Spacer()
                SyncIconButton(isRefreshing: store.loading.contains(.topics(repoID)), disabled: store.loading.contains(.topics(repoID)), tooltip: String.l10n("explore.refresh.tooltip")) {
                    Task { await store.refreshTopics(repoID: repoID, force: true) }
                }
            }
            if store.failed.contains(.topics(repoID)) {
                Text("linuxdo.cache.unavailable").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.topicSnapshots[repoID]?.payload.topics ?? []) { topic in
                        if let url = topic.safeURL {
                            VStack(alignment: .leading, spacing: 3) {
                                Link(destination: url) { Text(verbatim: topic.title).lineLimit(2) }
                                if let date = LinuxDoPayload.date(topic.publishedAt) {
                                    Text(date, format: .dateTime.year().month().day().locale(locale))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.topicSnapshots[repoID]?.payload.topics?.isEmpty ?? true {
                        Text(store.loading.contains(.topics(repoID)) ? "linuxdo.source.loading" : "linuxdo.source.noTopics")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 340, height: 240)
        .task(id: repoID) { await store.refreshTopics(repoID: repoID) }
    }
}
