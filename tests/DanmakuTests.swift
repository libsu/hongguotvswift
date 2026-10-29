// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct DanmakuTests {
    @MainActor static func main() async throws {
        func page(_ series: String, _ episode: String, _ start: Int, _ end: Int) -> TimedCommentPage {
            TimedCommentPage(seriesID: series, episodeID: episode, startMS: start, nextMS: min(start + 30000, end), items: [TimedComment(id: "test", text: "时间轴弹幕", timeMS: start + 1000)])
        }
        let store = DanmakuStore { series, episode, start, end in
            if episode == "slow" { try? await Task.sleep(nanoseconds: 180_000_000) }
            if episode == "error" { throw URLError(.timedOut) }
            return page(series, episode == "wrong" ? "other" : episode, start, end)
        }
        let original = UserDefaults.standard.object(forKey: "danmakuEnabled")
        defer { UserDefaults.standard.set(original, forKey: "danmakuEnabled") }
        store.enabled = true
        func update(_ episode: String, time: Double = 2) { store.update(series: "123456", episode: episode, time: time, duration: 90) }
        func wait() async throws { for _ in 0..<100 { if !store.loading { return }; try await Task.sleep(nanoseconds: 10_000_000) }; fatalError("Timed out") }
        update("234567"); try await wait()
        assert(store.visible(at: 0).isEmpty && store.visible(at: 2).count == 1 && store.visible(at: 9).count == 1 && store.visible(at: 11).isEmpty)
        update("slow"); update("new"); try await wait(); try await Task.sleep(nanoseconds: 250_000_000)
        assert(store.pages[0]?.episodeID == "new")
        update("wrong"); try await wait(); assert(store.error != nil && store.pages.isEmpty)
        update("error"); try await wait(); assert(store.error != nil)
        store.retry(); update("234567", time: 32); try await wait(); assert(store.pages[30000] != nil)
        store.enabled = false; assert(store.pages.isEmpty && store.visible(at: 32).isEmpty)
        store.clear(); assert(!store.loading && store.error == nil)
        testDanmakuClock()
        print("Timed-comment identity, seek windows, stale requests, retry and disable cleanup: PASS")
    }

    /// 弹幕时钟追帧校正纯函数的四种场景：静止、倍速、暂停恢复、拖动进度条。
    @MainActor static func testDanmakuClock() {
        // 静止（rate 0）：media 不变，线性外推也应不变，不触发重锚定。
        let still = DanmakuClock.corrected(media: 10.0, host: 11.0, rate: 0.0, current: (10.0, 10.0, 0.0))
        assert(still == nil, "静止且无漂移不应重锚定")

        // 倍速切换：rate 改变必然触发重锚定。
        let rate = DanmakuClock.corrected(media: 10.0, host: 11.0, rate: 2.0, current: (10.0, 10.0, 1.0))
        assert(rate != nil && rate!.rate == 2.0, "倍速改变应重锚定")

        // 暂停后恢复：恢复瞬间 rate 0 -> 1，触发重锚定。
        let resume = DanmakuClock.corrected(media: 12.0, host: 12.0, rate: 1.0, current: (12.0, 11.5, 0.0))
        assert(resume != nil && resume!.rate == 1.0, "暂停恢复应重锚定")

        // 拖动进度条：media 跳变远超阈值（0.015s），触发重锚定。
        let seek = DanmakuClock.corrected(media: 300.0, host: 310.0, rate: 1.0, current: (30.0, 300.0, 1.0))
        assert(seek != nil && seek!.media == 300.0, "拖动进度条应重锚定")

        // 正常播放小偏差（< 15ms）：不触发，避免每个轮询周期抖动。
        let small = DanmakuClock.corrected(media: 10.010, host: 10.010, rate: 1.0, current: (0.0, 0.0, 1.0))
        assert(small == nil, "小于阈值的漂移不应重锚定")
        print("DanmakuClock correction: still/rate/resume/seek/small PASS")
    }
}
