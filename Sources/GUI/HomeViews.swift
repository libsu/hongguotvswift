// SPDX-License-Identifier: GPL-3.0-only
// 首页：试播画面 + 剧集信息 + 内联剧评（「我的」页见 MineView.swift）
import SwiftUI

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
