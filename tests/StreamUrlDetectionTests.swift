// SPDX-License-Identifier: GPL-3.0-only
// 取流解析回归：直接调用 ContentRepository 的真实解析函数（rendition / renditions），
// 不再复刻一份实现，避免测试与生产代码漂移。
//
// 覆盖 multi_video_model 的 video_list 数组结构：
//   - main_url 明文 https  → 直接可用
//   - main_url 密文 base64 → 用 key_seed 解出明文
//   - 非法输入不崩溃、不被误判
//
// 用法：
//   bash scripts/test-stream-url.sh
//   bash scripts/test-stream-url.sh --crash-probe   # 子进程专用，验证崩溃场景
import Foundation

struct StreamUrlDetectionTests {
    static func expect(_ cond: Bool, _ msg: String) {
        if !cond { print("[FAIL] \(msg)"); exit(1) }
    }

    // MARK: - 真实响应样本（docs/接口分析.md）

    /// 主接口 video_list[0].main_url：明文 https。
    /// 注意其归一化长度 % 4 == 1——这正是 decryptUrl 内部 decode64 会崩溃的输入。
    static let plainURL = "https://v5-se-gddgtc-reading-video.qznovelvod.com/dc846d8895d2d99dfc7ac20a72e68f44/6ae7b662/video/tos/cn/tos-cn-v-6fcc8e/oACEzfGOmnnewDcdOHHWE0vIgW8LQXVeBIAHHZ/?a=8662&ch=0&cr=9&mime_type=video_mp4"

    /// video_meta 的真实字段（360p 档位）。
    static let meta: [String: Any] = [
        "definition": "360p", "quality": "normal", "vwidth": 640, "vheight": 360,
        "codec_type": "bytevc2", "bitrate": 189962,
    ]

    /// 构造一个 video_list 元素。codec 写进 video_meta（真实响应的位置）。
    /// 默认用 bytevc1（1080p 档位），注意 bytevc2 会被 isAV1 保守过滤。
    static func row(url: String = plainURL,
                    codec: String = "bytevc1",
                    encrypt: Bool? = true,
                    spadeA: String? = "p7wp82S/LMdViR/xZI0s3FGbKctnsC//ZoUqyniEN857iTOLiw==") -> [String: Any] {
        var encryptInfo: [String: Any] = ["kid": "6acd3e17f8818bf0759df32b0002ebeb"]
        if let encrypt { encryptInfo["encrypt"] = encrypt }
        if let spadeA { encryptInfo["spade_a"] = spadeA }
        var videoMeta = meta
        videoMeta["codec_type"] = codec
        return [
            "main_url": url,
            "backup_url": "https://v5-daily-cm-dj-reading-video.qznovelvod.com/backup",
            "video_meta": videoMeta,
            "encrypt_info": encryptInfo,
        ]
    }

    // MARK: - 用例

    static func run() {
        let seed = [UInt8](repeating: 0x42, count: 32)

        // 1. 明文 https + 有 seed：URL 原样保留，不进解密分支。
        //    回归背景：旧实现对带 seed 的明文 URL 也调 decryptUrl，而 decode64 对
        //    长度 % 4 == 1 的输入会 precondition 崩溃（try? 捕不住），导致闪退。
        do {
            let normalized = plainURL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            expect(normalized.count % 4 == 1, "明文样本归一化后长度 % 4 == 1，旧实现会在此崩溃")
            let r = ContentRepository.rendition(from: row(), key: nil, seed: seed)
            expect(r != nil, "明文 https + seed 应解析成功（不应走解密分支）")
            expect(r!.url == plainURL, "明文 URL 不应被改写，实得 \(r!.url)")
            expect(r!.quality == 360, "640x360 应解析为 360P，实得 \(r!.quality)")
            expect(r!.width == 640 && r!.height == 360, "宽高解析错误")
            expect(r!.codec == "bytevc1", "编码解析错误，实得 \(r!.codec)")
            expect(r!.key != nil, "encrypt=true + spade_a 应派生密钥")
        }

        // 2. 明文 https + 无 seed：同样原样保留。
        do {
            let r = ContentRepository.rendition(from: row(), key: nil, seed: nil)
            expect(r?.url == plainURL, "无 seed 时明文 URL 应原样保留")
        }

        // 3. AV1 档位应被过滤（bytevc2 在 CodecCapabilities.isAV1 里也被保守视为 AV1）。
        do {
            expect(ContentRepository.rendition(from: row(codec: "av01"), key: nil, seed: seed) == nil,
                   "av01 档位应被过滤")
            expect(ContentRepository.rendition(from: row(codec: "bytevc2"), key: nil, seed: seed) == nil,
                   "bytevc2 应按 AV1 保守过滤")
        }

        // 4. 无任何 URL 字段 → nil。
        do {
            var empty = row()
            empty["main_url"] = ""; empty["backup_url"] = ""
            expect(ContentRepository.rendition(from: empty, key: nil, seed: seed) == nil,
                   "无 URL 的档位应返回 nil")
        }

        // 5. main_url 缺失时回退 backup_url。
        do {
            var fallback = row()
            fallback["main_url"] = ""
            let r = ContentRepository.rendition(from: fallback, key: nil, seed: nil)
            expect(r?.url.contains("backup") == true, "main_url 为空时应回退 backup_url")
        }

        // 6. video_list 数组形态（主接口）：逐条解析并以 URL 去重。
        do {
            var seen = Set<String>()
            let rows: [[String: Any]] = [
                row(),
                row(),                                                   // 同一 URL，应被去重
                row(url: "https://v5-se-gddgtc-reading-video.qznovelvod.com/second"),
            ]
            let list = ContentRepository.renditions(from: rows, seed: nil, seen: &seen)
            expect(list.count == 2, "数组形态应解析出 2 条（第 2 条重复应去掉），实得 \(list.count)")
        }

        // 7. 长度 % 4 == 1 的非法 base64：不得崩溃。
        //    旧实现会在 decryptUrl → decode64 处 precondition 终止进程。
        do {
            let malformed = String(repeating: "A", count: 5)
            expect(malformed.count % 4 == 1, "样本长度应满足 % 4 == 1")
            let r = ContentRepository.rendition(from: row(url: malformed), key: nil, seed: seed)
            expect(r == nil, "非法 base64 且非 http 的输入应返回 nil，而不是崩溃")
        }

        print("[PASS] 取流解析（multi_video_model video_list 数组结构）全部通过")
    }

    /// 子进程入口：验证带 seed 时 rendition 对明文 URL 不再崩溃。
    /// 该场景曾经会走 decryptUrl → decode64 precondition 而终止进程。
    static func crashProbe() {
        let seed = [UInt8](repeating: 0x42, count: 32)
        print("[PROBE] 带 seed 解析明文 main_url…")
        let r = ContentRepository.rendition(from: row(), key: nil, seed: seed)
        guard r != nil else {
            print("[PROBE] 返回 nil，未崩溃但不应如此")
            exit(1)
        }
        print("[PROBE] 未崩溃，解析成功")
    }
}

@main struct StreamUrlDetectionMain {
    static func main() {
        if CommandLine.arguments.contains("--crash-probe") {
            StreamUrlDetectionTests.crashProbe()
        } else {
            StreamUrlDetectionTests.run()
        }
    }
}
