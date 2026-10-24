// SPDX-License-Identifier: GPL-3.0-only
// 对齐测试：复刻 上游-tv SignerTest，用 signing.json 逐条验证 Signer 各函数输出与 上游 一致。
import Foundation

struct SignerAlignment {
    static func run() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: url)
        let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

        var passed = 0
        for (i, row) in rows.enumerated() {
            let ts = (row["ts"] as! NSNumber).intValue
            let urlStr = row["url"] as! String
            let query = String(urlStr[urlStr.firstIndex(of: "?")!...].dropFirst())
            let body: [UInt8]? = (row["body"] as? String).flatMap { Array($0.utf8) }

            var seed: UInt32 = 17
            let signer = Signer(
                clock: { Int64(ts) * 1000 },
                random: {
                    seed = seed &* 1664525 &+ 1013904223
                    return Double(seed) / 4294967296.0
                }
            )

            let br = signer.branch(query: query, body: body, ts: Int32(ts))
            assert(br == 0, "branch \(i) = \(br)")

            let qSm3 = sm3(Array(query.utf8))
            let bMd5 = body != nil ? digest("MD5", body!) : [UInt8](repeating: 0, count: 16)
            let hash = hexString(signer.hashF13(query: qSm3, body: bMd5, ts: Int32(ts)))
            let expHash = row["hash"] as! String
            assert(hash == expHash, "hash \(i)\n  got  \(hash)\n  want \(expHash)")

            let gorgon = signer.gorgon(query: query, body: body, ts: Int32(ts), random: 42131)
            let expGorgon = row["gorgon"] as! String
            assert(gorgon == expGorgon, "gorgon \(i)\n  got  \(gorgon)\n  want \(expGorgon)")

            let helios = signer.helios(ts: Int32(ts))
            let expHelios = row["helios"] as! String
            assert(helios == expHelios, "helios \(i)\n  got  \(helios)\n  want \(expHelios)")

            let medusa = signer.medusa(url: urlStr, body: body, ts: Int32(ts))
            let expMedusa = row["medusa"] as! String
            assert(medusa == expMedusa, "medusa \(i)\n  got  \(medusa)\n  want \(expMedusa)")

            passed += 1
        }
        print("[PASS] 全部 \(passed) 条签名向量对齐通过")
    }
}

@main struct SignerAlignmentMain {
    static func main() throws {
        try SignerAlignment.run()
    }
}
