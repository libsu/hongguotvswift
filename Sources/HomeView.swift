// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

extension Model {
    func loadHome(more: Bool = false) {
        guard !busy else { return }
        homeGeneration = UUID(); homeWarmTask?.cancel(); homeWarmDetail = nil
        let selected = homeCategory
        let generation = homeGeneration
        let cacheKey = catalogCache.key(section: .home, category: selected, board: "")
        if !more, let cached = catalogCache.load(cacheKey) {
            self.catalogRows = cached.items
            self.catalogMore = cached.hasMore
            self.catalogPage = 1
            self.message = "已加载 \(cached.items.count) 部作品（缓存）"
            catalogRefreshTask?.cancel()
            catalogRefreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.fetchHome(selected: selected, generation: generation, cacheKey: cacheKey, more: false)
            }
            return
        }
        fetchHome(selected: selected, generation: generation, cacheKey: cacheKey, more: more)
    }

    /// 拉取首页推荐流 成功后落盘缓存
    private func fetchHome(selected: String, generation: UUID, cacheKey: String, more: Bool) {
        perform {
            if !more { self.loadingList = true }
            defer { if !more { self.loadingList = false } }
            self.message = "正在读取推荐作品…"
            let page = more ? self.catalogPage + 1 : 1
            let result: CatalogResult = try await self.request("feed", ["category": selected, "page": String(page), "refresh": String(!more)])
            guard self.section == .home, self.homeGeneration == generation else { return }
            let old = more ? self.catalogRows : []
            let ids = Set(old.map(\.id))
            let added = result.items.filter { !ids.contains($0.id) }
            self.catalogRows = old + added
            self.catalogMore = result.hasMore; self.catalogPage = page
            if !more { self.catalogCache.save(result, key: cacheKey) }
            // 自动试播：点「开始刷剧」或开启「首页直接播放」时加载完成即试播第一部
            if self.autoTrialAfterLoad, let first = added.first {
                self.autoTrialAfterLoad = false
                self.pendingHomeSeries = first
            } else if !more && self.homeAutoPlay, let first = added.first {
                self.pendingHomeSeries = first
            } else {
                self.message = "已加载 \(self.catalogRows.count) 部作品，点「开始刷剧」试播"
            }
        }
    }

    /// 用户主动开始试播：若有推荐列表直接试播第一部，否则先加载再试播
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
        guard section == .home, preview, let id = detail?.series.id,
              let index = catalogRows.firstIndex(where: { $0.id == id }), catalogRows.indices.contains(index + 1) else { return }
        let series = catalogRows[index + 1], selectedQuality = quality, generation = homeGeneration
        homeWarmTask = Task {
            do {
                if let backend = self.backend {
                    // 先取下一部剧详情，再预热其首集（预创建 Item，切剧秒开）
                    let detailJSON = try await backend.detail(id: series.id)
                    let data = try JSONSerialization.data(withJSONObject: detailJSON)
                    let next = try JSONDecoder().decode(Detail.self, from: data)
                    guard !Task.isCancelled, homeGeneration == generation, quality == selectedQuality else { return }
                    homeWarmDetail = next; homeWarmQuality = selectedQuality
                    if let first = next.episodes.first {
                        await self.prefetchEpisode(backend: backend, episodeID: first, quality: selectedQuality, index: 0, seriesID: next.series.id, preloadItem: true)
                    }
                    return
                }
                let next: Detail = try await request("warm", ["id": series.id, "quality": String(selectedQuality)])
                guard !Task.isCancelled, homeGeneration == generation, quality == selectedQuality else { return }
                homeWarmDetail = next; homeWarmQuality = selectedQuality
            } catch { /* Optional prefetch failure must not interrupt current playback. */ }
        }
    }
}
