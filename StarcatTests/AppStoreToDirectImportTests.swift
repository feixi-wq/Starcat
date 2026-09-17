//
//  AppStoreToDirectImportTests.swift
//  StarcatTests
//
//  Direct 首次从 App Store 拷贝数据：只认正式商店容器、确认后才拷、临时文件跳过。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AppStoreToDirectImport")
struct AppStoreToDirectImportTests {

    @Test("只在正式 Direct、尚未问过、商店有数据且 Direct 为空时弹出")
    func promptsOnlyForOfficialEmptyDirect() {
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isOfficialDirectBuild: true,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: true
            )
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isOfficialDirectBuild: false,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: true
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isOfficialDirectBuild: true,
                hasRecordedDecision: true,
                storeHasImportableData: true,
                destinationIsEmpty: true
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.shouldPrompt(
                isOfficialDirectBuild: true,
                hasRecordedDecision: false,
                storeHasImportableData: true,
                destinationIsEmpty: false
            ) == false
        )
    }

    @Test("Debug Direct 和 App Store 渠道都不算正式 Direct")
    func rejectsNonOfficialBundles() {
        #expect(
            AppStoreToDirectImportEvaluator.isOfficialDirectBuild(
                bundleIdentifier: "com.starcat.app.direct.debug",
                channel: .direct
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.isOfficialDirectBuild(
                bundleIdentifier: "com.starcat.app.direct",
                channel: .appStore
            ) == false
        )
        #expect(
            AppStoreToDirectImportEvaluator.isOfficialDirectBuild(
                bundleIdentifier: "com.starcat.app.direct",
                channel: .direct
            )
        )
    }

    @Test("Debug 商店容器不参与检测，正式商店库才算可导入")
    func ignoresDebugStoreContainer() throws {
        try withImportHome { home, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "42")
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager))
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))

            let debugContainer = home
                .appendingPathComponent("Library/Containers/com.starcat.app.store.debug/Data/Library/Application Support/com.starcat.app/users/99", isDirectory: true)
            try fileManager.createDirectory(at: debugContainer, withIntermediateDirectories: true)
            try Data("debug".utf8).write(to: debugContainer.appendingPathComponent("starcat.sqlite"))

            try fileManager.removeItem(at: layout.storeStarcatAppSupport)
            #expect(AppStoreToDirectImportEvaluator.storeHasImportableData(layout: layout, fileManager: fileManager) == false)
        }
    }

    @Test("确认拷贝会带走库、凭据、ZIP、头像缓存，并跳过临时文件")
    func copiesDurableFilesAndSkipsTemporary() throws {
        try withImportHome { _, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "42")
            try Data("token".utf8).write(
                to: layout.storeStarcatAppSupport.appendingPathComponent("credentials.json")
            )

            let zipDirectory = layout.storeProductSupport.appendingPathComponent("archives/github.com/octo", isDirectory: true)
            try fileManager.createDirectory(at: zipDirectory, withIntermediateDirectories: true)
            try Data("zip".utf8).write(to: zipDirectory.appendingPathComponent("repo.zip"))
            try Data("partial".utf8).write(to: zipDirectory.appendingPathComponent("repo.zip.tmp"))

            try fileManager.createDirectory(at: layout.storeKingfisherCache, withIntermediateDirectories: true)
            try Data("avatar".utf8).write(to: layout.storeKingfisherCache.appendingPathComponent("owner.png"))

            try fileManager.createDirectory(at: layout.storeWidgetGroup, withIntermediateDirectories: true)
            try Data("widget".utf8).write(to: layout.storeWidgetGroup.appendingPathComponent("widget-snapshot-v1.json"))

            try writeStorePreferences(
                layout: layout,
                fileManager: fileManager,
                values: [
                    "settings.appearanceMode": "dark",
                    "settings.pro.isProUser": true
                ]
            )

            let defaults = try isolatedDefaults()
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: FixedProcessInspector(isRunning: false),
                destinationDefaults: defaults
            )

            try service.copyConfirmedData()

            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("users/42/starcat.sqlite").path))
            #expect(fileManager.fileExists(atPath: layout.directStarcatAppSupport.appendingPathComponent("credentials.json").path))
            #expect(fileManager.fileExists(atPath: layout.directProductSupport.appendingPathComponent("archives/github.com/octo/repo.zip").path))
            #expect(fileManager.fileExists(atPath: layout.directProductSupport.appendingPathComponent("archives/github.com/octo/repo.zip.tmp").path) == false)
            #expect(fileManager.fileExists(atPath: layout.directKingfisherCache.appendingPathComponent("owner.png").path))
            #expect(fileManager.fileExists(atPath: layout.directWidgetGroup.appendingPathComponent("widget-snapshot-v1.json").path))
            #expect(fileManager.fileExists(atPath: layout.storeStarcatAppSupport.appendingPathComponent("users/42/starcat.sqlite").path))
            #expect(defaults.string(forKey: "settings.appearanceMode") == "dark")
            #expect(defaults.object(forKey: AppSettings.Keys.isProUser) == nil)
        }
    }

    @Test("商店版仍在运行时拒绝拷贝")
    func refusesCopyWhileStoreAppRunning() throws {
        try withImportHome { _, layout, fileManager in
            try writeStoreDatabase(layout: layout, fileManager: fileManager, userID: "1")
            let service = AppStoreToDirectImportCopyService(
                layout: layout,
                fileManager: fileManager,
                processInspector: FixedProcessInspector(isRunning: true),
                destinationDefaults: try isolatedDefaults()
            )

            #expect(throws: AppStoreToDirectImportError.storeAppRunning) {
                try service.copyConfirmedData()
            }
            #expect(AppStoreToDirectImportEvaluator.destinationIsEmpty(layout: layout, fileManager: fileManager))
        }
    }

    @Test("Pro 与 StoreKit 相关偏好不会迁入 Direct")
    func skipsSubscriptionPreferenceKeys() {
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("settings.appearanceMode"))
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey(AppSettings.Keys.isProUser) == false)
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("SUEnableAutomaticChecks") == false)
        #expect(AppStoreToDirectImportCopyService.shouldMigratePreferenceKey("storekit.transaction.cache") == false)
        #expect(
            AppStoreToDirectImportCopyService.shouldMigratePreferenceKey(
                AppStoreToDirectImportIdentity.decisionDefaultsKey
            ) == false
        )
    }

    private func withImportHome(
        _ body: (URL, AppStoreToDirectImportLayout, FileManager) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent(
            "direct-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }
        try body(home, AppStoreToDirectImportLayout(homeDirectory: home), fileManager)
    }

    private func writeStoreDatabase(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager,
        userID: String
    ) throws {
        let directory = layout.storeStarcatAppSupport
            .appendingPathComponent("users/\(userID)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("sqlite".utf8).write(to: directory.appendingPathComponent("starcat.sqlite"))
    }

    private func writeStorePreferences(
        layout: AppStoreToDirectImportLayout,
        fileManager: FileManager,
        values: [String: Any]
    ) throws {
        let directory = layout.storePreferencesPlist.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: layout.storePreferencesPlist)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "starcat.direct-import.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw AppStoreToDirectImportError.copyFailed(message: "defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

private struct FixedProcessInspector: AppStoreToDirectImportProcessInspecting {
    let isRunning: Bool

    func isAppStoreStarcatRunning() -> Bool {
        isRunning
    }
}
