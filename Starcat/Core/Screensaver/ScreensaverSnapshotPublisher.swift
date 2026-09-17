//
//  ScreensaverSnapshotPublisher.swift
//  Starcat
//
//  从当前账号 stars 拍 Owner 快照并写入屏保 App Group。发布必须带 userID，
//  切号 / 登出由调用方先 clear 再按新账号发布，避免旧头像留在容器里。
//

import Foundation

/// 把 Ambient Owner 目录写成屏保可消费的本地快照。
struct ScreensaverSnapshotPublisher {
    typealias LoadCards = () async throws -> [AmbientCardModel]
    typealias Clock = () -> Date

    private let loadCards: LoadCards
    private let store: ScreensaverSnapshotStore
    private let cache: ScreensaverAvatarCache
    private let downloader: ScreensaverAvatarCache.Downloader
    private let localImageSource: ScreensaverAvatarCache.LocalImageSource
    private let now: Clock

    init(
        loadCards: @escaping LoadCards,
        store: ScreensaverSnapshotStore,
        cache: ScreensaverAvatarCache,
        downloader: @escaping ScreensaverAvatarCache.Downloader,
        localImageSource: @escaping ScreensaverAvatarCache.LocalImageSource = { _ in nil },
        now: @escaping Clock = Date.init
    ) {
        self.loadCards = loadCards
        self.store = store
        self.cache = cache
        self.downloader = downloader
        self.localImageSource = localImageSource
        self.now = now
    }

    func publish(
        userID: Int64,
        onProgress: ScreensaverAvatarCache.ProgressHandler? = nil
    ) async throws {
        let cards = try await loadCards()
        let snapshotCards = await cache.enrich(
            cards: cards,
            downloader: downloader,
            localImageSource: localImageSource,
            onProgress: onProgress
        )
        try store.save(
            ScreensaverSnapshot(
                generatedAt: now(),
                userID: userID,
                cards: snapshotCards
            )
        )
    }

    func clear() throws {
        try store.delete()
    }

    static func makeNetworkDownloader() -> ScreensaverAvatarCache.Downloader {
        { url in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("StarcatScreensaver/1", forHTTPHeaderField: "User-Agent")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 15
            let session = URLSession(configuration: configuration)
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      data.count <= 2 * 1_024 * 1_024 else {
                    return nil
                }
                return data
            } catch {
                return nil
            }
        }
    }

    /// 只复用 Kingfisher 里已经按屏保 URL（size/s=512）缓存、且像素够大的原图。
    static func makeLocalImageSource() -> ScreensaverAvatarCache.LocalImageSource {
        { url in
            AvatarCacheLoader.cachedImageData(for: url)
        }
    }
}
