//
//  ScreensaverAvatarCache.swift
//  Starcat
//
//  主应用把 Owner 头像准备到屏保快照目录。.saver 不包含本文件，也不发起网络请求。
//

import AppKit
import CryptoKit
import Foundation

/// 为屏保快照准备本地头像文件，并按当前卡片集合 GC。
///
/// 关键约束：
/// - 列表 / Widget 常见 32…80px 头像不能拿来放大铺满屏保格子；
/// - GitHub 头像原图经常停在约 460px，所以复用门槛用 460 而不是死卡 512，避免下完再丢；
/// - 下载并发上限对齐 `AvatarCacheLoader`，避免上千 Owner 打爆 CDN。
struct ScreensaverAvatarCache: Sendable {
    typealias Downloader = @Sendable (URL) async -> Data?
    typealias LocalImageSource = @Sendable (URL) async -> Data?
    typealias ProgressHandler = @Sendable (Int, Int) -> Void

    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let requestedPixelSize = 512
    static let minimumReusablePixelSize = 460
    /// 上千 Owner 必须并行；8 路与导出头像加载器同一档。
    private static let downloadConcurrency = 8

    let containerURL: URL

    private var directoryURL: URL {
        ScreensaverSharedConfiguration.avatarsDirectoryURL(containerURL: containerURL)
    }

    init(containerURL: URL) {
        self.containerURL = containerURL
    }

    /// visualKey 映射为不可注入路径的稳定 PNG 文件名。
    static func fileName(visualKey: String) -> String {
        let digest = SHA256.hash(data: Data(visualKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    func enrich(
        cards: [AmbientCardModel],
        downloader: @escaping Downloader,
        localImageSource: LocalImageSource? = nil,
        onProgress: ProgressHandler? = nil
    ) async -> [ScreensaverSnapshotCard] {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        onProgress?(0, cards.count)
        guard !cards.isEmpty else {
            prune(keeping: [])
            return []
        }

        var results = [ScreensaverSnapshotCard?](repeating: nil, count: cards.count)
        await withTaskGroup(of: (Int, ScreensaverSnapshotCard).self) { group in
            var nextIndex = 0
            var running = 0
            let limit = min(Self.downloadConcurrency, cards.count)

            func enqueue() {
                while running < limit, nextIndex < cards.count {
                    let index = nextIndex
                    let card = cards[index]
                    nextIndex += 1
                    running += 1
                    group.addTask {
                        let snapshot = await self.materialize(
                            card,
                            downloader: downloader,
                            localImageSource: localImageSource
                        )
                        return (index, snapshot)
                    }
                }
            }

            enqueue()
            var completed = 0
            for await (index, snapshot) in group {
                results[index] = snapshot
                completed += 1
                onProgress?(completed, cards.count)
                running -= 1
                enqueue()
            }
        }

        let materialized = results.compactMap { $0 }
        prune(keeping: Set(materialized.compactMap(\.imageFileName)))
        return materialized
    }

    private func materialize(
        _ card: AmbientCardModel,
        downloader: @escaping Downloader,
        localImageSource: LocalImageSource?
    ) async -> ScreensaverSnapshotCard {
        let fileName = Self.fileName(visualKey: card.visualKey)
        let destinationURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        var storedFileName: String?

        if let existing = try? Data(contentsOf: destinationURL), isReusable(existing) {
            storedFileName = fileName
        } else if let remoteURL = allowedDownloadURL(from: card.artworkURLString) {
            if let local = await localImageSource?(remoteURL),
               let png = reusablePNGData(from: local) {
                storedFileName = writeReusablePNG(png, to: destinationURL, fileName: fileName)
            } else if let data = await downloader(remoteURL),
                      let png = reusablePNGData(from: data) {
                storedFileName = writeReusablePNG(png, to: destinationURL, fileName: fileName)
            }
        }

        return ScreensaverSnapshotCard(
            id: card.id,
            visualKey: card.visualKey,
            title: card.title,
            imageFileName: storedFileName
        )
    }

    func clear() {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func allowedDownloadURL(from rawValue: String?) -> URL? {
        guard let rawValue,
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              let host = url.host?.lowercased(),
              host == "github.com" || host == "avatars.githubusercontent.com" else {
            return nil
        }
        // 与 App 内 RemoteAvatar 同一套 size / s 规则，避免列表 80px 的 cache key 被误当成屏保图。
        return GitHubAvatarURL.imageURL(
            from: rawValue,
            displayDiameter: CGFloat(Self.requestedPixelSize),
            displayScale: 1,
            minimumPixelSize: Self.requestedPixelSize,
            maximumPixelSize: Self.requestedPixelSize
        ) ?? url
    }

    private func reusablePNGData(from data: Data) -> Data? {
        guard data.count <= Self.maximumResponseBytes, isReusable(data) else { return nil }
        return pngData(from: data)
    }

    private func isReusable(_ data: Data) -> Bool {
        guard let edge = pixelEdge(of: data) else { return false }
        return edge >= Self.minimumReusablePixelSize
    }

    private func pixelEdge(of data: Data) -> Int? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return min(bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    private func pngData(from data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func writeReusablePNG(_ png: Data, to destinationURL: URL, fileName: String) -> String? {
        do {
            try atomicWrite(png, to: destinationURL)
            return fileName
        } catch {
            return nil
        }
    }

    private func atomicWrite(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [])
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func prune(keeping retainedFileNames: Set<String>) {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for url in urls where !retainedFileNames.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}
