// SPDX-License-Identifier: GPL-3.0-only
// 与 coded 尺寸（编码尺寸，非显示尺寸）。用于在选定清晰度后二次校验编码族，
// 避免「API 元数据与实际编码不一致」时选中设备无法解码的流。
import Foundation

enum VideoTracks {
    struct Track {
        let fourcc: String
        let width: Int
        let height: Int
    }

    /// 从解密后的 MP4 header 读第一个视频轨道。找不到视频轨道或数据非法时返回 nil。
    static func videoTrack(_ header: [UInt8]) -> Track? {
        if header.count < 32 { return nil }
        guard String(bytes: header[4..<8], encoding: .ascii) == "ftyp" else { return nil }
        guard let moov = MediaCrypto.box(header, Int(readU32(header, 0)), header.count), moov.type == "moov" else { return nil }
        var cursor = moov.body
        while cursor < moov.end {
            guard let trak = MediaCrypto.box(header, cursor, moov.end) else { break }
            cursor = trak.end
            if trak.type != "trak" { continue }
            guard let mdia = MediaCrypto.find(header, "mdia", trak.body, trak.end) else { continue }
            guard let minf = MediaCrypto.find(header, "minf", mdia.body, mdia.end) else { continue }
            // 音频轨道没有 vmhd，跳过。
            if MediaCrypto.find(header, "vmhd", minf.body, minf.end) == nil { continue }
            guard let stbl = MediaCrypto.find(header, "stbl", minf.body, minf.end) else { continue }
            guard let stsd = MediaCrypto.find(header, "stsd", stbl.body, stbl.end) else { continue }
            // VisualSampleEntry：coded 宽/高是 16 位字段，位于 sample entry 起始 +32/+34。
            guard let entry = MediaCrypto.box(header, stsd.body + 8, stsd.end) else { continue }
            if entry.end - entry.start < 36 { continue }
            let width = (Int(header[entry.start + 32]) << 8) | Int(header[entry.start + 33])
            let height = (Int(header[entry.start + 34]) << 8) | Int(header[entry.start + 35])
            if width <= 0 || height <= 0 { continue }
            guard let fourcc = String(bytes: header[(entry.start + 4)..<(entry.start + 8)], encoding: .ascii) else { continue }
            return Track(fourcc: fourcc, width: width, height: height)
        }
        return nil
    }
}
