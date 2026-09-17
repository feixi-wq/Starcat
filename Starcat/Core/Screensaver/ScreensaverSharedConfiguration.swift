//
//  ScreensaverSharedConfiguration.swift
//  Starcat
//
//  Direct App 与 .saver 共用的快照文件布局。
//
//  关键约束：
//  - 不新增 App Group。新 group 需要改描述文件，当前 Direct Debug profile
//    还没有 `group.com.starcat.app.direct.screensaver`；
//  - Direct 主应用非沙箱，直接写 Application Support；
//  - `.saver` 进程沙箱只申请 home-relative 只读例外，读取同一目录。
//

import Foundation

/// 解析屏保快照目录与固定文件名。
enum ScreensaverSharedConfiguration {
    static let snapshotFileName = "screensaver-snapshot-v1.json"
    static let avatarsDirectoryName = "avatars"
    static let relativeSupportPath = "Library/Application Support/com.starcat.app/screensaver"

    static func productionContainerURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeSupportPath, isDirectory: true)
    }

    static func snapshotURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(snapshotFileName, isDirectory: false)
    }

    static func avatarsDirectoryURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(avatarsDirectoryName, isDirectory: true)
    }
}
