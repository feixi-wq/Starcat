//
//  ExternalStarInboxTests.swift
//  StarcatTests
//
//  外部新增星标收件箱：头像槽位、探测累加、ETag 隔离、门控与清队列。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("ExternalStarInbox")
struct ExternalStarInboxTests {

    @Test("1/2/3 pending items render avatars only")
    func presentationAvatarsOnlyWhenAtMostThree() {
        let items = (1...3).map(Self.makeItem)
        let slots = ExternalStarInboxPresentation.slots(from: items)
        #expect(slots.count == 3)
        #expect(slots.allSatisfy { if case .avatar = $0 { true } else { false } })
    }

    @Test("4 items become 3 avatars plus +1")
    func presentationOverflowFour() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...4).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 1)
    }

    @Test("5 items become 3 avatars plus +2")
    func presentationOverflowFive() {
        let slots = ExternalStarInboxPresentation.slots(from: (1...5).map(Self.makeItem))
        #expect(slots.count == 4)
        guard case .overflow(let count) = slots.last else {
            Issue.record("expected overflow slot")
            return
        }
        #expect(count == 2)
        if case .avatar(let repoID, _, _) = slots[0] {
            #expect(repoID == 1)
        } else {
            Issue.record("newest item should stay first")
        }
    }

    static func makeItem(_ repoID: Int64) -> ExternalStarInbox.Item {
        ExternalStarInbox.Item(
            repoID: repoID,
            ownerLogin: "o\(repoID)",
            avatarURL: "https://avatars.githubusercontent.com/u/\(repoID)",
            starredAt: "2026-09-18T00:00:00Z"
        )
    }
}
