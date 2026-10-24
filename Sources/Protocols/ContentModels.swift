// SPDX-License-Identifier: GPL-3.0-only
// 注意：UI 侧已有 Codable 的 Series/Topic/MacRank 等；这里的类型只服务于「取数」层，
// 结果最后映射回 UI 的 Codable 模型（见各 Protocol 文件的 toXXX 桥接）。
import Foundation

// 输出给桥接层的中间结果（与 上游 data class 对应）。

/// 一集可播放的某种清晰度（对应 上游 Rendition）。
struct Rendition {
    let quality: Int
    let codec: String
    let width: Int?
    let height: Int?
    let url: String
    let key: [UInt8]?

    func toStreamInfo() -> StreamInfo {
        StreamInfo(url: url, key: key, quality: quality > 0 ? "\(quality)P" : "自动")
    }
}

/// 某一集全部可选清晰度（对应 上游 StreamLadder），按清晰度 + 编码择优。
struct StreamLadder {
    let renditions: [Rendition]

    /// 同清晰度下的编码优先级：HEVC 优先（更省流量、加载更快，绝大多数 Mac 可解），
    /// 其次 AVC（为兼容旧设备保留）。返回越大越优。
    private func codecRank(_ codec: String) -> Int {
        if CodecCapabilities.isHEVC(codec) { return 2 }
        if CodecCapabilities.isAVC(codec) { return 1 }
        return 0   // AV1 / 未知
    }

    /// 更优判断：清晰度优先，同清晰度 HEVC > AVC > 其它。
    private func isBetter(_ a: Rendition, than b: Rendition) -> Bool {
        if a.quality != b.quality { return a.quality > b.quality }
        return codecRank(a.codec) > codecRank(b.codec)
    }

    func select(maxQuality: Int, supported: (Rendition) -> Bool = { _ in true }) -> Rendition? {
        let pool = renditions.filter(supported)
        let effective = pool.isEmpty ? renditions : pool
        // maxQuality <= 0 表示「自动/不限上限」，选源提供的最高可用档位。
        let within = effective.filter { $0.quality >= 1 && (maxQuality <= 0 || $0.quality <= maxQuality) }
        if let best = within.max(by: { isBetter($1, than: $0) }) { return best }
        let autoOrLower = effective.filter { $0.quality <= 0 }
        if let best = autoOrLower.max(by: { isBetter($1, than: $0) }) { return best }
        return effective.min(by: { isBetter($1, than: $0) })
    }

    /// 上游: playbackOrder(maxQuality, supported) —— select() 先选最佳，
    /// 再把「质量不高于选中项」的其它候选项按优到劣排在其后，供逐档降级验证。
    func playbackOrder(maxQuality: Int, supported: (Rendition) -> Bool = { _ in true }) -> [Rendition] {
        guard let pick = select(maxQuality: maxQuality, supported: supported) else { return [] }
        let alternates = renditions.filter { $0.url != pick.url && $0.quality <= pick.quality }
            .sorted { isBetter($0, than: $1) }
        return [pick] + alternates
    }
}

enum DramaCategory: String {
    case real = "REAL"
    case comic = "COMIC"
    case ai = "AI"

    var label: String {
        switch self {
        case .real: return "真人剧"
        case .comic: return "漫剧"
        case .ai: return "AI 剧"
        }
    }
    var route: String {
        switch self {
        case .real: return "real-drama"
        case .comic: return "comic-drama"
        case .ai: return "ai-drama"
        }
    }
    init?(fromRoute route: String) {
        switch route {
        case "real-drama": self = .real
        case "comic-drama": self = .comic
        case "ai-drama": self = .ai
        default: return nil
        }
    }
}

enum RankBoard: String {
    case comic = "COMIC"
    case real = "REAL"
    case ai = "AI"

    var route: String {
        switch self {
        case .comic: return "hot-comic-drama"
        case .real: return "hot-real-drama"
        case .ai: return "hot-ai-drama"
        }
    }
    /// loader 名（对应 上游 RankBoard.loader）
    var loader: String {
        switch self {
        case .comic: return "comic_rank"
        case .real: return "real_rank"
        case .ai: return "ai_rank"
        }
    }
    /// key（对应 上游 RankBoard.key）
    var key: String {
        switch self {
        case .comic: return "comic"
        case .real: return "real"
        case .ai: return "ai"
        }
    }
}

struct RankPosition {
    let rank: Int?
    let heat: String
    let metrics: String
}

struct ComicRanking {
    let positions: [String: RankPosition]
    let totalPages: Int
    let updatedText: String
}

struct DiscoveryInfo {
    let topics: [DramaTopic]
    let totalPages: Int
    let pageSize: Int
    let total: Int
}

struct DramaTopic {
    let id: String
    let label: String
}

/// 中间结果的合集。
struct CatalogPage {
    let items: [Series]
    let hasMore: Bool
    let ranking: ComicRanking?
    let discovery: DiscoveryInfo?
    let trialHints: [String: TrialHint]

    init(items: [Series], hasMore: Bool, ranking: ComicRanking? = nil, discovery: DiscoveryInfo? = nil, trialHints: [String: TrialHint] = [:]) {
        self.items = items; self.hasMore = hasMore; self.ranking = ranking; self.discovery = discovery; self.trialHints = trialHints
    }
}

struct TrialHint { let episodeId: String; let episodeCount: Int }

struct StreamInfo {
    let url: String
    let key: [UInt8]?
    let quality: String
}

struct RankSnapshot {
    let board: RankBoard
    let items: [Series]
    let ranking: ComicRanking

    // 对齐 上游 RankSnapshot：从 item.tags 切分标签 token 作为榜单题材。
    var topics: [DramaTopic] {
        var counts: [String: Int] = [:]
        for item in items {
            for token in topicTokens(item) {
                counts[token, default: 0] += 1
            }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { DramaTopic(id: $0.key, label: $0.key) }
    }

    func filtered(_ topic: String) -> [Series] {
        if topic.isEmpty { return items }
        return items.filter { topicTokens($0).contains(topic) }
    }

    private func topicTokens(_ item: Series) -> [String] {
        item.tags.split(separator: "·").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0.isNumber } }
    }
}

struct RelatedWork {
    let series: Series
    let season: String
    let upcoming: Bool
}

extension Series {
    /// 生成 id 校验：上游 `[0-9]{1,30}`。
    var isValidId: Bool { id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil }
}

func isValidNumericId(_ id: String, _ min: Int = 1, _ max: Int = 30) -> Bool {
    guard let _ = id.range(of: "^[0-9]{\(min),\(max)}$", options: .regularExpression) else { return false }
    return true
}

/// 生成纯数字播放设备 id（上游 newPlayerDeviceId()）。
func newPlayerDeviceId() -> String {
    var s = "3"
    for _ in 0..<18 { s += String(Int.random(in: 0...9)) }
    return s
}
