// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct CommentThreadTests {
    @MainActor static func main() async throws {
        func row(_ id: String) -> PublicComment { PublicComment(id: id, author: "作者", avatar: "", content: "普通评论", created: 1700000000, likes: 1, rating: 0) }
        var calls: [(String, String)] = [], failNext = false, failFirst = false
        let store = MacCommentThread { series, episode, cursor in
            calls.append((episode, cursor))
            if cursor.isEmpty, failFirst { failFirst = false; throw URLError(.timedOut) }
            if episode == "slow" { try? await Task.sleep(nanoseconds: 180_000_000) }
            if cursor == "next", failNext { failNext = false; throw URLError(.timedOut) }
            if episode == "wrong" { return AppCommentPage(seriesID: series, episodeID: "other", total: 100, items: [], nextCursor: "", hasMore: false) }
            if episode == "loop" { return AppCommentPage(seriesID: series, episodeID: episode, total: 100, items: [row("1")], nextCursor: "next", hasMore: true) }
            return AppCommentPage(seriesID: series, episodeID: episode, total: 100, items: cursor.isEmpty ? [row("1"), row("2")] : [row("2"), row("3")], nextCursor: cursor.isEmpty ? "next" : "", hasMore: cursor.isEmpty)
        }
        func wait() async throws { for _ in 0..<100 { if !store.loading { return }; try await Task.sleep(nanoseconds: 10_000_000) }; fatalError("Paging timed out") }
        store.load(series: "123456", episode: "234567"); try await wait()
        assert(store.items.count == 2 && store.total == 100 && store.hasMore)
        failNext = true
        store.more(series: "123456", episode: "234567"); store.more(series: "123456", episode: "234567"); try await wait()
        assert(store.items.count == 2 && store.error != nil && store.hasMore)
        store.more(series: "123456", episode: "234567"); try await wait()
        assert(store.items.map(\.id) == ["1", "2", "3"] && !store.hasMore && store.error == nil)
        assert(calls.map(\.1) == ["", "next", "next"], "Retry must use same cursor; concurrent continuation must be suppressed")
        store.load(series: "123456", episode: "slow"); store.load(series: "123456", episode: "new"); try await wait()
        try await Task.sleep(nanoseconds: 250_000_000)
        assert(store.items.count == 2 && store.loaded && store.error == nil)
        store.load(series: "123456", episode: "wrong"); try await wait(); assert(store.items.isEmpty && store.error != nil)
        store.load(series: "123456", episode: "loop"); try await wait()
        store.more(series: "123456", episode: "loop"); try await wait(); assert(store.items.count == 1 && store.error != nil)
        store.load(series: "123456", episode: "234567"); try await wait()
        store.more(series: "123456", episode: "234567"); try await wait()
        failFirst = true
        store.load(series: "123456", episode: "234567", force: true); try await wait()
        assert(store.items.count == 3 && store.error != nil)
        store.retry(series: "123456", episode: "234567"); try await wait()
        assert(store.items.count == 2 && store.error == nil && store.hasMore && calls.last?.1 == "", "Failed refresh must retry first page and replace old results")
        store.clear(); assert(!store.loaded && store.items.isEmpty && !store.loading)
        print("Comment continuation, deduplication, retry cursor, request isolation and loop rejection: PASS")
    }
}
