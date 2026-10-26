// SPDX-License-Identifier: GPL-3.0-only
// 编码族识别 + 解码能力判断（Mac 端）。
// 字节 CDN 的 codec_type 命名（API 元数据）：
//   - HEVC：bytevc1（已用 ffprobe 验证为标准 HEVC/H.265）、h265/hevc/hvc1/hev1
//   - AVC：h264/avc/avc1/avc3
//   - AV1：av01/av1/bytevc2/bvc2（bytevc2/bvc2 是字节 AV1 变体，多数 Mac 无视频解码）
import Foundation

enum CodecCapabilities {
    /// 是否为 AVC（H.264）编码族。
    static func isAVC(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "h264" || c == "avc" || c == "avc1" || c == "avc3"
    }

    /// 是否为 HEVC（H.265）编码族（bytevc1 经 ffprobe 验证为标准 HEVC）。
    static func isHEVC(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "h265" || c == "hevc" || c == "hvc1" || c == "hev1" || c == "bytevc1"
    }

    /// 是否为 AV1 编码族（含字节私有 bytevc2/bvc2 变体）。
    static func isAV1(_ codec: String) -> Bool {
        let c = codec.lowercased()
        return c == "av01" || c == "av1" || c == "bytevc2" || c == "bvc2" || c.hasPrefix("av01")
    }

    /// 该编码是否可解码。HEVC/AVC 普遍支持，AV1（含 bytevc2/bvc2）保守视为不支持，其它放行。
    static func supports(codec: String, width: Int?, height: Int?) -> Bool {
        if isAV1(codec) { return false }
        return true   // hevc/avc/未知：macOS 均可播或按未知放行
    }

    /// 便捷重载：按 Rendition 判断。生产未走此路（直接用 supports(codec:width:height:)）。
    static func supports(_ rendition: Rendition) -> Bool {
        supports(codec: rendition.codec, width: rendition.width, height: rendition.height)
    }

    /// 死代码：按 VideoTracks.Track 判断，当前无调用方。
    static func supports(_ track: VideoTracks.Track) -> Bool {
        supports(codec: track.fourcc, width: track.width, height: track.height)
    }
}
