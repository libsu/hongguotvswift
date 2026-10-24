// SPDX-License-Identifier: GPL-3.0-only
// 公开官网评论预览（匿名只读）。绝不转发账号凭据。
import Foundation

final class PublicComments {
    private let http: HongguoHTTP
    private var details: [String: (Int64, String)] = [:]
    private let clock: () -> Int64

    init(http: HongguoHTTP, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.clock = clock
    }

    func read(series: String, episode: String) async throws -> [String: Any] {
        guard series.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil,
              episode.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil else {
            throw ContentError("剧集参数异常")
        }
        let player = try await page("https://hongguoduanju.com/player/\(series)/\(episode)")
        let cached = details[series].flatMap { clock() - $0.0 < 30000 ? $0.1 : nil }
        let detail: String
        if let cached {
            detail = cached
        } else {
            detail = try await page("https://hongguoduanju.com/detail?series_id=\(series)")
            details[series] = (clock(), detail)
            while details.count > 16 { if let k = details.keys.first { details.removeValue(forKey: k) } }
        }
        return try Self.parse(html: player, series: series, episode: episode, detailHTML: detail)
    }

    private func page(_ url: String) async throws -> String {
        let headers = ["User-Agent": "Mozilla/5.0"]
        let response = try await http.request(url, headers: headers, limit: 8 * 1024 * 1024)
        guard (200..<300).contains(response.statusCode) else {
            throw ContentError("公开评论读取失败（HTTP \(response.statusCode)）", statusCode: response.statusCode)
        }
        guard response.data.count <= 8 * 1024 * 1024 else { throw ContentError("公开评论页面过大") }
        guard let html = String(data: response.data, encoding: .utf8) else { throw ContentError("公开评论为空") }
        return html
    }

    static func parse(html: String, series: String, episode: String, detailHTML: String? = nil) throws -> [String: Any] {
        let loaders = try ContentRepository.extractRouter(html).obj("loaderData") ?? [:]
        guard let data = loaders.values.compactMap({ $0 as? [String: Any] }).first(where: {
            $0["seriesDetail"] != nil && ($0["isSuccess"] as? Bool ?? true)
        }) else { throw ContentError("公开评论格式已变化") }
        guard (data["seriesDetail"] as? [String: Any])?.str("series_id") == series else { throw ContentError("评论剧集不匹配") }
        guard data.str("vid") == episode else { throw ContentError("评论分集不匹配") }

        func list(_ value: [String: Any]?, kind: String) -> [String: Any] {
            let rows = value?["reviews"] as? [[String: Any]] ?? []
            var items: [[String: Any]] = []
            var seen = Set<String>()
            for i in 0..<min(rows.count, 100) {
                let row = rows[i]
                let text = row.optString("content").trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000)
                if text.isEmpty { continue }
                let author = row.optString("user_name").prefix(200)
                let created = max(Int64(0), row.optLong("create_time", 0))
                let key = [series, episode, kind, String(author), String(created), String(text)].joined(separator: "\u{0}")
                let id = hexString(digest("SHA-256", Array(key.utf8)))
                if !seen.insert(id).inserted { continue }
                let avatarRaw = row.optString("user_avatar").prefix(4096)
                let avatar = String(avatarRaw).hasPrefix("https://") ? String(avatarRaw) : ""
                items.append([
                    "id": id, "author": String(author), "avatar": avatar, "content": String(text),
                    "created": created, "likes": max(Int64(0), row.optLong("digg_count", 0)),
                    "rating": row.optDouble("rating", 0.0),
                ])
                if items.count >= 50 { break }
            }
            return ["total": max(Int64(0), value?.optLong("total_count", 0) ?? 0), "items": items]
        }

        let detailData: [String: Any]
        if let detailHTML {
            let values = try ContentRepository.extractRouter(detailHTML).obj("loaderData") ?? [:]
            guard let d = values.values.compactMap({ $0 as? [String: Any] }).first(where: {
                $0["seriesDetail"] != nil && ($0["isSuccess"] as? Bool ?? true)
            }) else { throw ContentError("公开剧评格式已变化") }
            detailData = d
        } else {
            detailData = data
        }
        guard (detailData["seriesDetail"] as? [String: Any])?.str("series_id") == series else {
            throw ContentError("剧评剧集不匹配")
        }
        let social = detailData.obj("seriesSocialInfo")
        return [
            "seriesID": series, "episodeID": episode,
            "reviews": list(social?.obj("reviews"), kind: "series"),
            "comments": list(data.obj("episodeSocialInfo")?.obj("reviews"), kind: "episode"),
            "rating": social?.optDouble("rating", 0.0) ?? 0.0,
            "ratingCount": max(Int64(0), social?.optLong("rating_count", 0) ?? 0),
            "sourceURL": "https://hongguoduanju.com/player/\(series)/\(episode)",
            "limited": true,
        ]
    }
}
