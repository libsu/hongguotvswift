// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// MARK: - 导航与分区状态（去字符串化）

/// 内容分区：决定列表页/详情页展示哪类数据。
enum Section: String, CaseIterable {
    case home = "首页"
    case discover = "找剧"
    case rank = "榜单"
    case recommend = "推荐"
    case favorites = "收藏"
    case history = "历史"
    case account = "账户"
    case mine = "我的"
    case search = "搜索"

    var title: String { rawValue }
}

/// 账户片单分类：账户历史 / 收藏 / 已上线预约 / 待上线预约。
enum CloudType: String, CaseIterable {
    case history = "账户历史"
    case favorites = "账户收藏"
    case online = "已上线预约"
    case upcoming = "待上线预约"

    var title: String { rawValue }

    /// 后端 path 段：history / favorites / reservations。
    var path: String {
        switch self {
        case .history: return "history"
        case .favorites: return "favorites"
        case .online, .upcoming: return "reservations"
        }
    }

    /// 仅查询已上线（待上线预约传 false）。
    var onlineOnly: Bool { self != .upcoming }
}

/// 侧栏/顶栏导航目的地：与分区基本对应，但区分「本机收藏/历史」与「账户历史/收藏/预约」等入口。
enum Destination: String, CaseIterable {
    case home = "首页"
    case discover = "找剧"
    case rank = "榜单"
    case recommend = "推荐"
    case mine = "我的"
    case login = "登录"
    case localFavorites = "本机收藏"
    case localHistory = "本机历史"
    case accountHistory = "账户历史"
    case accountFavorites = "账户收藏"
    case accountOnline = "已上线预约"
    case accountUpcoming = "待上线预约"
    case search = "搜索"

    var title: String { rawValue }

    /// 该目的地对应的内容分区。
    var section: Section {
        switch self {
        case .home: return .home
        case .discover: return .discover
        case .rank: return .rank
        case .recommend: return .recommend
        case .mine, .login: return .mine
        case .localFavorites: return .favorites
        case .localHistory: return .history
        case .accountHistory, .accountFavorites, .accountOnline, .accountUpcoming: return .account
        case .search: return .search
        }
    }

    /// 账户类目的地对应的片单分类；非账户目的地为 nil。
    var cloudType: CloudType? {
        switch self {
        case .accountHistory: return .history
        case .accountFavorites: return .favorites
        case .accountOnline: return .online
        case .accountUpcoming: return .upcoming
        default: return nil
        }
    }
}

struct NavigationItem: Identifiable {
    let title: String
    let icon: String
    let destination: Destination
    var id: String { title }
}

/// 左侧主导航（发现类）。「搜索」入口已移除——顶栏搜索框已可直接搜索。
let discoveryNavigation = [
    NavigationItem(title: "首页", icon: "play.rectangle", destination: .home),
    NavigationItem(title: "找剧", icon: "square.grid.2x2", destination: .discover),
    NavigationItem(title: "榜单", icon: "chart.bar", destination: .rank),
]

/// 「我的」侧栏条目固定放在最下角；未登录显示「登录」，登录后优先显示用户名，无用户名时回退「我的」。
extension Model {
    var accountRailTitle: String {
        guard account?.loggedIn == true else { return "登录" }
        if let nickname = account?.nickname, !nickname.isEmpty, nickname != "红果用户" { return nickname }
        return "我的"
    }
    var accountRailIcon: String {
        (account?.loggedIn == true) ? "person.crop.circle.fill" : "person.crop.circle"
    }

    func navigate(_ destination: Destination) {
        if showDetail { saveProgress(); player.pause() }
        homeGeneration = UUID(); homeWarmTask?.cancel(); homeWarmDetail = nil
        showDetail = false
        detailGeneration = UUID(); detailTask?.cancel()
        navigation = destination == .login ? .mine : destination
        section = destination.section
        if let cloudType = destination.cloudType { self.cloudType = cloudType }
        let sameSection = section == previousSection
        previousSection = section
        if !sameSection { interruptPendingRequest() }
        if destination == .home { loadHome(); return }
        loadSection()
    }

    /// 取消进行中的请求并复位 busy，允许紧接着发起新栏目的请求。
    private func interruptPendingRequest() {
        action?.cancel()
        busy = false
    }

    private var previousSection: Section? {
        get { _previousSection }
        set { _previousSection = newValue }
    }

    func backToLibrary() { saveProgress(); player.pause(); showDetail = false }
}
