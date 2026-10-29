// SPDX-License-Identifier: GPL-3.0-only
// App 推荐流（非官网分类列表） 无账号时 account 为 nil
import Foundation

/// 内存分页游标，等价 上游 RecommendationCursor 绝不序列化服务端会话
final class RecommendationCursor {
    var session: String = ""
    var offset: Int = 0
    var seen: Set<String> = []
    var expectedPage: Int = 1
    var lastPage: Int = 0
    var lastResult: CatalogPage?

    init(session: String = "", offset: Int = 0) {
        self.session = session; self.offset = offset
    }
    /// 设计目标：克隆当前游标生成「下一批」副本（对应 上游 RecommendationCursor）
    /// 当前分页直接原地推进 cursor（offset/session），未使用此副本；保留以对齐上游语义，便于未来无副作用分页
    func nextBatch() -> RecommendationCursor {
        let c = RecommendationCursor(session: session, offset: offset)
        c.seen = seen
        return c
    }
}

final class RecommendationFeed {
    private let http: HongguoHTTP
    private let account: AccountCredentials?
    private let cursor: RecommendationCursor
    private let category: DramaCategory?
    private let clock: () -> Int64

    private static let feedResponseLimit = 16 * 1024 * 1024

    init(http: HongguoHTTP, account: AccountCredentials? = nil, cursor: RecommendationCursor = RecommendationCursor(), category: DramaCategory? = nil, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.account = account
        self.cursor = cursor
        self.category = category
        self.clock = clock
    }

    func page(_ page: Int) async throws -> CatalogPage {
        guard page >= 1 && page <= 100 else { throw ContentError("页数越界") }
        if page == cursor.lastPage { if let r = cursor.lastResult { return r } }
        if page != cursor.expectedPage { throw ContentError("推荐已刷新，请重新获取") }

        for _ in 0..<3 {
            var params: [String: String] = [
                "aid": "8662", "app_name": "novelread", "channel": "update_64",
                "device_platform": "android", "os": "android", "ssmix": "a", "device_type": "25053RT47C",
                "device_brand": "Redmi", "language": "zh", "os_api": "36", "os_version": "16",
                "resolution": "1280*2772", "dpi": "520", "ac": "wifi",
            ]
            if let account {
                let allowed: Set<String> = ["channel", "device_platform", "os", "ssmix", "device_type", "device_brand", "language", "os_api", "os_version", "resolution", "dpi", "ac"]
                for (k, v) in account.device where allowed.contains(k) { params[k] = v }
                if !account.deviceId.isEmpty { params["device_id"] = account.deviceId }
                if !account.installId.isEmpty { params["iid"] = account.installId }
            }
            params["version_code"] = "73532"; params["version_name"] = "7.3.5.32"
            params["manifest_version_code"] = "73532"; params["update_version_code"] = "73532"
            params["tab_type"] = "16"; params["bottom_tab_type"] = "7"; params["landing_bottom_tab_type"] = "7"
            params["offset"] = String(cursor.offset); params["client_req_type"] = cursor.offset == 0 ? "1" : "2"
            params["_rticket"] = String(clock())
            if !cursor.session.isEmpty { params["session_id"] = cursor.session }

            let host = "https://api5-normal-sinfonlinea.fqnovel.com"

            // 组装请求
            var headers: [String: String] = [:]
            var body: Data? = nil
            var urlString: String

            if category == nil {
                var components = URLComponents(string: "\(host)/reading/bookapi/bookmall/tab/v1/")!
                components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
                urlString = components.url!.absoluteString
            } else {
                let genre = (category == .comic) ? "comic_series" : "short_play"
                var selector: [String: Any] = ["genre": [genre]]
                for key in ["sort", "gender", "category_dim_theme", "category_dim_role", "category_dim_epoch", "online_time", "creation_status"] {
                    selector[key] = []
                }
                let payload: [String: Any] = [
                    "req_scene": (category == .comic) ? "comic_series" : "default",
                    "offset": cursor.offset, "limit": 24, "req_type": "only_content", "need_selector_panel": false,
                    "client_req_type": cursor.offset == 0 ? 3 : 2, "session_id": cursor.session,
                    "filter_ids": cursor.seen.sorted().joined(separator: ","), "select_items": selector,
                ]
                body = try! JSONSerialization.data(withJSONObject: payload)
                // 对齐 上游：Signer 的 device = VendorConstants.device + params（含 version_name 等覆盖）
                let mergedDevice = VendorConstants.device.merging(params) { $1 }
                let signer = Signer(clock: clock, device: mergedDevice)
                let queryKeys = params.filter { !["tab_type", "bottom_tab_type", "landing_bottom_tab_type", "offset", "client_req_type", "session_id"].contains($0.key) }
                let signed = signer.sign(base: "\(host)/reading/distribution/category/landpage/v/", values: queryKeys, body: Array(body!))
                urlString = signed.url
                for (k, v) in signed.headers { headers[k] = v }
            }

            headers["User-Agent"] = "com.dragon.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C)"
            headers["Accept"] = "application/json"
            headers["X-XS-From-Web"] = "0"
            headers["Sdk-Version"] = "2"
            if let cookie = account?.cookie, !cookie.isEmpty { headers["Cookie"] = cookie }

            let response = try await http.text(urlString, headers: headers, body: body, method: body != nil ? "POST" : "GET", limit: Self.feedResponseLimit)
            Log.shared.debug("feed page=\(page) -> \(response.count)B: \(String(response.prefix(400)))")
            let result = try parseJSON(response)
            let parsed = (category == nil) ? try Self.parse(result) : try Self.parseCategory(result)
            cursor.session = parsed.session.isEmpty ? cursor.session : parsed.session
            cursor.offset = (category == nil) ? cursor.offset + 1 : result.obj("data")?.optInt("next_offset", cursor.offset + parsed.page.items.count) ?? cursor.offset
            let freshItems = parsed.page.items.filter { !cursor.seen.contains($0.id) }
            cursor.seen.formUnion(parsed.page.items.map { $0.id })
            while cursor.seen.count > 540 { if let first = cursor.seen.first { cursor.seen.remove(first) } }
            let fresh = CatalogPage(items: freshItems, hasMore: parsed.page.hasMore, discovery: parsed.page.discovery, trialHints: parsed.page.trialHints)
            if fresh.items.isEmpty { continue }
            cursor.expectedPage = page + 1
            cursor.lastPage = page
            cursor.lastResult = fresh
            return fresh
        }
        throw ContentError("暂时没有新的推荐，请稍后换一批")
    }

