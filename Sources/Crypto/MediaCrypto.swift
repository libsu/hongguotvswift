// SPDX-License-Identifier: GPL-3.0-only
// 内容密钥派生、URL 解密、MP4 容器(ftyp/moov/trak/stbl/saiz/saio/stsz/stsc/stco/co64/sinf/frma)
// 解析，以及 AES-CTR 样本级解密。
import Foundation

/// 媒体解密/索引解析错误（生产环境可捕获，避免崩溃）。
struct MediaCryptoError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}

enum MediaCrypto {
    struct Sample {
        let start: Int64
        let end: Int64
        let iv: [UInt8]
        let encryptedOffset: Int64
        init(start: Int64, end: Int64, iv: [UInt8], encryptedOffset: Int64 = 0) {
            self.start = start; self.end = end; self.iv = iv; self.encryptedOffset = encryptedOffset
        }
    }
    struct Prepared {
        let header: [UInt8]
        let samples: [Sample]
    }

    // MARK: - 密钥与 URL

    /// 上游: deriveKey(value) —— 从 base64 内容密钥派生出 16 字节 AES 密钥。
    /// 输入来自服务端 spade_a，异常时抛错而非 precondition 崩溃。
    static func deriveKey(_ value: String) throws -> [UInt8] {
        let raw = decode64(value)
        guard raw.count >= 3 else { throw MediaCryptoError("内容密钥格式异常") }
        let length = min(raw.count - (Int(raw[0]) ^ Int(raw[1]) ^ Int(raw[2])) + 47, raw.count - 1)
        guard length >= 33 else { throw MediaCryptoError("内容密钥格式异常") }
        var work = Array(raw[1...(1 + length - 1)])
        var a = 85, b = 246
        for i in 0..<work.count {
            let old = Int(work[i])
            let previous = (i & 1 != 0) ? a : b
            if i & 1 != 0 { a = old } else { b = old }
            let v = (-21 - nonisolatedBitCount(i) + (previous ^ old))
            work[i] = UInt8(truncatingIfNeeded: v)
        }
        let ascii = String(bytes: work[1..<33], encoding: .ascii) ?? ""
        let key = hexBytes(ascii)
        guard key.count == 16 else { throw MediaCryptoError("内容密钥格式异常") }
        return key
    }
    /// Integer.bitCount(i)
    private static func nonisolatedBitCount(_ n: Int) -> Int { n.nonzeroBitCount }

