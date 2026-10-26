// SPDX-License-Identifier: GPL-3.0-only
// 封面图磁盘缓存：以封面 URL 为键，把图片落到应用支持目录，避免反复进入「我的-历史/收藏」
// 等页面时重新请求封面。内存层用 NSCache（自动 LRU），磁盘层带文件数上限。
// 下载由 CoverDownloader 统一调度：限制并发数并对同一 URL 去重，避免 100 张封面同时抢带宽。
import SwiftUI
import AppKit
import CryptoKit

/// 封面图缓存：内存（NSCache）+ 磁盘两层。线程安全。
final class CoverCache {
    static let shared = CoverCache()

    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private let maxFiles = 1000
    /// 磁盘写入与目录修剪放到串行后台队列，避免在 MainActor（UI 线程）上做文件写入与 stat。
    private let ioQueue = DispatchQueue(label: "hongguo.cover-cache.io", qos: .utility)
    /// 每隔多少张新落盘图才做一次全目录修剪，避免每次存图都扫描整个 covers 目录（最多 1000 个文件的 stat）。
    private let pruneInterval = 64
    /// 仅由 ioQueue 访问（store 的磁盘写入都在该串行队列上执行）。
    private var storesSincePrune = 0

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

    func store(data: Data, image: NSImage, for urlString: String) {
        guard !urlString.isEmpty, Self.isValidImageData(data) else { return }
        let key = Self.key(urlString)
        // 内存层复用调用方已解码的图，避免二次解码（decode 开销远大于本次内存写）。
        memory.setObject(image, forKey: key as NSString)
        let url = directory.appendingPathComponent(key + ".img")
        // 磁盘 IO 移出主线程；修剪按间隔节流，避免每张图都全量扫描目录。
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

    /// 极小开销校验：只读文件头魔数判断是否为常见图片格式，避免把 HTML 错误页/截断数据写入磁盘缓存。
    /// 封面实际为 JPEG（服务端 .img/.jpg 即 JPEG），同时兼容 PNG/GIF/WebP 以防个别封面用其它格式。
    static func isValidImageData(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let b = [UInt8](data.prefix(12))
        // JPEG: FF D8 FF
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47, b[4] == 0x0D, b[5] == 0x0A, b[6] == 0x1A, b[7] == 0x0A { return true }
        // GIF: 47 49 46 38 ("GIF8")
        if b.count >= 4, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return true }
        // WebP: RIFF .... WEBP
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }
        return false
    }

    /// 用 URL 字符串的 SHA-256 作为文件名，避免 URL 中的非法字符与超长路径。
    static func key(_ urlString: String) -> String {
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

/// 支持取消 + 优先级的异步信号量：限制并发，等待者按优先级（数值越小越优先，同优先级按 FIFO）排队，
/// 任务取消时从队列移除并抛 CancellationError。用锁保护状态，acquire/release 均为普通方法（release 可同步调用，便于放入 defer）。
/// release 时立即唤醒队首（最高优先级）等待者，形成滑动窗口：一个完成即让下一个进入，无需等整批结束。
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

/// 封面下载调度器：限制并发下载数（默认 10），并对同一 URL 的并发请求去重。
/// 下载按优先级排队（数值越小越优先，同优先级 FIFO），保证榜单首屏（前几项）先于后续滚动项。
/// 返回下载到的原始 Data，图片解码与 UI 状态更新留在调用方（MainActor）完成。
final class CoverDownloader: @unchecked Sendable {
    static let shared = CoverDownloader()

    private let semaphore = AsyncSemaphore(permits: 10)
    private let lock = NSLock()
    private var inflight: [String: Task<Data, Error>] = [:]

    func download(urlString: String, url: URL, priority: Int = .max) async throws -> Data {
        let key = CoverCache.key(urlString)
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
            // 字节跳动图片 CDN 的 pN-novel.byteimg.com 是多节点镜像，同一路径在所有节点均可访问。
            // 当某节点（如 p6）在当前网络下 TLS 握手/连接失败时，回退到健康节点（p1）重试同一路径。
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

    /// 把 pN-novel.byteimg.com 换成 p1-novel.byteimg.com；非该域名的 URL 返回 nil。
    private nonisolated static func fallbackURL(_ url: URL) -> URL? {
        guard let host = url.host,
              host.range(of: "^p\\d+-novel\\.byteimg\\.com$", options: .regularExpression) != nil,
              host.hasPrefix("p1-") == false else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "p1-novel.byteimg.com"
        return components?.url
    }
}

/// 封面图视图：磁盘缓存优先，未命中时经下载队列（并发受限 + 优先级）下载并缓存。
/// 尺寸/圆角由调用方通过 frame/clip 控制。
struct CoverImageView: View {
    let urlString: String
    /// 下载优先级：数值越小越优先（列表首屏项传入较小的索引即可先于后续滚动项加载）。
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
