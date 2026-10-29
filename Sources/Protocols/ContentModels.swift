// SPDX-License-Identifier: GPL-3.0-only
// UI 侧已有 Codable 的 Series/Topic/RankPosition 等；此文件类型仅服务取数层，结果再映射回 UI 模型
import Foundation


/// 一集可播放的某种清晰度
struct Rendition {
    let quality: Int
    let codec: String
    let width: Int?
    let height: Int?
    let url: String
    let key: [UInt8]?

    /// 死代码：映射为 UI 侧 StreamInfo，当前未接入（取流直接返回 StreamInfo）
    func toStreamInfo() -> StreamInfo {
        StreamInfo(url: url, key: key, quality: quality > 0 ? "\(quality)P" : "自动")
    }
}

/// 某一集全部可选清晰度，按清晰度 + 编码择优
struct StreamLadder {
    let renditions: [Rendition]

    /// 同清晰度下编码优先级：HEVC > AVC > 其它
    private func codecRank(_ codec: String) -> Int {
        if CodecCapabilities.isHEVC(codec) { return 2 }
        if CodecCapabilities.isAVC(codec) { return 1 }
        return 0   // AV1 / 未知
    }

    /// 清晰度优先，同清晰度 HEVC > AVC > 其它
    private func isBetter(_ a: Rendition, than b: Rendition) -> Bool {
        if a.quality != b.quality { return a.quality > b.quality }
        return codecRank(a.codec) > codecRank(b.codec)
    }

    func select(maxQuality: Int, supported: (Rendition) -> Bool = { _ in true }) -> Rendition? {
        let pool = renditions.filter(supported)
        let effective = pool.isEmpty ? renditions : pool
        // maxQuality <= 0 表示自动，选源提供的最高档
        let within = effective.filter { $0.quality >= 1 && (maxQuality <= 0 || $0.quality <= maxQuality) }
        if let best = within.max(by: { isBetter($1, than: $0) }) { return best }
        let autoOrLower = effective.filter { $0.quality <= 0 }
        if let best = autoOrLower.max(by: { isBetter($1, than: $0) }) { return best }
        return effective.min(by: { isBetter($1, than: $0) })
    }

    /// 死代码：供逐档降级验证，当前只用 select() 一步到位，未启用
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
    /// 死代码：由路由串反解枚举，当前前端直接按 rawValue 匹配
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
    /// 死代码：当前未接入，接口差异化加载时用
    var loader: String {
        switch self {
        case .comic: return "comic_rank"
        case .real: return "real_rank"
        case .ai: return "ai_rank"
        }
    }
    /// 死代码：当前无读取方
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

/// 中间结果的合集
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

    // 从 item.tags 切分标签 token 作为榜单题材
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

func isValidNumericId(_ id: String, _ min: Int = 1, _ max: Int = 30) -> Bool {
    guard let _ = id.range(of: "^[0-9]{\(min),\(max)}$", options: .regularExpression) else { return false }
    return true
}
