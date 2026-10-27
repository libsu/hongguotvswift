// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 详情数据磁盘缓存：按 series.id 缓存详情，二次进入同一部剧秒开，后台刷新后再覆盖。
/// 复用 CatalogCache 的「先本地、后网络」模式；解码失败（结构变化 / 版本不兼容）时优雅降级返回 nil，不阻塞正常网络填充。
@MainActor
final class DetailCache {
    private let directory: URL
    private let maxFiles: Int
    private let schemaVersion: Int

    init(directory: URL? = nil, maxFiles: Int = 128, schemaVersion: Int = 1) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac/detail", isDirectory: true)
        self.directory = dir
        self.maxFiles = maxFiles
        self.schemaVersion = schemaVersion
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func load(_ key: String) -> Detail? {
        let url = fileURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        // 结构变化 / 版本不兼容时解码失败或版本不符，返回 nil 优雅降级，走正常网络填充。
        guard let entry = try? JSONDecoder().decode(DetailCacheEntry.self, from: data), entry.version == schemaVersion else { return nil }
        // 空集数视为脏缓存，同样降级，避免上屏一个无法播放的详情。
        guard !entry.detail.episodes.isEmpty else { return nil }
        return entry.detail
    }

    func save(_ detail: Detail, key: String) {
        guard let data = try? JSONEncoder().encode(DetailCacheEntry(version: schemaVersion, detail: detail)) else { return }
        try? data.write(to: fileURL(key), options: .atomic)
        prune()
    }

    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let sorted = files.sorted { (a, b) in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        if sorted.count > maxFiles {
            for url in sorted.dropFirst(maxFiles) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// 落盘包一层 schema 版本号，详情结构变化时通过版本不符实现缓存失效（优雅降级）。
private struct DetailCacheEntry: Codable {
    let version: Int
    let detail: Detail
}

// 搜索与详情打开逻辑，从 HongguoMac.swift 拆分而来，保持 Model 主文件聚焦于状态与生命周期。
extension Model {
    func search(more: Bool = false) {
        let keyword = more ? searched : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 80 else { message = "请输入 1～80 字的剧名"; return }
        perform {
            if !more { self.loadingList = true }
            defer { if !more { self.loadingList = false } }
            let next = more ? self.page + 1 : 1
            self.message = "正在搜索…"
            let result: SearchResult = try await self.request("search", ["q": keyword, "page": String(next)])
            if more {
                let existing = Set(self.rows.map(\.id))
                self.rows += result.items.filter { !existing.contains($0.id) }
            } else { self.rows = result.items }
            if self.showDetail { self.saveProgress(); self.player.pause() }
            self.section = .search
            self.navigation = .search
            self.showDetail = false
            self.searched = keyword; self.page = next; self.hasMore = result.hasMore
            self.message = self.rows.isEmpty ? "没有找到相关剧集" : "已加载 \(self.rows.count) 部剧"
        }
    }

    /// 打开某一部剧：先立即切到详情骨架（不等待网络），后台再拉真实详情并填充。
    /// 采用「点击切换、后台等待」而非「点击等待、切换」，消除点击后原地转圈的卡顿。
    func open(_ series: Series, trial: Bool = false, resumeEpisodeID: String? = nil, resumePosition: Double? = nil) {
        // 1) 同步阶段：立即停旧节目、清空面板，用仅含 series 信息的 placeholder 切到详情页。
        comments.clear(); commentThread.clear(); danmaku.clear()
        // 立即保存并停止旧节目，避免加载详情期间旧节目还在播放。
        saveProgress()
        player.pause(); player.replaceCurrentItem(with: nil)
        activeLoader?.close(); activeLoader = nil
        prewarmLoader?.close(); prewarmLoader = nil; prewarmedEpisode = nil
        activeSeries = nil; activeEpisodeID = nil; activeEpisodeIndex = nil
        pendingNext = false
        warmedNearEndKey = nil
        related = []; relatedMessage = "正在读取相关作品…"
        relatedTask?.cancel()

        let placeholder = Detail(series: series, episodes: [])
        self.detail = placeholder
        self.showDetail = true
        self.episode = nil
        self.preview = trial
        self.cloudResume = nil
        self.message = "正在读取剧集…"

        // 快路径：试播命中首页预热缓存时，无需网络直接填充真实详情。
        if trial, let cached = homeWarmDetail, cached.series.id == series.id, homeWarmQuality == quality {
            applyDetail(cached, trial: trial, resumeEpisodeID: resumeEpisodeID, resumePosition: resumePosition)
            return
        }

        // 2) 乐观回填：命中详情磁盘缓存时先立即渲染（集数列表立即可点），后台再刷新覆盖。
        // 缓存兜底只填充详情数据、不自动播放：待后台刷新拿到权威数据后再统一自动播放，避免对过期集数自动续播。
        let cachedDetail = detailCache.load(series.id)
        if let cachedDetail {
            renderDetail(cachedDetail, trial: trial, resumeEpisodeID: resumeEpisodeID, resumePosition: resumePosition)
        }

        // 3) 后台阶段：独立 Task 拉取真实详情，不占用 busy，令牌防竞态。
        // 递增代次使旧的在途详情请求失效，避免快速连点两部剧时旧响应覆盖新画面。
        detailGeneration = UUID()
        let generation = detailGeneration
        detailTask?.cancel()
        detailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let detail: Detail = try await self.request("detail", ["id": series.id])
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                self.detailCache.save(detail, key: series.id)
                self.applyDetail(detail, trial: trial, resumeEpisodeID: resumeEpisodeID, resumePosition: resumePosition)
            } catch {
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                // 已有缓存兜底时，刷新失败保留缓存画面（而非退回片单）；无缓存则退回片单并提示错误。
                if cachedDetail != nil {
                    self.message = "剧集信息更新失败，已展示缓存内容"
                } else {
                    self.message = error.localizedDescription
                    self.showDetail = false
                }
            }
        }
    }

    /// 仅填充详情数据（集数/云端续播/相关作品/提示文案），不触发自动播放。
    /// 供乐观回填的缓存兜底使用：先上屏缓存详情，权威数据到达后再由 applyDetail 统一自动播放。
    func renderDetail(_ detail: Detail, trial: Bool, resumeEpisodeID: String?, resumePosition: Double?) {
        self.detail = detail
        self.preview = trial
        // 云端续播优先：调用方显式传入 episodeID/position（账户历史卡片）。
        if let resumeEpisodeID, let index = detail.episodes.firstIndex(of: resumeEpisodeID) {
            self.cloudResume = (index, resumePosition ?? 0)
        } else if self.section == .account && self.cloudType == .history, let cloud = self.cloudRows.first(where: { $0.id == detail.series.id }), let id = cloud.episodeID, let index = detail.episodes.firstIndex(of: id) {
            self.cloudResume = (index, cloud.position ?? 0)
        } else { self.cloudResume = nil }

        self.related = []; self.relatedMessage = "正在读取相关作品…"
        self.relatedTask?.cancel()
        self.relatedTask = Task {
            do {
                let result: RelatedResult = try await self.request("related", ["id": detail.series.id])
                if !Task.isCancelled && self.detail?.series.id == detail.series.id { self.related = result.items; self.relatedMessage = result.items.isEmpty ? "暂无相关作品" : "" }
            } catch { if !Task.isCancelled { self.relatedMessage = "相关作品暂时无法加载" } }
        }
        self.message = "选择集数开始播放 · 共 \(detail.episodes.count) 集"
    }

    /// 填充真实详情并触发后续：云端续播判断、相关作品拉取、以及详情就绪后的自动播放。
    /// 由 open 的同步快路径或后台 Task 调用，均运行在 MainActor。
    func applyDetail(_ detail: Detail, trial: Bool, resumeEpisodeID: String?, resumePosition: Double?) {
        renderDetail(detail, trial: trial, resumeEpisodeID: resumeEpisodeID, resumePosition: resumePosition)

        // 详情就绪后自动播放（试播播第一集 / 正式观看续播）。
        // 仅当用户仍停留在详情页时触发；若已返回片单，只保留详情数据不打扰播放。
        guard showDetail, !stopping else { return }
        if trial { play(0, trial: true) }
        else { resume() }
    }
}