    /// 上游: decryptUrl(value, seed) —— 解密带盐的播放地址。
    /// 输入来自服务端 main_url，异常时抛错而非 precondition 崩溃。
    static func decryptUrl(_ value: String, seed: [UInt8]) throws -> String {
        let raw = decode64(value)
        guard raw.count >= 20 && raw[0] == 0xa8 && raw[2] == 1 && raw[3] == 0 else {
            throw MediaCryptoError("播放地址格式异常")
        }
        let constants = hexBytes("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
        let h = digest("SHA-512", digest("SHA-512", seed) + constants)
        let encrypted = Array(raw[4..<(4 + (raw.count - 4) / 16 * 16)])
        let bytes = aesDecrypt(Array(h[0..<16]), Array(h[16..<32]), encrypted)
        var end = bytes.count
        let padding = Int(bytes.last ?? 0)
        if padding >= 1 && padding <= 16 && padding <= end { end -= padding }
        while end > 0 && bytes[end - 1] == 0 { end -= 1 }
        guard end >= 0, end <= bytes.count, let s = String(bytes: bytes[0..<end], encoding: .utf8) else {
            throw MediaCryptoError("播放地址格式异常")
        }
        return s
    }

    // MARK: - MP4 容器

    struct Box {
        let start: Int
        let end: Int
        let body: Int
        let type: String
    }

    static func box(_ data: [UInt8], _ at: Int, _ limit: Int) -> Box? {
        if at < 0 || at + 8 > limit { return nil }
        var size = readU32(data, at)
        var header = 8
        if size == 1 {
            if at + 16 > limit { return nil }
            size = UInt32(truncatingIfNeeded: readI64(data, at + 8))
            header = 16
        }
        if size == 0 { size = UInt32(limit - at) }
        if size < UInt32(header) || size > UInt32(limit - at) { return nil }
        guard let type = String(bytes: data[(at + 4)..<(at + 8)], encoding: .ascii) else { return nil }
        return Box(start: at, end: at + Int(size), body: at + header, type: type)
    }

    static func find(_ data: [UInt8], _ type: String, _ start: Int, _ limit: Int) -> Box? {
        if limit - 8 < start { return nil }
        let target = Array(type.utf8)[0]
        for at in start...(limit - 8) {
            if data[at + 4] == target {
                if let b = box(data, at, limit), b.type == type { return b }
            }
        }
        return nil
    }

    /// 上游: headerEnd(first, total)
    /// 生产环境：任何结构异常都抛错（不崩溃），由调用方上报给播放器。
    static func headerEnd(_ first: [UInt8], total: Int64) throws -> Int {
        guard first.count >= 16, String(bytes: first[4..<8], encoding: .ascii) == "ftyp" else { throw MediaCryptoError("不支持的视频容器") }
        let ftyp = readU32(first, 0)
        guard ftyp >= 8, Int64(ftyp) + 8 <= Int64(first.count), String(bytes: first[Int(ftyp) + 4..<Int(ftyp) + 8], encoding: .ascii) == "moov" else { throw MediaCryptoError("视频索引不在文件开头") }
        let size = readU32(first, Int(ftyp))
        let end = Int64(ftyp) + Int64(size)
        guard size >= 8, end <= total, end <= 8 * 1024 * 1024 else { throw MediaCryptoError("视频索引大小异常") }
        return Int(end)
    }

    /// 上游: prepare(data, key)
    /// 生产环境：任何结构异常都抛错（不崩溃）。所有下标访问都做边界检查。
    static func prepare(_ data: [UInt8], key: [UInt8]?) throws -> Prepared {
        if key == nil { return Prepared(header: data, samples: []) }
        // 安全读取：越界即抛错。
        func u8(_ i: Int, _ ctx: String) throws -> UInt8 {
            guard i >= 0 && i < data.count else { throw MediaCryptoError("\(ctx) 越界（\(i)/\(data.count)）") }
            return data[i]
        }
        func u32At(_ i: Int, _ ctx: String) throws -> UInt32 {
            guard i >= 0 && i + 4 <= data.count else { throw MediaCryptoError("\(ctx) 越界（\(i)/\(data.count)）") }
            return readU32(data, i)
        }
        guard let moov = box(data, Int(readU32(data, 0)), data.count), moov.type == "moov" else { throw MediaCryptoError("视频索引不完整") }
        var samples: [Sample] = []
        var header = data
        var cursor = moov.body
        while cursor < moov.end {
            guard let track = box(data, cursor, moov.end) else { throw MediaCryptoError("视频轨道格式异常") }
            cursor = track.end
            if track.type != "trak" { continue }
            guard let stbl = find(data, "stbl", track.body, track.end) else { continue }
            guard let saiz = find(data, "saiz", stbl.body, stbl.end) else { continue }
            guard let saio = find(data, "saio", stbl.body, stbl.end) else { throw MediaCryptoError("视频加密索引缺失") }
            guard let stsz = find(data, "stsz", stbl.body, stbl.end) else { throw MediaCryptoError("样本索引缺失") }
            guard let stsc = find(data, "stsc", stbl.body, stbl.end) else { throw MediaCryptoError("块索引缺失") }
            guard let chunks = find(data, "stco", stbl.body, stbl.end) ?? find(data, "co64", stbl.body, stbl.end) else { throw MediaCryptoError("块偏移缺失") }

            func count(_ at: Int, _ limit: Int) throws -> Int {
                guard at + 4 <= limit else { throw MediaCryptoError("索引越界") }
                let v = readU32(data, at)
                guard v <= 200000 else { throw MediaCryptoError("索引数量过大") }
                return Int(v)
            }

            let n = try count(stsz.body + 8, stsz.end)
            let defaultSize = try u32At(stsz.body + 4, "stsz.defaultSize")
            if defaultSize == 0 && Int64(stsz.body + 12) + Int64(n) * 4 > Int64(stsz.end) { throw MediaCryptoError("样本索引截断") }
            var sizes = [Int64](repeating: 0, count: n)
            for i in 0..<n { sizes[i] = defaultSize > 0 ? Int64(defaultSize) : Int64(try u32At(stsz.body + 12 + i * 4, "stsz.sizes")) }

            let chunkCount = try count(chunks.body + 4, chunks.end)
            let width = chunks.type == "co64" ? 8 : 4
            if Int64(chunks.body + 8) + Int64(chunkCount) * Int64(width) > Int64(chunks.end) { throw MediaCryptoError("块偏移截断") }
            var offsets = [Int64](repeating: 0, count: chunkCount)
            for i in 0..<chunkCount {
                if width == 8 {
                    guard chunks.body + 8 + i * width + 8 <= chunks.end else { throw MediaCryptoError("块偏移截断") }
                    offsets[i] = readI64(data, chunks.body + 8 + i * width)
                } else {
                    offsets[i] = Int64(try u32At(chunks.body + 8 + i * width, "chunks.offset"))
                }
            }

            let entryCount = try count(stsc.body + 4, stsc.end)
            if Int64(stsc.body + 8) + Int64(entryCount) * 12 > Int64(stsc.end) || entryCount == 0 { throw MediaCryptoError("块索引截断") }
            var entries: [(UInt32, UInt32)] = []
            for i in 0..<entryCount { entries.append((try u32At(stsc.body + 8 + i * 12, "stsc.firstChunk"), try u32At(stsc.body + 12 + i * 12, "stsc.samplesPerChunk"))) }

            let sizeBase = saiz.body + 4 + ((readI32(data, saiz.body) & 1 != 0) ? 8 : 0)
            if sizeBase + 5 > saiz.end { throw MediaCryptoError("辅助索引截断") }
            let auxDefault = Int(try u8(sizeBase, "saiz.default"))
            let auxCount = try count(sizeBase + 1, saiz.end)
            if auxCount != n || (auxDefault == 0 && sizeBase + 5 + n > saiz.end) { throw MediaCryptoError("辅助索引数量不一致") }
            var auxSizes = [Int](repeating: 0, count: n)
            for i in 0..<n { auxSizes[i] = auxDefault > 0 ? auxDefault : Int(try u8(sizeBase + 5 + i, "saiz.sizes")) }

            let offsetBase = saio.body + 4 + ((readI32(data, saio.body) & 1 != 0) ? 8 : 0)
            let offsetWidth = (try u8(saio.body, "saio.version")) == 1 ? 8 : 4
            if (try count(offsetBase, saio.end)) != 1 || offsetBase + 4 + offsetWidth > saio.end { throw MediaCryptoError("不支持的辅助索引布局") }
            var aux: Int64 = (offsetWidth == 8) ? readI64(data, offsetBase + 4) : Int64(try u32At(offsetBase + 4, "saio.offset"))
            let auxEnd = aux + Int64(auxSizes.reduce(0, +))
            if aux < 0 || auxEnd > data.count { throw MediaCryptoError("辅助数据超出索引范围") }

            var sampleIndex = 0
            var entry = 0
            for chunk in 0..<offsets.count {
                while entry + 1 < entries.count && entries[entry + 1].0 <= UInt32(chunk + 1) { entry += 1 }
                let cnt = Int(entries[entry].1)
                if cnt > n - sampleIndex || entries[entry].0 > UInt32(chunk + 1) { throw MediaCryptoError("样本与块数量不一致") }
                var position = offsets[chunk]
                for _ in 0..<cnt {
                    let length = sizes[sampleIndex]
                    let auxSize = auxSizes[sampleIndex]
                    if position < 0 || length <= 0 || position > Int64.max - length || auxSize < 8 { throw MediaCryptoError("样本索引异常") }
                    let iv = Array(data[Int(aux)..<Int(aux) + 8]) + [UInt8](repeating: 0, count: 8)
                    if auxSize == 8 {
                        samples.append(Sample(start: position, end: position + length, iv: iv))
                    } else {
                        if auxSize < 10 { throw MediaCryptoError("不支持的加密样本格式") }
                        let subs = (Int(try u8(Int(aux) + 8, "aux.subs")) << 8) | Int(try u8(Int(aux) + 9, "aux.subs"))
                        if auxSize != 10 + subs * 6 { throw MediaCryptoError("加密子样本索引异常") }
                        var offset = position
                        var encrypted: Int64 = 0
                        for sub in 0..<subs {
                            let at = Int(aux) + 10 + sub * 6
                            let clear = (Int(try u8(at, "aux.clear")) << 8) | Int(try u8(at + 1, "aux.clear"))
                            let sz = Int64(try u32At(at + 2, "aux.sz"))
                            offset += Int64(clear)
                            if offset + sz > position + length { throw MediaCryptoError("加密子样本越界") }
                            if sz > 0 { samples.append(Sample(start: offset, end: offset + sz, iv: iv, encryptedOffset: encrypted)) }
                            encrypted += sz
                            offset += sz
                        }
                        if offset != position + length { throw MediaCryptoError("加密子样本长度异常") }
                    }
                    position += length
                    aux += Int64(auxSize)
                    sampleIndex += 1
                }
            }
            if sampleIndex != n { throw MediaCryptoError("视频样本不完整") }

            // 保留 frma 原始编码（AVC/HEVC），不硬编码 HEVC 标签。
            var at = stbl.body
            while at + 8 <= stbl.end {
                guard let sinf = find(data, "sinf", at, stbl.end) else { break }
                guard let frma = find(data, "frma", sinf.body, sinf.end) else { throw MediaCryptoError("原始编码格式缺失") }
                if frma.body + 4 > frma.end { throw MediaCryptoError("原始编码格式无效") }
                let original = Array(data[frma.body..<(frma.body + 4)])
                var entryAt = sinf.start - 1
                while entryAt >= stbl.body {
                    guard let type = String(bytes: data[entryAt..<(entryAt + 4)], encoding: .ascii) else {
                        entryAt -= 1; continue
                    }
                    if type == "encv" || type == "enca" {
                        for k in 0..<4 { header[entryAt + k] = original[k] }
                        break
                    }
                    entryAt -= 1
                }
                let free = Array("free".utf8)
                for k in 0..<4 { header[sinf.start + 4 + k] = free[k] }
                for k in sinf.body..<sinf.end { header[k] = 0 }
                at = sinf.end
            }
        }
        if samples.isEmpty { throw MediaCryptoError("视频加密索引不可用") }
        let sorted = samples.sorted { $0.start < $1.start }
        for i in 0..<(sorted.count - 1) where sorted[i].end > sorted[i + 1].start {
            throw MediaCryptoError("视频样本重叠")
        }
        return Prepared(header: header, samples: sorted)
    }

    // MARK: - 样本解密

    /// 上游: decrypt(data, start, key, prepared)
    static func decrypt(_ data: [UInt8], start: Int64, key: [UInt8]?, prepared: Prepared) throws -> [UInt8] {
        guard start >= 0 else { throw MediaCryptoError("解密起始位置异常") }
        var result = data
        let end = start + Int64(data.count)
        if start < Int64(prepared.header.count) {
            let headerEndIdx = min(end, Int64(prepared.header.count))
            for i in Int(start)..<Int(headerEndIdx) {
                result[i - Int(start)] = prepared.header[i]
            }
        }
        if key == nil { return result }
        let samples = prepared.samples
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) >> 1
            if samples[middle].end <= start { low = middle + 1 } else { high = middle }
        }
        for i in low..<samples.count {
            let sample = samples[i]
            if sample.start >= end { break }
            let begin = max(start, sample.start)
            let stop = min(end, sample.end)
            if begin >= stop { continue }
            let relative = begin - sample.start + sample.encryptedOffset
            let skip = Int(relative % 16)
            let counter = counterBlock(iv: sample.iv, add: relative / 16)
            let src = Array(result[Int(begin - start)..<Int(stop - start)])
            let decrypted = aesCTRBlockSkip(key!, counter, src, skip)
            for j in 0..<decrypted.count { result[Int(begin - start) + j] = decrypted[j] }
        }
        return result
    }

    /// 计算 CTR 计数器块：iv 作为 128 位大端无符号整数 + add，模 2^128。
    private static func counterBlock(iv: [UInt8], add: Int64) -> [UInt8] {
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<8 {
            hi = (hi << 8) | UInt64(iv[i])
            lo = (lo << 8) | UInt64(iv[8 + i])
        }
        let addU = UInt64(bitPattern: add)
        let (newLo, carry) = lo.addingReportingOverflow(addU)
        let newHi = hi &+ (carry ? 1 : 0)
        var out = [UInt8](repeating: 0, count: 16)
        var h = newHi, l = newLo
        for i in stride(from: 7, through: 0, by: -1) { out[i] = UInt8(h & 0xff); h >>= 8 }
        for i in stride(from: 15, through: 8, by: -1) { out[i] = UInt8(l & 0xff); l >>= 8 }
        return out
    }

    /// 等效：从 counter 产生 keystream，跳过 skip 字节后与 data 异或。
    private static func aesCTRBlockSkip(_ key: [UInt8], _ counter: [UInt8], _ data: [UInt8], _ skip: Int) -> [UInt8] {
        // 构造 padded = skip 个 0 + data，整体 CTR，再取 skip 之后。
        let padded = [UInt8](repeating: 0, count: skip) + data
        let raw = aesCTR(key, counter: counter, padded)
        return Array(raw[skip..<raw.count])
    }
}
