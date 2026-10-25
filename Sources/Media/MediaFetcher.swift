// SPDX-License-Identifier: GPL-3.0-only
// 媒体层取流/解密的基础设施：把「预取头部 → 解析加密索引」这一步抽成可复用函数，
// 供 ResourceLoader（懒加载）与 Model 的预热（warm）共用，避免重复取流。
import Foundation

enum MediaFetcher {
    /// 拉取一个加密字节段（对齐 上游 RemoteVideo.range）。
    /// 用 NSURLSession 同步段请求，返回原始字节与内容总长。
    struct RangeResult {
        let bytes: [UInt8]
        let total: Int64
    }

    static func range(url: String, start: Int64, end: Int64, knownTotal: Int64, session: URLSession) async throws -> RangeResult {
        guard start >= 0, end >= start, end - start < 8 * 1024 * 1024 else {
            throw MediaCryptoError("分段范围异常")
        }
        guard let target = URL(string: url) else { throw MediaCryptoError("播放地址异常") }

        // 媒体取流易受网络抖动/DNS/超时影响，且中途失败会导致 AVPlayer 静默卡死（既不到
        // DidPlayToEndTime、也不置 status=failed）。对瞬时错误做指数退避重试，确定性错误不重试。
        var lastError: Error = MediaCryptoError("视频服务器无响应")
        for attempt in 0..<3 {
            do {
                return try await rangeOnce(target: target, start: start, end: end, knownTotal: knownTotal, session: session)
            } catch {
                lastError = error
                guard Self.isTransient(error), attempt < 2 else { throw error }
                // 退避 0.4s / 1.6s，避免对故障源雪崩重试。
                try await Task.sleep(nanoseconds: UInt64(400_000_000) << (UInt64(attempt) * 2))
            }
        }
        throw lastError
    }

