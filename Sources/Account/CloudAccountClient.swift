// SPDX-License-Identifier: GPL-3.0-only
// 账号云端客户端：profile/history/favorites/setFavorite/reservations/reserve/upload + 设备注册。
import Foundation

final class CloudAccountClient {
    private let http: HongguoHTTP
    private let clock: () -> Int64

    init(http: HongguoHTTP, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.clock = clock
    }

    // MARK: - 设备注册

    func registerDevice() async throws -> DeviceRegister.Registered? {
        let body = DeviceRegister.payload(device: VendorConstants.device, now: clock())
        let url = DeviceRegister.url()
        let headers = DeviceRegister.headers(body: body, device: VendorConstants.device, now: clock())
        let response = try await http.request(url, method: "POST", headers: headers, body: Data(body), limit: 2 * 1024 * 1024)
        guard (200..<300).contains(response.statusCode) else { throw AccountError("账号请求失败（HTTP \(response.statusCode)）") }
        guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else { throw AccountError("账号接口响应为空") }
        let setCookie = response.value(forHeaderField: "Set-Cookie") ?? ""
        // 一个响应可能携带多行 Set-Cookie；这里保留单值，实际回写由 parse 处理。
        return DeviceRegister.parse(text, setCookies: setCookie.isEmpty ? [] : setCookie.components(separatedBy: "\n"))
    }

    // MARK: - 签名请求核心

    /// 对齐 上游 CloudAccountClient.json()：用账号设备指纹签名，POST 时带登录态 Cookie。
    private func json(
        credentials: AccountCredentials,
        path: String,
        params: [String: String] = [:],
        body: [UInt8]? = nil,
        gzip: Bool = false
    ) async throws -> [String: Any] {
        var device = VendorConstants.device
        for (k, v) in credentials.device { device[k] = v }
        device["device_id"] = credentials.deviceId
        device["iid"] = credentials.installId
        let versionCode = body != nil ? "73932" : "72232"
        for key in ["version_code", "manifest_version_code", "update_version_code", "pv_player"] { device[key] = versionCode }
        device["version_name"] = body != nil ? "7.3.9.32" : "7.2.2.32"

        let wireBody: [UInt8]? = (gzip && body != nil) ? Gzip.compress(body!) : body
        var values = device
        for (k, v) in params { values[k] = v }
        let signer = Signer(clock: clock, device: device)
        let signed = signer.sign(base: "https://api5-normal-sinfonlinea.fqnovel.com\(path)", values: values, body: wireBody)

        var headers = signed.headers
        headers["Cookie"] = credentials.cookie
        if gzip { headers["Content-Encoding"] = "gzip" }

        let response = try await http.request(signed.url, method: wireBody != nil ? "POST" : "GET", headers: headers, body: wireBody.map { Data($0) }, limit: 2 * 1024 * 1024)
        guard (200..<300).contains(response.statusCode) else { throw AccountError("账号请求失败（HTTP \(response.statusCode)）") }
        guard response.data.count <= 2 * 1024 * 1024 else { throw AccountError("账号接口响应过大") }
        guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else { throw AccountError("账号接口返回空响应，请稍后重试") }
        guard let obj = try? parseJSON(text) else { throw AccountError("账号接口响应异常") }
        let code = obj.optInt("code", -1)
        guard code == 0 else { throw AccountError("账号接口不可用（错误码 \(code)），请重新登录或稍后重试") }
        return obj
    }

    // MARK: - 资料 / 历史 / 收藏 / 预约 / 上传

    func profile(credentials: AccountCredentials) async throws -> CloudProfile {
        let obj = try await json(credentials: credentials, path: "/reading/user/info/v1/")
        guard let data = obj.obj("data") else { throw AccountError("账号资料为空") }
        let id = data.str("biz_user_id")
        guard !id.isEmpty else { throw AccountError("登录态未通过账号验证，请重新登录") }
        let nickname = data.str("user_name").isEmpty ? "红果用户" : data.str("user_name")
        return CloudProfile(id: id, nickname: nickname)
    }

