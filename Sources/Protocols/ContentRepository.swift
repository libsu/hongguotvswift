// SPDX-License-Identifier: GPL-3.0-only
// 站点协议：搜索/发现/榜单/详情/相关/取流。直连官方 HTTPS。
// 依赖 Crypto 层的 Signer / Bytes / MediaCrypto（已通过字节级对齐）。
import Foundation

final class ContentRepository {
    let http: HongguoHTTP
    private let signer: Signer
    private let site = "https://hongguoduanju.com"
    private let clock: () -> Int64
    private let playerDevice: [String: String]

    private var relatedCache: [String: [RelatedWork]] = [:]
    /// 详情页内存缓存：避免反复进入同一剧集时重复请求详情页。
    private var detailCache: [String: (series: Series, episodes: [String])] = [:]

    init(http: HongguoHTTP = HongguoHTTP(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.clock = clock
        var device = VendorConstants.device
        device["iid"] = newPlayerDeviceId()
        device["device_id"] = newPlayerDeviceId()
        device["cdid"] = UUID().uuidString
        self.playerDevice = device
        self.signer = Signer(clock: clock)
    }

    // MARK: - 基础 HTTP

    /// 默认不自动重试：HTML 页面（首页/找剧/榜单）由 CDN 提供，504 等瞬态错误重试收益低且拖慢上屏，
    /// 快速失败后由 CatalogCache/用户手动重试兜底。仅幂等的 JSON 接口（如 searchAll）显式传入 retryTransient=true。
    private func text(_ url: String, signed: Signer.Request? = nil, retryTransient: Bool = false) async throws -> String {
        var headers: [String: String] = ["User-Agent": VendorConstants.VIDEO_UA, "Accept-Language": "zh-CN,zh;q=0.9"]
        var body: Data? = nil
        var method = "GET"
        if let signed {
            for (k, v) in signed.headers { headers[k] = v }
            if let b = signed.body { body = Data(b); method = "POST" }
        }
        let result = try await http.text(url, headers: headers, body: body, method: method, retryTransient: retryTransient)
        if let u = URL(string: url) {
            Log.shared.debug("text \(method) \(u.host ?? "")+path=\(u.path) -> \(result.count)B: \(String(result.prefix(400)).replacingOccurrences(of: "\n", with: " "))")
        }
        return result
    }

    private func router(_ url: String, retryTransient: Bool = false) async throws -> [String: Any] {
        let html = try await text(url, retryTransient: retryTransient)
        return try Self.extractRouter(html).obj("loaderData") ?? [:]
    }

    // MARK: - 卡片解析

    /// 上游: card(item) —— 归一化卡片字段。
    private func card(_ item: [String: Any]) -> Series {
        let o = item["video_data"] as? [String: Any] ?? item
        let count = o.optInt("episode_cnt", (o["series_episode_info"] as? [String: Any])?.optInt("episode_cnt", 0) ?? 0)
        var tagNames: [String] = []
        if let arr = o["tags"] as? [[String: Any]] {
            tagNames = arr.prefix(5).map { $0.str("name") }
        } else if let arr = o["category_list"] as? [[String: Any]] {
            tagNames = arr.prefix(5).map { $0.str("name") }
        } else if let arr = o["tags"] as? [String] {
            tagNames = arr.prefix(5).map { $0 }
        }
        let tags = tagNames.filter { !$0.isEmpty }.joined(separator: " · ")
        let seriesName = o.str("series_name")
        let seriesTitle = o.str("series_title")
        let itemName = item.str("name")
        let title = seriesName.isEmpty ? (seriesTitle.isEmpty ? itemName : seriesTitle) : seriesName
        let rightText = o.str("episode_right_text")
        let badge = rightText.isEmpty ? (count > 0 ? "全 \(count) 集" : "") : rightText
        return Series(id: o.str("series_id"), title: title, cover: cleanUrl(o.str("series_cover")),
                      description: o.str("series_intro"), badge: badge, tags: tags)
    }

    private func valid(_ rows: [Series]) -> [Series] {
        var seen = Set<String>()
        var out: [Series] = []
        for row in rows {
            guard isValidNumericId(row.id) && !row.title.isEmpty else { continue }
            guard seen.insert(row.id).inserted else { continue }
            out.append(row)
        }
        return out
    }

    // MARK: - 搜索

    /// 上游: searchAll —— 官网 JSON 跨分类搜索端点。
    func searchAll(keyword: String, page: Int) async throws -> CatalogPage {
        guard !keyword.isEmpty && keyword.count <= 80 && page >= 1 && page <= 100 else {
            throw ContentError("请检查搜索条件")
        }
        let raw = try await text("\(site)/api/search/result?query=\(Signer.encode(keyword))&page=\(page)", retryTransient: true)
        let section: [String: Any]
        do { section = try parseJSON(raw) }
        catch { throw ContentError("搜索响应格式已变化，请稍后重试") }
        if let pageNum = section["pageNum"] as? Int, pageNum != page {
            throw ContentError("搜索页码不匹配，请重新搜索")
        }
        guard let rows = section.array("searchList") else { throw ContentError("搜索数据结构已变化") }
        let items = valid(rows.map { card($0) })
        let more: Bool
        if let hasMore = section["hasMore"] as? Bool { more = hasMore }
        else if section.optInt("totalPages") > 0 { more = page < section.optInt("totalPages") }
        else { more = page < 100 }
        return CatalogPage(items: items, hasMore: !items.isEmpty && page < 100 && more)
    }

    // MARK: - 发现（找剧）

    /// 上游 ContentRepository.home：官网「分类」页（综合推荐，网站 JSON 端点）。
    func home(page: Int = 1) async throws -> CatalogPage {
        guard page >= 1 && page <= 100 else { throw ContentError("页数越界") }
        let data = try await router("\(site)/category?tab=1&sort_type=1" + (page > 1 ? "&page=\(page)" : ""))
        let section = data.obj("category_$") ?? data.obj("category_page") ?? data.obj("category_") ?? (nil as [String: Any]?)
        guard let section else { throw ContentError("首页数据结构已变化") }
        let rows = section.array("recommendList") ?? section.obj("categoryData")?.array("recommendList") ?? (nil as [[String: Any]]?)
        guard let rows else { throw ContentError("首页数据暂不可用") }
        let items = valid(rows.map { card($0) })
        let lastPage = section.obj("pagination")?.optInt("totalPages", 100) ?? 100
        return CatalogPage(items: items, hasMore: !items.isEmpty && page < min(lastPage, 100))
    }

    func discover(category: DramaCategory, topic: String, page: Int) async throws -> CatalogPage {
        guard page >= 1 && page <= 100 else { throw ContentError("页数越界") }
        guard topic.isEmpty || topic.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
            throw ContentError("题材参数异常")
        }
        let path = "/category/\(category.route)" + (topic.isEmpty ? "" : "/\(topic)")
        let data = try await router("\(site)\(path)?page=\(page)")
        let section = data.obj("category_$") ?? data.obj("category_page") ?? data.obj("category_") ?? (nil as [String: Any]?)
        guard let section else { throw ContentError("分类找剧数据已变化") }
        let info = try Self.discoveryInfo(section: section, category: category, topic: topic, page: page)
        guard let rows = section.array("recommendList") else { throw ContentError("分类剧集列表缺失") }
        let items = valid(rows.map { card($0) })
        if rows.count > 0 && items.isEmpty { throw ContentError("分类剧集格式已变化") }
        return CatalogPage(items: items, hasMore: !items.isEmpty && page < info.totalPages, discovery: info)
    }

