// SPDX-License-Identifier: GPL-3.0-only
// App 本集评论（含服务端续页游标）。只读，无写入方法。
import Foundation

final class AppCommentPages {
    private let transport: CommentTransport

    init(transport: CommentTransport = CommentTransport()) {
        self.transport = transport
    }

    func read(series: String, episode: String, cursor: String) async throws -> [String: Any] {
        guard series.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil,
              episode.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil else {
            throw ContentError("剧集参数异常")
        }
        _ = try Self.validateCursor(cursor)
        let payload: [String: Any] = [
            "comment_source": 4, "server_channel": 18, "group_id": episode, "group_type": 30,
            "comment_type": 4, "sort": 1, "need_count": true, "count": 20, "cursor": cursor,
            "aid": 8662, "compliance_status": 0,
            "business_param": ["book_id": series, "req_type": 0],
        ]
        let result = try await transport.read(episode: episode, payload: payload, source: 4, channel: 18)
        return try Self.parse(result: result, series: series, episode: episode, cursor: cursor)
    }

    static func validateCursor(_ cursor: String) throws -> Int64 {
        guard cursor.count <= 8192 else { throw ContentError("评论游标无效") }
        if cursor.isEmpty { return 0 }
        guard let data = try? parseJSON(cursor) else { throw ContentError("评论游标无效") }
        guard let sessionId = data["session_id"] as? String, sessionId.count >= 1 && sessionId.count <= 200 else {
            throw ContentError("评论游标无效")
        }
        let offset = data.optLong("offset")
        guard offset >= 0 && offset <= 10000000 else { throw ContentError("评论游标无效") }
        return offset
    }

    static func parse(result: [String: Any], series: String, episode: String, cursor: String) throws -> [String: Any] {
        guard result.optInt("code", -1) == 0 else { throw ContentError("评论接口未返回成功数据") }
        let previous = try validateCursor(cursor)
        guard let data = result.obj("data"), let info = data.obj("common_list_info") else {
            throw ContentError("评论接口未返回成功数据")
        }
        let more = info.optBool("has_more")
        let next = info.optString("cursor")
        if more {
            let nextOffset = try validateCursor(next)
            guard next != cursor && nextOffset > previous else { throw ContentError("评论游标未推进") }
        }
        let rows = data["data_list"] as? [[String: Any]] ?? []
        var items: [[String: Any]] = []
        var seen = Set<String>()
        for i in 0..<min(rows.count, 100) {
            guard let row = rows[i]["comment"] as? [String: Any],
                  let common = row["common"] as? [String: Any],
                  let expand = row["expand"] as? [String: Any] else { continue }
            guard common.optString("group_id") == episode && expand.optString("book_id") == series else {
                throw ContentError("评论剧集或分集不匹配")
            }
            guard common.optInt("status", -1) == 1 else { continue }
            let id = row.optString("comment_id")
            let rawContent = common.obj("content")?.optString("text") ?? ""
            let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20000)
            guard !id.isEmpty && id.count <= 120 && !content.isEmpty && seen.insert(id).inserted else { continue }
            let user = common.obj("user_info")?.obj("base_info")
            let avatarRaw = user?.optString("user_avatar") ?? ""
            let avatar = avatarRaw.prefix(4096)
            let avatarStr = String(avatar).hasPrefix("https://") ? String(avatar) : ""
            items.append([
                "id": id,
                "author": String((user?.optString("user_name") ?? "").prefix(200)),
                "avatar": avatarStr,
                "content": String(content),
                "created": max(Int64(0), common.optLong("create_timestamp", 0)),
                "likes": max(Int64(0), row.obj("stat")?.optLong("digg_count", 0) ?? 0),
                "rating": 0,
            ])
        }
        return [
            "seriesID": series, "episodeID": episode, "total": max(Int64(0), info.optLong("total", 0)),
            "items": items, "nextCursor": more ? next : "", "hasMore": more,
        ]
    }
}