    func history(credentials: AccountCredentials) async throws -> [CloudProgress] {
        let obj = try await json(credentials: credentials, path: "/reading/bookapi/read_progress/list/v1/", params: ["book_types": "2", "limit": "50"])
        guard let rows = obj.array("video_data") ?? obj.obj("data")?.array("video_data") else { throw AccountError("云端历史数据格式已变化") }
        let progress = Self.parseProgress(rows)
        if progress.isEmpty { return [] }
        let ids = progress.map { $0.series.id }.joined(separator: ",")
        let detailsObj = try await json(credentials: credentials, path: "/reading/bookapi/multi-detail/v1/", params: ["book_id": ids, "book_type": "2"])
        guard let details = detailsObj.array("data") else { throw AccountError("云端剧集资料格式已变化") }
        var seriesById: [String: Series] = [:]
        for row in details {
            let id = row.str("book_id")
            seriesById[id] = Series(id: id, title: row.str("book_name"), cover: cleanUrl(row.str("thumb_url")), description: row.str("abstract"), badge: Self.episodeBadge(row))
        }
        return progress.map { p in
            let s = seriesById[p.series.id] ?? Series(id: p.series.id, title: "剧集 \(p.series.id)", cover: "", description: "", badge: "")
            return CloudProgress(series: s, episodeId: p.episodeId, episodeIndex: p.episodeIndex, position: p.position, duration: p.duration, updatedAt: p.updatedAt, episodeCount: p.episodeCount)
        }
    }

    func favorites(credentials: AccountCredentials) async throws -> [CloudFavorite] {
        let obj = try await json(credentials: credentials, path: "/reading/bookapi/bookshelf/video/info/v1/")
        return try Self.parseFavorites(obj)
    }

    func setFavorite(credentials: AccountCredentials, seriesId: String, add: Bool) async throws {
        guard seriesId.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else { throw AccountError("剧集编号无效") }
        var entry: [String: Any] = [
            "book_id": seriesId, "book_type": 2,
            "modify_time": clock(), "video_shelf_operate_type": add ? 0 : 1,
        ]
        if !add { entry["group_name"] = "" }
        var body: [String: Any] = ["is_cancelled": false, "update_bookshelf_video_list": [entry]]
        if add {
            body["shark_extra"] = ["enter_from": "MainFragmentActivity", "previous_page": "", "page_list": "MainFragmentActivity", "is_active_behavior": "true", "inactive_type": "0"]
        }
        let bodyData = jsonString(body)
        _ = try await json(credentials: credentials, path: "/reading/bookapi/bookshelf/video/update/v1/", body: Array(bodyData.utf8))
    }

    func reservations(credentials: AccountCredentials, online: Bool) async throws -> [CloudReservation] {
        let params: [String: String] = [
            "offset": "0", "limit": "20", "is_online": online.description, "tab_type": "13",
            "subscribe_order_type": "0", "swipe_type": "0", "need_calendar_schema": "false", "subscribe_offset": "0",
        ]
        let obj = try await json(credentials: credentials, path: "/reading/user/subscribe/list/v0/", params: params)
        let rows = try Self.parseReservations(obj, online: online)
        if !online { return rows }
        let missing = rows.filter { episodeTotal($0.series.badge) == 0 }.map { $0.series.id }
        guard !missing.isEmpty else { return rows }
        let totalsObj = try? await json(credentials: credentials, path: "/reading/bookapi/multi-detail/v1/", params: ["book_id": missing.joined(separator: ","), "book_type": "2"])
        var totals: [String: String] = [:]
        for row in (totalsObj?.array("data") ?? []) {
            totals[row.str("book_id")] = Self.episodeBadge(row)
        }
        return rows.map { row in
            if let badge = totals[row.series.id], !badge.isEmpty {
                let s = Series(id: row.series.id, title: row.series.title, cover: row.series.cover, description: row.series.description, badge: badge, tags: row.series.tags)
                return CloudReservation(series: s, online: row.online, publishAt: row.publishAt, publishText: row.publishText)
            }
            return row
        }
    }

