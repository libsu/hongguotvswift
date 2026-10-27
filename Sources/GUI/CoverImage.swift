// SPDX-License-Identifier: GPL-3.0-only
// 封面图两级缓存（内存 NSCache + 磁盘）；下载由 CoverDownloader 统一调度（并发受限 + 同 URL 去重 + CDN 节点回退）。
import SwiftUI
import AppKit
import CryptoKit

/// 封面图缓存：内存 + 磁盘两层。
final class CoverCache {
    static let shared = CoverCache()

    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private let maxFiles = 1000
    private let ioQueue = DispatchQueue(label: "hongguo.cover-cache.io", qos: .utility)
    private let pruneInterval = 64
    private var storesSincePrune = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac/covers", isDirectory: true)
        self.directory = base
        memory.countLimit = 256
        memory.totalCostLimit = 64 * 1024 * 1024
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func cachedImage(for urlString: String) -> NSImage? {
        guard !urlString.isEmpty, let name = Self.fileName(urlString) else { return nil }
        if let hit = memory.object(forKey: name as NSString) { return hit }
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        memory.setObject(image, forKey: name as NSString, cost: Self.cost(image))
        return image
    }

    func store(data: Data, image: NSImage, for urlString: String) {
        guard !urlString.isEmpty, let name = Self.fileName(urlString) else { return }
        memory.setObject(image, forKey: name as NSString, cost: Self.cost(image))
        let url = directory.appendingPathComponent(name)
        ioQueue.async { [weak self] in
            guard let self else { return }
            try? data.write(to: url, options: .atomic)
            self.storesSincePrune += 1
            if self.storesSincePrune >= self.pruneInterval {
                self.storesSincePrune = 0
                self.pruneIfNeeded()
            }
        }
    }

    private static func cost(_ image: NSImage) -> Int {
        let fallbackW = Int(image.size.width), fallbackH = Int(image.size.height)
        guard let rep = image.representations.first else { return fallbackW * fallbackH * 4 }
        let pixelsWide = rep.pixelsWide > 0 ? rep.pixelsWide : fallbackW
        let pixelsHigh = rep.pixelsHigh > 0 ? rep.pixelsHigh : fallbackH
        return pixelsWide * pixelsHigh * 4
    }

    /// 文件名直接取 URL 路径最后一段（如 ce13baee...~tplv-shrink:640:0.image）。
    static func fileName(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
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


final class AsyncSemaphore: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let priority: Int
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private let lock = NSLock()
    private var permits: Int
    private var waiters: [Waiter] = []
    private var nextSequence: UInt64 = 0

    init(permits: Int) {
        self.permits = permits
    }

    func acquire(priority: Int = .max) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                if permits > 0 {
                    permits -= 1
                    lock.unlock()
                    cont.resume()
                } else {
                    waiters.append(Waiter(id: id, priority: priority, sequence: nextSequence, continuation: cont))
                    nextSequence += 1
                    // 维持按优先级排序；同优先级按入队顺序（sequence）保持稳定。
                    waiters.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.sequence < $1.sequence }
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                lock.unlock()
                w.continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            permits += 1
            lock.unlock()
        } else {
            let w = waiters.removeFirst()
            lock.unlock()
            w.continuation.resume()
        }
    }
}


final class CoverDownloader: @unchecked Sendable {
    static let shared = CoverDownloader()

    private let semaphore = AsyncSemaphore(permits: 10)
    private let lock = NSLock()
    private var inflight: [String: Task<Data, Error>] = [:]

    func download(urlString: String, url: URL, priority: Int = .max) async throws -> Data {
        let key = CoverCache.fileName(urlString) ?? url.lastPathComponent
        if let existing = inflightTask(key) {
            return try await existing.value
        }
        let task = Task<Data, Error> {
            defer { self.removeInflight(key) }
            try await self.semaphore.acquire(priority: priority)
            defer { self.semaphore.release() }
            return try await Self.fetch(url: url)
        }
        putInflight(key, task)
        return try await task.value
    }

    private func inflightTask(_ key: String) -> Task<Data, Error>? {
        lock.lock(); defer { lock.unlock() }
        return inflight[key]
    }

    private func putInflight(_ key: String, _ task: Task<Data, Error>) {
        lock.lock(); defer { lock.unlock() }
        inflight[key] = task
    }

    private func removeInflight(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        inflight[key] = nil
    }

    private nonisolated static func fetch(url: URL) async throws -> Data {
        do {
            return try await Self.fetchOnce(url: url)
        } catch {
            guard let fallback = Self.fallbackURL(url) else { throw error }
            return try await Self.fetchOnce(url: fallback)
        }
    }

    private nonisolated static func fetchOnce(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private nonisolated static func fallbackURL(_ url: URL) -> URL? {
        guard let host = url.host,
              host.range(of: "^p\\d+-novel\\.byteimg\\.com$", options: .regularExpression) != nil,
              host.hasPrefix("p1-") == false else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "p1-novel.byteimg.com"
        return components?.url
    }
}

struct CoverImageView: View {
    let urlString: String
    var priority: Int = .max
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
        guard !urlString.isEmpty, let url = URL(string: urlString) else { failed = true; Log.shared.warn("cover 失败：空/非法 URL \(urlString)"); return }
        if let cached = CoverCache.shared.cachedImage(for: urlString) {
            image = cached
            return
        }
        do {
            let data = try await CoverDownloader.shared.download(urlString: urlString, url: url, priority: priority)
            guard !Task.isCancelled else { Log.shared.debug("cover 取消：\(urlString)"); return }
            guard let img = NSImage(data: data) else { failed = true; Log.shared.warn("cover 解码失败：\(urlString) bytes=\(data.count)"); return }
            CoverCache.shared.store(data: data, image: img, for: urlString)
            image = img
            Log.shared.debug("cover 成功：\(urlString) bytes=\(data.count)")
        } catch {
            if !Task.isCancelled { failed = true; Log.shared.warn("cover 下载失败：\(urlString) \(error.localizedDescription)") }
        }
    }
}
