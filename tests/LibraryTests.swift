// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct LibraryTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let series = Series(id: "123", title: "测试", cover: "", description: "", badge: "全10集")
        let store = LocalLibrary(file: file)
        store.toggleFavorite(series)
        store.record(WatchRecord(series: series, episodeID: "456", episodeIndex: 2, position: 35, duration: 90, completed: false, updatedAt: Date()))
        let restored = LocalLibrary(file: file)
        assert(restored.favorite("123")); assert(restored.history("123")?.position == 35)
        restored.record(WatchRecord(series: series, episodeID: "789", episodeIndex: 3, position: 0, duration: 90, completed: false, updatedAt: Date()))
        assert(restored.contents.history.count == 1); assert(restored.history("123")?.episodeID == "789")
        restored.record(WatchRecord(series: series, episodeID: "bad", episodeIndex: 3, position: .nan, duration: 90, completed: false, updatedAt: Date()))
        assert(restored.history("123")?.episodeID == "789")
        restored.removeHistory("123"); restored.toggleFavorite(series)
        assert(LocalLibrary(file: file).contents.history.isEmpty); assert(!LocalLibrary(file: file).favorite("123"))
        try Data("broken".utf8).write(to: file)
        let corrupt = LocalLibrary(file: file)
        assert(corrupt.error != nil); corrupt.toggleFavorite(series)
        let preserved = try String(contentsOf: file, encoding: .utf8)
        assert(preserved == "broken")
        print("Local favorites, resume records, persistence and corrupt-file preservation: PASS")
    }
}
