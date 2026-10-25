// SPDX-License-Identifier: GPL-3.0-only
// 时间轴弹幕（匿名只读）。
import Foundation

final class TimedComments {
    private let transport: CommentTransport
    private var cache: [String: (Int64, String)] = [:]
    private let clock: () -> Int64

    init(transport: CommentTransport = CommentTransport(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.transport = transport
        self.clock = clock
    }

    func read(series: String, episode: String, start: Int64, duration: Int64) async throws -> [String: Any] {
        guard series.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil,
              episode.range(of: "^[0-9]{6,30}$", options: .regularExpression) != nil else {
            throw ContentError("剧集参数异常")
        }
        guard start >= 0 && duration > start && duration <= 86400000 else { throw ContentError("弹幕时间段异常") }
        let key = "\(series)/\(episode)/\(start)/\(duration)"
        let cached = cache[key].flatMap { clock() - $0.0 < 60000 ? $0.1 : nil }
        if let cached {
            return try parseJSON(cached)
        }
        let payload: [String: Any] = [
            "comment_source": 601, "server_channel": 1000, "group_id": episode, "group_type": 30,
            "comment_type": 20, "sort": 1, "count": 90, "cursor": "", "aid": 8662, "compliance_status": 0,
            "business_param": [
                "book_id": series, "start_offset_time": start, "playlet_item_duration": duration,
                "need_danmaku_guide_type": [1, 3, 4, 2],
            ],
        ]
        let parsed = try await Self.fetchWithRetry(transport: transport, episode: episode, payload: payload, series: series, start: start, duration: duration)
        cache[key] = (clock(), jsonString(parsed))
        while cache.count > 64 { if let k = cache.keys.first { cache.removeValue(forKey: k) } }
        return parsed
    }

    /// 拉取并解析一页弹幕，对网络跨态错误（超时/504 等）自动重试，避免偶发抖动导致加载失败。
    private static func fetchWithRetry(transport: CommentTransport, episode: String, payload: [String: Any], series: String, start: Int64, duration: Int64) async throws -> [String: Any] {
        func fetchOnce() async throws -> [String: Any] {
            let result = try await transport.read(episode: episode, payload: payload, source: 601, channel: 1000)
            return try parse(result: result, series: series, episode: episode, start: start, duration: duration)
        }
        do {
            return try await fetchOnce()
        } catch {
            if !isTransientNetworkError(error) || Task.isCancelled { throw error }
            for attempt in 1...2 {
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * attempt))
                try Task.checkCancellation()
                do { return try await fetchOnce() }
                catch {
                    if attempt == 2 || !isTransientNetworkError(error) || Task.isCancelled { throw error }
                }
            }
            throw ContentError("弹幕暂时无法读取，请稍后重试")
        }
    }

    static func parse(result: [String: Any], series: String, episode: String, start: Int64, duration: Int64) throws -> [String: Any] {
        guard let code = result["code"] as? NSNumber, code.intValue == 0 else { throw ContentError("弹幕接口未返回成功数据") }
        guard let data = result.obj("data") else { throw ContentError("弹幕接口未返回成功数据") }
        guard let extra = data.obj("extra") else { throw ContentError("弹幕接口未返回成功数据") }
        let next = extra.optLong("next_query_danmaku_list_time")
        guard next > start && next <= 86400000 else { throw ContentError("弹幕时间段无效") }
        let end = min(next, duration)
        var items: [[String: Any]] = []
        var seen = Set<String>()
        let rows = data["data_list"] as? [[String: Any]] ?? []
        for i in 0..<min(rows.count, 300) {
            guard let comment = rows[i]["comment"] as? [String: Any],
                  let common = comment["common"] as? [String: Any],
                  let expand = comment["expand"] as? [String: Any] else { continue }
            guard common.optString("group_id") == episode && common.optInt("status", -1) == 1 else { continue }
            let time = expand.optLong("offset_time", -1)
            guard time >= start && time < end else { continue }
            let id = comment.optString("comment_id").prefix(120)
            let rawText = common.obj("content")?.optString("text") ?? ""
            let text = rawText.replacingOccurrences(of: "[\\p{Cc}\\u2028\\u2029]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)
            guard !id.isEmpty && !text.isEmpty && seen.insert(String(id)).inserted else { continue }
            items.append(["id": String(id), "text": String(text), "timeMS": time])
            if items.count >= 90 { break }
        }
        items.sort { ($0["timeMS"] as? Int64 ?? 0) < ($1["timeMS"] as? Int64 ?? 0) }
        return [
            "seriesID": series, "episodeID": episode, "startMS": start, "nextMS": end, "items": items,
        ]
    }
}