    struct Parsed {
        let page: CatalogPage
        let session: String
    }

    static func parse(_ result: [String: Any]) throws -> Parsed {
        guard result.optInt("code", -1) == 0 else {
            throw ContentError("推荐暂不可用（错误码 \(result.optInt("code", -1))），请稍后刷新")
        }
        guard let tabItem = result.obj("data")?.array("tab_item") else { throw ContentError("推荐数据格式已变化") }
        guard let tab = tabItem.first(where: { $0.str("tab_type") == "16" }) else { throw ContentError("推荐数据格式已变化") }
        let session = tab.str("session_id")
        guard session.count <= 4096 && !session.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\u{0}" }) else {
            throw ContentError("推荐分页标记无效")
        }
        var rows: [[String: Any]] = []
        for cell in (tab["cell_data"] as? [[String: Any]] ?? []) {
            for card in (cell["cell_data"] as? [[String: Any]] ?? []) {
                for v in (card["video_data"] as? [[String: Any]] ?? []) {
                    let row = (v["video_detail"] as? [String: Any]) ?? v
                    rows.append(row)
                }
            }
        }
        var items: [Series] = []
        var seen = Set<String>()
        for row in rows {
            let id = row.str("series_id").isEmpty ? row.str("book_id") : row.str("series_id")
            let title = row.str("series_title").isEmpty ? (row.str("book_name").isEmpty ? row.str("title") : row.str("book_name")) : row.str("series_title")
            guard id.range(of: "^[0-9]{1,24}$", options: .regularExpression) != nil, !title.isEmpty else { continue }
            let cover = row.str("series_cover").isEmpty ? row.str("cover") : row.str("series_cover")
            let intro = row.str("series_intro").isEmpty ? row.str("video_desc") : row.str("series_intro")
            let count = row.optInt("episode_cnt")
            let series = Series(id: id, title: title, cover: cleanUrl(cover), description: intro,
                                badge: count > 0 ? "共 \(count) 集" : "")
            if seen.insert(id).inserted { items.append(series) }
            if items.count >= 30 { break }
        }
        guard !items.isEmpty else { throw ContentError("推荐未返回可播放的剧集，请刷新重试") }
        // trial hints（这里不用于 Mac 试播；保留空）
        return Parsed(page: CatalogPage(items: items, hasMore: true), session: session)
    }

    static func parseCategory(_ result: [String: Any]) throws -> Parsed {
        guard result.optInt("code", -1) == 0 else {
            throw ContentError("分类推荐暂不可用（错误码 \(result.optInt("code", -1))）")
        }
        guard let data = result.obj("data") else { throw ContentError("分类推荐数据格式已变化") }
        guard let rows = data["video_data"] as? [[String: Any]] else { throw ContentError("分类推荐列表缺失") }
        // 归一化为 parse 期望的结构
        let cellData: [String: Any] = ["cell_data": [["video_data": rows]]]
        let tab: [String: Any] = ["tab_type": 16, "session_id": data.str("session_id"), "cell_data": [cellData]]
        let normalized: [String: Any] = ["code": 0, "data": ["tab_item": [tab]]]
        let parsed = try parse(normalized)
        let hasMore = data.optBool("has_more", true)
        return Parsed(page: CatalogPage(items: parsed.page.items, hasMore: hasMore, trialHints: parsed.page.trialHints), session: parsed.session)
    }
}