    func reserve(credentials: AccountCredentials, work: RelatedWork) async throws {
        guard work.upcoming, work.series.id.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil else { throw AccountError("预约编号无效") }
        guard let id = Int64(work.series.id) else { throw AccountError("预约编号无效") }
        let body: [String: Any] = ["item_id": id, "item_type": 3, "op_type": 1, "subscribe_source": 0]
        let bodyData = jsonString(body)
        _ = try await json(credentials: credentials, path: "/reading/bookapi/search/uncover_subscribe/v1/", body: Array(bodyData.utf8), gzip: true)
    }

    func upload(credentials: AccountCredentials, progress: CloudProgress, episodeCount: Int) async throws {
        guard progress.series.id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
              progress.episodeId.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else { throw AccountError("剧集编号无效") }
        let rate = progress.duration > 0 ? min(max(Double(progress.position) / Double(progress.duration), 0.0), 1.0) : 0.0
        let entry: [String: Any] = [
            "book_id": progress.series.id, "item_id": progress.episodeId,
            "vid_index": progress.episodeIndex + 1, "current_play_time": max(0, progress.position),
            "current_total_time": max(0, progress.duration), "episode_count": episodeCount,
            "read_timestamp_ms": progress.updatedAt, "book_type": 2,
            "progress_rate": String(rate),
            "player_cumulative_total_duration": max(0, progress.position),
        ]
        let body: [String: Any] = ["books": [entry], "write_mode": 1]
        let bodyData = jsonString(body)
        _ = try await json(credentials: credentials, path: "/reading/bookapi/read_progress/upload/v1/", body: Array(bodyData.utf8))
    }

    // MARK: - 解析器（静态）

    static func episodeBadge(_ row: [String: Any]) -> String {
        let count = ["episode_cnt", "episode_count", "drama_chapter_number"].map { row.optInt($0) }.first { $0 > 0 } ?? 0
        return count > 0 ? "全 \(count) 集" : ""
    }

    static func parseFavorites(_ raw: [String: Any]) throws -> [CloudFavorite] {
        guard let data = raw.obj("data") else { throw AccountError("账户收藏数据格式已变化") }
        guard data["video_shelf_info"] != nil else { throw AccountError("账户收藏列表格式已变化") }
        let rows = data["video_shelf_info"] as? [[String: Any]] ?? []
        var result: [CloudFavorite] = []
        for row in rows {
            let video = row.obj("video_data") ?? row
            let id = video.str("series_id").isEmpty ? (row.str("series_id").isEmpty ? row.str("book_id") : row.str("series_id")) : video.str("series_id")
            let title = row.str("series_title").isEmpty ? (video.str("title").isEmpty ? row.str("book_name") : video.str("title")) : row.str("series_title")
            guard id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil, !title.isEmpty else { continue }
            let cover = row.str("series_cover_url").isEmpty ? (video.str("cover").isEmpty ? (video.str("cover_url").isEmpty ? (video.str("thumb_url").isEmpty ? row.str("thumb_url") : video.str("thumb_url")) : video.str("cover_url")) : video.str("cover")) : row.str("series_cover_url")
            let count = video.optInt("episode_cnt", video.optInt("episode_count", row.optInt("episode_cnt")))
            let tags: String
            if let schemaStr = row["category_schema"] as? String, let schemaData = schemaStr.data(using: .utf8), let schemaArr = (try? JSONSerialization.jsonObject(with: schemaData)) as? [[String: Any]] {
                tags = schemaArr.map { $0.str("name") }.filter { !$0.isEmpty }.prefix(5).joined(separator: " · ")
            } else { tags = video.str("category") }
            let stamp = max(Int64(0), row.optLong("collect_time", 0))
            let normalizedStamp = (stamp >= 1 && stamp <= 9999999999) ? stamp * 1000 : stamp
            let badge = count > 0 ? "全 \(count) 集" : ""
            let description = row.str("series_intro").isEmpty ? (video.str("video_desc").isEmpty ? row.str("abstract") : video.str("video_desc")) : row.str("series_intro")
            result.append(CloudFavorite(series: Series(id: id, title: title, cover: cleanUrl(cover), description: description, badge: badge, tags: tags), collectedAt: normalizedStamp))
        }
        if !rows.isEmpty && result.isEmpty { throw AccountError("账户收藏条目格式已变化") }
        let sorted = result.sorted { $0.collectedAt > $1.collectedAt }
        var seen = Set<String>(); var out: [CloudFavorite] = []
        for f in sorted where seen.insert(f.series.id).inserted { out.append(f) }
        return out
    }

