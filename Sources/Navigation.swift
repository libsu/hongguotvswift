// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct NavigationItem: Identifiable {
    let title: String
    let icon: String
    var id: String { title }
}

/// 左侧主导航（发现类）。「搜索」入口已移除——顶栏搜索框已可直接搜索。
let discoveryNavigation = [
    NavigationItem(title: "首页", icon: "play.rectangle.fill"),
    NavigationItem(title: "找剧", icon: "square.grid.2x2"),
    NavigationItem(title: "榜单", icon: "chart.bar"),
]

/// 「我的」侧栏条目固定放在最下角；未登录显示「登录」，登录后显示「我的」。
extension Model {
    var accountRailTitle: String {
        (account?.loggedIn == true) ? "我的" : "登录"
    }
    var accountRailIcon: String {
        (account?.loggedIn == true) ? "person.crop.circle.fill" : "person.crop.circle"
    }

    func navigate(_ destination: String) {
        if showDetail { saveProgress(); player.pause() }
        homeGeneration = UUID(); homeWarmTask?.cancel(); homeWarmDetail = nil
        showDetail = false
        navigation = destination
        switch destination {
        case "我的", "登录": section = "我的"; navigation = "我的"
        case "本机收藏": section = "收藏"
        case "本机历史": section = "历史"
        case "账户历史", "账户收藏", "已上线预约", "待上线预约": section = "账户"; cloudType = destination
        default: section = destination
        }
        // 跨栏目切换时打断进行中的请求，让新栏目能立即加载（旧响应会被各处的 generation/section 校验丢弃）。
        // 这使请求期间用户仍能点击其它栏目，不会锁死 GUI。
        let sameSection = section == previousSection
        previousSection = section
        if !sameSection { interruptPendingRequest() }
        if destination == "首页" { loadHome(); return }
        loadSection()
    }

    /// 取消进行中的请求并复位 busy，允许紧接着发起新栏目的请求。
    private func interruptPendingRequest() {
        action?.cancel()
        busy = false
    }

    private var previousSection: String {
        get { _previousSection }
        set { _previousSection = newValue }
    }

    func backToLibrary() { saveProgress(); player.pause(); showDetail = false }
}
