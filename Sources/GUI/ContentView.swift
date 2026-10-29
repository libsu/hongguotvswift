// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    init(model: Model) { self.model = model; library = model.library }

    // MARK: - 播放区/内容区最小尺寸
    static let detailMinWidth: CGFloat = 720
    static let detailMinHeight: CGFloat = 405 - 50
    /// 侧栏最小/最大宽度，与 `ModelPlatform` 的窗口最小尺寸保持一致
    static let railMinWidth: CGFloat = 180
    static let railMaxWidth: CGFloat = Theme.railMaxWidth

    private var items: [Series] {
        switch model.section {
        case .favorites: return library.contents.favorites
        case .history: return library.contents.history.map(\.series)
        case .discover, .rank, .recommend: return model.catalogRows
        case .account: return model.cloudRows.map(\.series)
        default: return model.rows
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailColumn
        }
        .task(waitForInitialLoad)
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(discoveryNavigation) { railItem($0) }
            }
            .padding(.top, 8)
            Spacer()
            railItem(NavigationItem(title: model.accountRailTitle, icon: model.accountRailIcon, destination: .mine), tag: .mine, iconSize: 20)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .navigationTitle("红果")
        .navigationSplitViewColumnWidth(min: Self.railMinWidth, ideal: 200, max: Self.railMaxWidth)
    }

    @ViewBuilder
    private func railItem(_ item: NavigationItem, tag: Destination? = nil, iconSize: CGFloat = 16) -> some View {
        let target = tag ?? item.destination
        let selected = model.navigation == target
        Button { model.navigate(target) } label: {
            HStack(spacing: Theme.railContentSpacing) {
                Image(systemName: item.icon).font(.system(size: iconSize)).frame(width: Theme.railIconWidth)
                Text(item.title).font(.body).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.railHPadding).padding(.vertical, Theme.railVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.railSelected : .clear, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: - 详情列

    private var detailColumn: some View {
        VStack(spacing: 0) {
            mainContent.frame(minWidth: Self.detailMinWidth)
            Divider()
            statusBar
        }
        .navigationTitle(model.showDetail ? (model.detail?.series.title ?? "播放") : model.navigation.title)
        .toolbar { detailToolbar }
        .searchable(text: $model.query, placement: .toolbar, prompt: "搜索全部剧集")
        .onSubmit(of: .search) { model.search() }
    }

    @ViewBuilder
    private var mainContent: some View {
        if model.section == .home && (model.preview || !model.showDetail) {
            HomeFeedView(model: model, library: library)
        } else if model.showDetail, let detail = model.detail {
            EpisodeView(model: model, detail: detail)
        } else if model.section == .mine {
            MyAccountView(model: model, library: library)
        } else {
            libraryView
        }
    }

    private var statusBar: some View {
        InlineHint(text: library.error ?? model.message, isLoading: model.loadingList || model.cloudLoading)
            .padding(.horizontal, Theme.overlayPadding)
            .frame(height: Theme.statusBarHeight)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if model.showDetail {
            ToolbarItem(placement: .navigation) {
                Button { model.backToLibrary() } label: { Label("返回片单", systemImage: "chevron.left") }
            }
        } else if model.detail != nil {
            ToolbarItem { Button("返回播放") { model.showDetail = true } }
        }
    }

    private func waitForInitialLoad() async {
        while model.busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
        if !Task.isCancelled && model.navigation == .search && model.rows.isEmpty { model.navigate(.home) }
    }

    // MARK: - 片单网格

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            libraryHeader
            filters
            libraryBody
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryHeader: some View {
        HStack {
            Text(model.section == .account ? "红果账号片单 · 本机记录独立保留" : "\(items.count) 部剧")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            if model.section == .account, model.account != nil {
                Button { model.loadCloud() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.cloudLoading)
            }
            if model.section == .recommend {
                Button("换一批") { model.loadCatalog(refresh: true) }.disabled(model.busy)
            }
        }
    }

    /// 按优先级依次判断：未登录 → 加载中 → 加载失败 → 空结果 → 正常网格
    @ViewBuilder
    private var libraryBody: some View {
        if model.section == .account, model.account == nil {
            EmptyStateView(title: "登录后查看账户片单", symbol: "person.crop.circle",
                           detail: "账户历史、收藏与预约会随登录账号切换 ") {
                Button("扫码登录") { model.navigate(.mine) }
            }
        } else if model.section == .account, model.cloudLoading {
            InlineHint(text: "正在读取\(model.cloudType.title)…", isLoading: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.section == .account, let error = model.cloudError {
            EmptyStateView(title: "账户片单读取失败", symbol: "exclamationmark.arrow.triangle.2.circlepath", detail: error) {
                Button("重新读取") { model.loadCloud() }
            }
        } else if items.isEmpty {
            EmptyStateView(title: emptyTitle,
                           symbol: model.section == .search ? "magnifyingglass" : "rectangle.stack",
                           detail: model.section == .search ? "在窗口右上角输入剧名，按回车搜索 " : "可刷新账号片单，或浏览找剧与排行榜 ")
        } else {
            seriesGrid
        }
    }

    private var showsCatalogPaging: Bool { [.discover, .recommend].contains(model.section) && model.catalogMore }

    private var seriesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Theme.gridItemMinWidth, maximum: Theme.gridItemMaxWidth), spacing: Theme.gridColumnSpacing)], alignment: .leading, spacing: Theme.gridRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, series in card(series, index: index) }
                // 哨兵必须放在 LazyVGrid 内（惰性渲染）：只有滚到它被实例化时 onAppear 才会触发
                if showsCatalogPaging {
                    Color.clear.frame(height: 1).onAppear { model.loadCatalog(more: true) }
                }
            }
            .padding(.top, 4)
            if model.section == .search && model.hasMore {
                Button("加载更多") { model.search(more: true) }.disabled(model.busy).padding()
            }
            if showsCatalogPaging {
                Button("加载更多") { model.loadCatalog(more: true) }.disabled(model.busy).padding()
            }
        }
    }

    private var emptyTitle: String {
        switch model.section {
        case .account: return model.cloudLoadedKey == nil ? "准备读取账户片单" : "账号暂无此类记录"
        case .favorites: return "还没有本机收藏"
        case .history: return "还没有本机观看记录"
        case .search: return model.query.isEmpty ? "找一部想看的剧" : "暂无搜索结果"
        default: return model.loadingList ? "正在加载…" : "暂无内容"
        }
    }

    // MARK: - 筛选栏

    @ViewBuilder
    private var filters: some View {
        VStack(alignment: .leading, spacing: Theme.spacingLG) {
            if model.section == .discover {
                CapsuleFilterRow(title: "类型", options: Self.categoryOptions, selection: $model.category, layout: .fixed) {
                    model.topic = ""; model.loadCatalog()
                }
            }
            if model.section == .rank {
                CapsuleFilterRow(title: "热播榜", options: Self.boardOptions, selection: $model.board, layout: .fixed) {
                    model.topic = ""; model.loadCatalog()
                }
            }
            if (model.section == .discover || model.section == .rank), !model.topics.isEmpty {
                CapsuleFilterRow(title: "题材", options: topicOptions, selection: $model.topic) { model.loadCatalog() }
            }
        }
    }

    private static let categoryOptions: [CapsuleFilterRow.Option] = [
        .init(label: "漫剧", value: "COMIC"),
        .init(label: "真人剧", value: "REAL"),
        .init(label: "AI 剧", value: "AI"),
    ]
    private static let boardOptions: [CapsuleFilterRow.Option] = [
        .init(label: "综合", value: "ALL"),
        .init(label: "漫剧", value: "COMIC"),
        .init(label: "真人剧", value: "REAL"),
        .init(label: "AI 剧", value: "AI"),
    ]
    /// 题材选项
    private var topicOptions: [CapsuleFilterRow.Option] {
        var options = model.topics.compactMap { t -> CapsuleFilterRow.Option? in
            let label = t.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !t.id.isEmpty else { return nil }
            return .init(label: label, value: t.id)
        }.sorted { $0.label < $1.label }
        options.insert(.init(label: "全部题材", value: ""), at: 0)
        return options
    }

    // MARK: - 剧集卡片

    private func card(_ series: Series, index: Int) -> some View {
        let cloud = model.section == .account ? model.cloudRows.first(where: { $0.id == series.id }) : nil
        let progressText = cloud?.episodeIndex.map { "账号看到第 \($0 + 1) 集" } ?? library.history(series.id)?.label

        var firstLine = SeriesCard.SubtitleLine(text: series.badge.isEmpty ? "" : series.badge)
        firstLine.trailingText = progressText
        firstLine.trailingAccent = false

        var lines = [firstLine]
        if model.section == .rank, let rank = model.rankPositions[series.id] {
            let text = [rank.rank.map { "第 \($0) 名" } ?? "", rank.heat].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append(.init(text: text, accent: true))
        } else if let publish = cloud?.publishText {
            lines.append(.init(text: publish))
        }

        var menu: [SeriesCard.MenuItem] = [
            .init(id: "fav", title: library.favorite(series.id) ? "取消本机收藏" : "加入本机收藏") { library.toggleFavorite(series) }
        ]
        if model.account?.loggedIn == true {
            menu.append(.init(id: "cloud-fav", title: "加入账户收藏") { model.cloudFavorite(series, add: true) })
            if model.section == .account && model.cloudType == .favorites {
                menu.append(.init(id: "cloud-unfav", title: "取消账户收藏") { model.cloudFavorite(series, add: false) })
            }
        }
        if model.section == .history {
            menu.append(.init(id: "remove-history", title: "删除本机观看记录") { library.removeHistory(series.id) })
        }

        return SeriesCard(
            cover: series.cover,
            title: series.title,
            coverHeight: Theme.posterLargeHeight,
            subtitleLines: lines,
            menuItems: menu,
            priority: index
        ) {
            if cloud?.online == false { model.message = "该剧待上线，暂时无法播放" }
            else { model.open(series, trial: model.section == .recommend) }
        }
    }
}

struct EpisodeView: View {
    @ObservedObject var model: Model
    let detail: Detail

    var body: some View {
        ZStack {
            Color.black
            PlayerSurfaceWindow(player: model.player, model: model)
                .background(.black)
                .overlay { DanmakuOverlay(model: model, danmaku: model.danmaku) }
                .overlay { PlayerTapLayer(model: model) }
                .frame(minHeight: ContentView.detailMinHeight)
            GeometryReader { _ in
                PlayerOverlays(model: model, detail: detail, context: .window)
            }
        }
        .animation(Theme.overlayAnimation, value: model.playerControlsVisible)
        .animation(Theme.overlayAnimation, value: model.infoPanelOpen)
        .modifier(PlayerZone(model: model))
        .onAppear { model.reconcileControls(.sync) }
        .colorScheme(.dark)
    }
}
