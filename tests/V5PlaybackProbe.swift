// SPDX-License-Identifier: GPL-3.0-only
// 探针：直接按剧集 id 调生产入口 streamLadder，验证 v5 签名能否出档位。
// 用法：bash scripts/probe-v5-playback.sh <剧集id...>
import Foundation

@main struct V5PlaybackProbe {
    static func main() async {
        let ids = CommandLine.arguments.count > 1
            ? Array(CommandLine.arguments.dropFirst())
            : ["7706890409019984920", "7699475193185438744"]
        let repo = ContentRepository()
        var failures = 0
        for id in ids {
            let t0 = Date()
            do {
                let ladder = try await repo.streamLadder(id: id)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("=== \(id) 耗时 \(ms)ms 档位 \(ladder.renditions.count)")
                for r in ladder.renditions.sorted(by: { $0.quality > $1.quality }) {
                    let mark = CodecCapabilities.supports(r) ? "*" : ""
                    print("  \(r.quality)p \(r.codec) \(r.width)x\(r.height)\(mark)")
                }
                if !ladder.hasPlayable { failures += 1; print("  ⚠️ 无本机可解码档位") }
            } catch {
                failures += 1
                print("=== \(id) 失败：\(error.localizedDescription)")
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}
