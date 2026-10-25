// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

struct PublicComment: Decodable, Identifiable {
    let id: String
    let author: String
    let avatar: String
    let content: String
    let created: Double
    let likes: Int
    let rating: Double
    var date: Date? { created > 0 ? Date(timeIntervalSince1970: created > 1e12 ? created / 1000 : created) : nil }
}
struct PublicCommentList: Decodable { let total: Int; let items: [PublicComment] }
struct PublicSocial: Decodable {
    let seriesID: String
    let episodeID: String
    let reviews: PublicCommentList
    let comments: PublicCommentList
    let rating: Double
    let ratingCount: Int
    let sourceURL: String
    let limited: Bool
}
@MainActor final class MacComments: ObservableObject {
    @Published var result: PublicSocial?
    @Published var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var key: String?
    let fetch: (String, String) async throws -> PublicSocial
    init(fetch: @escaping (String, String) async throws -> PublicSocial) { self.fetch = fetch }
    func clear() {
        task?.cancel(); requestID = UUID(); result = nil; error = nil; loading = false; key = nil
    }
    func load(series: String, episode: String, force: Bool = false) {
        let next = series + "/" + episode
        if !force && key == next && (loading || result != nil) { return }
        clear(); key = next; loading = true
        let id = requestID
        task = Task {
            defer { if requestID == id { loading = false } }
            do {
                let data = try await fetch(series, episode)
                guard !Task.isCancelled, requestID == id else { return }
                guard data.seriesID == series && data.episodeID == episode else { throw URLError(.cannotParseResponse) }
                result = data
            } catch {
                if !Task.isCancelled && requestID == id { self.error = "评论暂时无法读取，请稍后重试。" }
            }
        }
    }
}
extension Model {
    func loadComments(force: Bool = false) {
        guard let detail, let episode, detail.episodes.indices.contains(episode) else { return }
        comments.load(series: detail.series.id, episode: detail.episodes[episode], force: force)
        commentThread.load(series: detail.series.id, episode: detail.episodes[episode], force: force)
    }
    func loadMoreComments() {
        guard let detail, let episode, detail.episodes.indices.contains(episode) else { return }
        commentThread.more(series: detail.series.id, episode: detail.episodes[episode])
    }
    func retryComments() {
        guard let detail, let episode, detail.episodes.indices.contains(episode) else { return }
        commentThread.retry(series: detail.series.id, episode: detail.episodes[episode])
    }
    var commentKey: String { (detail?.series.id ?? "") + "/" + String(episode ?? -1) }
}