    /// 单次分段请求。与重试拆开，便于单元测试与避免重试逻辑污染。
    private static func rangeOnce(target: URL, start: Int64, end: Int64, knownTotal: Int64, session: URLSession) async throws -> RangeResult {
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        request.setValue(VendorConstants.VIDEO_UA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "HongguoMedia", code: 4, userInfo: [NSLocalizedDescriptionKey: "视频服务器无响应"])
        }
        guard http.statusCode == 206 else {
            throw NSError(domain: "HongguoMedia", code: 5, userInfo: [NSLocalizedDescriptionKey: "视频服务器不支持分段读取（HTTP \(http.statusCode)）"])
        }
        guard let contentRange = http.value(forHTTPHeaderField: "Content-Range") else {
            throw NSError(domain: "HongguoMedia", code: 6, userInfo: [NSLocalizedDescriptionKey: "视频分段响应异常"])
        }
        let pattern = #"bytes (\d+)-(\d+)/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: contentRange, range: NSRange(contentRange.startIndex..<contentRange.endIndex, in: contentRange)) else {
            throw NSError(domain: "HongguoMedia", code: 7, userInfo: [NSLocalizedDescriptionKey: "视频分段响应异常"])
        }
        guard match.numberOfRanges == 4,
              let beginR = Range(match.range(at: 1), in: contentRange),
              let finishR = Range(match.range(at: 2), in: contentRange),
              let sizeR = Range(match.range(at: 3), in: contentRange),
              let begin = Int64(contentRange[beginR]),
              let finish = Int64(contentRange[finishR]),
              let full = Int64(contentRange[sizeR]) else {
            throw NSError(domain: "HongguoMedia", code: 8, userInfo: [NSLocalizedDescriptionKey: "视频分段范围不匹配"])
        }
        let last = min(end, full - 1)
        guard begin == start && finish == last && full > 0 else {
            throw NSError(domain: "HongguoMedia", code: 9, userInfo: [NSLocalizedDescriptionKey: "视频分段范围不匹配"])
        }
        if knownTotal != 0 && full != knownTotal {
            throw NSError(domain: "HongguoMedia", code: 10, userInfo: [NSLocalizedDescriptionKey: "视频资源已变化，请重试"])
        }
        let n = last - start + 1
        guard Int64(data.count) >= n else {
            throw NSError(domain: "HongguoMedia", code: 11, userInfo: [NSLocalizedDescriptionKey: "视频分段为空"])
        }
        return RangeResult(bytes: Array(data.prefix(Int(n))), total: full)
    }

    /// 判断错误是否值得重试：网络/超时/DNS/HTTP 5xx 视为瞬时；范围/格式不匹配等确定性错误不重试。
    private static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable, .cancelled:
                return true
            default: return false
            }
        }
        if let ns = error as NSError?, ns.domain == "HongguoMedia", (ns.code == 4 || ns.code == 5 || ns.code == 10) {
            // code 4 = 无响应（服务端瞬时抖动）；code 5 = 非 206（可能被限流）；
            // code 10 = 资源已变化（CDN 内容漂移，换一次请求可能拿到与 knownTotal 一致的内容）。
            return true
        }
        return false
    }

    struct Prepared {
        let prepared: MediaCrypto.Prepared
        let total: Int64
        /// 可选预取的「开头第一段已解密媒体数据」：起始绝对偏移 + 解密后字节。
        /// nil 表示未预取媒体段（仅预取了头部索引）。
        let mediaPrefixStart: Int64?
        let mediaPrefix: [UInt8]

        init(prepared: MediaCrypto.Prepared, total: Int64, mediaPrefixStart: Int64? = nil, mediaPrefix: [UInt8] = []) {
            self.prepared = prepared; self.total = total
            self.mediaPrefixStart = mediaPrefixStart; self.mediaPrefix = mediaPrefix
        }
    }

    /// 上游 RemoteVideo.prepare：预取 256KB 前缀 → 计算 headerEnd → 补足头部 → 解析密文索引。
    static func prepare(url: String, key: [UInt8]?, session: URLSession) async throws -> Prepared {
        let first = try await range(url: url, start: 0, end: 256 * 1024 - 1, knownTotal: 0, session: session)
        Log.shared.info("media prepare: 首段 \(first.bytes.count)B total=\(first.total)")
        var prefix = first.bytes
        let total = first.total
        let end = try MediaCrypto.headerEnd(prefix, total: total)
        Log.shared.info("media prepare: headerEnd=\(end)")
        if end > prefix.count {
            let rest = try await range(url: url, start: Int64(prefix.count), end: Int64(end - 1), knownTotal: total, session: session)
            prefix += rest.bytes
        } else {
            prefix = Array(prefix.prefix(end))
        }
        Log.shared.info("media prepare: 头部 \(prefix.count)B，解析加密索引…")
        let prep = try MediaCrypto.prepare(prefix, key: key)
        guard prep.samples.allSatisfy({ $0.end <= total }) else {
            throw NSError(domain: "HongguoMedia", code: 2, userInfo: [NSLocalizedDescriptionKey: "视频样本超出资源大小"])
        }
        if let track = VideoTracks.videoTrack(prep.header) {
            Log.shared.info("media prepare: 视频轨道 fourcc=\(track.fourcc) coded=\(track.width)x\(track.height)")
        }
        // 调试样本写入已在主取流路径上引发卡顿，暂时注释掉（保留函数本体，需要时再启用）。
        // await saveDecryptedSampleForInspection(url: url, key: key, session: session, prepared: prep, total: total)
        return Prepared(prepared: prep, total: total)
    }

    /// 预热下一集：在 prepare（头部索引）基础上，额外预取开头第一段媒体数据（解密后），
    /// 存入 mediaPrefix 供切集时直接回喂，消除首包网络延迟。预取失败会退回到无前缀的正常 prepare。
    static func prepareWithMediaPrefix(url: String, key: [UInt8]?, session: URLSession, prefixBytes: Int = 1024 * 1024) async throws -> Prepared {
        let base = try await prepare(url: url, key: key, session: session)
        guard let firstSample = base.prepared.samples.first else { return base }
        let start = firstSample.start
        // 取开头一段媒体数据：起始为第一个加密样本，长度不超过 prefixBytes 与文件末尾。
        let end = min(start + Int64(prefixBytes) - 1, base.total - 1)
        guard end >= start else { return base }
        do {
            let raw = try await range(url: url, start: start, end: end, knownTotal: base.total, session: session)
            let clear = try MediaCrypto.decrypt(raw.bytes, start: start, key: key, prepared: base.prepared)
            Log.shared.info("media prepare: 预取首段媒体 \(start)-\(end) 解密 \(clear.count)B")
            return Prepared(prepared: base.prepared, total: base.total, mediaPrefixStart: start, mediaPrefix: clear)
        } catch {
            Log.shared.warn("media prepare: 预取首段媒体失败，退回无前缀：\(error.localizedDescription)")
            return base
        }
    }

    /// 设计目标（调试）：把解密后的 MP4 头 + 开头一小段解密媒体数据拼成文件，存到日志文件夹，
    /// 供用 ffprobe/MediaInfo 查看真实编码、分辨率与容器信息（不承诺可完整播放）。
    /// 调用处已在主取流路径上被注释（避免写入卡顿），保留函数本体以便需要时一键启用。
    private static func saveDecryptedSampleForInspection(url: String, key: [UInt8]?, session: URLSession, prepared: MediaCrypto.Prepared, total: Int64) async {
        do {
            let header = prepared.header
            // mdat 起始：取第一个加密样本的起始偏移（通常紧随 moov 之后）。
            let mdatStart = prepared.samples.first?.start ?? Int64(header.count)
            let sampleBytes = 256 * 1024
            let raw = try await range(url: url, start: mdatStart, end: mdatStart + Int64(sampleBytes) - 1, knownTotal: total, session: session)
            let clear = try MediaCrypto.decrypt(raw.bytes, start: mdatStart, key: key, prepared: prepared)
            var payload = header
            payload.append(contentsOf: clear)

            let fm = FileManager.default
            let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HongguoTVMac", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let fileName = "decrypted-sample-\(stamp).mp4"
            let urlOut = dir.appendingPathComponent(fileName)
            try Data(payload).write(to: urlOut)
            Log.shared.info("media prepare: 已保存解密样本 \(urlOut.path)（头 \(header.count)B + 媒体 \(clear.count)B）")
        } catch {
            Log.shared.warn("media prepare: 保存解密样本失败：\(error.localizedDescription)")
        }
    }
}
