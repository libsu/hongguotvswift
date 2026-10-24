// SPDX-License-Identifier: GPL-3.0-only
// 对齐 上游-tv 的 StreamLadderTest + VideoTracksTest：验证编码择优（HEVC 优先、AV1 过滤）、
// 降级顺序，以及从解密 MP4 头读取真实编码与 coded 尺寸。
import Foundation

struct CodecSelectionTests {
    static func u16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func u32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func box(_ type: String, _ payload: [UInt8] = []) -> [UInt8] {
        u32(payload.count + 8) + Array(type.utf8) + payload
    }

    static func rendition(_ q: Int, _ codec: String = "h264", _ w: Int? = nil, _ h: Int? = nil) -> Rendition {
        Rendition(quality: q, codec: codec, width: w, height: h, url: "https://example.com/\(q)-\(codec)", key: nil)
    }
    static func ladder(_ renditions: Rendition...) -> StreamLadder { StreamLadder(renditions: renditions) }

    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("[FAIL] \(msg)"); exit(1) }
    }

    static func run() {
        // StreamLadder.select：同清晰度下 HEVC 优先于 AVC（省流量、加载快）。
        do {
            let p = ladder(rendition(720, "h264"), rendition(720, "bytevc1")).select(maxQuality: 1080)!
            expect(p.codec == "bytevc1", "同清晰度应优先 HEVC(bytevc1)，实得 \(p.codec)")
        }
        // hvc1/hev1 也是 HEVC，应同等优先。
        do {
            let p = ladder(rendition(1080, "h264"), rendition(1080, "hvc1")).select(maxQuality: 1080)!
            expect(p.codec == "hvc1", "同清晰度应优先 HEVC(hvc1)，实得 \(p.codec)")
        }
        // 不支持的高档应跳过，退到支持的低档。
        do {
            let p = ladder(rendition(1080, "bytevc1", 1080, 1920), rendition(720, "h264", 720, 1280), rendition(480))
                .select(maxQuality: 1080) { $0.codec == "h264" }!
            expect(p.quality == 720, "过滤后应退到 720p，实得 \(p.quality)")
        }
        // 全部不支持时回退到最佳 rendition。
        do {
            let p = ladder(rendition(1080, "bytevc1", 1080, 1920), rendition(720, "h264", 720, 1280))
                .select(maxQuality: 1080) { _ in false }!
            expect(p.quality == 1080, "全不支持应回退到 1080p")
        }
        // playbackOrder：select 领先，其余候选项按优到劣。
        do {
            let o = ladder(rendition(1080, "bytevc1"), rendition(720, "bytevc1"), rendition(720, "h264"), rendition(480))
                .playbackOrder(maxQuality: 1080) { $0.codec == "h264" }
            expect(o.first?.quality == 720 && o.first?.codec == "h264", "playbackOrder 首项应为 720/h264")
        }

        // CodecCapabilities：编码族识别（HEVC/AVC 支持、AV1 过滤）。
        do {
            expect(CodecCapabilities.isHEVC("bytevc1") && CodecCapabilities.isHEVC("hvc1") && CodecCapabilities.isHEVC("hev1") && CodecCapabilities.isHEVC("h265") && CodecCapabilities.isHEVC("hevc"), "HEVC 变体应全部识别")
            expect(CodecCapabilities.isAVC("h264") && CodecCapabilities.isAVC("avc1"), "AVC 应识别")
            expect(CodecCapabilities.isAV1("bytevc2") && CodecCapabilities.isAV1("bvc2") && CodecCapabilities.isAV1("av01") && CodecCapabilities.isAV1("av1"), "AV1 变体（bytevc2/bvc2/av01/av1）应全部识别")
            expect(!CodecCapabilities.supports(codec: "av01", width: 1920, height: 1080), "av01 应判为不支持")
            expect(!CodecCapabilities.supports(codec: "bytevc2", width: 1920, height: 1080), "bytevc2 应判为不支持")
            expect(!CodecCapabilities.supports(codec: "bvc2", width: 1920, height: 1080), "bvc2 应判为不支持")
            expect(CodecCapabilities.supports(codec: "h264", width: 1920, height: 1080), "h264 应支持")
            expect(CodecCapabilities.supports(codec: "bytevc1", width: 1920, height: 1080), "bytevc1(HEVC) 应支持")
            expect(CodecCapabilities.supports(codec: "hvc1", width: 1920, height: 1080), "hvc1(HEVC) 应支持")
            expect(CodecCapabilities.supports(codec: "hev1", width: 1920, height: 1080), "hev1(HEVC) 应支持")
            expect(!CodecCapabilities.supports(rendition(1080, "av01", 1920, 1080)), "rendition(av01) 应过滤")
        }

        // VideoTracks：读 coded 尺寸与 fourcc，跳过音频轨道。
        do {
            func sampleEntry(_ fourcc: String, _ w: Int, _ h: Int) -> [UInt8] {
                box(fourcc, [UInt8](repeating: 0, count: 24) + u16(w) + u16(h) + u16(0x18) + u16(0xffff) + u32(0) + u32(0))
            }
            func videoTrak(_ fourcc: String, _ w: Int, _ h: Int) -> [UInt8] {
                let stsd = box("stsd", u32(0) + u32(1) + sampleEntry(fourcc, w, h))
                let stbl = box("stbl", stsd)
                let minf = box("minf", box("vmhd") + stbl)
                return box("trak", box("tkhd") + box("mdia", box("hdlr") + minf))
            }
            func audioTrak() -> [UInt8] {
                let stsd = box("stsd", u32(0) + u32(1) + box("mp4a"))
                let minf = box("minf", box("smhd") + box("stbl", stsd))
                return box("trak", box("tkhd") + box("mdia", box("hdlr") + minf))
            }
            func header(_ traks: [UInt8]...) -> [UInt8] {
                box("ftyp", Array("isom".utf8)) + box("moov", traks.flatMap { $0 })
            }
            let t = VideoTracks.videoTrack(header(videoTrak("avc1", 1920, 1080)))!
            expect(t.fourcc == "avc1" && t.width == 1920 && t.height == 1080, "videoTrack 应读出 avc1 1920x1080")
            let p = VideoTracks.videoTrack(header(videoTrak("hvc1", 1080, 1920)))!
            expect(p.width == 1080 && p.height == 1920, "竖屏 coded 尺寸应为 1080x1920")
            let withAudio = VideoTracks.videoTrack(header(audioTrak(), videoTrak("avc1", 720, 1280)))!
            expect(withAudio.fourcc == "avc1" && withAudio.width == 720, "应跳过音频轨道读到视频轨道")
            expect(VideoTracks.videoTrack(header(audioTrak())) == nil, "无视频轨道应返回 nil")
        }

        print("[PASS] 编码择优 / AV1 过滤 / 降级顺序 / VideoTracks 全部通过")
    }
}

@main struct CodecSelectionMain {
    static func main() { CodecSelectionTests.run() }
}
