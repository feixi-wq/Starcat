//
//  AmbientArtworkStyle.swift
//  Starcat
//
//  Ambient / 屏保共用的占位与像素尺寸纯函数。图片加载仍留在各自壳层，
//  避免 Core 依赖 Kingfisher 或 GitHub URL 规则。
//

import Foundation

/// 稳定占位与解码边长。App Ambient 和系统屏保必须得出同一套色板索引。
enum AmbientArtworkStyle {
    static let paletteCount = 8

    static func targetPixelSize(tilePointSize: Double, displayScale: Double) -> Int {
        let requested = Int(ceil(max(1, tilePointSize) * max(1, displayScale)))
        return min(max(requested, 64), 1_024)
    }

    static func monogram(from title: String) -> String? {
        guard let character = title.first(where: { !$0.isWhitespace }) else { return nil }
        return String(character).uppercased()
    }

    /// Swift 的 `hashValue` 每进程随机；FNV-1a 保证同一 card id 永远映射同一占位色。
    static func paletteIndex(for cardID: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in cardID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash % UInt64(paletteCount))
    }
}
