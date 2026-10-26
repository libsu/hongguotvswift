// SPDX-License-Identifier: GPL-3.0-only
// 切集预热缓存：按 episodeID 缓存已解析的加密索引（MediaCrypto.Prepared）与会话配置，
// 使 play 命中预热时跳过取流/解析延迟（对齐 上游 RemoteVideo 的 warmed 单槽语义，
// 但改为按 episodeID 精确键控，切集/切清晰度时作废，避免串集）。
import Foundation

/// 一个已完成预热的播放会话缓存项。
struct PreparedEntry {
    let episodeID: String
    let quality: Int
    let stream: ResourceLoader.Stream
    let prepared: MediaCrypto.Prepared
    let total: Int64
    /// 可选预取的「开头第一段已解密媒体数据」：起始绝对偏移 + 解密后字节，
    /// 供切集时 ResourceLoader 直接回喂，消除首包网络延迟。
    let mediaPrefixStart: Int64
    let mediaPrefix: [UInt8]

    init(episodeID: String, quality: Int, stream: ResourceLoader.Stream, prepared: MediaCrypto.Prepared, total: Int64, mediaPrefixStart: Int64 = 0, mediaPrefix: [UInt8] = []) {
        self.episodeID = episodeID; self.quality = quality; self.stream = stream
        self.prepared = prepared; self.total = total
        self.mediaPrefixStart = mediaPrefixStart; self.mediaPrefix = mediaPrefix
    }
}

@MainActor
final class PreparedCache {
    private var entries: [String: PreparedEntry] = [:]
    private let capacity: Int

    init(capacity: Int = 2) {
        self.capacity = capacity
    }

    func key(episodeID: String, quality: Int) -> String {
        "\(episodeID)/\(quality)"
    }

    func get(episodeID: String, quality: Int) -> PreparedEntry? {
        entries[key(episodeID: episodeID, quality: quality)]
    }

    /// 保存一个预热条目，按 LRU 上限淘汰。
    func put(_ entry: PreparedEntry) {
        let k = key(episodeID: entry.episodeID, quality: entry.quality)
        entries[k] = entry
        if entries.count > capacity {
            if let oldest = entries.keys.first { entries.removeValue(forKey: oldest) }
        }
    }

    /// 切集/作废时清空（避免串集）。
    func clear() {
        entries.removeAll()
    }

    /// 死代码：按 episodeID 作废，当前 clear() 已覆盖。
    func invalidate(episodeID: String) {
        entries = entries.filter { $0.value.episodeID != episodeID }
    }
}
