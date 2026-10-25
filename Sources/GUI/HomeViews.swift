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
                HStack(spacing: 8) {
                    Button("推荐") { if model.homeCategory != "ALL" { model.homeCategory = "ALL"; model.loadHome() } }
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(model.homeCategory == "ALL" ? Color.accentColor : Color.gray.opacity(0.16), in: Capsule())
                        .foregroundStyle(model.homeCategory == "ALL" ? Color.white : Color.primary)
                    Button("真人剧") { if model.homeCategory != "REAL" { model.homeCategory = "REAL"; model.loadHome() } }
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(model.homeCategory == "REAL" ? Color.accentColor : Color.gray.opacity(0.16), in: Capsule())
                        .foregroundStyle(model.homeCategory == "REAL" ? Color.white : Color.primary)
                    Button("漫剧") { if model.homeCategory != "COMIC" { model.homeCategory = "COMIC"; model.loadHome() } }
                        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 5)
                        .background(model.homeCategory == "COMIC" ? Color.accentColor : Color.gray.opacity(0.16), in: Capsule())
                        .foregroundStyle(model.homeCategory == "COMIC" ? Color.white : Color.primary)
                    Button { model.loadHome() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("换一批").disabled(model.busy)
                }.disabled(model.busy)
                Spacer()
                // 上一部/下一部
                Button { model.moveRecommendation(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).help("上一部")
                Button { model.moveRecommendation(1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless).help("下一部")
            }
            if let detail = model.detail, model.showDetail {
                HStack(alignment: .top, spacing: 24) {
                    NativePlayer(player: model.player, model: model)
                        .overlay { DanmakuOverlay(model: model, danmaku: model.danmaku) }
                        .overlay(alignment: .topTrailing) { PlayerCornerButtons(model: model) }
                        .background(.black).cornerRadius(16)
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
                    Text(model.busy ? "正在准备试播…" : "看看下一部好故事").font(.title2)
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

    private let accountEntrySpecs: [(title: String, icon: String, cloudType: String)] = [
        ("账户收藏", "star.circle", "账户收藏"),
        ("账户历史", "clock.arrow.circlepath", "账户历史"),
        ("已上线预约", "play.rectangle", "已上线预约"),
        ("待上线预约", "calendar", "待上线预约"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 本机收藏：直接平铺卡片，无需进入单独列表页。
                sectionHeader("收藏")
                if library.contents.favorites.isEmpty {
                    Text("暂无收藏").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
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
                        HStack(spacing: 12) {
                            ForEach(library.contents.history) { record in historyCard(record) }
                        }
                    }
                }

                // 2. 红果账号
                sectionHeader("红果账户")
                if model.account?.loggedIn == true {
                    HStack {
                        Label(model.account?.nickname ?? "红果用户", systemImage: "person.crop.circle.fill").font(.headline)
                        Spacer()
                        Button("退出登录") { model.logout() }.disabled(model.busy)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(accountEntrySpecs, id: \.cloudType) { spec in
                            tile(spec.title, icon: spec.icon, subtitle: "查看账号片单") { model.navigate(spec.cloudType) }
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
        Button { model.open(series) } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: series.cover)) { image in image.resizable().scaledToFill() }
                    placeholder: { Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film")) }
                    .frame(width: 110, height: 150).clipped().cornerRadius(10)
                Text(series.title).font(.caption).lineLimit(2).frame(height: 30, alignment: .topLeading)
            }.frame(width: 110, alignment: .leading)
        }.buttonStyle(.plain).padding(4).disabled(model.busy)
    }

    private func historyCard(_ record: WatchRecord) -> some View {
        Button { model.open(record.series) } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: record.series.cover)) { image in image.resizable().scaledToFill() }
                    placeholder: { Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film")) }
                    .frame(width: 110, height: 150).clipped().cornerRadius(10)
                Text(record.series.title).font(.caption).lineLimit(2).frame(height: 30, alignment: .topLeading)
                Text(record.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 110, alignment: .leading)
        }.buttonStyle(.plain).padding(4).disabled(model.busy)
    }

    private func tile(_ title: String, icon: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.bordered).disabled(model.busy)
    }
}
