// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Topic: Codable, Identifiable { let id: String; let label: String }
struct MacRank: Codable { let rank: Int?; let heat: String }
struct CatalogResult: Codable { let items: [Series]; let hasMore: Bool; let topics: [Topic]; let positions: [String: MacRank]? }
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

    func key(section: String, category: String, board: String) -> String {
        // 键只与栏目类型有关；题材话题不入键（缓存第一页全部题材）。
        let c = section == "榜单" ? board : category
        return "\(section)-\(c)"
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
        if section == "账户" { loadCloud(); return }
        if ["找剧", "榜单", "推荐"].contains(section) {
            if section != "推荐" && category == "ALL" { category = "COMIC" }
            topic = ""; topics = []; loadCatalog()
        }
    }
    func loadCatalog(more: Bool = false, refresh: Bool = false) {
        let kind = section
        guard ["找剧", "榜单", "推荐"].contains(kind), !busy else { return }
        let endpoint = kind == "找剧" ? "catalog" : kind == "榜单" ? "rank" : "feed"
        let selectedCategory = category, selectedTopic = topic, selectedBoard = board
        let cacheKey = catalogCache.key(section: kind, category: selectedCategory, board: selectedBoard)
        // 首页/换一批：先上缓存「架子」（找剧/榜单），避免每次进入都是空的；首页推荐不缓存。
        if !more && kind != "推荐" {
            if let cached = catalogCache.load(cacheKey) {
                self.catalogRows = cached.items
                self.topics = cached.topics
                self.rankPositions = cached.positions ?? [:]
                self.catalogMore = cached.hasMore
                self.catalogPage = 1
                self.message = "已加载 \(cached.items.count) 部剧（缓存）"
            }
        }
        perform {
            let next = more ? self.catalogPage + 1 : 1
            if !more { self.catalogRows = [] }
            self.message = "正在加载\(kind)…"
            let result: CatalogResult = try await self.request(endpoint, ["category": selectedCategory, "topic": selectedTopic, "board": selectedBoard, "page": String(next), "refresh": String(refresh)])
            guard self.section == kind else { return }
            if more {
                let existing = Set(self.catalogRows.map(\.id))
                self.catalogRows += result.items.filter { !existing.contains($0.id) }
            } else { self.catalogRows = result.items }
            self.catalogMore = result.hasMore; self.catalogPage = next; self.catalogKind = kind
            self.topics = result.topics; self.rankPositions = result.positions ?? [:]
            self.message = "已加载 \(self.catalogRows.count) 部剧"
            // 仅缓存第一页结果，避免脏数据与磁盘膨胀。
            if !more && kind != "推荐" && next == 1 {
                self.catalogCache.save(result, key: cacheKey)
            }
        }
    }
}
