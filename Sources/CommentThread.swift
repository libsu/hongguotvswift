// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

struct AppCommentPage: Decodable {
    let seriesID: String
    let episodeID: String
    let total: Int
    let items: [PublicComment]
    let nextCursor: String
    let hasMore: Bool
}
@MainActor final class CommentThreadStore: ObservableObject {
    @Published private(set) var items: [PublicComment] = []
    @Published private(set) var total = 0
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var hasMore = false
    @Published private(set) var error: String?
    private var retryReset = true
    private var cursor = ""
    private var cursors = Set<String>()
    private var key = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    let fetch: (String, String, String) async throws -> AppCommentPage
    init(fetch: @escaping (String, String, String) async throws -> AppCommentPage) { self.fetch = fetch }
    func clear() {
        task?.cancel(); generation = UUID(); items = []; total = 0; loading = false; loaded = false
        hasMore = false; error = nil; cursor = ""; cursors = []; key = ""
    }
    func load(series: String, episode: String, force: Bool = false) {
        let next = series + "/" + episode
        if next != key { clear(); key = next }
        if !force && (loading || loaded) { return }
        request(series: series, episode: episode, reset: true)
    }
    func more(series: String, episode: String) {
        guard key == series + "/" + episode, loaded, hasMore, !loading else { return }
        request(series: series, episode: episode, reset: false)
    }
    func retry(series: String, episode: String) {
        guard key == series + "/" + episode, !loading, error != nil else { return }
        request(series: series, episode: episode, reset: retryReset)
    }
    private func request(series: String, episode: String, reset: Bool) {
        task?.cancel(); generation = UUID()
        let id = generation, sent = reset ? "" : cursor
        retryReset = reset; loading = true; error = nil
        task = Task {
            defer { if generation == id { loading = false } }
            do {
                let page = try await fetch(series, episode, sent)
                guard !Task.isCancelled, generation == id else { return }
                guard page.seriesID == series, page.episodeID == episode,
                      !page.hasMore || (!page.nextCursor.isEmpty && page.nextCursor != sent && (reset || !cursors.contains(page.nextCursor))) else { throw URLError(.cannotParseResponse) }
                let previous = reset ? [] : items
                var seen = Set(previous.map(\.id))
                let merged = previous + page.items.filter { seen.insert($0.id).inserted }
                // 上限保护：服务端异常（hasMore 恒 true 且不断返回新评论）时不无限累积内存。
                items = merged.count > 5000 ? Array(merged.suffix(5000)) : merged
                total = page.total; loaded = true; hasMore = page.hasMore; cursor = page.nextCursor
                if reset { cursors = [] }
                cursors.insert(sent); cursors.insert(page.nextCursor)
            } catch {
                if !Task.isCancelled, generation == id { self.error = "评论加载失败，已保留当前内容，请重试。" }
            }
        }
    }
}
