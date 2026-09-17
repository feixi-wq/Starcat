//
//  ExternalStarInbox.swift
//  Starcat
//
//  前台探测 GitHub `/user/starred` 第一页，找出本地还没有的外部新增 star，
//  攒进内存队列供中栏胶囊展示。点击后再走现有 SyncManager 增量同步。
//
//  关键约束：
//  - 探测不得写入 repos / lastSyncAt / 同步用的 starsETag。探测 ETag 只活在内存里，
//    否则点胶囊时 SyncManager 会 304 早退，新仓库进不来。
//  - 队列跨探测轮次累加，整批插到最前，避免逐条 prepend 把同一轮顺序反转。
//  - TestEnvironment 只挡住 15 秒循环，不挡住 poll()，单测才能驱动探测。
//

import Foundation
import Observation

/// 胶囊头像槽：最多 3 个真实头像，超出部分收成 `+N`。
enum ExternalStarInboxPresentation {
    enum Slot: Equatable {
        case avatar(repoID: Int64, ownerLogin: String, avatarURL: String?)
        case overflow(Int)
    }

    static func slots(
        from items: [ExternalStarInbox.Item],
        maxAvatars: Int = 3
    ) -> [Slot] {
        let overflow = items.count - maxAvatars
        let avatars = items.prefix(maxAvatars).map {
            Slot.avatar(repoID: $0.repoID, ownerLogin: $0.ownerLogin, avatarURL: $0.avatarURL)
        }
        if overflow > 0 {
            return avatars + [.overflow(overflow)]
        }
        return Array(avatars)
    }
}

/// 外部新增星标的前台收件箱。先提示，点了才同步。
@MainActor
@Observable
final class ExternalStarInbox {

    /// 待同步队列项。只为胶囊渲染和去重服务，不入库。
    struct Item: Equatable, Identifiable, Sendable {
        var id: Int64 { repoID }
        let repoID: Int64
        let ownerLogin: String
        let avatarURL: String?
        let starredAt: String
    }

    /// 前台探测间隔。
    static let pollInterval: TimeInterval = 15

    /// 最新在前的待同步队列。
    private(set) var pending: [Item] = []

    /// 15 秒循环是否在跑。测试 host 必须保持 false。
    private(set) var isLoopRunning = false
}
