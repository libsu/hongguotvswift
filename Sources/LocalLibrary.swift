// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

struct WatchRecord: Codable, Identifiable {
    var id: String { series.id }
    let series: Series
    let episodeID: String
    let episodeIndex: Int
    let position: Double
    let duration: Double
    let completed: Bool
    let updatedAt: Date
    var label: String {
        let time = max(0, Int(position))
        return "第 \(episodeIndex + 1) 集 · \(completed ? "已看完" : String(format: "%02d:%02d", time / 60, time % 60))"
    }
}
struct SavedLibrary: Codable {
    var schema = 1
    var favorites: [Series] = []
    var history: [WatchRecord] = []
}

@MainActor final class LocalLibrary: ObservableObject {
    @Published private(set) var contents = SavedLibrary()
    @Published private(set) var error: String?
    private let file: URL
    private var writable = true
    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac/library.json")
        if FileManager.default.fileExists(atPath: self.file.path) {
            do {
                let data = try Data(contentsOf: self.file)
                guard data.count <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let saved = try JSONDecoder().decode(SavedLibrary.self, from: data)
                guard saved.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
                contents = saved
            } catch {
                writable = false
                self.error = "本机记录读取失败，已保留原文件；请备份后检查。"
            }
        }
    }
    func record(_ value: WatchRecord) {
        guard value.position.isFinite, value.duration.isFinite, value.position >= 0,
              value.duration >= 0, value.episodeIndex >= 0, !value.episodeID.isEmpty else { return }
        contents.history.removeAll { $0.id == value.id }
        contents.history.insert(value, at: 0)
        contents.history = Array(contents.history.prefix(500))
        save()
    }
    func toggleFavorite(_ series: Series) {
        if contents.favorites.contains(where: { $0.id == series.id }) { contents.favorites.removeAll { $0.id == series.id } }
        else { contents.favorites.insert(series, at: 0); contents.favorites = Array(contents.favorites.prefix(2000)) }
        save()
    }
    func removeHistory(_ id: String) { contents.history.removeAll { $0.id == id }; save() }
    func favorite(_ id: String) -> Bool { contents.favorites.contains { $0.id == id } }
    func history(_ id: String) -> WatchRecord? { contents.history.first { $0.id == id } }
    private func save() {
        guard writable else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(contents).write(to: file, options: .atomic)
            error = nil
        } catch { self.error = "本机记录保存失败，请检查磁盘空间。" }
    }
}
