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
        // 命中缓存先上屏架子，再后台刷新。
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

    /// 拉取首页推荐流；首屏（more=false）成功后落盘缓存。
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
            // 自动试播：点「开始刷剧」或开启「首页直接播放」时加载完成即试播第一部。
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
        guard section == .home, preview, let id = detail?.series.id,
              let index = catalogRows.firstIndex(where: { $0.id == id }), catalogRows.indices.contains(index + 1) else { return }
        let series = catalogRows[index + 1], selectedQuality = quality, generation = homeGeneration
        homeWarmTask = Task {
            do {
                if let backend = self.backend {
                    // 先取下一部剧详情，再预热其首集（预创建 Item，切剧秒开）。
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
    func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: speed) }
    }
    /// 显示播放控件并在 2.5 秒后自动隐藏。
    /// `keepVisible` 为真时（信息面板开启、鼠标按住拖动等）延后隐藏，避免阅读/拖拽时控件消失。
    /// 全屏与非全屏共用；鼠标移动/点击/按键及各控件交互均调用此方法复位计时。
    /// 显示播放控件并在一段时间后自动隐藏。
    /// 非全屏下，自动隐藏需同时满足「超时」与「鼠标不在播放区」两个条件；
    /// 全屏时鼠标移动会持续触发 reveal，因此沿用超时即可。
    /// `keepVisible` 为真时（信息面板开启、鼠标按住拖动等）延后隐藏。
    func revealPlayerControls(keepVisible: Bool = false) {
        // 控件从隐藏变可见时先补一次进度：隐藏期间进度条时钟不再更新。
        if !playerControlsVisible {
            playerControlsVisible = true
            playbackClock.update(player.currentTime().seconds)
        }
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if keepVisible || self.infoPanelOpen || self.hoveringPlayer {
                self.revealPlayerControls()
            } else {
                self.playerControlsVisible = false
            }
        }
    }
    /// 隐藏播放控件（并关闭信息面板）。
    func hidePlayerControls() {
        controlsHideTask?.cancel(); controlsHideTask = nil
        playerControlsVisible = false
        infoPanelOpen = false
    }
    func skipPlayback(_ seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600))
    }
}
