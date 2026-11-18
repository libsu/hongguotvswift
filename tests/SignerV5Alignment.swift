// SPDX-License-Identifier: GPL-3.0-only
// v04.10.03（v5）签名对齐测试。
// 向量来自 N3urda/hongguoTV kotlin-tv 的 SignerV5Test 资源：
//   signing-v5-f13.json     —— 覆盖全部 32 个时间戳旋转类的 hashF13 摘要
//   signing-v5-carrier.json —— 覆盖 AesV3 v5 的 4 个 time 变体
// 用法：bash scripts/test-signer-v5.sh
import Foundation

struct SignerV5Alignment {
    static func run() throws {
        guard CommandLine.arguments.count > 2 else {
            preconditionFailure("用法: signer-v5 <f13.json> <carrier.json>")
        }
        try checkF13(CommandLine.arguments[1])
        try checkCarrier(CommandLine.arguments[2])
        try checkMedusa(CommandLine.arguments[3])
        print("[PASS] v5 签名向量对齐通过")
    }

    /// hashF13 的 v5 变体：固定 seed、单组轮常量、校验和置 bit 5。
    private static func checkF13(_ path: String) throws {
        let rows = try load(path)
        let signer = Signer(device: VendorConstants.device)
        assert(rows.count == 32, "f13 向量应为 32 条，实际 \(rows.count)")
        for (i, row) in rows.enumerated() {
            let query = hexBytes(row["query"] as! String)
            let body = hexBytes(row["body"] as! String)
            let ts = Int32((row["ts"] as! NSNumber).intValue)
            let result = signer.hashF13(query: query, body: body, ts: ts, v5: true)
            let digest = hexString(Array(result.prefix(16)))
            let expected = row["digest"] as! String
            assert(digest == expected, "f13 第 \(i) 条\n  got  \(digest)\n  want \(expected)")
            assert(result.count == 20, "f13 第 \(i) 条摘要长度应为 20")
            // v5 校验和必须置 bit 5。
            assert(result[16] & 0x24 == 0x24, "f13 第 \(i) 条校验位缺失")
        }
        print("[PASS] hashF13 v5 全部 \(rows.count) 条时间戳旋转类对齐")
    }

    /// AesV3 的 v5 参量表与 sbox。
    private static func checkCarrier(_ path: String) throws {
        let rows = try load(path)
        for (i, row) in rows.enumerated() {
            let key = hexBytes(row["key"] as! String)
            let source = hexBytes(row["source"] as! String)
            let iv = hexBytes(row["iv"] as! String)
            let ts = Int((row["ts"] as! NSNumber).intValue)
            let encrypted = AesV3(key: key, timestamp: ts, v5: true).encrypt(source: source, iv: iv)
            let actual = hexString(encrypted)
            let expected = row["encrypted"] as! String
            assert(actual == expected, "carrier 变体 \(i)\n  got  \(actual)\n  want \(expected)")
        }
        print("[PASS] AesV3 v5 全部 \(rows.count) 条变体对齐")
    }

    /// 整帧 x-medusa / x-helios：固定 random/processNonce/processStarted 后必须逐字节一致。
    private static func checkMedusa(_ path: String) throws {
        let rows = try load(path)
        for (i, row) in rows.enumerated() {
            let ts = Int32((row["ts"] as! NSNumber).intValue)
            let values = row["values"] as! [String: String]
            let body = hexBytes(row["body"] as! String)
            let signer = Signer(
                clock: { Int64(ts) * 1000 }, device: values, random: { 0.5 },
                deviceNonce: row["device_nonce"] as! String, processStarted: Int64(ts) * 1000
            )
            let medusa = signer.medusaV5(url: row["url"] as! String, body: body, ts: ts)
            assert(medusa == row["medusa"] as! String, "medusa 第 \(i) 条\n  got  \(medusa)\n  want \(row["medusa"]!)")
            let helios = signer.helios(ts: ts, v5: true)
            assert(helios == row["helios"] as! String, "helios 第 \(i) 条\n  got  \(helios)\n  want \(row["helios"]!)")
        }
        print("[PASS] x-medusa / x-helios v5 整帧对齐")
    }

    private static func load(_ path: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    }
}

@main struct SignerV5AlignmentMain {
    static func main() throws {
        try SignerV5Alignment.run()
    }
}