    static func discoveryInfo(section: [String: Any], category: DramaCategory, topic: String, page: Int) throws -> DiscoveryInfo {
        guard section.optBool("isSuccess") else { throw ContentError("分类找剧暂不可用") }
        guard let route = section.obj("categoryRoute") else { throw ContentError("分类信息已变化") }
        let expected = "/category/\(category.route)" + (topic.isEmpty ? "" : "/\(topic)")
        guard route.str("contentType") == category.route && route.str("canonicalPath") == expected && route.optBool("enabled") else {
            throw ContentError("分类条件未被确认，请重新选择")
        }
        guard let pagination = section.obj("pagination") else { throw ContentError("分类分页信息缺失") }
        let pages = pagination.optInt("totalPages", -1)
        guard pagination.optInt("pageNum") == page && pages >= 0 else { throw ContentError("分类分页信息异常") }
        guard let selectors = section["selectorList"] as? [[String: Any]] else { throw ContentError("题材选项格式已变化") }
        var topics: [DramaTopic] = []
        var seen = Set<String>()
        for selector in selectors {
            for item in (selector["items"] as? [[String: Any]] ?? []) {
                let id = item.str("selector_item_id")
                let label = item.str("show_name")
                guard id.count <= 80, id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
                      !label.isEmpty, label.count <= 40, seen.insert(id).inserted else { continue }
                topics.append(DramaTopic(id: id, label: label))
                if topics.count >= 128 { break }
            }
        }
        if !topic.isEmpty && !topics.contains(where: { $0.id == topic }) { throw ContentError("该题材已变化，请重新选择") }
        return DiscoveryInfo(topics: topics, totalPages: min(pages, 100), pageSize: pagination.optInt("pageSize", 24), total: max(0, pagination.optInt("total", 0)))
    }

