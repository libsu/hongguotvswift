// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

struct TimedComment: Decodable, Identifiable { let id: String; let text: String; let timeMS: Int }
struct TimedCommentPage: Decodable { let seriesID: String; let episodeID: String; let startMS: Int; let nextMS: Int; let items: [TimedComment] }
@MainActor final class MacDanmaku: ObservableObject {
    @Published var enabled = UserDefaults.standard.object(forKey: "danmakuEnabled") as? Bool ?? false {
        didSet { UserDefaults.standard.set(enabled, forKey: "danmakuEnabled"); if !enabled { clear() } }
    }
    @Published private(set) var pages: [Int: TimedCommentPage] = [:]
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    static let travelMS = 10000
    private var scheduled: [(item: TimedComment, lane: Int)] = []
    private var key = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var failedAt = Date.distantPast
    let fetch: (String, String, Int, Int) async throws -> TimedCommentPage
    init(fetch: @escaping (String, String, Int, Int) async throws -> TimedCommentPage) { self.fetch = fetch }
    func clear() { task?.cancel(); generation = UUID(); pages = [:]; scheduled = []; loading = false; error = nil; key = ""; failedAt = .distantPast }
    func retry() { failedAt = .distantPast; error = nil }
    func update(series: String, episode: String, time: Double, duration: Double) {
        let nextKey = series + "/" + episode
        if key != nextKey { clear(); key = nextKey }
        guard enabled, !loading, time.isFinite, duration.isFinite, time >= 0, duration > time, duration <= 86400, Date().timeIntervalSince(failedAt) >= 5 else { return }
        let position = Int(time * 1000), end = Int(duration * 1000)
        let current = position / 30000 * 30000
        var desired = [current]
        if position - current < Self.travelMS && current > 0 { desired.append(current - 30000) }
        if current + 30000 - position < 10000 && current + 30000 < end { desired.append(current + 30000) }
        guard let start = desired.first(where: { pages[$0] == nil }) else { return }
        let id = generation
        loading = true
        task = Task {
            defer { if generation == id { loading = false } }
            do {
                let page = try await fetch(series, episode, start, end)
                guard !Task.isCancelled, generation == id else { return }
                guard page.seriesID == series, page.episodeID == episode, page.startMS == start, page.nextMS > start, page.nextMS <= end,
                      page.items.allSatisfy({ $0.timeMS >= start && $0.timeMS < page.nextMS }) else { throw URLError(.cannotParseResponse) }
                pages[start] = page; error = nil
                while pages.count > 8, let oldest = pages.keys.max(by: { abs($0 - current) < abs($1 - current) }) { pages.removeValue(forKey: oldest) }
                rebuildSchedule()
            } catch { if !Task.isCancelled, generation == id { self.error = "弹幕暂时无法读取"; failedAt = Date() } }
        }
    }
    // Sort and reserve lanes only when data changes, never on the animation frame path.
    private func rebuildSchedule() {
        var available = Array(repeating: -1, count: 4), seen = Set<String>()
        scheduled = []
        for item in pages.values.flatMap(\.items).sorted(by: { $0.timeMS == $1.timeMS ? $0.id < $1.id : $0.timeMS < $1.timeMS }) {
            guard seen.insert(item.id).inserted, let lane = available.firstIndex(where: { $0 <= item.timeMS }) else { continue }
            available[lane] = item.timeMS + Self.travelMS
            scheduled.append((item, lane))
        }
    }
    func visible(at time: Double) -> [(item: TimedComment, lane: Int)] {
        guard enabled, time.isFinite, time >= 0, time <= 86400 else { return [] }
        let position = Int(time * 1000)
        return scheduled.filter { $0.item.timeMS <= position && position < $0.item.timeMS + Self.travelMS }
    }
}
