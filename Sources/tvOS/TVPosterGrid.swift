// SPDX-License-Identifier: GPL-3.0-only
// tvOS 通用海报网格：单行横向滚动，卡片占满可用高度，Siri Remote 左右移动焦点
// 首页/找剧/榜单/我的/搜索共用，聚焦视觉统一
import SwiftUI

/// 单行海报栏：横向滚动，卡片占满可用高度（cardHeight 由外部分配），Siri Remote 左右移动焦点
struct TVPosterGrid: View {
    let items: [Series]
    let section: Section
    @ObservedObject var model: Model
    @FocusState.Binding var focusedSeries: String?
    let hasMore: Bool
    let loadMore: () -> Void
    let onSelect: (Series) -> Void
    var cardHeight: CGFloat

    var body: some View {
        // 聚焦放大系数 = TVFX.focusScale，非聚焦封面先按该系数缩小，聚焦放大后占满
        let scaleFactor = TVFX.focusScale
        // 文字区统一 3 行（标题2行 + 集数1行 + 其他1行，约 120pt）+ 聚焦放大冗余，封面高度相应降低，避免放大超出卡片区
        let coverHeight = max(160, (cardHeight - 140) / scaleFactor)
        // 封面宽度按竖版海报 2:3 宽高比自适应
        let coverWidth = coverHeight * 2 / 3
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(items) { series in
                    TVPosterCard(
                        series: series,
                        rank: section == .rank ? model.rankPositions[series.id] : nil,
                        focused: focusedSeries == series.id,
                        coverWidth: coverWidth,
                        coverHeight: coverHeight
                    ) {
                        onSelect(series)
                    }
                    .focused($focusedSeries, equals: series.id)
                }
                if hasMore {
                    Color.clear.frame(width: 1).onAppear { loadMore() }
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, 32)
            .padding(.bottom, 32)
            .frame(height: cardHeight)
        }
    }
}

/// 单张海报卡片：封面 + 标题 + 徽标，可选排名/热度角标宽度按竖版海报宽高比自适应
struct TVPosterCard: View {
    let series: Series
    let rank: RankBadge?
    let focused: Bool
    var coverWidth: CGFloat = 180
    var coverHeight: CGFloat = 240
    let action: () -> Void

    var body: some View {
        let cardFill: Color = focused ? TVFX.focusedFill : Color.clear
        let cardStroke: Color = focused ? Color.accentColor : Color.clear
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TVCoverImage(url: series.cover, width: coverWidth, height: coverHeight, cornerRadius: 12)

                Text(series.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(width: coverWidth, alignment: .leading)
                    .frame(minHeight: 38, alignment: .topLeading)
                    .foregroundStyle(.white)
                Text(series.badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .topLeading)
                Text(rank.map { rankText($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .frame(height: 18, alignment: .topLeading)
            }
            .frame(width: coverWidth, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16).fill(cardFill))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(cardStroke, lineWidth: TVFX.focusStrokeWidth))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.borderless)
        .scaleEffect(focused ? TVFX.focusScale : 1.0)
        .shadow(color: TVFX.focusShadowColor, radius: focused ? TVFX.focusShadowRadius : 0)
        .animation(.easeInOut(duration: 0.18), value: focused)
        .accessibilityLabel(series.title)
    }

    private func rankText(_ rank: RankBadge) -> String {
        let pos = rank.rank.map { "第 \($0) 名" } ?? ""
        let heat = rank.heat
        return [pos, heat].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
