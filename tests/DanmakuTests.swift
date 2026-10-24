// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct DanmakuTests {
    @MainActor static func main() async throws {
        func page(_ series: String, _ episode: String, _ start: Int, _ end: Int) -> TimedCommentPage {
            TimedCommentPage(seriesID: series, episodeID: episode, startMS: start, nextMS: min(start + 30000, end), items: [TimedComment(id: "test", text: "时间轴弹幕", timeMS: start + 1000)])
        }
        let store = MacDanmaku { series, episode, start, end in
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
        print("Timed-comment identity, seek windows, stale requests, retry and disable cleanup: PASS")
    }
}
