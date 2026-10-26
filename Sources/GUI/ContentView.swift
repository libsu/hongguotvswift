// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    @ObservedObject var updates: MacUpdates
    init(model: Model) { self.model = model; library = model.library; updates = model.updates }
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
            VStack(spacing: 0) {
                // 发现区
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(discoveryNavigation) { item in
                        railItem(item)
                    }
                }
                .padding(.top, 8)
                Spacer()
                // 我的/登录：沉在底部（Apple TV 风）
                railItem(NavigationItem(title: model.accountRailTitle, icon: model.accountRailIcon, destination: .mine), tag: .mine, iconSize: 20)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
            .navigationTitle("红果")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if model.section == .home && (model.preview || !model.showDetail) {
                    HomeFeedView(model: model, library: library)
                } else if model.showDetail, let detail = model.detail {
                    EpisodeView(model: model, library: library, detail: detail)
                } else if model.section == .mine {
                    MyAccountView(model: model, library: library, updates: updates)
                } else { libraryView }
                Divider()
                HStack(spacing: 10) {
                    if model.loadingList || model.cloudLoading { ProgressView().controlSize(.small) }
                    Text(library.error ?? model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 20)
                    .frame(height: 44, alignment: .center)
            }.navigationTitle(model.showDetail ? (model.detail?.series.title ?? "播放") : model.navigation.title)
                .toolbar {
                    if model.showDetail {
                        ToolbarItem(placement: .navigation) {
                            Button { model.backToLibrary() } label: { Label("返回片单", systemImage: "chevron.left") }
                        }
                    } else if model.detail != nil {
                        ToolbarItem { Button("返回播放") { model.showDetail = true } }
                    }
                }
                .searchable(text: $model.query, placement: .toolbar, prompt: "搜索全部剧集")
                .onSubmit(of: .search) { model.search() }
                .sheet(isPresented: $model.showComments) {
                    VStack(spacing: 0) {
                        HStack { Spacer(); Button("关闭") { model.showComments = false } }.padding(12)
                        CommentsPanel(model: model, comments: model.comments, thread: model.commentThread)
                    }.frame(width: 540, height: 680)
                }
        }.task {
            while model.busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
            if !Task.isCancelled && model.navigation == .search && model.rows.isEmpty { model.navigate(.home) }
        }.frame(minWidth: 1000, minHeight: 720)
    }
    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    // 顶栏 navigationTitle 已统一显示当前栏目名，内容区不再重复大字标题，只留条数/说明副标题。
                    Text(model.section == .account ? "红果账号片单 · 本机记录独立保留" : "\(items.count) 部剧").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.section == .account, model.account != nil {
                    Button { model.loadCloud() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.cloudLoading)
                }
                if model.section == .recommend { Button("换一批") { model.loadCatalog(refresh: true) }.disabled(model.busy) }
            }
            filters
            if model.section == .account, model.account == nil {
                emptyState("登录后查看账户片单", symbol: "person.crop.circle", detail: "账户历史、收藏与预约会随登录账号切换。") {
                    Button("扫码登录") { model.navigate(.mine) }
                }
            } else if model.section == .account, model.cloudLoading {
                VStack(spacing: 16) { ProgressView(); Text("正在读取\(model.cloudType.title)…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.section == .account, let error = model.cloudError {
                emptyState("账户片单读取失败", symbol: "exclamationmark.arrow.triangle.2.circlepath", detail: error) {
                    Button("重新读取") { model.loadCloud() }
                }
            } else if items.isEmpty {
                emptyState(emptyTitle, symbol: model.section == .search ? "magnifyingglass" : "rectangle.stack", detail: model.section == .search ? "在窗口右上角输入剧名，按回车搜索。" : "可刷新账号片单，或浏览找剧与排行榜。") { EmptyView() }
            } else {
                ScrollView {
                    // 多列自适应（minimum != maximum，避免 HVGrid 崩溃）；卡片内部固定 158 宽、靠左。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, series in card(series, index: index) }
                        // 哨兵必须放在 LazyVGrid 内（惰性渲染）：只有滚到它被实例化时 onAppear 才会触发。
                        // 若放在 ScrollView 直接子级（非惰性），会在首屏渲染时立即触发、之后滚动到底也不再触发。
                        if [.discover, .recommend].contains(model.section), model.catalogMore {
                            Color.clear.frame(height: 1)
                                .onAppear { model.loadCatalog(more: true) }
                        }
                    }.padding(.top, 4)
                    if model.section == .search && model.hasMore { Button("加载更多") { model.search(more: true) }.disabled(model.busy).padding() }
                    if [.discover, .recommend].contains(model.section) && model.catalogMore { Button("加载更多") { model.loadCatalog(more: true) }.disabled(model.busy).padding() }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @ViewBuilder private var filters: some View {
        VStack(alignment: .leading, spacing: Theme.spacingLG) {
            if model.section == .discover {
                CapsuleFilterRow(title: "类型", options: [
                    .init(label: "漫剧", value: "COMIC"),
                    .init(label: "真人剧", value: "REAL"),
                    .init(label: "AI 剧", value: "AI"),
                ], selection: $model.category, layout: .row) { model.topic = ""; model.loadCatalog() }
            }
            if model.section == .rank {
                CapsuleFilterRow(title: "热播榜", options: [
                    .init(label: "综合", value: "ALL"),
                    .init(label: "漫剧", value: "COMIC"),
                    .init(label: "真人剧", value: "REAL"),
                    .init(label: "AI 剧", value: "AI"),
                ], selection: $model.board, layout: .row) { model.topic = ""; model.loadCatalog() }
            }
            if (model.section == .discover || model.section == .rank) && !model.topics.isEmpty {
                CapsuleFilterRow(title: "题材", options: topicOptions, selection: $model.topic) { model.loadCatalog() }
            }
        }
    }

    /// 题材选项（含「全部题材」空选项）；过滤掉 label/id 为空的条目，避免渲染空胶囊。
    /// 返回有序列表：「全部题材」总在首位，其余按 label 字母序（对齐原字典排序）。
    private var topicOptions: [CapsuleFilterRow.Option] {
        var options: [CapsuleFilterRow.Option] = []
        for t in model.topics {
            let label = t.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !t.id.isEmpty else { continue }
            options.append(.init(label: label, value: t.id))
        }
        options.sort { $0.label < $1.label }
        options.insert(.init(label: "全部题材", value: ""), at: 0)
        return options
    }
    private func card(_ series: Series, index: Int) -> some View {
        let cloud = model.section == .account ? model.cloudRows.first(where: { $0.id == series.id }) : nil
        // 组装副标题行，最多两行：第一行「全xx集」（灰，左）+ 历史进度（蓝，右）；第二行榜单名次/热度或待上线文案。
        let progressText: String? = {
            if let cloud, let index = cloud.episodeIndex { return "账号看到第 \(index + 1) 集" }
            if let record = library.history(series.id) { return record.label }
            return nil
        }()
        var lines: [SeriesCard.SubtitleLine] = []
        var firstLine = SeriesCard.SubtitleLine(text: series.badge.isEmpty ? "" : series.badge)
        firstLine.trailingText = progressText
        firstLine.trailingAccent = false
        lines.append(firstLine)
        if model.section == .rank, let rank = model.rankPositions[series.id] {
            lines.append(.init(text: [rank.rank.map { "第 \($0) 名" } ?? "", rank.heat].filter { !$0.isEmpty }.joined(separator: " · "), accent: true))
        } else if let publish = cloud?.publishText {
            lines.append(.init(text: publish))
        }
        // 组装右键菜单项。
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
    private func emptyState<Actions: View>(_ title: String, symbol: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(Color.accentColor)
            Text(title).font(.title2.bold())
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
            actions()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 侧栏条目（自绘 Apple TV 风）：图标 + 标题，选中高亮，点击导航。
    @ViewBuilder
    private func railItem(_ item: NavigationItem, tag: Destination? = nil, iconSize: CGFloat = 16) -> some View {
        let target = tag ?? item.destination
        let selected = model.navigation == target
        Button { model.navigate(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: iconSize))
                    .frame(width: 24, alignment: .center)
                Text(item.title).font(.body).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.railSelected : Color.clear, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

struct EpisodeView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    let detail: Detail

    var body: some View {
        ZStack {
            Color.black
            // 播放器占满，自绘 Apple TV 风控件（非系统浮动控件）。
            ImmersivePlayer(model: model)
                .overlay { DanmakuOverlay(model: model, danmaku: model.danmaku) }
                .overlay { PlayerTapLayer(model: model) }
            // 悬浮覆盖层：右上角全屏入口 + 顶部栏 + 底部栏 + 信息面板（与非全屏一致，由 PlayerOverlays 复用）。
            PlayerOverlays(model: model, library: library, detail: detail, showsTransport: true, corner: .enterFullscreen)
        }
        .animation(.easeInOut(duration: 0.25), value: model.playerControlsVisible)
        .animation(.easeInOut(duration: 0.25), value: model.infoPanelOpen)
        // 仅播放区保持深色（视频画面 + 悬浮控件），不向上影响左侧栏/工具栏/信息栏，
        // 那些 chrome 跟随系统深浅模式。
        .colorScheme(.dark)
    }
}
