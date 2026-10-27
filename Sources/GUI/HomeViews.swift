// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

struct HomeFeedView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 16) {
                // 推荐频道选择 + 换一批（合并到左上）。
                HStack(alignment: .center, spacing: Theme.spacingMD) {
                    CapsuleFilterRow(title: nil, options: [
                        .init(label: "推荐", value: "ALL"),
                        .init(label: "真人剧", value: "REAL"),
                        .init(label: "漫剧", value: "COMIC"),
                    ], selection: $model.homeCategory, layout: .row) { model.loadHome() }
                    Button { model.loadHome() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("换一批").disabled(model.busy)
                }.disabled(model.busy)
                Spacer()
                // 上一部/下一部
                Button { model.moveRecommendation(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("上一部")
                Button { model.moveRecommendation(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("下一部")
            }
            if let detail = model.detail, model.showDetail {
                HStack(alignment: .top, spacing: 24) {
                    NativePlayer(player: model.player)
                        .overlay { DanmakuOverlay(model: model, danmaku: model.danmaku) }
                        .overlay(alignment: .topTrailing) { PlayerCornerButtons(model: model) }
                        .background(.black).cornerRadius(Theme.cornerLarge)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(detail.series.title).font(.title2.bold()).textSelection(.enabled)
                            HStack(spacing: 10) {
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
                VStack(spacing: 18) {
                    Image(systemName: "play.rectangle").font(.system(size: 52)).foregroundStyle(Color.accentColor)
                    Text(model.loadingList ? "正在准备试播…" : "看看下一部好故事").font(.title2)
                    Button("开始刷剧") { model.startHomeTrial() }.disabled(model.busy)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(24)
    }
}

/// 首页内联的整剧剧评列表（只读、可滚动、占满剩余高度）。
struct InlineReviewsView: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.comments.loading {
                ProgressView("正在读取评论…").frame(maxWidth: .infinity)
            } else if let error = model.comments.error {
                VStack(spacing: 10) { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { model.loadComments(force: true) } }
                    .frame(maxWidth: .infinity)
            } else if let reviews = model.comments.result?.reviews.items, !reviews.isEmpty {
                ForEach(reviews) { comment in
                    VStack(alignment: .leading, spacing: 8) {
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
                Text("暂无整剧剧评").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .task(id: model.commentKey) { model.loadComments() }
    }
}

struct MyAccountView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    @ObservedObject var updates: MacUpdates

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 本机收藏：直接平铺卡片，无需进入单独列表页。
                sectionHeader("收藏")
                if library.contents.favorites.isEmpty {
                    Text("暂无收藏").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(library.contents.favorites) { series in seriesCard(series) }
                        }
                    }
                }

                // 本机历史：直接平铺卡片。
                sectionHeader("历史")
                if library.contents.history.isEmpty {
                    Text("暂无观看记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(library.contents.history) { record in historyCard(record) }
                        }
                    }
                }

                // 2. 账户：标题、用户名、退出登录均靠左（start），登录后四类账号片单直接平铺。
                HStack(spacing: 12) {
                    sectionHeader("账户")
                    if model.account?.loggedIn == true {
                        Text(model.account?.nickname ?? "红果用户").font(.headline).foregroundStyle(.secondary).lineLimit(1)
                        Button("登出") { model.logout() }.disabled(model.accountBusy)
                    }
                    Spacer(minLength: 0)
                }
                if model.account?.loggedIn == true {
                    if model.cloudAllLoading && model.cloudAllError == nil && model.cloudFavorites.isEmpty && model.cloudHistory.isEmpty && model.cloudOnline.isEmpty && model.cloudUpcoming.isEmpty {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在读取账号片单…").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        accountSection("账户收藏", entries: model.cloudFavorites, style: .favorite, empty: "账号暂无收藏")
                        accountSection("账户历史", entries: model.cloudHistory, style: .history, empty: "账号暂无观看记录")
                        accountSection("已上线预约", entries: model.cloudOnline, style: .reservation, empty: "暂无已上线预约")
                        accountSection("待上线预约", entries: model.cloudUpcoming, style: .reservation, empty: "暂无待上线预约")
                        if let error = model.cloudAllError {
                            HStack(spacing: 8) {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("重试") { model.loadAllCloud() }.disabled(model.cloudAllLoading)
                            }
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 24) {
                        AccountPanel(model: model)
                        Spacer()
                    }
                }

                // 3. 设置
                sectionHeader("设置")
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("连播", isOn: $model.autoNext)
                    Toggle("首页直接播放", isOn: $model.homeAutoPlay)
                        .help("开启后进入首页加载完成即自动播放，不再等待「开始刷剧」确认。")
                    Toggle("自动清晰度", isOn: Binding(get: { model.quality == 0 }, set: { auto in model.setQualityPreference(auto ? 0 : 1080) }))
                        .help("开启后自动选择源提供的最高可用清晰度。")
                    Toggle("自动检查更新", isOn: $updates.autoCheck)
                        .help("开启后启动时自动检查更新。")
                    // 「检查更新」手动按钮入口已停用：更新独立发布，界面不再暴露手动检查入口。
                    // MacUpdates.check/download 逻辑保留，供自动检查与未来重新开放使用。
                    // Button("检查 Mac 更新") { updates.check() }.disabled(updates.busy)
                    Text(updates.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if updates.available != nil { Button("下载并校验更新包") { updates.download() }.disabled(updates.busy) }
                    if updates.busy { ProgressView().controlSize(.small) }
                }

                Text("HongGuo · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "测试版")")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.title2.bold())
    }

    private func seriesCard(_ series: Series) -> some View {
        SeriesPosterCard(cover: series.cover, title: series.title) { model.open(series) }
    }

    private func historyCard(_ record: WatchRecord) -> some View {
        SeriesPosterCard(cover: record.series.cover, title: record.series.title, subtitle: record.label) {
            model.open(record.series)
        }
    }

    // MARK: - 账户四类片单

    private enum AccountSectionStyle { case favorite, history, reservation }

    @ViewBuilder
    private func accountSection(_ title: String, entries: [CloudEntry], style: AccountSectionStyle, empty: String) -> some View {
        Text(title).font(.title3.bold())
        if entries.isEmpty {
            Text(empty).font(.caption).foregroundStyle(.secondary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(entries) { entry in cloudCard(entry, style: style) }
                }
            }
        }
    }

    private func cloudCard(_ entry: CloudEntry, style: AccountSectionStyle) -> some View {
        SeriesPosterCard(cover: entry.series.cover, title: entry.series.title, subtitle: cloudSubtitle(entry, style: style)) {
            if style == .reservation && entry.online == false { model.message = "该剧待上线，暂时无法播放" }
            else if style == .history { model.open(entry.series, resumeEpisodeID: entry.episodeID, resumePosition: entry.position) }
            else { model.open(entry.series) }
        }
    }

    private func cloudSubtitle(_ entry: CloudEntry, style: AccountSectionStyle) -> String? {
        switch style {
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
}
