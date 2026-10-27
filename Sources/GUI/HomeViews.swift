// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

struct HomeFeedView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    var body: some View {
        VStack(spacing: Theme.sectionGap) {
            HStack(spacing: Theme.spacingXL) {
                // 推荐频道选择 + 换一批（合并到左上）
                HStack(alignment: .center, spacing: Theme.spacingMD) {
                    CapsuleFilterRow(title: nil, options: [
                        .init(label: "推荐", value: "ALL"),
                        .init(label: "真人剧", value: "REAL"),
                        .init(label: "漫剧", value: "COMIC"),
                    ], selection: $model.homeCategory, layout: .fixed) { model.loadHome() }
                    Button { model.loadHome() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("换一批").disabled(model.busy)
                }.disabled(model.busy)
                Spacer()
                // 上一部/下一部
                Button { model.moveRecommendation(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("上一部")
                Button { model.moveRecommendation(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("下一部")
            }
            if let detail = model.detail, model.showDetail {
                HStack(alignment: .top, spacing: Theme.spacingHuge) {
                    PlayerSurfacePreview(player: model.player)
                        .overlay { DanmakuOverlay(model: model, danmaku: model.danmaku) }
                        .overlay(alignment: .topTrailing) {
                            PlayerCornerButton(model: model, corner: .enterFullscreen, style: .plain)
                                .buttonStyle(.borderless).padding(10)
                        }
                        .background(.black).cornerRadius(Theme.cornerLarge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.spacingXL) {
                            Text(detail.series.title).font(.title2.bold()).textSelection(.enabled)
                            HStack(spacing: Theme.spacingMD) {
                                Text(detail.series.badge).foregroundStyle(.secondary)
                                Button { model.toggleFavorite(detail.series) } label: {
                                    Image(systemName: model.favoriteActive(detail.series) ? "star.fill" : "star")
                                        .foregroundStyle(model.favoriteActive(detail.series) ? Color.accentColor : .secondary)
                                }.buttonStyle(.plain).help(model.favoriteActive(detail.series) ? "取消收藏" : "收藏")
                            }
                            if !detail.series.description.isEmpty {
                                Text(detail.series.description).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                            }
                            Button { model.watchFull() } label: {
                                Text("观看全集").font(.body.weight(.semibold))
                                    .frame(maxWidth: .infinity).frame(height: 48)
                            }.buttonStyle(.borderedProminent).disabled(model.busy)
                            Text("评论").font(.headline)
                            Divider()
                            InlineReviewsView(model: model)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(width: 300)
                }
            } else {
                EmptyStateView(title: model.loadingList ? "正在准备试播…" : "看看下一部好故事", symbol: "play.rectangle") {
                    Button("开始刷剧") { model.startHomeTrial() }.disabled(model.busy)
                }
            }
        }.padding(Theme.pagePadding)
    }
}

/// 首页内联的整剧剧评列表（只读、可滚动、占满剩余高度）
struct InlineReviewsView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.comments.loading {
                ProgressView("正在读取评论…").frame(maxWidth: .infinity)
            } else if let error = model.comments.error {
                InlineHint(text: error, retry: { model.loadComments(force: true) })
                    .frame(maxWidth: .infinity)
            } else if let reviews = model.comments.result?.reviews.items, !reviews.isEmpty {
                ForEach(reviews) { comment in
                    VStack(alignment: .leading, spacing: Theme.spacingMD) {
                        HStack {
                            Text(comment.author.isEmpty ? "红果用户" : comment.author).font(.subheadline).lineLimit(1)
                            Spacer()
                            Label("\(comment.likes)", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(comment.content).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let date = comment.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        Divider()
                    }
                }
            } else {
                EmptyStateView(title: "暂无整剧剧评", symbol: "text.bubble", size: .compact)
            }
        }
        .task(id: model.commentKey) { model.loadComments() }
    }
}

struct MyAccountView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingSection) {
                // 本机收藏与历史直接平铺卡片，无需进入单独列表页
                PosterSection("收藏", items: library.contents.favorites, emptyHint: "暂无收藏") { series in
                    SeriesPosterCard(cover: series.cover, title: series.title) { model.open(series) }
                }

                PosterSection("历史", items: library.contents.history, emptyHint: "暂无观看记录") { record in
                    SeriesPosterCard(cover: record.series.cover, title: record.series.title, subtitle: record.label) {
                        model.open(record.series)
                    }
                }

                // 2. 账户：标题、用户名、退出登录均靠左（start），登录后四类账号片单直接平铺
                HStack(spacing: Theme.spacingLG) {
                    SectionTitle("账户")
                    if model.account?.loggedIn == true {
                        Text(model.account?.nickname ?? "红果用户").font(.headline).foregroundStyle(.secondary).lineLimit(1)
                        Button("登出") { model.logout() }.disabled(model.accountBusy)
                    }
                    Spacer(minLength: 0)
                }
                if model.account?.loggedIn == true {
                    if model.cloudAllLoading && model.cloudAllError == nil && model.cloudFavorites.isEmpty && model.cloudHistory.isEmpty && model.cloudOnline.isEmpty && model.cloudUpcoming.isEmpty {
                        InlineHint(text: "正在读取账号片单…", isLoading: true)
                    } else {
                        cloudSection("账户收藏", entries: model.cloudFavorites, style: .favorite, empty: "账号暂无收藏")
                        cloudSection("账户历史", entries: model.cloudHistory, style: .history, empty: "账号暂无观看记录")
                        cloudSection("已上线预约", entries: model.cloudOnline, style: .reservation, empty: "暂无已上线预约")
                        cloudSection("待上线预约", entries: model.cloudUpcoming, style: .reservation, empty: "暂无待上线预约")
                        if let error = model.cloudAllError {
                            InlineHint(text: error, retry: { model.loadAllCloud() }, disabled: model.cloudAllLoading)
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: Theme.spacingHuge) {
                        AccountPanel(model: model)
                        Spacer()
                    }
                }

                // 3. 设置
                SectionTitle("设置")
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    Toggle("连播", isOn: $model.autoNext)
                        .settingsToggle()
                    Toggle("首页直接播放", isOn: $model.homeAutoPlay)
                        .settingsToggle()
                        .help("开启后进入首页加载完成即自动播放")
                    Toggle("自动清晰度", isOn: Binding(get: { model.quality == 0 }, set: { auto in model.setQualityPreference(auto ? 0 : 1080) }))
                        .settingsToggle()
                        .help("开启后自动选择源提供的最高可用清晰度 ")
                    Toggle("自动检查更新", isOn: Binding(get: { model.updates.autoCheck }, set: { model.updates.autoCheck = $0 }))
                        .settingsToggle()
                        .help("开启后启动时自动检查更新 ")
                    // 发现新版本时只提示并跳转发布页：本 App 不下载、不自替换（发布包未签名/公证，自更新不可靠）
                    if let update = model.updates.available {
                        HStack(spacing: Theme.spacingMD) {
                            Text("发现新版本 \(update.version)").font(.caption).foregroundStyle(.secondary)
                            Button("前往发布页下载") {
                                NSWorkspace.shared.open(MacUpdates.releasePageURL)
                            }
                        }
                    } else if model.updates.busy {
                        ProgressView().controlSize(.small)
                    }
                }

                Text("HongGuo · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "测试版")")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(Theme.spacingSection).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 账户四类片单

    /// 账户片单的类别：决定副标题文案与点击行为（收藏直接播放、历史续播、预约区分上线状态）
    private enum AccountSectionStyle {
        case favorite, history, reservation

        func subtitle(_ entry: CloudEntry) -> String? {
            switch self {
            case .favorite:
                return nil
            case .history:
                let ep = (entry.episodeIndex ?? 0) + 1
                let pos = max(0, Int(entry.position ?? 0))
                return "第 \(ep) 集 · \(String(format: "%02d:%02d", pos / 60, pos % 60))"
            case .reservation:
                return entry.online == false ? "待上线" : ((entry.publishText ?? "").isEmpty ? "已上线" : entry.publishText)
            }
        }

        @MainActor
        func open(_ entry: CloudEntry, in model: Model) {
            switch self {
            case .favorite:
                model.open(entry.series)
            case .history:
                model.open(entry.series, resumeEpisodeID: entry.episodeID, resumePosition: entry.position)
            case .reservation where entry.online == false:
                model.message = "该剧待上线，暂时无法播放"
            case .reservation:
                model.open(entry.series)
            }
        }
    }

    /// 带小标题的账户片单：文案与点击行为都由 `style` 自己决定
    private func cloudSection(_ title: String, entries: [CloudEntry], style: AccountSectionStyle, empty: String) -> some View {
        PosterSection(title, items: entries, level: .subsection, emptyHint: empty) { entry in
            SeriesPosterCard(cover: entry.series.cover, title: entry.series.title, subtitle: style.subtitle(entry)) {
                style.open(entry, in: model)
            }
        }
    }
}
