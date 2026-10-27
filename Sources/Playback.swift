// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

// 播放管理与相关逻辑，从 HongguoMac.swift 拆分而来，保持 Model 主文件聚焦于状态与生命周期。
extension Model {
    func play(_ index: Int, position: Double = 0, autoplay: Bool = true, trial: Bool = false, auto: Bool = false) {
        guard let detail, detail.episodes.indices.contains(index) else { return }
        let selectedQuality = quality
        let episodeID = detail.episodes[index]
        // 命中预加载 item 则直接切换，跳过二次取流；跨剧时校验 seriesID。
        if let pre = prewarmedEpisode, pre.episodeID == episodeID,
           (pre.seriesID == nil || pre.seriesID == detail.series.id) {
            activeLoader?.close()
            activeLoader = prewarmLoader
            prewarmedEpisode = nil
            prewarmLoader = nil
            startEpisode(item: pre.item, index: index, quality: pre.quality, position: position, autoplay: autoplay, trial: trial)
            saveProgress()
            Log.shared.info("play \(episodeID) 命中预热 item，无缝切换")
            autoRetrying = false
            if trial && self.section == .home { self.warmNextHome() }
            return
        }
        perform {
            self.saveProgress()
            self.message = "正在准备第 \(index + 1) 集…"
            if let backend = self.backend {
                let info = try await backend.stream(episodeID: episodeID, quality: selectedQuality)
                guard !Task.isCancelled else { return }
                try await self.startNativeEpisode(episodeID: episodeID, info: info, index: index, position: position, autoplay: autoplay, trial: trial)
            } else {
                let result: PlayResult = try await self.request("play", ["id": episodeID, "quality": String(selectedQuality)])
                guard !Task.isCancelled else { return }
                guard let url = URL(string: result.url), url.host == "127.0.0.1" else { throw URLError(.badURL) }
                self.startEpisode(url: url, index: index, quality: result.quality, position: position, autoplay: autoplay, trial: trial)
            }
            if trial && self.section == .home { self.warmNextHome() }
            self.autoRetrying = false
        } onRetryable: { error in
            // 自动连播遇可重试软失败时再试一次；幂等标记避免无限重试。
            guard auto, self.autoNext, index + 1 < detail.episodes.count else { return }
            guard isTransientNetworkError(error) else { return }
            guard !self.autoRetrying else {
                self.message = "下一集加载失败，已暂停自动连播"
                return
            }
            self.autoRetrying = true
            self.message = "下一集加载失败，正在自动重试…"
            self.pendingNext = true
        }
    }

    /// 用 AVAssetResourceLoaderDelegate 播放（自定义 scheme）；命中缓存则复用已解析索引。
    func startNativeEpisode(episodeID: String, info: ResourceLoader.StreamAndQuality, index: Int, position: Double, autoplay: Bool, trial: Bool) async throws {
        let stream = ResourceLoader.Stream(url: info.url, key: info.key)
        // 未预热时先取头解析索引作为 seed，避免 AVPlayer 首次探测同步卡住。
        let seed: MediaFetcher.Prepared?
        if let cached = preparedCache.get(episodeID: episodeID, quality: quality) {
            seed = MediaFetcher.Prepared(prepared: cached.prepared, total: cached.total, mediaPrefixStart: cached.mediaPrefixStart > 0 ? cached.mediaPrefixStart : nil, mediaPrefix: cached.mediaPrefix)
        } else {
            seed = try await MediaFetcher.prepare(url: info.url, key: info.key, session: ResourceLoader.defaultSession())
        }
        let loader = ResourceLoader(stream: stream, episodeID: episodeID, seed: seed)
        let asset = AVURLAsset(url: MediaScheme.url(episodeID: episodeID), options: nil)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        activeLoader?.close()
        activeLoader = loader
        let item = AVPlayerItem(asset: asset)
        startEpisode(item: item, index: index, quality: info.quality, position: position, autoplay: autoplay, trial: trial)
    }

