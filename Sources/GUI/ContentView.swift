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
        case "收藏": return library.contents.favorites
        case "历史": return library.contents.history.map(\.series)
        case "找剧", "榜单", "推荐": return model.catalogRows
        case "账户": return model.cloudRows.map(\.series)
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
                railItem(NavigationItem(title: model.accountRailTitle, icon: model.accountRailIcon), tag: "我的", iconSize: 20)
                    .padding(.bottom, 8)
            }
            .padding(.horizontal, 8)
            .navigationTitle("红果")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 230)
        } detail: {
            VStack(spacing: 0) {
                if model.section == "首页" && (model.preview || !model.showDetail) {
                    HomeFeedView(model: model, library: library)
                } else if model.showDetail, let detail = model.detail {
                    EpisodeView(model: model, library: library, detail: detail)
                } else if model.section == "我的" {
                    MyAccountView(model: model, library: library, updates: updates)
                } else { libraryView }
                Divider()
                HStack(spacing: 10) {
                    if model.busy || model.cloudLoading { ProgressView().controlSize(.small) }
                    Text(library.error ?? model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    if let account = model.account { Label(account.nickname ?? "已登录", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 20)
                    .frame(height: 44, alignment: .center)
            }.navigationTitle(model.showDetail ? (model.detail?.series.title ?? "播放") : model.navigation)
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
            if !Task.isCancelled && model.navigation == "搜索" && model.rows.isEmpty { model.navigate("首页") }
        }.frame(minWidth: 1000, minHeight: 720)
    }
    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    // 顶栏 navigationTitle 已统一显示当前栏目名，内容区不再重复大字标题，只留条数/说明副标题。
                    Text(model.section == "账户" ? "红果账号片单 · 本机记录独立保留" : "\(items.count) 部剧").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.section == "账户", model.account != nil {
                    Button { model.loadCloud() } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.cloudLoading)
                }
                if model.section == "推荐" { Button("换一批") { model.loadCatalog(refresh: true) }.disabled(model.busy) }
            }
            filters
            if model.section == "账户", model.account == nil {
                emptyState("登录后查看账户片单", symbol: "person.crop.circle", detail: "账户历史、收藏与预约会随登录账号切换。") {
                    Button("扫码登录") { model.navigate("我的") }
                }
            } else if model.section == "账户", model.cloudLoading {
                VStack(spacing: 16) { ProgressView(); Text("正在读取\(model.cloudType)…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.section == "账户", let error = model.cloudError {
                emptyState("账户片单读取失败", symbol: "exclamationmark.arrow.triangle.2.circlepath", detail: error) {
                    Button("重新读取") { model.loadCloud() }
                }
            } else if items.isEmpty {
                emptyState(emptyTitle, symbol: model.section == "搜索" ? "magnifyingglass" : "rectangle.stack", detail: model.section == "搜索" ? "在窗口右上角输入剧名，按回车搜索。" : "可刷新账号片单，或浏览找剧与排行榜。") { EmptyView() }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 20)], alignment: .leading, spacing: 24) {
                        ForEach(items) { series in card(series) }
                    }.padding(.top, 4)
                    if model.section == "搜索" && model.hasMore { Button("加载更多") { model.search(more: true) }.disabled(model.busy).padding() }
                    if ["找剧", "推荐"].contains(model.section) && model.catalogMore { Button("加载更多") { model.loadCatalog(more: true) }.disabled(model.busy).padding() }
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var emptyTitle: String {
        switch model.section {
        case "账户": return model.cloudLoadedKey == nil ? "准备读取账户片单" : "账号暂无此类记录"
        case "收藏": return "还没有本机收藏"
        case "历史": return "还没有本机观看记录"
        case "搜索": return model.query.isEmpty ? "找一部想看的剧" : "暂无搜索结果"
        default: return model.busy ? "正在加载…" : "暂无内容"
        }
    }
    @ViewBuilder private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.section == "找剧" {
                FilterRow(title: "类型", options: ["漫剧": "COMIC", "真人剧": "REAL", "AI 剧": "AI"], selection: $model.category) { model.topic = ""; model.loadCatalog() }
            }
            if model.section == "榜单" {
                FilterRow(title: "热播榜", options: ["综合": "ALL", "漫剧": "COMIC", "真人剧": "REAL", "AI 剧": "AI"], selection: $model.board) { model.topic = ""; model.loadCatalog() }
            }
            if (model.section == "找剧" || model.section == "榜单") && !model.topics.isEmpty {
                FilterRow(title: "题材", options: topicOptions, selection: $model.topic) { model.loadCatalog() }
            }
        }
    }

    /// 题材选项（含「全部题材」空选项）；过滤掉 label/id 为空的条目，避免渲染空胶囊。
    private var topicOptions: [String: String] {
        var map: [String: String] = ["全部题材": ""]
        for t in model.topics {
            let label = t.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !t.id.isEmpty else { continue }
            map[label] = t.id
        }
        return map
    }

    /// 平铺点选筛选（点一次即选中，替代原 Picker 的两步点击）。
    /// 标题在上，胶囊流式换行在下（占据整行宽度）。胶囊内文本不换行，整组可占用多行。
    private struct FilterRow: View {
        let title: String
        let options: [String: String]
        @Binding var selection: String
        let onChange: () -> Void
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72, maximum: 200), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(orderedKeys, id: \.self) { label in
                        let value = options[label] ?? ""
                        let selected = selection == value
                        Button {
                            guard !selected else { return }
                            selection = value
                            onChange()
                        } label: {
                            Text(label)
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(selected ? Color.accentColor : Color.gray.opacity(0.16), in: Capsule())
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }

        /// 排序后的键：value 为空（「全部题材」）总在首位，其余按 label 排序。
        private var orderedKeys: [String] {
            options.keys.sorted { a, b in
                let av = options[a] ?? "", bv = options[b] ?? ""
                if av.isEmpty != bv.isEmpty { return av.isEmpty }
                return a < b
            }
        }
    }
    private func card(_ series: Series) -> some View {
        let cloud = model.section == "账户" ? model.cloudRows.first(where: { $0.id == series.id }) : nil
        return Button {
            if cloud?.online == false { model.message = "该剧待上线，暂时无法播放" }
            else { model.open(series, trial: model.section == "推荐") }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: URL(string: series.cover)) { image in image.resizable().scaledToFill() }
                    placeholder: { Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film").foregroundStyle(.secondary)) }
                    .frame(height: 225).frame(maxWidth: .infinity).clipped().cornerRadius(10)
                Text(series.title).font(.headline).lineLimit(2).frame(height: 40, alignment: .topLeading)
                Text(series.badge).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let cloud, let index = cloud.episodeIndex { Text("账号看到第 \(index + 1) 集").font(.caption).foregroundStyle(Color.accentColor) }
                else if let record = library.history(series.id) { Text(record.label).font(.caption).foregroundStyle(Color.accentColor) }
                if let publish = cloud?.publishText { Text(publish).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if model.section == "榜单", let rank = model.rankPositions[series.id] {
                    Text([rank.rank.map { "第 \($0) 名" } ?? "", rank.heat].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy).accessibilityLabel(series.title)
            .contextMenu {
                Button(library.favorite(series.id) ? "取消本机收藏" : "加入本机收藏") { library.toggleFavorite(series) }
                if model.account?.loggedIn == true {
                    Button("加入账户收藏") { model.cloudFavorite(series, add: true) }
                    if model.section == "账户" && model.cloudType == "账户收藏" { Button("取消账户收藏") { model.cloudFavorite(series, add: false) } }
                }
                if model.section == "历史" { Button("删除本机观看记录") { library.removeHistory(series.id) } }
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
    private func railItem(_ item: NavigationItem, tag: String? = nil, iconSize: CGFloat = 16) -> some View {
        let target = tag ?? item.title
        let selected = model.navigation == target
        Button { model.navigate(target) } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon).font(.system(size: iconSize))
                    .frame(width: 24, alignment: .center)
                Text(item.title).font(.body)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            // 右上角全屏入口——与上下控件一起随 playerControlsVisible 自动隐藏。
            if model.playerControlsVisible {
                VStack {
                    HStack {
                        Spacer()
                        Button { model.fullscreenPlayback.show() } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.5), in: Circle())
                        }.help("全屏").buttonStyle(.plain).padding(12)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
            // 顶部渐变栏（自动隐藏）
            if model.playerControlsVisible {
                VStack { PlayerTopBar(model: model); Spacer() }
                    .transition(.opacity)
            }
            // 底部渐变栏（自动隐藏）
            if model.playerControlsVisible {
                VStack { Spacer(); PlayerBottomBar(model: model, library: library, detail: detail) }
                    .transition(.opacity)
            }
            // 底部信息面板（选集/简介/相关作品）
            if model.infoPanelOpen {
                VStack { Spacer(); PlayerInfoPanel(model: model, library: library, detail: detail) }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.playerControlsVisible)
        .animation(.easeInOut(duration: 0.25), value: model.infoPanelOpen)
        // 仅播放区保持深色（视频画面 + 悬浮控件），不向上影响左侧栏/工具栏/信息栏，
        // 那些 chrome 跟随系统深浅模式。
        .colorScheme(.dark)
    }
}
