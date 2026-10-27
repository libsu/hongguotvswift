// SPDX-License-Identifier: GPL-3.0-only
// tvOS 根视图、栏目主界面、顶部导航栏，以及各栏目（首页/找剧/榜单/我的/搜索）
// 逻辑层（Model / loadHome / loadCatalog / open / play 等）跨平台复用，
// 本文件只负责「用 SwiftUI focus 系统承载 Siri Remote 焦点」的展示与交互
import SwiftUI
import UIKit

// MARK: - 根视图

struct TVRootView: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.showDetail {
            TVPlayerView(model: model)
        } else {
            TVLibraryView(model: model)
        }
    }
}

// MARK: - 栏目主界面

/// 栏目主界面：顶部导航页签 + 对应内容区
struct TVLibraryView: View {
    @ObservedObject var model: Model

    // 顶部页签：首页 / 找剧 / 榜单 / 我的 搜索是导航栏右侧的孤立 TextField，不占页签按钮
    private let tabs: [(title: String, icon: String, destination: Destination)] = [
        ("首页", "play.rectangle", .home),
        ("找剧", "square.grid.2x2", .discover),
        ("榜单", "chart.bar", .rank),
        ("我的", "person.crop.circle", .mine),
    ]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TVNavBar(model: model, tabs: tabs)
                    .frame(height: TVLayout.h(TVLayout.navVH, of: geo.size.height))
                Divider()
                content(canvasHeight: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // 菜单键（Siri Remote 的 Menu / 返回）从任意栏目回到首页，符合 tvOS 惯例
        // 扫码登录浮层显示期间不抢 Menu，交给浮层内的 cancelLogin 处理
        .onExitCommand {
            if model.qrImageData == nil && model.navigation != .home { model.navigate(.home) }
        }
        .task {
            // 冷启动完成后引导到首页（与 macOS ContentView 的引导一致）
            while model.busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !Task.isCancelled && model.rows.isEmpty && model.catalogRows.isEmpty && model.navigation == .search {
                model.navigate(.home)
            }
        }
    }

    @ViewBuilder
    private func content(canvasHeight: CGFloat) -> some View {
        switch model.navigation {
        case .home:
            TVHomeView(model: model, canvasHeight: canvasHeight)
        case .discover:
            TVCatalogView(model: model, canvasHeight: canvasHeight)
        case .rank:
            TVBoardView(model: model, canvasHeight: canvasHeight)
        case .mine:
            TVMineView(model: model, canvasHeight: canvasHeight)
        case .search:
            TVSearchView(model: model, canvasHeight: canvasHeight)
        default:
            TVHomeView(model: model, canvasHeight: canvasHeight)
        }
    }
}

// MARK: - 顶部导航栏

/// 顶部横向焦点导航栏：四个按钮（首页/找剧/榜单/我的）+ 右侧孤立搜索 TextField
struct TVNavBar: View {
    @ObservedObject var model: Model
    let tabs: [(title: String, icon: String, destination: Destination)]
    @FocusState private var focused: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 48) {
            ForEach(tabs, id: \.title) { tab in
                TVTabButton(
                    title: tab.title,
                    icon: tab.icon,
                    selected: model.navigation == tab.destination,
                    focused: focused == tab.title
                ) {
                    if model.navigation != tab.destination { model.navigate(tab.destination) }
                }
                .focused($focused, equals: tab.title)
            }
            // 孤立的搜索 TextField：无任何外框，键入完成（确认键）即触发搜索
            TextField("搜索剧名", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { model.search() }
                .frame(width: 480, height: 40, alignment: .leading)
            Spacer()
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 20)
    }
}

// MARK: - 首页

struct TVHomeView: View {
    @ObservedObject var model: Model
    let canvasHeight: CGFloat
    @FocusState private var focus: String?

    private static let categoryOptions: [TVFilterOption] = [
        TVFilterOption(id: "cat:ALL", title: "推荐", value: "ALL"),
        TVFilterOption(id: "cat:REAL", title: "真人剧", value: "REAL"),
        TVFilterOption(id: "cat:COMIC", title: "漫剧", value: "COMIC"),
    ]

    var body: some View {
        TVSectionContainer(canvasHeight: canvasHeight) {
            // b 筛选区：频道切换 + 换一批 + 开始刷剧
            HStack(spacing: 16) {
                TVFilterRow(options: Self.categoryOptions, current: model.homeCategory, focus: $focus) { value in
                    if model.homeCategory != value { model.homeCategory = value; model.loadHome() }
                }
                TVCapsuleButton(title: "换一批", icon: "arrow.clockwise", enabled: !model.busy, focusKey: "act:shuffle", focus: $focus) {
                    model.loadHome()
                }
                TVCapsuleButton(title: "开始刷剧", icon: "play.fill", enabled: !model.busy, focusKey: "act:start", focus: $focus) {
                    model.startHomeTrial()
                }
            }
        } card: {
            // c 卡片区
            if model.busy && model.catalogRows.isEmpty {
                TVLoadingView(text: model.message)
            } else if model.catalogRows.isEmpty {
                TVEmptyView(title: "看看下一部好故事", symbol: "play.rectangle")
            } else {
                TVPosterGrid(
                    items: model.catalogRows,
                    section: .home,
                    model: model,
                    focusedSeries: $focus,
                    hasMore: model.catalogMore,
                    loadMore: { model.loadHome(more: true) },
                    onSelect: { model.open($0, trial: true) },
                    cardHeight: TVLayout.h(TVLayout.cardVH, of: canvasHeight)
                )
            }
        } status: {
            model.message
        }
    }
}

