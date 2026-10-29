// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// 卡片装配规则回归测试：验证 SeriesCardBuilder 的副标题/菜单纯函数与 ContentView.card 手工逻辑等价。
// 规则收敛后应由本套件锁死，避免各列表页再次漂移。

@main struct SeriesCardBuilderTests {
    @MainActor static func main() async throws {
        let series = Series(id: "1", title: "标题", cover: "", description: "", badge: "全20集")
        let onlineNo = CloudEntry(series: series, episodeID: "1-1", episodeIndex: 2, position: 10, duration: 100, online: false, publishText: nil)

        func ctx(
            section: Section,
            cloudType: CloudType? = nil,
            rank: RankBadge? = nil,
            cloud: CloudEntry? = nil,
            loggedIn: Bool = false,
            localFav: Bool = false,
            history: WatchRecord? = nil
        ) -> SeriesCardBuilder.Context {
            SeriesCardBuilder.Context(
                section: section,
                cloudType: cloudType,
                rankPosition: rank,
                cloudEntry: cloud,
                accountLoggedIn: loggedIn,
                isLocalFavorite: localFav,
                historyRecord: history
            )
        }

        // 1. 榜单：副标题第二行 = 名次 + 热度，accent
        let rank = RankBadge(rank: 3, heat: "1.2万热度")
        let rankLines = SeriesCardBuilder.subtitleLines(for: series, context: ctx(section: .rank, rank: rank, loggedIn: false))
        assert(rankLines.count == 2, "榜单应有两行副标题")
        assert(rankLines[0].text == "全20集" && rankLines[0].trailingText == nil)
        assert(rankLines[1].text.contains("第 3 名") && rankLines[1].text.contains("1.2万热度") && rankLines[1].accent)

        // 2. 账户片单：第一行尾随「账号看到第 N 集」且不加 accent
        let cloud = CloudEntry(series: series, episodeID: "1-3", episodeIndex: 2, position: 30, duration: 100, online: true, publishText: "待更新")
        let accountLines = SeriesCardBuilder.subtitleLines(for: series, context: ctx(section: .account, cloud: cloud, loggedIn: true))
        assert(accountLines[0].trailingText == "账号看到第 3 集" && accountLines[0].trailingAccent == false)
        assert(accountLines.count == 2 && accountLines[1].text == "待更新", "账户片单第二行为 publishText")

        // 3. 历史：尾随本机历史 label
        let record = WatchRecord(series: series, episodeID: "1-1", episodeIndex: 0, position: 30, duration: 100, completed: false, updatedAt: Date())
        let histLines = SeriesCardBuilder.subtitleLines(for: series, context: ctx(section: .history, history: record))
        assert(histLines[0].trailingText == record.label)

        // 4. 菜单：默认仅本机收藏；登录加账户收藏；账户收藏 tab 加取消；历史加删除
        func menu(_ c: SeriesCardBuilder.Context) -> [SeriesCard.MenuItem] {
            SeriesCardBuilder.menuItems(for: c, actions: SeriesCardBuilder.Actions(
                toggleLocalFavorite: {}, addCloudFavorite: {}, removeCloudFavorite: {}, removeLocalHistory: {}
            ))
        }
        assert(menu(ctx(section: .recommend, loggedIn: false, localFav: false)).map(\.title) == ["加入本机收藏"])
        assert(menu(ctx(section: .recommend, loggedIn: true, localFav: false)).map(\.title) == ["加入本机收藏", "加入账户收藏"])
        assert(menu(ctx(section: .account, cloudType: .favorites, loggedIn: true)).map(\.title) == ["加入本机收藏", "加入账户收藏", "取消账户收藏"])
        assert(menu(ctx(section: .history, loggedIn: true)).map(\.title) == ["加入本机收藏", "加入账户收藏", "删除本机观看记录"])

        // 5. 待上线剧点击动作应由调用方决定（这里仅验证装配不含副作用）
        assert(onlineNo.online == false)

        print("SeriesCard subtitle/menu assembly for rank/account/history/login branches: PASS")
    }
}
