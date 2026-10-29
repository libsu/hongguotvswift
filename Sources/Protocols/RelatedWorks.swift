// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum RelatedWorks {
    /// 解析相关作品 cell
    static func parse(raw: String, currentId: String) throws -> [RelatedWork] {
        let root = try parseJSON(raw)
        guard root.optInt("code", -1) == 0 else { throw ContentError("相关作品接口暂不可用") }
        guard let cells = root["data"] as? [[String: Any]] else { throw ContentError("相关作品数据格式已变化") }
        var out: [RelatedWork] = []
        var seen = Set<String>()
        for cell in cells {
            let showType = cell.optInt("show_type")
            guard showType == 547 || cell.str("cell_name") == "相关作品" else { continue }
            for row in (cell["video_data"] as? [[String: Any]] ?? []) {
                let id = row.str("series_id")
                let title = row.str("title")
                let type = row.optInt("content_type")
                guard id != currentId && isValidNumericId(id) && !title.isEmpty && (type == 1004 || type == 1007) else { continue }
                let upcoming = type == 1007
                guard upcoming || (!row.optBool("disable_play") && row.optInt("episode_cnt") > 0) else { continue }
                let tagText = (row.obj("tag_info"))?.str("text") ?? ""
                let seasonIndex = row.optInt("season_index")
                let season = tagText.isEmpty ? (seasonIndex > 0 ? "第\(seasonIndex)季" : "") : tagText
                let badge = upcoming ? "待上线" : "全 \(row.optInt("episode_cnt")) 集"
                let series = Series(id: id, title: title, cover: cleanUrl(row.str("cover")), description: row.str("video_desc"), badge: badge)
                guard seen.insert(id).inserted else { continue }
                out.append(RelatedWork(series: series, season: season, upcoming: upcoming))
                if out.count >= 30 { return out }
            }
        }
        return out
    }
}
