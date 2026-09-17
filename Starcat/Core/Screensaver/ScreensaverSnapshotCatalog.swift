//
//  ScreensaverSnapshotCatalog.swift
//  Starcat
//
//  把 App Group 快照投影为 Ambient 卡片。屏保进程只走这条只读路径。
//

import Foundation

/// 从本地快照提供 Owner 卡片；缺图时保留 title 仅供占位首字母使用。
struct ScreensaverSnapshotCatalog: AmbientCatalogProviding {
    let store: ScreensaverSnapshotStore

    init(store: ScreensaverSnapshotStore) {
        self.store = store
    }

    func loadCards(scene: AmbientSceneKind) async throws -> [AmbientCardModel] {
        let snapshot = try store.load()
        let avatars = ScreensaverSharedConfiguration.avatarsDirectoryURL(
            containerURL: store.containerURL
        )
        return snapshot.cards.map { card in
            let artworkURLString = resolvedArtworkURLString(
                imageFileName: card.imageFileName,
                avatarsDirectory: avatars
            )
            return AmbientCardModel(
                id: card.id,
                visualKey: card.visualKey,
                title: card.title,
                artworkURLString: artworkURLString,
                subtitle: nil,
                metadata: [:]
            )
        }
    }

    private func resolvedArtworkURLString(
        imageFileName: String?,
        avatarsDirectory: URL
    ) -> String? {
        guard let imageFileName,
              !imageFileName.isEmpty,
              !imageFileName.contains("/"),
              !imageFileName.contains("..") else {
            return nil
        }
        let url = avatarsDirectory.appendingPathComponent(imageFileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.absoluteString
    }
}
