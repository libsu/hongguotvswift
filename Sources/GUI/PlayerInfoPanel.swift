// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

/// 底部信息面板：选集网格 + 相关作品（复用 `PosterRow` + `SeriesPosterCard`）
/// 高度由内容决定，限制在 `Theme.infoPanelMinHeight…infoPanelMaxHeight`（见 `PlayerOverlays`）
struct PlayerInfoPanel: View {
    @ObservedObject var model: Model
    let detail: Detail

    private let cellSize = CGSize(width: 45, height: 32)

    var body: some View {
        let episode = model.episode ?? 0
        VStack(alignment: .leading, spacing: 14) {
            header(episode: episode)
            episodeGrid(episode: episode)
            relatedSection
        }
        .padding(Theme.overlayPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .padding(.horizontal, Theme.overlayPadding).padding(.bottom, Theme.spacingXL)
    }

    // MARK: - 布局

    private func header(episode: Int) -> some View {
        HStack(spacing: Theme.spacingLG) {
            Label("选集", systemImage: "list.bullet").font(.headline)
            Text("当前第 \(episode + 1) 集 / 共 \(detail.episodes.count) 集")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Toggle("连播", isOn: $model.autoNext)
                .playerToggle()
                .help("开启后本集播完自动播放下一集")
            Group {
                Button { play(episode - 1) } label: { Label("上一集", systemImage: "backward.end.fill") }
                    .disabled(episode <= 0 || model.busy)
                Button { play(episode + 1) } label: { Label("下一集", systemImage: "forward.end.fill") }
                    .disabled(episode + 1 >= detail.episodes.count || model.busy)
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).font(.body)
            // 分隔：把「关闭」和连续播放操作分开，避免误点退出面板
            Divider().frame(height: 16)
            Button { close() } label: { Label("关闭", systemImage: "xmark") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).font(.body)
        }
    }

    private func episodeGrid(episode: Int) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cellSize.width, maximum: cellSize.width), spacing: Theme.spacingMD)], spacing: Theme.spacingMD) {
                ForEach(detail.episodes.indices, id: \.self) { index in
                    Button { play(index) } label: {
                        Text("\(index + 1)")
                            .font(.subheadline).fontWeight(episode == index ? .semibold : .regular)
                            .frame(width: cellSize.width, height: cellSize.height)
                            .background(episode == index ? Theme.darkSelected : Theme.darkUnselected,
                                        in: RoundedRectangle(cornerRadius: Theme.spacingSM, style: .continuous))
                            .foregroundStyle(episode == index ? Theme.darkSelectedForeground : Theme.darkUnselectedForeground)
                    }.buttonStyle(.plain).disabled(model.busy)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }.frame(maxHeight: 200)
    }

    @ViewBuilder
    private var relatedSection: some View {
        if !model.related.isEmpty {
            Text("相关作品").font(.subheadline).foregroundStyle(.secondary)
            // 与「我的」片单共用同一张海报卡（封面圆角/标题行高/点击区域继承 DesignSystem）
            PosterRow(model.related) { work in
                SeriesPosterCard(cover: work.series.cover, title: work.series.title) {
                    close()
                    work.upcoming ? model.reserve(work) : model.open(work.series)
                }
                .disabled(model.busy || (work.upcoming && model.account?.loggedIn != true))
            }
            // 横向行高度显式封顶为一行卡片，相关作品再多也只横向滚动，面板被压缩时不会把卡片挤矮
            .frame(height: Theme.posterSmallHeight + 44)
        }
    }

    // MARK: - 操作

    private func play(_ index: Int) { model.play(index); close() }
    private func close() { model.infoPanelOpen = false }
}
