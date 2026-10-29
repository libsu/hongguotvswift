// SPDX-License-Identifier: GPL-3.0-only
// 封面缓存与下载调度共享层
// 只管理磁盘文件并对外传递本地路径（URL）
import Foundation

/// 封面图磁盘缓存：只负责落地与裁剪，命中时返回本地文件路径
final class CoverCache {
    static let shared = CoverCache()

    private let directory: URL
    private let maxFiles = 1000
    private let pruneInterval = 64
    private let ioQueue = DispatchQueue(label: "hongguo.cover-cache.io", qos: .utility)
    private var storesSincePrune = 0

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTV/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 已缓存的封面路径
    func cachedURL(for urlString: String) -> URL? {
        guard let name = Self.fileName(urlString) else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 写入封面 落盘在后台串行队列执行
    @discardableResult
    func store(data: Data, for urlString: String) -> URL? {
        guard let name = Self.fileName(urlString) else { return nil }
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
        return url
    }

    /// 文件名直接取 URL 路径最后一段（如 ce13baee...~tplv-shrink:640:0.image）
    static func fileName(_ urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private func pruneIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        func modDate(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let sorted = files.sorted { modDate($0) > modDate($1) }
        guard sorted.count > maxFiles else { return }
        for url in sorted.dropFirst(maxFiles) { try? FileManager.default.removeItem(at: url) }
    }
}

/// 简易异步信号量：按优先级（数值越小越先）+ 入队顺序公平出队
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

    init(permits: Int) { self.permits = permits }

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
                    waiters.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.sequence < $1.sequence }
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            guard let idx = waiters.firstIndex(where: { $0.id == id }) else { lock.unlock(); return }
            let w = waiters.remove(at: idx)
            lock.unlock()
            w.continuation.resume(throwing: CancellationError())
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

/// 封面下载调度：并发受限 + 同 URL 去重 + CDN 节点回退
final class CoverDownloader: @unchecked Sendable {
    static let shared = CoverDownloader()

    private let semaphore = AsyncSemaphore(permits: 10)
    private let lock = NSLock()
    private var inflight: [String: Task<Data, Error>] = [:]

    func download(urlString: String, url: URL, priority: Int = .max) async throws -> URL {
        let key = CoverCache.fileName(urlString) ?? url.lastPathComponent
        let task: Task<Data, Error> = {
            lock.lock(); defer { lock.unlock() }
            if let existing = inflight[key] { return existing }
            let t = Task<Data, Error> {
                defer { self.lock.lock(); self.inflight[key] = nil; self.lock.unlock() }
                try await self.semaphore.acquire(priority: priority)
                defer { self.semaphore.release() }
                return try await Self.fetch(url: url)
            }
            inflight[key] = t
            return t
        }()
        let data = try await task.value
        guard let local = CoverCache.shared.store(data: data, for: urlString) else { throw URLError(.badURL) }
        return local
    }

    private nonisolated static func fetch(url: URL) async throws -> Data {
        do {
            return try await fetchOnce(url: url)
        } catch {
            guard let fallback = fallbackURL(url) else { throw error }
            guard let data = try? await fetchOnce(url: fallback) else { throw error }
            return data
        }
    }

    private nonisolated static func fetchOnce(url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private nonisolated static func fallbackURL(_ url: URL) -> URL? {
        guard let host = url.host,
              host.range(of: "^p\\d+-novel\\.byteimg\\.com$", options: .regularExpression) != nil,
              !host.hasPrefix("p1-") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "p1-novel.byteimg.com"
        return components?.url
    }
}
