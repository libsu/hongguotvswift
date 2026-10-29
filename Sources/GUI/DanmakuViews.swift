// SPDX-License-Identifier: GPL-3.0-only
// macOS 弹幕渲染与开关：逐帧 Canvas 绘制 + 追帧对齐 + 控制栏开关
// 仅 macOS 播放界面使用（首页预览、普通窗口、全屏），逻辑层见共享的 Danmaku.swift
import SwiftUI

/// 弹幕时钟：把「追帧对齐」从渲染里抽出，只负责把播放器的 media time 与主时钟对齐，
/// 对外暴露一个可通过 `TimelineView` 每帧读取的 `time`。
/// 追帧校正的纯函数逻辑见 `DanmakuClock.corrected`，可脱离 View 单测。
@MainActor final class DanmakuClock: ObservableObject {
    @Published private(set) var time: Double = 0
    private(set) var anchorMedia = 0.0
    private(set) var anchorHost = CACurrentMediaTime()
    private(set) var anchorRate = 0.0

    /// 漂移阈值（秒）。播放位置与线性外推的偏差超过该值才重新锚定。
    /// 单位是秒，15ms 级别：弹幕单趟行程数秒，150ms 在屏幕上已肉眼可见。
    static let resyncThreshold = 0.015

    /// 用某一时刻的播放器快照校正锚点，返回是否发生重锚定。
    /// 超过阈值（或倍速改变）才更新锚点，避免每个轮询周期都抖动。
    @discardableResult
    func resync(media: Double, host: Double, rate: Double) -> Bool {
        guard media.isFinite else { return false }
        let next = Self.corrected(media: media, host: host, rate: rate,
                                  current: (anchorMedia, anchorHost, anchorRate))
        guard next != nil else { return false }
        anchorMedia = next!.media; anchorHost = next!.host; anchorRate = next!.rate
        return true
    }

    /// 纯函数：给定播放器快照与当前锚点，判断是否需要重锚定。
    /// 返回 `nil` 表示无需校正；返回新锚点表示需要校正并同步 `time`。
    /// - 静止（rate 0）、倍速切换、拖动进度条（current 与线性外推偏差大）都会触发。
    static func corrected(media: Double, host: Double, rate: Double,
                          current: (media: Double, host: Double, rate: Double))
        -> (media: Double, host: Double, rate: Double)? {
        let (curMedia, curHost, curRate) = current
        let extrapolated = curMedia + (host - curHost) * curRate
        if rate != curRate || abs(media - extrapolated) > resyncThreshold {
            return (media, host, rate)
        }
        return nil
    }

    /// 当前时间轴位置（秒），由 `TimelineView` 每帧读取。
    var now: Double {
        anchorMedia + (CACurrentMediaTime() - anchorHost) * anchorRate
    }
}

struct DanmakuOverlay: View {
    @ObservedObject var model: Model
    @ObservedObject var danmaku: DanmakuStore
    @StateObject private var clock = DanmakuClock()
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !danmaku.enabled || model.pipActive)) { _ in
            let time = clock.now
            let rows = danmaku.visible(at: time)
            Canvas { context, size in
                for row in rows {
                    let text = Text(row.item.text).font(.system(size: Theme.danmakuFontSize, weight: .bold))
                    let white = context.resolve(text.foregroundColor(.white))
                    let black = context.resolve(text.foregroundColor(.black))
                    let width = white.measure(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)).width
                    let fraction = min(1, max(0, (time * 1000 - Double(row.item.timeMS)) / Double(DanmakuStore.travelMS)))
                    let origin = CGPoint(x: size.width - (size.width + width) * fraction,
                                         y: Theme.danmakuTopOffset + Double(row.lane) * Theme.danmakuLaneHeight)
                    // A solid outline remains sharp over bright video without a blur filter.
                    for dx in [-Theme.danmakuOutlineOffset, 0, Theme.danmakuOutlineOffset] {
                        for dy in [-Theme.danmakuOutlineOffset, 0, Theme.danmakuOutlineOffset] where dx != 0 || dy != 0 {
                            context.draw(black, at: CGPoint(x: origin.x + dx, y: origin.y + dy), anchor: .topLeading)
                        }
                    }
                    context.draw(white, at: origin, anchor: .topLeading)
                }
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
            // 追帧对齐（250ms 一次），只负责校正锚点；网络预取独立于动画。
            .task(id: model.commentKey) {
                while !Task.isCancelled {
                    let position = model.player.currentTime().seconds
                    let host = CACurrentMediaTime(), rate = Double(model.player.rate)
                    clock.resync(media: position, host: host, rate: rate)
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                }
            }
            // 网络预取：与动画/时钟解耦，4 次/秒即可。
            .task(id: model.commentKey) {
                while !Task.isCancelled {
                    let position = model.player.currentTime().seconds
                    if !model.busy, let detail = model.detail, let index = model.episode, detail.episodes.indices.contains(index) {
                        danmaku.update(series: detail.series.id, episode: detail.episodes[index], time: position, duration: model.player.currentItem?.duration.seconds ?? 0)
                    }
                    do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
                }
            }
    }
}
