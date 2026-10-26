// SPDX-License-Identifier: GPL-3.0-only
// GZIP 压缩/解压（供账号层 DeviceRegister 的 gzip(body) 与 CloudAccount 的 gzip 请求体用）。
// 用 Compression 框架（compression_encode_buffer / decode）封成标准 GZIP 流（RFC 1952）。
import Foundation
import zlib

enum Gzip {
    /// GZIP 压缩（对齐 Java GZIPOutputStream：完整 gzip header + deflate + CRC32 + ISIZE）。
    static func compress(_ data: [UInt8]) -> [UInt8] {
        let input = Data(data)
        guard !input.isEmpty else { return gzipEmpty() }
        let destinationCapacity = input.count + 32

        // 使用 zlib（deflateInit2 窗口位 15+16 即 gzip）。
        var z = z_stream()
        z.next_in = nil; z.avail_in = 0; z.total_out = 0
        var status = deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return [] }

        var out = [UInt8](repeating: 0, count: destinationCapacity)
        input.withUnsafeBytes { rawIn in
            out.withUnsafeMutableBytes { rawOut in
                z.next_in = UnsafeMutablePointer(mutating: rawIn.bindMemory(to: UInt8.self).baseAddress)
                z.avail_in = uInt(rawIn.count)
                z.next_out = rawOut.bindMemory(to: UInt8.self).baseAddress
                z.avail_out = uInt(rawOut.count)
                status = deflate(&z, Z_FINISH)
            }
        }
        deflateEnd(&z)
        guard status == Z_STREAM_END else { return [] }
        return Array(out.prefix(Int(z.total_out)))
    }

    /// GZIP 解压（对称于 compress，供测试 round-trip 与未来解析服务端 gzip 响应）。
    static func decompress(_ data: [UInt8]) -> [UInt8] {
        let input = Data(data)
        // 用 zlib inflateInit2 窗口位 15+16 即 gzip。
        var z = z_stream()
        z.next_in = nil; z.avail_in = 0; z.total_out = 0
        var status = inflateInit2_(&z, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return [] }
        defer { inflateEnd(&z) }

        var out = [UInt8](repeating: 0, count: data.count * 4 + 64)
        input.withUnsafeBytes { rawIn in
            out.withUnsafeMutableBytes { rawOut in
                z.next_in = UnsafeMutablePointer(mutating: rawIn.bindMemory(to: UInt8.self).baseAddress)
                z.avail_in = uInt(rawIn.count)
                z.next_out = rawOut.bindMemory(to: UInt8.self).baseAddress
                z.avail_out = uInt(rawOut.count)
                status = inflate(&z, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return [] }
        return Array(out.prefix(Int(z.total_out)))
    }

    private static func gzipEmpty() -> [UInt8] {
        // 空输入的合法 GZIP 流。
        let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
        let crc32: UInt32 = 0
        let isize: UInt32 = 0
        var out = header
        out += [UInt8(crc32 & 0xff), UInt8((crc32 >> 8) & 0xff), UInt8((crc32 >> 16) & 0xff), UInt8((crc32 >> 24) & 0xff)]
        out += [UInt8(isize & 0xff), UInt8((isize >> 8) & 0xff), UInt8((isize >> 16) & 0xff), UInt8((isize >> 24) & 0xff)]
        return out
    }
}
