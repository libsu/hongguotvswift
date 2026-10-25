// SPDX-License-Identifier: GPL-3.0-only
// tvOS 根视图：最小可运行骨架。
// 阶段 A 只打通「逻辑层可复用 + 无片源状态展示」；完整首页/搜索/榜单的
// 遥控器焦点导航在后续阶段实现。
import SwiftUI
import AVKit

struct TVRootView: View {
    @ObservedObject var model: Model

    var body: some View {
        if model.showDetail {
            TVPlayerView(model: model)
        } else {
            TVHomeView(model: model)
        }
    }
}

/// 首页骨架：启动状态 + 搜索 + 结果列表。
struct TVHomeView: View {
    @ObservedObject var model: Model

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("红果").font(.largeTitle.bold())

                if model.busy {
                    ProgressView("正在启动…")
                } else {
                    Text(model.message).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    TextField("搜索剧名", text: $model.query)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 480)
                    Button("搜索") { model.search() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.rows) { series in
                            TVSeriesRow(series: series, model: model)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                }

                Spacer()
            }
            .padding(32)
        }
    }
}

/// 单条剧集行（只读；点选进入播放器骨架）。
struct TVSeriesRow: View {
    let series: Series
    @ObservedObject var model: Model

    var body: some View {
        HStack(spacing: 16) {
            AsyncImage(url: URL(string: series.cover)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "film"))
            }
            .frame(width: 96, height: 54).clipped().cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(series.title).font(.headline).lineLimit(1)
                Text(series.badge).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { model.open(series) }
    }
}