// MARK: - 找剧

/// 找剧：题材 + 类型筛选，平铺海报网格
struct TVCatalogView: View {
    @ObservedObject var model: Model
    let canvasHeight: CGFloat
    @FocusState private var focus: String?

    private static let categoryOptions: [TVFilterOption] = [
        TVFilterOption(id: "cat:COMIC", title: "漫剧", value: "COMIC"),
        TVFilterOption(id: "cat:REAL", title: "真人剧", value: "REAL"),
        TVFilterOption(id: "cat:AI", title: "AI 剧", value: "AI"),
    ]

    /// 题材选项：固定「全部」（空值）+ 后端返回的动态题材列表
    private var topicOptions: [TVFilterOption] {
        [TVFilterOption(id: "topic:_all", title: "全部", value: "")]
            + model.topics.map { TVFilterOption(id: "topic:\($0.id)", title: $0.label, value: $0.id) }
    }

    var body: some View {
        TVSectionContainer(canvasHeight: canvasHeight) {
            // b 筛选区
            filterBar
        } card: {
            // c 卡片区
            if model.busy && model.catalogRows.isEmpty {
                TVLoadingView(text: model.message)
            } else if model.catalogRows.isEmpty {
                TVEmptyView(title: "暂无内容", symbol: "rectangle.stack")
            } else {
                TVPosterGrid(
                    items: model.catalogRows,
                    section: .discover,
                    model: model,
                    focusedSeries: $focus,
                    hasMore: model.catalogMore,
                    loadMore: { model.loadCatalog(more: true) },
                    onSelect: { model.open($0) },
                    cardHeight: TVLayout.h(TVLayout.cardVH, of: canvasHeight)
                )
            }
        } status: {
            model.message
        }
        .task { if model.catalogRows.isEmpty || model.catalogKind != .discover { model.loadCatalog() } }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Text("类型").font(.subheadline).foregroundStyle(.secondary)
            TVFilterRow(options: Self.categoryOptions, current: model.category, focus: $focus) { value in
                model.category = value; model.topic = ""; model.loadCatalog()
            }
            if !model.topics.isEmpty {
                Text("题材").font(.subheadline).foregroundStyle(.secondary).padding(.leading, 12)
                TVFilterRow(options: topicOptions, current: model.topic, focus: $focus) { value in
                    model.topic = value; model.loadCatalog()
                }
            }
            Spacer()
        }
    }
}

// MARK: - 榜单

/// 榜单：热播榜切换 + 排名海报网格
struct TVBoardView: View {
    @ObservedObject var model: Model
    let canvasHeight: CGFloat
    @FocusState private var focus: String?

    private static let boardOptions: [TVFilterOption] = [
        TVFilterOption(id: "board:ALL", title: "综合", value: "ALL"),
        TVFilterOption(id: "board:COMIC", title: "漫剧", value: "COMIC"),
        TVFilterOption(id: "board:REAL", title: "真人剧", value: "REAL"),
        TVFilterOption(id: "board:AI", title: "AI 剧", value: "AI"),
    ]

    var body: some View {
        TVSectionContainer(canvasHeight: canvasHeight) {
            // b 筛选区
            HStack(spacing: 12) {
                Text("热播榜").font(.subheadline).foregroundStyle(.secondary)
                TVFilterRow(options: Self.boardOptions, current: model.board, focus: $focus) { value in
                    model.board = value; model.topic = ""; model.loadCatalog()
                }
                Spacer()
            }
        } card: {
            // c 卡片区
            if model.busy && model.catalogRows.isEmpty {
                TVLoadingView(text: model.message)
            } else if model.catalogRows.isEmpty {
                TVEmptyView(title: "暂无内容", symbol: "chart.bar")
            } else {
                TVPosterGrid(
                    items: model.catalogRows,
                    section: .rank,
                    model: model,
                    focusedSeries: $focus,
                    hasMore: false,
                    loadMore: {},
                    onSelect: { model.open($0) },
                    cardHeight: TVLayout.h(TVLayout.cardVH, of: canvasHeight)
                )
            }
        } status: {
            model.message
        }
        .task { if model.catalogRows.isEmpty || model.catalogKind != .rank { model.loadCatalog() } }
    }
}

// MARK: - 搜索

struct TVSearchView: View {
    @ObservedObject var model: Model
    let canvasHeight: CGFloat
    @FocusState private var focusedSeries: String?

    var body: some View {
        VStack(alignment: .leading, spacing: TVLayout.h(TVLayout.gapVH, of: canvasHeight)) {
            // c 卡片区（搜索输入由顶部「搜索」按钮弹出的系统输入界面完成；无 b 筛选区）
            if model.busy && model.rows.isEmpty {
                TVLoadingView(text: model.message)
            } else if !model.rows.isEmpty {
                TVPosterGrid(
                    items: model.rows,
                    section: .search,
                    model: model,
                    focusedSeries: $focusedSeries,
                    hasMore: model.hasMore,
                    loadMore: { model.search(more: true) },
                    onSelect: { model.open($0) },
                    cardHeight: TVLayout.h(TVLayout.cardVH, of: canvasHeight)
                )
            } else {
                TVEmptyView(title: model.query.isEmpty ? "点击顶部搜索按钮输入剧名" : "暂无搜索结果", symbol: "magnifyingglass")
            }

            // d 信息区
            TVStatusBar(text: model.message)
                .frame(height: TVLayout.h(TVLayout.statusVH, of: canvasHeight))
        }
        .padding(.top, TVLayout.h(TVLayout.gapVH, of: canvasHeight))
    }
}
