// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct Series: Codable, Identifiable {
    let id: String
    let title: String
    let cover: String
    let description: String
    let badge: String
    let tags: String

    init(id: String, title: String, cover: String, description: String, badge: String, tags: String = "") {
        self.id = id; self.title = title; self.cover = cover; self.description = description; self.badge = badge; self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.cover = try c.decodeIfPresent(String.self, forKey: .cover) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.badge = try c.decodeIfPresent(String.self, forKey: .badge) ?? ""
        self.tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
    }
}
struct SearchResult: Decodable { let items: [Series]; let hasMore: Bool }
struct Detail: Decodable { let series: Series; let episodes: [String] }
struct PlayResult: Decodable { let url: String; let quality: String }
struct BridgeError: Decodable { let error: String }
