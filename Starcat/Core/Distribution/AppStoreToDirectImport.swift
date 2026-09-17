//
//  AppStoreToDirectImport.swift
//  Starcat
//
//  Direct 正式版第一次打开时，把本机 App Store 正式容器里的数据拷到 Direct。
//
//  关键约束：
//  - 只认 `com.starcat.app.store`，忽略 `.store.debug` 和任何 Direct 容器；
//  - 只拷不共用：两边目录仍然独立，App Store 原数据不删；
//  - 必须用户确认；选「不拷贝」后不再追问；
//  - Apple 订阅 / StoreKit 镜像不迁，避免 Direct 出现假 Pro。
//

import AppKit
import Foundation

/// 正式渠道的固定标识。Debug bundle 故意排除。
enum AppStoreToDirectImportIdentity {
    static let officialAppStoreBundleID = "com.starcat.app.store"
    static let officialDirectBundleID = "com.starcat.app.direct"
    static let storeWidgetGroupID = "group.com.starcat.app.store.widgets"
    static let directWidgetGroupID = "group.com.starcat.app.direct.widgets"
    static let kingfisherCacheFolderName = "com.onevcat.Kingfisher.ImageCache.default"
    static let storePreferencesFileName = "com.starcat.app.store.plist"
    static let productSupportFolderName = "Starcat"
    static let decisionDefaultsKey = "launch.directImport.fromAppStore.decision.v1"
}

/// 用户对首次导入弹窗的选择。
enum AppStoreToDirectImportDecision: String, Equatable, Sendable {
    case skipped
    case imported
}

/// Direct / App Store 在本机家目录下的路径布局。
///
/// 生产走 POSIX 家目录：导入只跑在无沙盒的正式 Direct 里。
/// 测试注入临时 `homeDirectory`，避免碰到真实 Containers。
struct AppStoreToDirectImportLayout: Sendable {
    var homeDirectory: URL

    static func live() -> AppStoreToDirectImportLayout {
        AppStoreToDirectImportLayout(
            homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    var storeContainerURL: URL {
        homeDirectory
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.officialAppStoreBundleID, isDirectory: true)
    }

    var storeLibraryURL: URL {
        storeContainerURL
            .appendingPathComponent("Data/Library", isDirectory: true)
    }

    var storeApplicationSupportRoot: URL {
        storeLibraryURL.appendingPathComponent("Application Support", isDirectory: true)
    }

    var storeStarcatAppSupport: URL {
        storeApplicationSupportRoot.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
    }

    var storeProductSupport: URL {
        storeApplicationSupportRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.productSupportFolderName,
            isDirectory: true
        )
    }

    var storeCachesRoot: URL {
        storeLibraryURL.appendingPathComponent("Caches", isDirectory: true)
    }

    var storeKingfisherCache: URL {
        storeCachesRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.kingfisherCacheFolderName,
            isDirectory: true
        )
    }

    var storePreferencesPlist: URL {
        storeLibraryURL
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.storePreferencesFileName, isDirectory: false)
    }

    var storeWidgetGroup: URL {
        homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.storeWidgetGroupID, isDirectory: true)
    }

    var directApplicationSupportRoot: URL {
        homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    var directStarcatAppSupport: URL {
        directApplicationSupportRoot.appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
    }

    var directProductSupport: URL {
        directApplicationSupportRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.productSupportFolderName,
            isDirectory: true
        )
    }

    var directCachesRoot: URL {
        homeDirectory.appendingPathComponent("Library/Caches", isDirectory: true)
    }

    var directKingfisherCache: URL {
        directCachesRoot.appendingPathComponent(
            AppStoreToDirectImportIdentity.kingfisherCacheFolderName,
            isDirectory: true
        )
    }

    var directWidgetGroup: URL {
        homeDirectory
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(AppStoreToDirectImportIdentity.directWidgetGroupID, isDirectory: true)
    }
}

/// 是否弹出导入确认的纯判断。IO 和进程检查放在调用方。
enum AppStoreToDirectImportEvaluator {
    static func shouldPrompt(
        isOfficialDirectBuild: Bool,
        hasRecordedDecision: Bool,
        storeHasImportableData: Bool,
        destinationIsEmpty: Bool
    ) -> Bool {
        isOfficialDirectBuild
            && !hasRecordedDecision
            && storeHasImportableData
            && destinationIsEmpty
    }

    static func isOfficialDirectBuild(
        bundleIdentifier: String?,
        channel: DistributionChannel
    ) -> Bool {
        channel.isDirect && bundleIdentifier == AppStoreToDirectImportIdentity.officialDirectBundleID
    }

    /// 商店容器里有用户库或加密凭据，才值得问。
    static func storeHasImportableData(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager
    ) -> Bool {
        containsStarcatDatabase(at: layout.storeStarcatAppSupport, fileManager: fileManager)
            || fileManager.fileExists(atPath: layout.storeStarcatAppSupport.appendingPathComponent("credentials.json").path)
    }

    /// Direct 已有库或凭据就当作已经用过，不再覆盖。
    static func destinationIsEmpty(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager
    ) -> Bool {
        !containsStarcatDatabase(at: layout.directStarcatAppSupport, fileManager: fileManager)
            && !fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("credentials.json").path)
    }

    static func containsStarcatDatabase(at root: URL, fileManager: FileManager) -> Bool {
        let users = root.appendingPathComponent(AppConstants.usersDirectoryName, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: users,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator where url.lastPathComponent == AppConstants.databaseFileName {
            return true
        }
        return false
    }
}

/// 首次导入选择落在 Direct 自己的 UserDefaults 里，和商店版 plist 隔离。
struct AppStoreToDirectImportDecisionStore {
    var defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var decision: AppStoreToDirectImportDecision? {
        guard let raw = defaults.string(forKey: AppStoreToDirectImportIdentity.decisionDefaultsKey) else {
            return nil
        }
        return AppStoreToDirectImportDecision(rawValue: raw)
    }

    func record(_ decision: AppStoreToDirectImportDecision) {
        defaults.set(decision.rawValue, forKey: AppStoreToDirectImportIdentity.decisionDefaultsKey)
    }
}

/// 查询商店版是否仍在运行。测试注入假实现，避免依赖本机进程。
protocol AppStoreToDirectImportProcessInspecting: Sendable {
    func isAppStoreStarcatRunning() -> Bool
}

struct LaunchServicesAppStoreProcessInspector: AppStoreToDirectImportProcessInspecting {
    func isAppStoreStarcatRunning() -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: AppStoreToDirectImportIdentity.officialAppStoreBundleID
        ).isEmpty
    }
}

/// 文件拷贝已在启动前检查过商店版进程，后台任务不再重复查。
struct IdleAppStoreProcessInspector: AppStoreToDirectImportProcessInspecting {
    func isAppStoreStarcatRunning() -> Bool { false }
}
