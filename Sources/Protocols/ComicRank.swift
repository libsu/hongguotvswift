// SPDX-License-Identifier: GPL-3.0-only
// 榜单解析（适配 2026-10 当前站点结构）
// 榜单数据在 <script data-fn-name="r" data-fn-args='["rank_<route>/page","content",{...}]'> 里，
// 属性用单引号 + HTML 实体（&quot; &amp; &#x2F; 等），payload 含 isSuccess/rankList/pagination
import Foundation

enum ComicRank {
    static func parse(html: String, page: Int, board: RankBoard) throws -> CatalogPage {
        do {
            // loader 键：rank_<route>/page，例如 rank_hot-comic-drama/page
            let loaderKey = "rank_\(board.route)/page"
            for script in extractScripts(html: html) {
                guard let name = script.attr("data-fn-name"), (name == "r" || name == "mergeLoaderData") else { continue }
                guard let argsRaw = script.attr("data-fn-args"), let args = try? parseJSONArray(decodeHtml(argsRaw)) else { continue }
                guard args.count > 0, let first = args[0] as? String, first == loaderKey else { continue }

                var raw: Any?
                if name == "r" && args.count >= 3, (args[1] as? String) == "content" {
                    raw = args[2]
                } else if name == "mergeLoaderData" {
                    if let list = args[1] as? [[String: Any]] {
                        let entry = list.first { ($0["key"] as? String) == "content" }
                        if let arr = entry?["routerDataFnArgs"] as? [Any], arr.count > 0 { raw = arr[0] }
                    }
                }

                let payload: [String: Any]
                if let d = raw as? [String: Any] { payload = d }
                else if let s = raw as? String, let d = try? parseJSON(decodeHtml(s)) { payload = d }
                else { continue }

                guard payload.optBool("isSuccess") else { throw ContentError("剧集榜单暂不可用") }
                guard let rows = payload["rankList"] as? [[String: Any]] else { throw ContentError("剧集榜单格式已变化") }
                let pagination = payload.obj("pagination")
                let totalPages = pagination?.optInt("totalPages", 0) ?? 0
                guard totalPages >= 1 && (pagination?.optInt("pageNum", page) ?? page) == page else {
                    throw ContentError("剧集分页信息异常")
                }

                var positions: [String: RankPosition] = [:]
                var items: [Series] = []
                var seen = Set<String>()
                for row in rows {
                    let id = row.str("seriesId").isEmpty ? (row.str("series_id").isEmpty ? row.str("id") : row.str("series_id")) : row.str("seriesId")
                    let count = row.optInt("episodeCount", (row["episodeVids"] as? [Any])?.count ?? 0)
                    if positions[id] == nil {
                        let rank = row.optInt("rank")
                        let metrics = [row.str("scoreText"), row.str("favoriteText"), row.str("likeText")].filter { !$0.isEmpty }.joined(separator: " · ")
                        positions[id] = RankPosition(rank: rank > 0 ? rank : nil, heat: row.str("heatText"), metrics: metrics)
                    }
                    let badge = count > 0 ? "全 \(count) 集" : row.str("heatText")
                    var tagNames: [String] = []
                    if let arr = row["tags"] as? [String] { tagNames = arr.prefix(5).map { $0 } }
                    else if let arr = row["tags"] as? [[String: Any]] { tagNames = arr.prefix(5).map { $0.str("name") } }
                    let tags = tagNames.filter { !$0.isEmpty }.joined(separator: " · ")
                    let title = row.str("title").isEmpty ? row.str("series_name") : row.str("title")
                    let cover = row.str("cover").isEmpty ? row.str("series_cover") : row.str("cover")
                    let desc = row.str("description").isEmpty ? row.str("series_intro") : row.str("description")
                    let series = Series(id: id, title: title, cover: cleanUrl(cover), description: desc, badge: badge, tags: tags)
                    if isValidNumericId(id) && !series.title.isEmpty && seen.insert(id).inserted {
                        items.append(series)
                    }
                }
                let filteredPositions = positions.filter { id, _ in items.contains { $0.id == id } }
                return CatalogPage(items: items, hasMore: !items.isEmpty && page < min(totalPages, 100),
                                   ranking: ComicRanking(positions: filteredPositions, totalPages: min(totalPages, 100), updatedText: ""))
            }
            throw ContentError("页面没有剧集榜单数据")
        } catch let e as ContentError {
            throw e
        } catch {
            throw ContentError("剧集榜单格式已变化")
        }
    }

    // MARK: - HTML 实体解码（对齐 reference decodeHtml）

    static func decodeHtml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - script 标签解析（支持单引号/双引号属性 + HTML 实体）

    private struct ScriptTag {
        let attributes: [String: String]
        func attr(_ name: String) -> String? { attributes[name] }
    }

    private static func extractScripts(html: String) -> [ScriptTag] {
        let pattern = "<script\\b([^>]*)>"
        let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        var out: [ScriptTag] = []
        for m in regex.matches(in: html, options: [], range: nsrange) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let attrString = String(html[r])
            var attrs: [String: String] = [:]
            // 双引号
            let dq = try! NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)=\"([^\"]*)\"")
            for am in dq.matches(in: attrString, options: [], range: NSRange(attrString.startIndex..<attrString.endIndex, in: attrString)) {
                guard let kr = Range(am.range(at: 1), in: attrString), let vr = Range(am.range(at: 2), in: attrString) else { continue }
                attrs[String(attrString[kr])] = String(attrString[vr])
            }
            // 单引号
            let sq = try! NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)='([^']*)'")
            for am in sq.matches(in: attrString, options: [], range: NSRange(attrString.startIndex..<attrString.endIndex, in: attrString)) {
                guard let kr = Range(am.range(at: 1), in: attrString), let vr = Range(am.range(at: 2), in: attrString) else { continue }
                if attrs[String(attrString[kr])] == nil { attrs[String(attrString[kr])] = String(attrString[vr]) }
            }
            out.append(ScriptTag(attributes: attrs))
        }
        return out
    }

    private static func parseJSONArray(_ s: String) throws -> [Any] {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ContentError("榜单脚本参数格式异常")
        }
        return arr
    }
}