    /// 拿到播放 URL 后切换 AVPlayer 到指定集；预取命中时直接切 item，跳过网络。
    func startEpisode(url: URL, index: Int, quality: String, position: Double, autoplay: Bool, trial: Bool) {
        startEpisode(item: AVPlayerItem(url: url), index: index, quality: quality, position: position, autoplay: autoplay, trial: trial)
    }

    func startEpisode(item: AVPlayerItem, index: Int, quality: String, position: Double, autoplay: Bool, trial: Bool) {
        guard let detail else { return }
        player.pause()
        danmaku.clear()
        player.replaceCurrentItem(with: item)
        activeSeries = detail.series; activeEpisodeID = detail.episodes[index]; activeEpisodeIndex = index
        activeTrial = trial; preview = trial
        episode = index; actualQuality = quality
        playbackClock.update(position.isFinite ? max(0, position) : 0)
        if position.isFinite && position > 0 {
            Task { await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        if autoplay { player.playImmediately(atRate: speed) }
        saveProgress()
        message = "第 \(index + 1) 集 · \(quality)"
    }

    /// 预热下一集（仅正式观看 + 开启自动连播）；切集时 play 命中预加载 item，省去取流/解密延迟。
    func warmNextEpisode() {
        warmNextTask?.cancel()
        guard !activeTrial, autoNext, let detail, let index = episode, index + 1 < detail.episodes.count else { return }
        let seriesID = detail.series.id, nextID = detail.episodes[index + 1], selectedQuality = quality
        if warmedNearEndKey == nextID { return }
        warmedNearEndKey = nextID
        warmNextTask = Task { [weak self] in
            guard let self else { return }
            if let backend = self.backend {
                await self.prefetchEpisode(backend: backend, episodeID: nextID, quality: selectedQuality, index: index + 1, seriesID: seriesID, preloadItem: true)
            } else {
                do {
                    let _: Detail = try await self.request("warm", ["id": seriesID, "episode": nextID, "quality": String(selectedQuality)])
                    Log.shared.info("warmNextEpisode \(nextID) 成功（旧桥 /warm）")
                } catch {
                    Log.shared.warn("warmNextEpisode \(nextID) 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 距本集结束不足 15 秒时触发下一集预热（挂在 2 秒进度观测上，避免新增 Timer）。
    func warmNextIfNearEnd() {
        guard !activeTrial, autoNext, !busy,
              let detail, let index = episode, index + 1 < detail.episodes.count,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite,
              duration - current <= 15, duration - current > 0 else { return }
        warmNextEpisode()
    }

    /// 原生预热某一集：取流 -> 解析索引 -> 预取首段媒体 -> 存入缓存；可选预创建 Item 并加载到位。
    /// seriesID 用于跨剧试播时在 play 阶段做剧集匹配。
    func prefetchEpisode(backend: HongguoBackend, episodeID: String, quality: Int, index: Int, seriesID: String? = nil, preloadItem: Bool = false) async {
        do {
            let info = try await backend.stream(episodeID: episodeID, quality: quality)
            Log.shared.info("prefetch \(episodeID) 取流完成，开始 prepare")
            let stream = ResourceLoader.Stream(url: info.url, key: info.key)
            let prepared = try await MediaFetcher.prepareWithMediaPrefix(url: info.url, key: info.key, session: ResourceLoader.defaultSession())
            let headerBytes = prepared.prepared.header.count
            let prefixBytes = prepared.mediaPrefix.count
            Log.shared.info("warmNextEpisode \(episodeID) 成功：header=\(headerBytes)B prefix=\(prefixBytes)B samples=\(prepared.prepared.samples.count) total=\(prepared.total)")
            preparedCache.put(PreparedEntry(episodeID: episodeID, quality: quality, stream: stream, prepared: prepared.prepared, total: prepared.total, mediaPrefixStart: prepared.mediaPrefixStart ?? 0, mediaPrefix: prepared.mediaPrefix))
            guard preloadItem else { return }
            // 复用本次取流的 url/key + 索引作为 seed，避免到时二次 stream() 撞上不同 CDN host。
            let seed = MediaFetcher.Prepared(prepared: prepared.prepared, total: prepared.total, mediaPrefixStart: prepared.mediaPrefixStart, mediaPrefix: prepared.mediaPrefix)
            let loader = ResourceLoader(stream: stream, episodeID: episodeID, seed: seed)
            let asset = AVURLAsset(url: MediaScheme.url(episodeID: episodeID), options: nil)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            let item = AVPlayerItem(asset: asset)
            self.prewarmLoader = loader
            self.prewarmedEpisode = PrewarmedEpisode(item: item, episodeID: episodeID, seriesID: seriesID, index: index, quality: info.quality)
            Log.shared.info("warmNextEpisode \(episodeID) 已预创建 AVPlayerItem，触发预加载…")
            // 仅创建 Item 不会触发取流；显式 load duration/tracks 才会走 resourceLoader 预热。
            let duration: CMTime? = try? await asset.load(.duration)
            let tracks = try? await asset.load(.tracks)
            Log.shared.info("warmNextEpisode \(episodeID) 预加载完成 duration=\(duration?.seconds ?? -1) tracks=\(tracks?.count ?? -1)")
        } catch { Log.shared.warn("warmNextEpisode \(episodeID) 失败：\(error.localizedDescription)") }
    }

    func playNextEpisode() {
        guard let detail, let index = episode, index + 1 < detail.episodes.count else { return }
        if busy { pendingNext = true } else { play(index + 1, auto: true) }
    }

    func watchFull() {
        preview = false; activeTrial = false; saveProgress()
        let current = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 && current >= duration - 0.5 { play(episode ?? 0) }
        else if player.currentItem != nil { player.playImmediately(atRate: speed) }
        message = "已进入正式观看，可选择集数"
    }

    func moveRecommendation(_ delta: Int) {
        guard !busy, let id = detail?.series.id, let index = catalogRows.firstIndex(where: { $0.id == id }) else { return }
        if catalogRows.indices.contains(index + delta) { open(catalogRows[index + delta], trial: true) }
        else if delta > 0 && section == .home && catalogMore { loadHome(more: true) }
        else { message = "当前批次已到边界，可以换一批" }
    }

    func resume() {
        guard let detail else { return }
        if let cloudResume { play(cloudResume.0, position: cloudResume.1); self.cloudResume = nil; return }
        guard let saved = library.history(detail.series.id), let index = detail.episodes.firstIndex(of: saved.episodeID) else { play(0); return }
        if saved.completed && index + 1 < detail.episodes.count { play(index + 1) }
        else { play(index, position: saved.completed ? 0 : saved.position) }
    }

    func saveProgress(completed: Bool = false) {
        guard !activeTrial, let series = activeSeries, let id = activeEpisodeID, let index = activeEpisodeIndex, player.currentItem != nil else { return }
        let position = CMTimeGetSeconds(player.currentTime()), duration = CMTimeGetSeconds(player.currentItem!.duration)
        guard position.isFinite else { return }
        let record = WatchRecord(series: series, episodeID: id, episodeIndex: index, position: max(0, position), duration: duration.isFinite ? max(0, duration) : 0, completed: completed || (duration.isFinite && duration > 0 && position >= duration - 0.5), updatedAt: Date())
        library.record(record)
        uploadProgress(record, count: detail?.episodes.count ?? 0)
    }

    func changeSpeed(_ value: Float) {
        guard [0.5, 0.75, 1, 1.25, 1.5, 2].contains(value) else { return }
        speed = value; UserDefaults.standard.set(value, forKey: "playbackSpeed")
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }

    func changeQuality(_ value: Int) {
        guard [0, 480, 720, 1080].contains(value) else { return }
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
        if let episode { play(episode, position: CMTimeGetSeconds(player.currentTime()), autoplay: player.rate > 0, trial: activeTrial) }
    }

    /// 仅设置清晰度偏好（不触发重新播放），供「我的」页的自动清晰度开关使用。
    func setQualityPreference(_ value: Int) {
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
    }
}
