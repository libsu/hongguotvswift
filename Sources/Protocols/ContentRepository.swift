// SPDX-License-Identifier: GPL-3.0-only
// 站点协议：搜索/发现/榜单/详情/相关/取流，直连官方 HTTPS。
import Foundation

final class ContentRepository {
    let http: HongguoHTTP
    private let signer: Signer
    private let site = "https://hongguoduanju.com"
    private let clock: () -> Int64
    private let playerDevices: PlayerDeviceSource

    private var relatedCache: [String: [RelatedWork]] = [:]
    private var detailCache: [String: (series: Series, episodes: [String])] = [:]

    init(http: HongguoHTTP = HongguoHTTP(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }, defaults: UserDefaults = .standard) {
        self.http = http
        self.clock = clock
        self.playerDevices = PlayerDeviceSource(http: http, clock: clock, defaults: defaults)
        self.signer = Signer(clock: clock)
    }

    // MARK: - 基础 HTTP

    /// 默认不重试：HTML 页面由 CDN 提供，504 等瞬态错误重试收益低且拖慢上屏，
    /// 快速失败交给 CatalogCache/用户重试；仅幂等的 JSON 接口（如 searchAll）才传 retryTransient。
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
            // Log.shared.debug("text \(method) \(u.host ?? "")+path=\(u.path) -> \(result.count)B: \(String(result.prefix(400)).replacingOccurrences(of: "\n", with: " "))")
        }
        return result
    }

    private func router(_ url: String, retryTransient: Bool = false) async throws -> [String: Any] {
        let html = try await text(url, retryTransient: retryTransient)
        return try Self.extractRouter(html).obj("loaderData") ?? [:]
    }

    // MARK: - 卡片解析

    /// 上游 card(item)。
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

    /// 上游 searchAll：官网 JSON 跨分类搜索端点（幂等，故允许重试）。
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

    /// 上游 ContentRepository.home：官网「分类」页。
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
        // 第 1 页拿到总页数后并行拉取剩余页，避免串行逐页导致榜单加载缓慢。
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
        // 详情页偶发 504，跨态重试避免一次超时即失败。
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
        for host in ["api5-normal-sinfonlineb.fqnovel.com","api5-normal-sinfonlinec.fqnovel.com", "api5-normal-hl.fqnovel.com", "api5-normal-lf.fqnovel.com"] {
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
        // 清晰度优先，同清晰度 HEVC > AVC。
        guard let selected = ladder.select(maxQuality: maxQuality, supported: CodecCapabilities.supports) else {
            let summary = ladder.renditions.map { "\($0.codec) \($0.quality)P" }.joined(separator: ", ")
            // Log.shared.warn("stream 无可用档位 episode=\(id) 共 \(ladder.renditions.count) 档：\(summary)")
            throw ContentError("没有可播放的清晰度")
        }
        let quality = selected.quality > 0 ? "\(selected.quality)P" : "自动"
        // Log.shared.info("stream select episode=\(id) codec=\(selected.codec) quality=\(selected.quality) size=\(selected.width ?? 0)x\(selected.height ?? 0)")
        let info = StreamInfo(url: selected.url, key: selected.key, quality: maxQuality > 0 && selected.quality > maxQuality ? quality + "（兼容资源）" : quality)
        return info
    }

    /// 设备被上游拒绝（错误码）的内部信号，由 `streamLadder` 捕获后换设备重试。
    /// 只携带上游给出的客观事实，不推测原因。
    private struct PlayerDeviceRejected: LocalizedError {
        let reason: String
        var errorDescription: String? { "播放设备失效：\(reason)" }
    }

    /// 取流入口：设备级失效时丢弃设备重注册一次。
    ///
    /// 只用注册得到的设备，不回退内置设备（`VendorConstants.device`）——
    /// 它已被上游永久拒绝 110001，回退只会白跑一次请求并覆盖真实错误。
    func streamLadder(id: String) async throws -> StreamLadder {
        guard isValidNumericId(id) else { throw ContentError("剧集 id 异常") }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                return try await registeredStreamLadder(id: id)
            } catch {
                lastError = error
                guard Self.shouldRotateDevice(error), attempt == 0 else { break }
                await playerDevices.invalidate()
                // Log.shared.warn("streamLadder 重新注册设备，触发原因：\(error.localizedDescription)")
            }
        }
        throw lastError ?? ContentError("播放接口暂不可用，请稍后重试")
    }

    /// 该错误是否应触发换设备重注册。
    /// 无可用档位不算设备信号：服务端回了 code=0 但 video_list 为空/全不可解码，
    /// 换设备也解决不了。空响应同理：接口整体故障时换新设备也一样空。
    private static func shouldRotateDevice(_ error: Error) -> Bool {
        error is PlayerDeviceRejected || (error as? ContentError)?.deviceRejected == true
    }

    /// 按设备档位取流。默认先用 device_level=3，拿不到本机可解码档位时降级到 1 重试。
    ///
    /// device_level 对返回档位的影响（实测）：
    /// - 3：清晰度最全，但 720p 及以下多为 bytevc2，本机无法解码
    /// - 1：全档位 H.265，但部分剧集最高只有 480p
    /// 因此 1 不能作为默认值，只能作为后备。
    private func registeredStreamLadder(id: String) async throws -> StreamLadder {
        let device = try await playerDevices.obtain()
        var values = VendorConstants.device
        values["iid"] = device.installId
        values["device_id"] = device.deviceId
        values["cdid"] = device.cdid
        values["openudid"] = device.openudid

        do {
            let ladder = try await fetchLadder(id: id, device: values)
            if ladder.hasPlayable { return ladder }
            // Log.shared.warn("streamLadder 默认档位无本机可解码档位，改用 device_level=1 重试 episode=\(id)")
        } catch {
            // 设备级失效、可重试的空响应（接口可能整体故障）都交给外层：降档位没有意义。
            if error is PlayerDeviceRejected || (error as? ContentError)?.retryable == true { throw error }
            // Log.shared.warn("streamLadder 默认档位取流失败（\(error.localizedDescription)），改用 device_level=1 重试 episode=\(id)")
        }
        return try await fetchLadder(id: id, device: values, deviceLevel: 1)
    }

    /// 播放模型接口所用的番茄小说应用标识；参与 Ladon/Argus 签名，必须与 UA 版本号一致。
    private static let playbackAid: Int64 = 1967

    /// 覆盖 VendorConstants 中属于红果（aid=8662）的版本字段。
    private static let playbackOverrides: [String: String] = [
        "aid": "1967",
        "app_name": "novelapp",
        "version_code": "74332",
        "version_name": "7.4.3.32",
        "manifest_version_code": "74332",
        "update_version_code": "74332",
        "pv_player": "74332",
    ]

    /// 请求 `multi_video_model` 并解析档位。
    /// - Parameters:
    ///   - device: 已注册设备拼成的查询参数。
    ///   - deviceLevel: 设备性能档位，默认 3；1 见 `registeredStreamLadder` 的降级说明。
    private func fetchLadder(id: String, device: [String: String], deviceLevel: Int = 3) async throws -> StreamLadder {
        let payload = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":\(deviceLevel),\"disable_digg_stat\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"mixed_video_id_map\":{\"1004\":[\"\(id)\"]}}"
        // 只剩 b 节点
        let streamHosts = [
            "api5-normal-sinfonlineb.fqnovel.com",
        ]
        // 上游按 gzip 正文解压并校验 x-ss-stub（针对压缩后的字节）。
        let body = Gzip.compress(Array(payload.utf8))
        var lastError: Error?
        // 设备级失效信号：110001/10001/10002。
        // 上抛成 PlayerDeviceRejected 让外层换设备，而非当作普通取流失败。
        var deviceRejected = false
        var rejectReason: String?
        for host in streamHosts {
            var values = device
            // 播放接口使用番茄小说（aid=1967）的版本参数：aid 参与 Ladon/Argus 签名，
            // 与 UA 版本号必须一致。沿用 VendorConstants 的 8662/71332 会被判为非法签名（空正文）。
            for (key, value) in Self.playbackOverrides { values[key] = value }
            values["_rticket"] = String(clock())
            let query = Signer.encode(values)
            let url = "https://\(host)/novel/player/multi_video_model/v1/?\(query)"
            let ts = clock() / 1000
            // 播放类接口要求 x-argus/x-ladon 完整签名，否则一律 200 + 空正文。
            let signature = Argus.headers(
                query: query, body: body, ts: ts, aid: Self.playbackAid,
                deviceId: values["device_id"] ?? "", installId: values["iid"] ?? ""
            )
            var headers: [String: String] = [
                "User-Agent": VendorConstants.PLAYBACK_UA,
                "Accept": "application/json; charset=utf-8,application/x-protobuf",
                "Content-Type": "application/json; charset=UTF-8",
                "Content-Encoding": "gzip",
                "x-ss-dp": "8662",
            ]
            for (key, value) in signature { headers[key] = value }
            do {
                let resp = try await http.request(url, method: "POST", headers: headers, body: Data(body))
                let raw = String(data: resp.data, encoding: .utf8) ?? ""
                if raw.isEmpty {
                    // 空 body（HTTP 200 + content-length: 0）不再当作设备级失效：
                    // 实测接口整体故障时，任意设备/剧集/档位都返回空，换设备无意义。
                    // 保留 retryable 标记，让上层决定是否重试。
                    lastError = ContentError("播放接口返回空响应", statusCode: resp.statusCode, retryable: true)
                    // Log.shared.warn("streamLadder 取流失败 host=\(host)：播放接口返回空响应")
                    continue
                }
                let data = try parseJSON(raw)
                let code = data.optInt("Code", data.optInt("code", 0))
                if Self.isDeviceRejected(code) {
                    deviceRejected = true
                    rejectReason = "错误码 \(code)"
                    lastError = ContentError("播放设备已被上游拒绝（错误码 \(code)）", deviceRejected: true)
                    // Log.shared.warn("streamLadder 播放设备被拒绝 host=\(host) device_id=\(values["device_id"] ?? "?") code=\(code)")
                    continue
                }
                guard code == 0 else {
                    lastError = ContentError("播放接口不可用（错误码 \(code)）")
                    // Log.shared.warn("streamLadder 取流失败 host=\(host)：错误码 \(code)")
                    continue
                }
                guard let map = data.obj("data"), !map.isEmpty else {
                    lastError = ContentError("播放信息为空")
                    // Log.shared.warn("streamLadder 取流失败 host=\(host)：播放信息为空")
                    continue
                }
                if let ladder = try await ladder(from: map), !ladder.renditions.isEmpty {
                    return ladder
                }
                // Log.shared.warn("streamLadder 无可用档位 episode=\(id) code=\(code) video_list=\(Self.model(from: map)?["video_list"] ?? "nil")")
                lastError = ContentError("没有可播放的清晰度")
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                // Log.shared.warn("streamLadder 取流失败 host=\(host)：\(error.localizedDescription)")
            }
        }
        if deviceRejected { throw PlayerDeviceRejected(reason: rejectReason ?? "未知") }
        throw lastError ?? ContentError("播放接口空响应")
    }

    private static func isDeviceRejected(_ code: Int) -> Bool {
        code == 10001 || code == 10002 || code == 110001
    }

    /// 解析 video_model 并提取档位；直接档位为空时再请求 fallback_api。
    private func ladder(from data: [String: Any]) async throws -> StreamLadder? {
        var models: [[String: Any]] = []
        if let model = Self.model(from: data) { models.append(model) }
        for (_, value) in data {
            guard let entry = value as? [String: Any], let model = Self.model(from: entry) else { continue }
            models.append(model)
        }
        var renditions: [Rendition] = []
        var seen = Set<String>()
        for model in models {
            let seed = Self.lenientBase64(model.str("key_seed"))
            renditions += Self.renditions(from: model["video_list"], seed: seed, seen: &seen)
        }
        // 直接档位为空时才请求 fallback_api，避免为可能的备用源多等一轮。
        if renditions.isEmpty {
            for model in models {
                let fallback = Self.fallbackApi(model)
                guard fallback.hasPrefix("https://") else { continue }
                do {
                    let raw = try await text(fallback)
                    let infoData = try parseJSON(raw)
                    guard let info = infoData.obj("video_info")?.obj("data") else { continue }
                    let infoSeed = Self.lenientBase64(info.str("key_seed"))
                    renditions += Self.renditions(from: info["video_list"], seed: infoSeed, seen: &seen)
                } catch {
                    if Task.isCancelled { throw error }
                    // Log.shared.warn("streamLadder fallback 取流失败：\(error.localizedDescription)")
                }
            }
        }
        guard !renditions.isEmpty else { return nil }
        renditions.sort { $0.quality > $1.quality }
        return StreamLadder(renditions: renditions)
    }

    /// 从容器取出 video_model：兼容字典、JSON 字符串，以及 video_list 直接在顶层的少数响应。
    private static func model(from container: [String: Any]) -> [String: Any]? {
        if let model = container.obj("video_model") { return model }
        if let raw = container["video_model"] as? String, let model = try? parseJSON(raw) { return model }
        return container["video_list"] == nil ? nil : container
    }

    private static func fallbackApi(_ model: [String: Any]) -> String {
        let raw = model["fallback_api"]
        if let dict = raw as? [String: Any] { return dict.str("fallback_api") }
        if let rows = raw as? [[String: Any]] { return rows.first?.str("fallback_api") ?? "" }
        if let value = raw as? String { return (try? parseJSON(value).str("fallback_api")) ?? value }
        return ""
    }

    // 下面两个解析函数不放 private：tests/StreamUrlDetectionTests.swift 直接调用它们做回归，
    // 避免测试里另写一份可能失真的复刻逻辑。
    /// 遍历 video_list（数组或字典两种形态）并解析档位，按 URL 去重。
    static func renditions(from raw: Any?, seed: [UInt8]?, seen: inout Set<String>) -> [Rendition] {
        var out: [Rendition] = []
        func append(_ row: [String: Any], key: String?) {
            guard let rendition = rendition(from: row, key: key, seed: seed), !seen.contains(rendition.url) else { return }
            seen.insert(rendition.url)
            out.append(rendition)
        }
        if let rows = raw as? [String: Any] {
            for (key, value) in rows { if let row = value as? [String: Any] { append(row, key: key) } }
        } else if let rows = raw as? [[String: Any]] {
            for row in rows { append(row, key: nil) }
        }
        return out
    }

    /// 解析单个档位。兼容旧结构（vheight/codec_type 在顶层）与新结构（在 video_meta/encrypt_info 内）。
    /// 不可解码的编码（AV1 / bytevc2）直接返回 nil。
    static func rendition(from row: [String: Any], key: String?, seed: [UInt8]?) -> Rendition? {
        let meta = row.obj("video_meta") ?? [:]
        let encrypt = row.obj("encrypt_info") ?? [:]
        let codec = (row.str("codec_type").isEmpty ? meta.str("codec_type") : row.str("codec_type")).lowercased()
        guard !CodecCapabilities.isAV1(codec) else { return nil }

        var url = row.str("main_url")
        if url.isEmpty { url = row.str("backup_url_1") }
        if url.isEmpty { url = row.str("backup_url") }
        if url.isEmpty { url = row.str("play_url") }
        guard !url.isEmpty else { return nil }

        // 少数旧源把 URL 整体 base64 编码，解出后按普通 URL 处理。
        if !url.hasPrefix("http"), let data = lenientBase64(url), data.count > 4,
           String(decoding: data.prefix(4), as: UTF8.self) == "http" {
            url = String(decoding: data, as: UTF8.self)
        }
        // 只解密非明文地址：decryptUrl 内部 decode64 对长度 % 4 == 1 会 precondition 崩溃，
        // try? 捕不住，所以先自行校验长度。主接口的 main_url 本就是明文 https。
        if !url.hasPrefix("http"), let seed, !seed.isEmpty {
            let normalized = url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if normalized.count % 4 != 1 {
                url = (try? MediaCrypto.decryptUrl(url, seed: seed)) ?? url
            }
        }
        url = cleanUrl(url)
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }

        let width = positiveInt(row, meta: meta, keys: ["vwidth", "width"])
        let height = positiveInt(row, meta: meta, keys: ["vheight", "height"])
        var quality = qualityFromDimensions(width: width, height: height)
        if quality == 0 {
            let desc = row.str("quality_desc").isEmpty
                ? row.str("quality_type", row.str("quality", row.str("definition", key ?? "")))
                : row.str("quality_desc")
            quality = qualityNumber(desc)
        }
        let spadeA = row.str("spade_a").isEmpty ? encrypt.str("spade_a") : row.str("spade_a")
        let keyBytes = spadeA.isEmpty ? nil : try? MediaCrypto.deriveKey(spadeA)
        return Rendition(
            quality: quality,
            codec: codec,
            width: width,
            height: height,
            url: url,
            key: keyBytes
        )
    }

    private static func positiveInt(_ row: [String: Any], meta: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            let value = row.optInt(key, 0) > 0 ? row.optInt(key, 0) : meta.optInt(key, 0)
            if value > 0 { return value }
        }
        return nil
    }

    /// 短边命名清晰度（竖屏 360x640 记为 360P）；缺一维时退回单维/高度映射。
    private static func qualityFromDimensions(width: Int?, height: Int?) -> Int {
        if let width, let height, width > 0, height > 0 {
            return qualityNumber(String(min(width, height)))
        }
        if let width, width > 0 { return qualityNumber(String(width)) }
        return qualityFromHeight(height)
    }

    /// 宽松 base64 解码：容忍 url-safe 字符与缺失填充。失败返回 nil。
    private static func lenientBase64(_ value: String) -> [UInt8]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized.padding(toLength: ((normalized.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        return Data(base64Encoded: padded).map { Array($0) }
    }

    // MARK: - 解析器（静态）

    /// 上游 extractRouter(html)：取出 `_ROUTER_DATA` 后的首段 JSON。
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

    /// 上游 qualityNumber(value)。
    static func qualityNumber(_ value: String) -> Int {
        let patterns = ["2160", "1440", "1080", "720", "576", "540", "480", "360"]
        for p in patterns {
            if value.contains(p) { return Int(p)! }
        }
        let map: [String: Int] = ["1920": 1080, "1280": 720, "1024": 576, "854": 480, "640": 360]
        if let v = map[value] { return v }
        return Int(value) ?? 0
    }

    /// 由 height 反推清晰度档位；非标准高度返回 0，交由 qualityNumber 兜底。
    static func qualityFromHeight(_ height: Int?) -> Int {
        guard let height else { return 0 }
        switch height {
        case 1441...: return 2160
        case 1081...1440: return 1440
        case 810...1080: return 1080
        case 721...809: return 720
        case 577...720: return 576
        case 541...576: return 540
        case 481...540: return 480
        case 361...480: return 360
        default: return 0
        }
    }
}
