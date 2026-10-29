// SPDX-License-Identifier: GPL-3.0-only
// 媒体层：AVAssetResourceLoaderDelegate 直接取流 + 解密后回喂 AVPlayer（替代 RemoteVideo + 本地 HttpServer）。
import Foundation
import AVFoundation

/// 供播放器使用的自定义 scheme（Info.plist 无需声明）。
enum MediaScheme {
    static let name = "hongguo"
    static func url(episodeID: String) -> URL {
        var components = URLComponents()
        components.scheme = name
        components.host = "episode"
        components.path = "/" + episodeID
        guard let url = components.url else {
            // 理论上不可达（scheme/host/path 均合法）。
            return URL(string: "\(name)://episode/\(episodeID)")!
        }
        return url
    }
}

/// 单个 `AVPlayerItem` 的加载委托，生命周期与 item 绑定；切集/切清晰度时由 Model 作废旧会话。
final class ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    struct Stream {
        let url: String
        let key: [UInt8]?
    }

    struct StreamAndQuality {
        let url: String
        let key: [UInt8]?
        let quality: String
    }

    private let stream: Stream
    private let episodeID: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "com.hongguotvswift.app.resource")
    private let stateLock = NSLock()
    private var requestID = 0

    // 由独立串行队列 + NSLock 保护：若在 MainActor 上处理，UI/相关作品请求会占住主线程，
    // 导致 AVPlayer 的探测请求被延迟甚至超时。
    private var prepared: MediaCrypto.Prepared?
    private var total: Int64 = 0
    /// 预热时已解析的索引，首次取流拷到 prepared 后置 nil，避免双份持有。
    private var seed: MediaFetcher.Prepared?
    /// 预取的首段已解密媒体数据（起始偏移 + 字节），切集命中时直接回喂。
    private var mediaPrefixStart: Int64?
    private var mediaPrefix: [UInt8] = []

    init(stream: Stream, episodeID: String, session: URLSession = ResourceLoader.defaultSession(), seed: MediaFetcher.Prepared? = nil) {
        self.stream = stream
        self.episodeID = episodeID
        self.session = session
        self.seed = seed
        self.mediaPrefixStart = seed?.mediaPrefixStart
        self.mediaPrefix = seed?.mediaPrefix ?? []
        super.init()
    }

    nonisolated static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    var delegateQueue: DispatchQueue { queue }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        requestID += 1
        let id = requestID
        Log.shared.info("media \(episodeID) request#\(id) offset=\(loadingRequest.dataRequest?.requestedOffset ?? -1) len=\(loadingRequest.dataRequest?.requestedLength ?? -1) all=\(loadingRequest.dataRequest?.requestsAllDataToEndOfResource ?? false) info=\(loadingRequest.contentInformationRequest != nil) data=\(loadingRequest.dataRequest != nil)")
        // 独立串行队列，不依赖 MainActor（后者可能被 UI/相关作品请求占住）。
        queue.async { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.handle(loadingRequest)
                    Log.shared.debug("media \(self.episodeID) request#\(id) done")
                } catch {
                    Log.shared.warn("media \(self.episodeID) request#\(id) failed: \(error.localizedDescription)")
                    loadingRequest.finishLoading(with: error)
                }
            }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // 无需清理：下层 URLSession 任务自然结束。
    }

    // MARK: - 处理

    private func currentPrepared() -> (MediaCrypto.Prepared, Int64)? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let p = prepared else { return nil }
        return (p, total)
    }

    private func storePrepared(_ p: MediaCrypto.Prepared, total: Int64) {
        stateLock.lock(); prepared = p; self.total = total; stateLock.unlock()
    }

    private func handle(_ request: AVAssetResourceLoadingRequest) async throws {
        if currentPrepared() == nil {
            if let seed {
                storePrepared(seed.prepared, total: seed.total)
                // 索引已拷入 prepared，释放 seed 的大字段避免双份持有。
                self.seed = nil
            } else {
                try await prepare()
            }
        }
        guard let (prepared, total) = currentPrepared() else {
            throw NSError(domain: "HongguoMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频索引不可用"])
        }

        if let info = request.contentInformationRequest {
            // contentType 必须是 AVFoundation 认识的 UTI（MP4 为 public.mpeg-4）而非 MIME；
            // 错传 MIME 会让 AVURLAsset 判定为不支持。
            let allowed = info.allowedContentTypes ?? []
            let chosen: String
            if allowed.contains("public.mpeg-4") { chosen = "public.mpeg-4" }
            else if allowed.contains("com.apple.m4v-video") { chosen = "com.apple.m4v-video" }
            else if !allowed.isEmpty { chosen = allowed[0] }
            else { chosen = "public.mpeg-4" }
            info.contentType = chosen
            info.isByteRangeAccessSupported = true
            info.contentLength = total
            Log.shared.info("media \(episodeID) contentType=\(chosen) allowed=\(allowed.joined(separator: ",")) contentLength=\(total)")
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let start = dataRequest.requestedOffset
        let requestedEnd: Int64
        if dataRequest.requestsAllDataToEndOfResource {
            requestedEnd = total - 1
        } else {
            requestedEnd = start + Int64(dataRequest.requestedLength) - 1
        }
        let end = min(requestedEnd, total - 1)
        if start >= total || end < start {
            request.finishLoading()
            return
        }
        Log.shared.info("media \(episodeID) range \(start)-\(end) (\(end - start + 1)B)")
        // 完全命中已解密的头（ftyp+moov）时直接内存回喂：AVPlayer 首次 2 字节探测会命中，
        // 避免网络延迟导致探测超时。
        if end < Int64(prepared.header.count) {
            let clear = Array(prepared.header[Int(start)...Int(end)])
            dataRequest.respond(with: Data(clear))
            request.finishLoading()
            // Log.shared.info("media \(episodeID) range done: 回喂 \(clear.count)B")
            return
        }
        // 命中预取的首段媒体数据时直接回喂，消除切集首包延迟。
        if let mpStart = mediaPrefixStart, !mediaPrefix.isEmpty,
           start >= mpStart, end < mpStart + Int64(mediaPrefix.count) {
            let lo = Int(start - mpStart), hi = Int(end - mpStart)
            let clear = Array(mediaPrefix[lo...hi])
            dataRequest.respond(with: Data(clear))
            request.finishLoading()
            Log.shared.info("media \(episodeID) range done: 回喂预取段 \(clear.count)B")
            return
        }
        // 跨 header 边界：前半段内存回喂，后半段远程取流 + 解密。
        let remoteStart: Int64
        if start < Int64(prepared.header.count) {
            let headerPart = Array(prepared.header[Int(start)..<prepared.header.count])
            dataRequest.respond(with: Data(headerPart))
            remoteStart = Int64(prepared.header.count)
        } else {
            remoteStart = start
        }
        // MediaFetcher.range 单段硬限 8MB，而 requestsAllDataToEndOfResource 可能请求整个文件；
        // 这里按 4MB 有界分块回喂，避免超大文件 OOM。
        let fedTo = await fetchRangeDecrypted(from: remoteStart, to: end, prepared: prepared, total: total) { decrypted in
            dataRequest.respond(with: Data(decrypted))
        }
        // 一个字节都没喂成功（URL 失效/CDN 内容漂移）时抛错，让 AVPlayer 停止重试同一失效范围；
        // 否则正常结束，剩余由 AVPlayer 续传。
        if fedTo < remoteStart { throw NSError(domain: "HongguoMedia", code: 12, userInfo: [NSLocalizedDescriptionKey: "当前视频源不可用，请切换清晰度或重试"]) }
        request.finishLoading()
        Log.shared.info("media \(episodeID) range done: 回喂 \(fedTo - remoteStart + 1)B\(fedTo < end ? "（未到末尾，后续续传）" : "")")
    }

    /// 远程取流 + 逐段解密，每段立即回调不累积；每段以文件绝对 offset 作 start，保证 CTR 计数器正确。
    /// 返回最后成功回喂块的末尾偏移（可能 < end）。
    @discardableResult
    private func fetchRangeDecrypted(from start: Int64, to end: Int64, prepared: MediaCrypto.Prepared, total: Int64, onChunk: ([UInt8]) -> Void) async -> Int64 {
        // 4MB，低于 MediaFetcher.range 的 8MB 单段上限。
        let step: Int64 = 4 * 1024 * 1024
        var cursor = start
        var fedTo = start - 1
        while cursor <= end {
            let segEnd = min(cursor + step - 1, end)
            do {
                let raw = try await MediaFetcher.range(url: stream.url, start: cursor, end: segEnd, knownTotal: total, session: session)
                let decrypted = try MediaCrypto.decrypt(raw.bytes, start: cursor, key: stream.key, prepared: prepared)
                onChunk(decrypted)
                fedTo = segEnd
            } catch {
                // 该块失败即停止续喂，剩余由 AVPlayer 后续重发。
                Log.shared.warn("media \(episodeID) range 分段失败 @\(cursor)-\(segEnd)：\(error.localizedDescription)")
                break
            }
            cursor = segEnd + 1
        }
        return fedTo
    }

    private func prepare() async throws {
        let result = try await MediaFetcher.prepare(url: stream.url, key: stream.key, session: session)
        storePrepared(result.prepared, total: result.total)
        Log.shared.debug("media \(episodeID) prepared: total=\(result.total), samples=\(result.prepared.samples.count), key=\(stream.key != nil ? "yes" : "no")")
    }

    func close() {
        // 显式释放大字段，避免冗余副本残留。
        stateLock.lock()
        prepared = nil
        total = 0
        mediaPrefix = []
        mediaPrefixStart = nil
        stateLock.unlock()
        seed = nil
    }
}
