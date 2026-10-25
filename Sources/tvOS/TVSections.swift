// SPDX-License-Identifier: GPL-3.0-only
// tvOS 栏目通用三段式容器：b 筛选区 + c 卡片区 + d 状态区。
// 首页/找剧/榜单/我的 四个栏目共用这套「上筛选、中卡片、下状态」骨架，消除重复样板。
// 搜索栏目无 b 筛选区，另用独立布局（见 TVShelfViews.swift 的 TVSearchView）。
import SwiftUI

/// 栏目三段式骨架：顶部筛选区 → 中部卡片区 → 底部状态栏。
/// 负责统一间距、高度与顶留白；筛选控件由 `bar` 注入，卡片区由 `card` 注入，
/// 状态文本由 `status` 注入。
struct TVSectionContainer<Bar: View, Card: View>: View {
    let canvasHeight: CGFloat
    @ViewBuilder var bar: () -> Bar
    @ViewBuilder var card: () -> Card
    var status: () -> String

    private var gap: CGFloat { TVLayout.h(TVLayout.gapVH, of: canvasHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            // b 筛选区
            bar()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TVLayout.h(TVLayout.filterVH, of: canvasHeight))
                .padding(.horizontal, 64)

            // c 卡片区：固定为 cardVH 高度，空态/加载态/网格不因内容不同而改变高度，
            // 避免在栏目内部切换（如「我的」收藏↔预约）时上下布局抖动。
            card()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(height: TVLayout.h(TVLayout.cardVH, of: canvasHeight))

            // d 信息区
            TVStatusBar(text: status())
                .frame(height: TVLayout.h(TVLayout.statusVH, of: canvasHeight))
        }
        .padding(.top, gap)
    }
}

// MARK: - 「我的」栏目数据（收藏 · 历史 · 预约）

extension Model {
    /// 收藏片单（已登录→账户收藏，未登录→本机收藏）。
    var mineFavorites: [Series] {
        account?.loggedIn == true ? cloudFavorites.map(\.series) : library.contents.favorites
    }

    /// 历史片单（已登录→账户历史，未登录→本机历史）。
    var mineHistory: [Series] {
        account?.loggedIn == true ? cloudHistory.map(\.series) : library.contents.history.map(\.series)
    }

    /// 已上线预约（仅登录有数据，未登录为空）。
    var mineReservations: [Series] {
        account?.loggedIn == true ? cloudOnline.map(\.series) : []
    }
}
