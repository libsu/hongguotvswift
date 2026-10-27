// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Topic: Codable, Identifiable { let id: String; let label: String }
struct RankBadge: Codable { let rank: Int?; let heat: String }
struct CatalogResult: Codable { let items: [Series]; let hasMore: Bool; let topics: [Topic]; let positions: [String: RankBadge]? }
struct RelatedEntry: Decodable, Identifiable {
    var id: String { series.id }
    let series: Series
    let season: String
    let upcoming: Bool
}
struct RelatedResult: Decodable { let items: [RelatedEntry] }

/// 目录数据磁盘缓存：把「找剧/榜单」第一页结果按栏目键缓存，进入栏目时先上屏缓存的「架子」，
/// 后台刷新后再覆盖。限制缓存文件数量，避免磁盘无限增长。
@MainActor
final class CatalogCache {
    private let directory: URL
    private let maxFiles: Int

    init(directory: URL? = nil, maxFiles: Int = 6) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac/catalog", isDirectory: true)
        self.directory = dir
        self.maxFiles = maxFiles
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func key(section: Section, category: String, board: String) -> String {
        // 键只与栏目类型有关；题材话题不入键（缓存第一页全部题材）。
        let c = section == .rank ? board : category
        return "\(section.rawValue)-\(c)"
    }
    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    func load(_ key: String) -> CatalogResult? {
        let url = fileURL(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(CatalogResult.self, from: data)
    }

    /// 兑底读取：从同 section 的任意缓存文件中取出 topics。
    /// 供「无缓存（当前 board 首次进入）时」先渲染题材胶囊，避免 topics 依赖网络返回后才突然插入导致的布局跳变。
    func fallbackTopics(section: Section) -> [Topic] {
        let prefix = section.rawValue + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { continue }
            let key = String(name.dropLast(".json".count))
            if let result = load(key), !result.topics.isEmpty { return result.topics }
        }
        return []
    }

    func save(_ result: CatalogResult, key: String) {
        guard let data = try? JSONEncoder().encode(result) else { return }
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

extension Model {
    func loadSection() {
        if section == .account { loadCloud(); return }
        if [.discover, .rank, .recommend].contains(section) {
            if section != .recommend && category == "ALL" { category = "COMIC" }
            topic = ""; topics = []; loadCatalog()
        }
    }
    func loadCatalog(more: Bool = false, refresh: Bool = false) {
        let kind = section
        guard [.discover, .rank, .recommend].contains(kind) else { return }
        let endpoint = kind == .discover ? "catalog" : kind == .rank ? "rank" : "feed"
        let selectedCategory = category, selectedTopic = topic, selectedBoard = board
        let cacheKey = catalogCache.key(section: kind, category: selectedCategory, board: selectedBoard)
        // 首次进入（找剧/榜单）且命中缓存：先上屏缓存「架子」，再后台非阻塞刷新。
        if !more && kind != .recommend, let cached = catalogCache.load(cacheKey) {
            self.catalogRows = cached.items
            self.topics = cached.topics
            self.rankPositions = cached.positions ?? [:]
            self.catalogMore = cached.hasMore
            self.catalogPage = 1
            self.message = "已加载 \(cached.items.count) 部剧（缓存）"
            // 后台刷新不占用 busy，因此卡片保持可点、不会被置灰。
            catalogRefreshTask?.cancel()
            catalogRefreshTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.fetchCatalog(kind: kind, endpoint: endpoint, category: selectedCategory, topic: selectedTopic, board: selectedBoard, cacheKey: cacheKey, more: false, refresh: refresh)
                } catch {
                    if !Task.isCancelled { self.message = error.localizedDescription }
                }
            }
            return
        }
        // 无缓存（首次加载、加载更多或推荐换一批）：走 perform，占用 busy 展示加载态。
        guard !busy else { return }
        // 兑底：当前 board 无缓存、但 topics 尚未就绪时，尝试从同 section 的其它缓存兑底题材，
        // 让题材胶囊立即渲染，避免网络返回后才突然插入。
        if !more, kind != .recommend, self.topics.isEmpty {
            self.topics = catalogCache.fallbackTopics(section: kind)
        }
        perform {
            if !more { self.loadingList = true }
            defer { if !more { self.loadingList = false } }
            if !more { self.catalogRows = [] }
            try await self.fetchCatalog(kind: kind, endpoint: endpoint, category: selectedCategory, topic: selectedTopic, board: selectedBoard, cacheKey: cacheKey, more: more, refresh: refresh)
        }
    }

    /// 拉取一页目录数据并应用结果（含第一页落盘缓存），供首次加载与后台刷新共用。
    private func fetchCatalog(kind: Section, endpoint: String, category: String, topic: String, board: String, cacheKey: String, more: Bool, refresh: Bool) async throws {
        let next = more ? self.catalogPage + 1 : 1
        self.message = "正在加载\(kind.title)…"
        let result: CatalogResult = try await self.request(endpoint, ["category": category, "topic": topic, "board": board, "page": String(next), "refresh": String(refresh)])
        guard self.section == kind else { return }
        if more {
            let existing = Set(self.catalogRows.map(\.id))
            self.catalogRows += result.items.filter { !existing.contains($0.id) }
        } else { self.catalogRows = result.items }
        self.catalogMore = result.hasMore; self.catalogPage = next; self.catalogKind = kind
        self.topics = result.topics; self.rankPositions = result.positions ?? [:]
        self.message = "已加载 \(self.catalogRows.count) 部剧"
        // 仅缓存第一页结果，避免脏数据与磁盘膨胀。
        if !more && kind != .recommend && next == 1 {
            self.catalogCache.save(result, key: cacheKey)
        }
    }
}
