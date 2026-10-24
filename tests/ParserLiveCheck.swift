// SPDX-License-Identifier: GPL-3.0-only
// 用抓到的真实页面 HTML 直接校验 rank/catalog 解析（离线，无需网络）。
import Foundation

@main struct ParserLiveCheck {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { print("用法: ParserLiveCheck <rank.html> <catalog.html>"); exit(2) }
        let rankHtml = try String(contentsOfFile: args[1], encoding: .utf8)
        let catalogHtml = try String(contentsOfFile: args[2], encoding: .utf8)

        // 榜单
        do {
            let page = try ComicRank.parse(html: rankHtml, page: 1, board: .comic)
            print("rank items=\(page.items.count) hasMore=\(page.hasMore) totalPages=\(page.ranking?.totalPages ?? -1)")
            if let first = page.items.first {
                print("  first: id=\(first.id) title=\(first.title) badge=\(first.badge) tags=\(first.tags)")
            }
            assert(page.items.count > 0, "榜单应为非空")
        } catch {
            print("rank 解析失败: \(error)")
            exit(1)
        }

        // 分类（comic-drama）
        do {
            let data = try ContentRepository.extractRouter(catalogHtml)
            let loaderData = data.obj("loaderData") ?? [:]
            guard let section = loaderData.obj("category_$") else { print("[FAIL] 缺少 category_$"); exit(1) }
            let rows = section.array("recommendList") ?? []
            assert(rows.count > 0, "分类 recommendList 应为非空")
            print("catalog recommendList=\(rows.count)")
        } catch {
            print("catalog 解析失败: \(error)")
            exit(1)
        }
        print("榜单/分类 真实页面解析通过")
    }
}
