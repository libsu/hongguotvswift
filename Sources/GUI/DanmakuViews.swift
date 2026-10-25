// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct DanmakuOverlay: View {
    @ObservedObject var model: Model
    @ObservedObject var danmaku: MacDanmaku
    @State private var anchorMedia = 0.0
    @State private var anchorHost = CACurrentMediaTime()
    @State private var anchorRate = 0.0
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !danmaku.enabled)) { _ in
            let time = anchorMedia + (CACurrentMediaTime() - anchorHost) * anchorRate
            let rows = danmaku.visible(at: time)
            Canvas { context, size in
                for row in rows {
                    let text = Text(row.item.text).font(.system(size: 22, weight: .bold))
                    let white = context.resolve(text.foregroundColor(.white))
                    let black = context.resolve(text.foregroundColor(.black))
                    let width = white.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
                    let fraction = min(1, max(0, (time * 1000 - Double(row.item.timeMS)) / Double(MacDanmaku.travelMS)))
                    let origin = CGPoint(x: size.width - (size.width + width) * fraction,
                                         y: 62 + Double(row.lane) * 36)
                    // A solid outline remains sharp over bright video without a blur filter.
                    for dx in [-1.25, 0, 1.25] {
                        for dy in [-1.25, 0, 1.25] where dx != 0 || dy != 0 {
                            context.draw(black, at: CGPoint(x: origin.x + dx, y: origin.y + dy), anchor: .topLeading)
                        }
                    }
                    context.draw(white, at: origin, anchor: .topLeading)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
            .task(id: model.commentKey) {
                // Network prefetch is independent of animation. It needs only four checks per second.
                while !Task.isCancelled {
                    let position = model.player.currentTime().seconds
                    let host = CACurrentMediaTime(), rate = Double(model.player.rate)
                    if position.isFinite && (rate != anchorRate || abs(position - (anchorMedia + (host - anchorHost) * anchorRate)) > 0.15) {
                        anchorMedia = position; anchorHost = host; anchorRate = rate
                    }
                    if !model.busy, let detail = model.detail, let index = model.episode, detail.episodes.indices.contains(index) {
                        danmaku.update(series: detail.series.id, episode: detail.episodes[index], time: position, duration: model.player.currentItem?.duration.seconds ?? 0)
                    }
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                }
            }
    }
}

struct DanmakuControl: View {
    @ObservedObject var danmaku: MacDanmaku
    var body: some View {
        HStack(spacing: 8) {
            Toggle("弹幕", isOn: $danmaku.enabled).toggleStyle(.switch).controlSize(.small)
            // 重试按钮隐藏：失败时自动退避重试，避免在控制栏占用空间。
        }.help("按视频时间同步的真实弹幕；暂停、拖动和倍速同步")
    }
}
