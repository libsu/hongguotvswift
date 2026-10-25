// SPDX-License-Identifier: GPL-3.0-only
// 封面图磁盘缓存：以封面 URL 为键，把图片落到应用支持目录，避免反复进入「我的-历史/收藏」
// 等页面时重新请求封面。内存层用 NSCache（自动 LRU），磁盘层带文件数上限。
import SwiftUI
import AppKit
import CryptoKit

/// 封面图缓存：内存（NSCache）+ 磁盘两层。线程安全。
final class CoverCache {
    static let shared = CoverCache()

    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private let maxFiles = 1000

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac/covers", isDirectory: true)
        self.directory = base
        memory.countLimit = 256
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func cachedImage(for urlString: String) -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        let key = Self.key(urlString)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        let url = directory.appendingPathComponent(key + ".img")
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func store(data: Data, for urlString: String) {
        guard !urlString.isEmpty else { return }
        let key = Self.key(urlString)
        if let image = NSImage(data: data) { memory.setObject(image, forKey: key as NSString) }
        let url = directory.appendingPathComponent(key + ".img")
        try? data.write(to: url, options: .atomic)
        pruneIfNeeded()
    }

    /// 用 URL 字符串的 SHA-256 作为文件名，避免 URL 中的非法字符与超长路径。
    private static func key(_ urlString: String) -> String {
        SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        if sorted.count > maxFiles {
            for url in sorted.dropFirst(maxFiles) { try? FileManager.default.removeItem(at: url) }
        }
    }
}

/// 封面图视图：磁盘缓存优先，未命中时下载并缓存。尺寸/圆角由调用方通过 frame/clip 控制。
struct CoverImageView: View {
    let urlString: String
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) { await load() }
    }

    @MainActor
    private func load() async {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { failed = true; return }
        if let cached = CoverCache.shared.cachedImage(for: urlString) {
            image = cached
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data) else {
                failed = true
                return
            }
            CoverCache.shared.store(data: data, for: urlString)
            image = img
        } catch {
            failed = true
        }
    }
}
