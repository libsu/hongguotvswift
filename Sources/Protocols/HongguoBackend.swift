// SPDX-License-Identifier: GPL-3.0-only
// Mac 客户端协议层编排：把原先由本地 Helper（上游）提供的只读接口，
// 改为直连官方 HTTPS 的 Swift 实现 返回结果仍是 JSON 结构（[String: Any]），
// 由 Model.request 用同一套 Decodable 模型解码，从而保证 UI 零改动
import Foundation

/// 只读协议后端 账号层（account/*）与媒体层（play/warm/video）在后续阶段迁移，
/// 阶段 2 仅覆盖：search / feed / catalog / rank / related / detail / comments /
/// comment-page / danmaku
@MainActor
final class HongguoBackend {
    let repository: ContentRepository
    private let publicComments: PublicComments
    private let timedComments: TimedComments
    private let appCommentPages: AppCommentPages
    private let http: HongguoHTTP
    private let account: AccountSession

    init(session: URLSession? = nil) {
        let http = session.map { HongguoHTTP(session: $0) } ?? HongguoHTTP()
        self.http = http
        self.repository = ContentRepository(http: http)
        self.publicComments = PublicComments(http: http)
        self.timedComments = TimedComments(transport: CommentTransport(http: http))
        self.appCommentPages = AppCommentPages(transport: CommentTransport(http: http))
        self.account = AccountSession(http: http)
    }

    // MARK: - 各 operation 的实现，返回 JSON 结构

    func search(q: String, page: Int) async throws -> [String: Any] {
        let result = try await repository.searchAll(keyword: q, page: page)
        return ["items": result.items.map(seriesJSON), "hasMore": result.hasMore]
    }

    func feed(category: String, page: Int, refresh: Bool) async throws -> [String: Any] {
        // 对齐官网「分类」页（首页推荐 = category?tab=1&sort_type=1；漫剧/真人 = 同名 category 路由）
        // 不再使用签名 mall-tab/category-landpage（该接口结构已变化）
        var items: [Series] = []
        var hasMore = false
        if category == "ALL" {
            let result = try await repository.home(page: page)
            items = result.items; hasMore = result.hasMore
        } else if let cat = DramaCategory(rawValue: category) {
            let result = try await repository.discover(category: cat, topic: "", page: page)
            items = result.items; hasMore = result.hasMore
        }
        return ["items": items.map(seriesJSON), "hasMore": hasMore, "topics": []]
    }

    func catalog(category: String, topic: String, board: String, page: Int, refresh: Bool) async throws -> [String: Any] {
        // board 在此操作用不到（上游 catalog 只用 category/topic），rank 单独处理
        return try await discover(category: category, topic: topic, page: page)
    }

    func rank(category: String, topic: String, board: String, page: Int, refresh: Bool) async throws -> [String: Any] {
        let boardEnum = RankBoard(rawValue: board.isEmpty ? "COMIC" : board) ?? .comic
        let snapshot = try await repository.rankSnapshot(board: boardEnum)
        var positions: [String: Any] = [:]
        for (id, pos) in snapshot.ranking.positions {
            var value: [String: Any] = ["heat": pos.heat]
            value["rank"] = pos.rank as Any? ?? NSNull()
            positions[id] = value
        }
        let items = snapshot.filtered(topic)
        return [
            "items": items.map(seriesJSON),
            "hasMore": false,
            "positions": positions,
            "topics": snapshot.topics.map { ["id": $0.id, "label": $0.label] },
        ]
    }

    func discover(category: String, topic: String, page: Int) async throws -> [String: Any] {
        let cat = DramaCategory(rawValue: category) ?? .comic
        let result = try await repository.discover(category: cat, topic: topic, page: page)
        return [
            "items": result.items.map(seriesJSON),
            "hasMore": result.hasMore,
            "topics": (result.discovery?.topics ?? []).map { ["id": $0.id, "label": $0.label] },
        ]
    }

    func related(id: String) async throws -> [String: Any] {
        let items = try await repository.related(id: id)
        return ["items": items.map { ["series": seriesJSON($0.series), "season": $0.season, "upcoming": $0.upcoming] }]
    }

    func detail(id: String) async throws -> [String: Any] {
        let (series, episodes) = try await repository.detail(id: id)
        return ["series": seriesJSON(series), "episodes": episodes]
    }

    func comments(series: String, episode: String) async throws -> [String: Any] {
        try await publicComments.read(series: series, episode: episode)
    }

    func commentPage(series: String, episode: String, cursor: String) async throws -> [String: Any] {
        try await appCommentPages.read(series: series, episode: episode, cursor: cursor)
    }

    func danmaku(series: String, episode: String, start: Int64, duration: Int64) async throws -> [String: Any] {
        try await timedComments.read(series: series, episode: episode, start: start, duration: duration)
    }

    // MARK: - 媒体取流（阶段 3）

    /// 解析某一集的播放流信息（URL + 密钥 + 实际清晰度），供 ResourceLoader 使用
    func stream(episodeID: String, quality: Int) async throws -> ResourceLoader.StreamAndQuality {
        let info = try await repository.stream(id: episodeID, maxQuality: quality)
        let host = URL(string: info.url)?.host ?? "unknown"
        Log.shared.info("stream episode=\(episodeID) quality=\(info.quality) host=\(host) key=\(info.key != nil)")
        return ResourceLoader.StreamAndQuality(url: info.url, key: info.key, quality: info.quality)
    }

    // MARK: - 账号（阶段 4）

    func accountHandle(action: String, query: [String: String], body: [String: Any]) async throws -> [String: Any] {
        try await account.handle(action: action, query: query, body: body)
    }

    func accountClose() { account.close() }

    let supportedOperations: Set<String> = ["search", "feed", "catalog", "rank", "related", "detail", "comments", "comment-page", "danmaku"]

    private func seriesJSON(_ s: Series) -> [String: Any] {
        ["id": s.id, "title": s.title, "cover": s.cover, "description": s.description, "badge": s.badge, "tags": s.tags]
    }
}