    // MARK: - 榜单

    func rankPage(board: RankBoard, page: Int = 1) async throws -> CatalogPage {
        guard page >= 1 && page <= 100 else { throw ContentError("页数越界") }
        let html = try await text("\(site)/rank/\(board.route)?page=\(page)")
        return try ComicRank.parse(html: html, page: page, board: board)
    }

    func rankSnapshot(board: RankBoard) async throws -> RankSnapshot {
        let first = try await rankPage(board: board)
        guard let meta = first.ranking else { throw ContentError("榜单信息缺失") }
        if meta.totalPages > 5 { throw ContentError("榜单页数已变化，请稍后重试") }
        var rows = first.items
        var positions = meta.positions
        // 后续页并发请求（第 1 页已知总页数后再并行拉取 2..totalPages），
        // 避免串行逐页请求导致榜单加载缓慢。
        if meta.totalPages > 1 {
            let laterPages = try await withThrowingTaskGroup(of: CatalogPage.self) { group in
                for page in 2...meta.totalPages {
                    group.addTask { try await self.rankPage(board: board, page: page) }
                }
                var pages: [CatalogPage] = []
                for try await page in group { pages.append(page) }
                return pages.sorted { ($0.ranking?.totalPages ?? 0) < ($1.ranking?.totalPages ?? 0) }
            }
            for next in laterPages {
                guard next.ranking?.totalPages == meta.totalPages else { throw ContentError("榜单正在更新，请刷新重试") }
                rows += next.items
                if let p = next.ranking?.positions { positions.merge(p) { $1 } }
            }
        }
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.id).inserted }
        let ranking = ComicRanking(positions: positions, totalPages: meta.totalPages, updatedText: meta.updatedText)
        return RankSnapshot(board: board, items: rows, ranking: ranking)
    }

    // MARK: - 详情

    func detail(id: String) async throws -> (series: Series, episodes: [String]) {
        guard isValidNumericId(id) else { throw ContentError("剧集 id 异常") }
        if let cached = detailCache[id] { return cached }
        // 详情页异常点较多（页面较慢/偶尔 504），启用跨态重试，避免一次超时就直接失败。
        let o = try await router("\(site)/detail?series_id=\(id)", retryTransient: true)
        guard let detailPage = o.obj("detail_page"), let seriesDetail = detailPage.obj("seriesDetail") else {
            throw ContentError("剧集详情暂不可用")
        }
        guard let raw = seriesDetail["vid_list"] as? [String] else { throw ContentError("分集暂不可用") }
        let episodes = raw.map { $0 }
        guard !episodes.isEmpty, episodes.allSatisfy({ isValidNumericId($0) }), Set(episodes).count == episodes.count else {
            throw ContentError("分集数据异常")
        }
        let series = card(seriesDetail)
        let result = (Series(id: id, title: series.title, cover: series.cover, description: series.description, badge: series.badge, tags: series.tags), episodes)
        if detailCache.count >= 32 { detailCache.removeValue(forKey: detailCache.keys.first!) }
        detailCache[id] = result
        return result
    }

    // MARK: - 相关作品

    func related(id: String, force: Bool = false) async throws -> [RelatedWork] {
        guard isValidNumericId(id) else { throw ContentError("剧集 id 异常") }
        if !force {
            if let cached = relatedCache[id] { return cached }
        }
        var values = VendorConstants.device
        for k in ["version_code", "manifest_version_code", "update_version_code", "pv_player"] { values[k] = "72232" }
        values["version_name"] = "7.2.2.32"
        values["scene"] = "10"; values["from"] = "detail_page_more_related"; values["book_id"] = id
        values["new_search_middle_page"] = "false"; values["bookstore_tab_type"] = "0"; values["query_history_removed"] = "false"
        values["user_is_login"] = "0"; values["bookstore_tab"] = "0"; values["search_middle_page_version"] = "0"
        values["pad_column_detail"] = "0"; values["hot_word_exchange"] = "false"; values["device_level"] = "3"
        values["limit"] = "0"; values["offset"] = "0"; values["is_horizontal_screen"] = "false"; values["reader_single_col_from_ip_strategy"] = "false"

        var lastFailure: Error? = nil
        for host in ["api5-normal-sinfonlinec.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com"] {
            do {
                let request = signer.sign(base: "https://\(host)/reading/bookapi/plan/v:version/", values: values)
                let raw = try await text(request.url, signed: request, retryTransient: false)
                if raw.isEmpty { lastFailure = ContentError("相关作品接口暂无响应"); continue }
                let rows = try RelatedWorks.parse(raw: raw, currentId: id)
                if relatedCache.count >= 8 { relatedCache.removeValue(forKey: relatedCache.keys.first!) }
                relatedCache[id] = rows
                return rows
            } catch {
                if Task.isCancelled { throw error }
                lastFailure = error
            }
        }
        throw ContentError("相关作品暂时无法加载，请重试\(lastFailure.map { "：\($0)" } ?? "")")
    }

    // MARK: - 取流

    func stream(id: String, maxQuality: Int = 1080) async throws -> StreamInfo {
        let ladder = try await streamLadder(id: id)
        // 对齐 上游 openStream：先用 CodecCapabilities 过滤掉当前 Mac 无法解码的编码族（AV1/bytevc2），
        // 再按「清晰度优先、同清晰度 HEVC > AVC」择优（节省流量、加快响应）。
        guard let selected = ladder.select(maxQuality: maxQuality, supported: CodecCapabilities.supports) else {
            throw ContentError("没有电视可播放的清晰度，请稍后再试或选择其他剧集")
        }
        let quality = selected.quality > 0 ? "\(selected.quality)P" : "自动"
        Log.shared.info("stream select episode=\(id) codec=\(selected.codec) quality=\(selected.quality) size=\(selected.width ?? 0)x\(selected.height ?? 0)")
        let info = StreamInfo(url: selected.url, key: selected.key, quality: maxQuality > 0 && selected.quality > maxQuality ? quality + "（兼容资源）" : quality)
        return info
    }

    func streamLadder(id: String) async throws -> StreamLadder {
        guard isValidNumericId(id) else { throw ContentError("剧集 id 异常") }
        let payload = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":3,\"disable_digg_stat\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"mixed_video_id_map\":{\"1004\":[\"\(id)\"]}}"
        var device = playerDevice
        device["_rticket"] = String(clock())
        let query = Signer.encode(device)
        let playerUrl = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?\(query)"
        let request = Signer.Request(url: playerUrl, headers: [
            "User-Agent": "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)",
            "Accept": "application/json; charset=utf-8,application/x-protobuf"
        ], body: Array(payload.utf8))
        let response = try await text(request.url, signed: request, retryTransient: false)
        guard !response.isEmpty else { throw ContentError("播放接口返回空响应，请稍后重试或更新应用") }
        let data = try parseJSON(response)
        let code = data.optInt("Code", data.optInt("code", 0))
        guard code == 0 else { throw ContentError("播放接口暂不可用（错误码 \(code)）") }
        guard let map = data.obj("data"), !map.isEmpty else { throw ContentError("播放信息为空") }
        let entry: [String: Any]
        if let e = map.obj(id) { entry = e }
        else if let first = map.values.compactMap({ $0 as? [String: Any] }).first { entry = first }
        else { throw ContentError("播放信息为空") }
        let model = entry.obj("video_model") ?? (try? parseJSON(entry.str("video_model"))) ?? [:]
        let fallbackRaw = model["fallback_api"]
        var fallback: String
        if let d = fallbackRaw as? [String: Any] { fallback = d.str("fallback_api") }
        else if let a = fallbackRaw as? [[String: Any]] { fallback = a.first?.str("fallback_api") ?? "" }
        else if let s = fallbackRaw as? String { fallback = (try? parseJSON(s).str("fallback_api")) ?? s }
        else { fallback = "" }
        guard fallback.hasPrefix("https://") else { throw ContentError("播放地址格式异常") }
        let infoRaw = try await text(fallback)
        let infoData = try parseJSON(infoRaw)
        guard let videoInfo = infoData.obj("video_info"), let dataObj = videoInfo.obj("data") else {
            throw ContentError("没有播放资源")
        }
        let info = dataObj
        guard let videoList = info.obj("video_list") else { throw ContentError("没有可用清晰度") }
        // 过滤掉 bytevc2/bvc2（字节私有的 AV1 变体）：其在 MP4 提取器里可能只暴露音频、无视频轨道，
        // 且大多数 Mac 无 AV1 视频解码。识别集中在 CodecCapabilities.isAV1，避免漏识别或误判。
        var rows: [(quality: Int, key: String, o: [String: Any])] = []
        for (k, v) in videoList {
            guard let o = v as? [String: Any] else { continue }
            let mainUrl = o.str("main_url")
            let codec = o.str("codec_type").lowercased()
            guard !mainUrl.isEmpty, !CodecCapabilities.isAV1(codec) else { continue }
            let desc = o.str("quality_desc").isEmpty
                ? (o.str("height").isEmpty ? (o.str("vheight").isEmpty ? (o.str("quality").isEmpty ? k : o.str("quality")) : o.str("vheight")) : o.str("height"))
                : o.str("quality_desc")
            rows.append((Self.qualityNumber(desc), k, o))
        }
        rows.sort { $0.quality > $1.quality }
        let seed = info.str("key_seed")
        var renditions: [Rendition] = []
        for (quality, _, o) in rows {
            var url = cleanUrl(o.str("main_url"))
            if !seed.isEmpty { url = try MediaCrypto.decryptUrl(url, seed: decode64(seed)) }
            guard url.hasPrefix("https://") || url.hasPrefix("http://") else { continue }
            let width = dimension(o, keys: ["vwidth", "width"])
            let height = dimension(o, keys: ["vheight", "height"])
            let spadeA = o.str("spade_a")
            let keyBytes: [UInt8]? = spadeA.isEmpty ? nil : try MediaCrypto.deriveKey(spadeA)
            renditions.append(Rendition(quality: quality, codec: o.str("codec_type").lowercased(), width: width, height: height, url: url, key: keyBytes))
        }
        guard !renditions.isEmpty else { throw ContentError("没有电视可播放的清晰度，请稍后再试或选择其他剧集") }
        return StreamLadder(renditions: renditions)
    }

    private func dimension(_ o: [String: Any], keys: [String]) -> Int? {
        for key in keys { let v = o.optInt(key, 0); if v > 0 { return v } }
        return nil
    }

    // MARK: - 解析器（静态）

    /// 上游: extractRouter(html) —— 从页面 HTML 中取出 `_ROUTER_DATA` 后的首段 JSON。
    static func extractRouter(_ html: String) throws -> [String: Any] {
        guard let marker = html.range(of: "_ROUTER_DATA") else { throw ContentError("页面没有内容数据") }
        guard let first = html[marker.upperBound...].firstIndex(of: "{") else { throw ContentError("页面数据格式错误") }
        var depth = 0
        var quoted = false
        var escaped = false
        var idx = first
        while idx < html.endIndex {
            let ch = html[idx]
            if quoted {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { quoted = false }
                idx = html.index(after: idx); continue
            }
            if ch == "\"" { quoted = true }
            else if ch == "{" || ch == "[" { depth += 1 }
            else if ch == "}" || ch == "]" {
                depth -= 1
                if depth == 0 {
                    let end = html.index(after: idx)
                    let sub = String(html[first..<end])
                    return try parseJSON(sub)
                }
            }
            idx = html.index(after: idx)
        }
        throw ContentError("页面数据不完整")
    }

    /// 上游: qualityNumber(value)
    static func qualityNumber(_ value: String) -> Int {
        let patterns = ["2160", "1440", "1080", "720", "576", "540", "480", "360"]
        for p in patterns {
            if value.contains(p) { return Int(p)! }
        }
        let map: [String: Int] = ["1920": 1080, "1280": 720, "1024": 576, "854": 480, "640": 360]
        if let v = map[value] { return v }
        return Int(value) ?? 0
    }
}
