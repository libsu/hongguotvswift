// SPDX-License-Identifier: GPL-3.0-only
// 替代 RemoteVideo + HttpServer 的媒体层：AVAssetResourceLoaderDelegate 直接取流 + 解密，
// 回喂 AVPlayer。每个请求带完整 dataRequest（offset/length/是否 Range），
// 按 offset/length 拉取加密数据 → MediaCrypto.decrypt → respond。
import Foundation
import AVFoundation

/// 供播放器使用的自定义 scheme；Info.plist 无需额外声明即可用。
enum MediaScheme {
    static let name = "hongguo"
    /// 构造一个指向某集的自定义 scheme URL。
    static func url(episodeID: String) -> URL {
        var components = URLComponents()
        components.scheme = name
        components.host = "episode"
        components.path = "/" + episodeID
        guard let url = components.url else {
            // 理论上不会走到这里（scheme/host/path 均合法）。
            return URL(string: "\(name)://episode/\(episodeID)")!
        }
        return url
    }
}

/// 一个播放会话的资源加载委托，负责：预取头部 → 解析加密索引 → 按需取流 + 逐段解密。
/// 生命周期与单个 AVPlayerItem 绑定；切集/切清晰度时由 Model 作废旧会话。
final class ResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    /// 单个加密渲染流的取流信息。
    struct Stream {
        let url: String
        let key: [UInt8]?
    }

    /// 取流信息 + 实际清晰度。
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

    // 上游 RemoteVideo 状态。由独立串行队列 + NSLock 保护，避免与 MainActor 上的 UI/网络任务
    // （如相关作品请求）竞争，导致 AVPlayer 的探测请求被延迟而超时。
    private var prepared: MediaCrypto.Prepared?
    private var total: Int64 = 0
    /// 预热时预先解析好的索引，避免 play 再次取流。首次取流拷贝到 prepared 后即置 nil 释放，避免双份持有。
    private var seed: MediaFetcher.Prepared?
    /// 预取的「开头第一段已解密媒体数据」（起始偏移 + 字节），切集命中时直接回喂。
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
        // 在独立串行队列上启动处理，避免依赖 MainActor 调度（MainActor 被 UI/相关作品请求占用时会导致延迟）。
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
        // AVPlayer 取消的请求无需特别清理；下层 URLSession data task 会自然结束。
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
                // 索引已拷贝到 prepared，释放 seed 大字段（header/samples/mediaPrefix），避免双份持有。
                self.seed = nil
            } else {
                try await prepare()
            }
        }
        guard let (prepared, total) = currentPrepared() else {
            throw NSError(domain: "HongguoMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: "视频索引不可用"])
        }

        if let info = request.contentInformationRequest {
            // contentType 必须是 AVFoundation 认识的 UTI（MP4 为 public.mpeg-4，属于 AVURLAsset.audiovisualTypes()），
            // 而非 MIME 类型。错误的值会让 AVURLAsset 判定为不受支持的媒体类型。
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
        // 关键优化：请求完全落在已缓存的解密头（ftyp+moov）范围内时，直接从内存取，
        // 不再发 HTTP 请求。AVPlayer 的首次 2 字节探测会命中这里，瞬时响应，避免因网络延迟导致探测超时。
        if end < Int64(prepared.header.count) {
            let clear = Array(prepared.header[Int(start)...Int(end)])
            dataRequest.respond(with: Data(clear))
            request.finishLoading()
            Log.shared.info("media \(episodeID) range done: 回喂 \(clear.count)B")
            return
        }
        // 命中预取的「开头第一段媒体数据」：请求区间完全落在已预取范围内时，直接从内存回喂，
        // 不发网络请求，消除切集时的首包延迟。
        if let mpStart = mediaPrefixStart, !mediaPrefix.isEmpty,
           start >= mpStart, end < mpStart + Int64(mediaPrefix.count) {
            let lo = Int(start - mpStart), hi = Int(end - mpStart)
            let clear = Array(mediaPrefix[lo...hi])
            dataRequest.respond(with: Data(clear))
            request.finishLoading()
            Log.shared.info("media \(episodeID) range done: 回喂预取段 \(clear.count)B")
            return
        }
        // 跨 header 边界：前半段缓存在内存（ftyp+moov），后半段远程取流 + 解密。
        let remoteStart: Int64
        if start < Int64(prepared.header.count) {
            let headerPart = Array(prepared.header[Int(start)..<prepared.header.count])
            dataRequest.respond(with: Data(headerPart))
            remoteStart = Int64(prepared.header.count)
        } else {
            remoteStart = start
        }
        // 远程取流 + 解密：MediaFetcher.range 有单段 < 8MB 的硬限制，而 AVPlayer 在
        // requestsAllDataToEndOfResource 时可能一次性请求远超该上限的区间（甚至整个文件）。
        // 这里改为「有界分块 respond」：每 4MB 解密后立即回喂，不一次性累积整段到内存，
        // 避免对超大文件 reserveCapacity/append 导致 OOM 崩溃。剩余区间由 AVPlayer 继续请求。
        let fedTo = await fetchRangeDecrypted(from: remoteStart, to: end, prepared: prepared, total: total) { decrypted in
            dataRequest.respond(with: Data(decrypted))
        }
        // 若一个字节都没喂成功（如 URL 已失效/CND 内容漂移），以错误结束，让 AVPlayer 感知失败
        // 并停止无谓地重复请求同一失效范围；否则按已回喂范围正常结束，剩余由 AVPlayer 续传。
        if fedTo < remoteStart { throw NSError(domain: "HongguoMedia", code: 12, userInfo: [NSLocalizedDescriptionKey: "当前视频源不可用，请切换清晰度或重试"]) }
        request.finishLoading()
        Log.shared.info("media \(episodeID) range done: 回喂 \(fedTo - remoteStart + 1)B\(fedTo < end ? "（未到末尾，后续续传）" : "")")
    }

    /// 远程取流 + 逐段解密，每段解密后立即回调（通常为 respond），避免整段缓存。
    /// MediaFetcher.range 的单段上限（<8MB）低于 AVPlayer 的大范围请求，这里按固定步长切分，
    /// 每段以其在文件中的绝对 offset 作为 decrypt 的 start，保证 CTR 计数器正确。
    /// 返回最后一个已成功回喂块的末尾偏移（可能 < end），调用方据此结束本次 loading request。
    @discardableResult
    private func fetchRangeDecrypted(from start: Int64, to end: Int64, prepared: MediaCrypto.Prepared, total: Int64, onChunk: ([UInt8]) -> Void) async -> Int64 {
        // 单段步长（略低于 8MB 上限，留余量）：4MB。
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
                // 该块取流/解密失败：停止续喂，让本次请求到此为止，剩余由 AVPlayer 后续重发。
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
        // 释放大字段（索引 + 预取段 + seed），切集/关闭时显式清空，避免冗余副本残留。
        stateLock.lock()
        prepared = nil
        total = 0
        mediaPrefix = []
        mediaPrefixStart = nil
        stateLock.unlock()
        seed = nil
    }
}