    static func parseReservations(_ raw: [String: Any], online: Bool) throws -> [CloudReservation] {
        guard let data = raw.obj("data") else { throw AccountError("预约数据格式已变化，请稍后重试") }
        guard data["subscribe_items"] != nil else { throw AccountError("预约列表格式已变化，请稍后重试") }
        let rows = data["subscribe_items"] as? [[String: Any]] ?? []
        var result: [CloudReservation] = []
        var seen = Set<String>()
        for row in rows {
            let video: [String: Any]
            let flat = (row["subscribe_data"] as? [String: Any]) ?? (row["video_data"] as? [String: Any])
            if let flat { video = flat } else { video = row } // 上游: ?: row（平铺预约项）
            let isFlat = (row["subscribe_data"] == nil && row["video_data"] == nil)
            let seriesId = video.str("series_id").isEmpty ? (row.str("series_id").isEmpty ? row.str("book_id") : row.str("series_id")) : video.str("series_id")
            let id: String
            if seriesId.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil { id = seriesId }
            else if !online && isFlat && row.str("item_id").range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil { id = "reservation:" + row.str("item_id") }
            else { continue }
            let title = row.str("series_title").isEmpty ? (video.str("title").isEmpty ? (video.str("book_name").isEmpty ? row.str("name") : video.str("book_name")) : video.str("title")) : row.str("series_title")
            if title.isEmpty { continue }
            if let isOnline = row["is_online"] as? Bool, isOnline != online { continue }
            let cover = row.str("series_cover_url").isEmpty ? (video.str("cover").isEmpty ? (video.str("cover_url").isEmpty ? video.str("thumb_url") : video.str("cover_url")) : video.str("cover")) : row.str("series_cover_url")
            let stamp = max(Int64(0), row.optLong("schedule_publish_time", 0))
            let normalizedStamp = (stamp >= 1 && stamp <= 9999999999) ? stamp * 1000 : stamp
            let badge: String
            if online {
                let b = episodeBadge(video).isEmpty ? (episodeBadge(row).isEmpty ? "已上线" : episodeBadge(row)) : episodeBadge(video)
                badge = b
            } else { badge = "待上线" }
            let description = video.str("video_desc").isEmpty ? (row.str("abstract").isEmpty ? row.str("item_desc") : row.str("abstract")) : video.str("video_desc")
            let series = Series(id: id, title: title, cover: cleanUrl(cover), description: description, badge: badge, tags: video.str("category"))
            guard seen.insert(id).inserted else { continue }
            result.append(CloudReservation(series: series, online: online, publishAt: normalizedStamp, publishText: row.str("expected_rec_text")))
        }
        if !rows.isEmpty && result.isEmpty { throw AccountError("预约条目格式已变化，请稍后重试") }
        return result
    }

    static func parseProgress(_ rows: [[String: Any]]) -> [CloudProgress] {
        var result: [CloudProgress] = []
        for row in rows {
            let id = row.str("series_id").isEmpty ? row.str("book_id") : row.str("series_id")
            let episode = row.str("vid")
            guard id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
                  episode.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else { continue }
            let rawStamp = row.optLong("last_watch_time")
            let stamp = (rawStamp >= 1 && rawStamp <= 9999999999) ? rawStamp * 1000 : rawStamp
            result.append(CloudProgress(
                series: Series(id: id, title: "", cover: "", description: "", badge: ""),
                episodeId: episode,
                episodeIndex: max(0, row.optInt("vid_index", 1) - 1),
                position: max(0, row.optLong("current_play_time")),
                duration: max(0, row.optLong("current_total_time")),
                updatedAt: stamp,
                episodeCount: max(0, row.optInt("episode_count"))
            ))
        }
        var seen = Set<String>(); var out: [CloudProgress] = []
        for p in result where seen.insert(p.series.id).inserted { out.append(p) }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
}
