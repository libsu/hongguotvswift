// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

extension Model {
    func loadHome(more: Bool = false) {
        guard !busy else { return }
        homeGeneration = UUID(); homeWarmTask?.cancel(); homeWarmDetail = nil
        let selected = homeCategory
        let generation = homeGeneration
        perform {
            self.message = "正在读取推荐作品…"
            let page = more ? self.catalogPage + 1 : 1
            let result: CatalogResult = try await self.request("feed", ["category": selected, "page": String(page), "refresh": String(!more)])
            guard self.section == "首页", self.homeGeneration == generation else { return }
            let old = more ? self.catalogRows : []
            let ids = Set(old.map(\.id))
            let added = result.items.filter { !ids.contains($0.id) }
            self.catalogRows = old + added
            self.catalogMore = result.hasMore; self.catalogPage = page
            // 进入首页不自动试播；仅当用户主动点「开始刷剧」时才试播第一部。
            if self.autoTrialAfterLoad, let first = added.first {
                self.autoTrialAfterLoad = false
                self.pendingHomeSeries = first
            } else {
                self.message = "已加载 \(self.catalogRows.count) 部作品，点「开始刷剧」试播"
            }
        }
    }

    /// 用户主动开始试播：若有推荐列表直接试播第一部，否则先加载再试播。
    func startHomeTrial() {
        if let first = catalogRows.first {
            open(first, trial: true)
        } else {
            autoTrialAfterLoad = true
            loadHome()
        }
    }
    func warmNextHome() {
        homeWarmTask?.cancel(); homeWarmDetail = nil
        guard section == "首页", preview, let id = detail?.series.id,
              let index = catalogRows.firstIndex(where: { $0.id == id }), catalogRows.indices.contains(index + 1) else { return }
        let series = catalogRows[index + 1], selectedQuality = quality, generation = homeGeneration
        homeWarmTask = Task {
            do {
                if let backend = self.backend {
                    // 原生：先取详情，再预热首集（首页试播切集复用。）。
                    let detailJSON = try await backend.detail(id: series.id)
                    let data = try JSONSerialization.data(withJSONObject: detailJSON)
                    let next = try JSONDecoder().decode(Detail.self, from: data)
                    guard !Task.isCancelled, homeGeneration == generation, quality == selectedQuality else { return }
                    homeWarmDetail = next; homeWarmQuality = selectedQuality
                    if let first = next.episodes.first {
                        await self.prefetchEpisode(backend: backend, episodeID: first, quality: selectedQuality)
                    }
                    return
                }
                let next: Detail = try await request("warm", ["id": series.id, "quality": String(selectedQuality)])
                guard !Task.isCancelled, homeGeneration == generation, quality == selectedQuality else { return }
                homeWarmDetail = next; homeWarmQuality = selectedQuality
            } catch { /* Optional prefetch failure must not interrupt current playback. */ }
        }
    }
    func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: speed) }
    }
    func skipPlayback(_ seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600))
    }
}
