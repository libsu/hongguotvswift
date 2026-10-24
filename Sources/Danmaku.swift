// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

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
        guard enabled, !loading, time.isFinite, duration.isFinite, time >= 0, duration > time, duration <= 86400, Date().timeIntervalSince(failedAt) >= 15 else { return }
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
