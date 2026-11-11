// SPDX-License-Identifier: GPL-3.0-only
// Argus/Ladon 签名回归：用上游 hongguo-open-player 的固定向量逐字节校验，
// 避免移植后的实现与 JS 版本漂移。
//
// 用法：
//   bash scripts/test-argus.sh
import Foundation

struct ArgusTests {
    private var passed = 0
    private var failed = 0

    mutating func equal(_ label: String, _ got: String, _ want: String) {
        if got == want {
            passed += 1
        } else {
            failed += 1
            print("[FAIL] \(label)\n  得到: \(got)\n  期望: \(want)")
        }
    }

    mutating func run() {
        // Simon 64/128 固定向量（上游 argus.test.js）
        let k: [UInt64] = [1_111_111_111_111_111_111, 2_222_222_222_222_222_222, 3_333_333_333_333_333_333, 4_444_444_444_444_444_444]
        let ct = Argus.simonEncrypt(12_345_678_901_234_567_89, 9_876_543_210_987_654_321, k)
        equal("simon ct[0]", String(ct.0), "6071150433487837324")
        equal("simon ct[1]", String(ct.1), "2027321285990159935")

        // Ladon 固定向量
        equal(
            "ladon(khronos=1700000000)",
            Argus.Ladon.encrypt(khronos: 1_700_000_000, licenseID: 1_611_921_764, aid: 1967, random: [0x01, 0x02, 0x03, 0x04]),
            "AQIDBKM7Y7bWnOIUXmTybD6/MpGbuge4sBwUJsyHVivhtMsH"
        )

        // 哈希固定向量
        equal("bodyHash(\"\")", hexString(Argus.bodyHash("")), "106e34a2b8c7")
        equal("queryHash(\"\")", hexString(Argus.queryHash("")), "106e34a2b8c7")
        equal("queryHash(aid=1967&device_id=123)", hexString(Argus.queryHash("aid=1967&device_id=123")), "925b8d86b20f")
        // 带真实 body 的 stub：早期实现用 UInt8(radix:) 校验，32 位 hex 必然溢出，导致恒走空分支。
        equal("bodyHash(32 位 stub)", hexString(Argus.bodyHash("1a038b7ebfeb3807c6e7e1e0572b19ed")), "f1e66e0a852a")

        // Argus 551 完整帧
        equal(
            "argus sign (上游向量)",
            Argus.sign(
                query: "aid=1967&device_id=dev_aaaaaaaa&iid=111", stubHex: "", ts: 1_700_000_000,
                aid: 1967, deviceId: "dev_aaaaaaaa", installId: "", randField: 659_662_259
            ),
            "8oHyrVYEy1xDCDlx64ko40qC6JC9VYY/ZkjJzEl50iSFDw8Yfph1hupLxfKrA9GswSEz0Yi4goA7OQ4u+H8ECdOaQDL4GduQ3LULSq9Q4iSEGbS3L6G24GXChtnmPr6n46M2PLlKpXvF7uE0lhH4yD+X69FpdM41gQwx5Y5U3NdwXFaxlqYFszyp7dlUE6BEBWqwDsiAH8Jk9TGKr/jfHt4fVmMc9zRyNRdGeV0x6aP//x7aV+8Po8a/9KK3UNG5KEpmIgzRT6NUttkBP9gRNUh3"
        )

        // 真实设备参数（本轮实测可出播放模型的组合）
        equal(
            "argus sign (真实设备)",
            Argus.sign(
                query: "aid=1967&device_id=1624456208323876&iid=1624456208327972", stubHex: "", ts: 1_700_000_000,
                aid: 1967, deviceId: "1624456208323876", installId: "1624456208327972", randField: 659_662_259
            ),
            "8oEzzYYQyj8eTZ27kE36t4leAIHdoIk7gpm/pA5oXyaDQKNciGvgqcTpGCy3gkU70mQrW7sVp7iIMGlVeDIM3p8JBgSjpuJ28rccW15hQ+seqrgMd72K1WSFOWEXnnMNPIQXeuuShtNiRjavwMLHjSBDwPjYWOSrowEZnn4Yl3HtGij7zJTcaiV5NgG/igE5EfGjOa1l0CtujvyDvP9CCmPBZDkK6pE2suVK7TF8I7QlhchZUFGGUgY1f+YN9z/pRfykLBJCAG+XXTVREhwOF6lWRixD02q+HwcOE0+2JmJMqw=="
        )

        // queryParam 行为
        equal("queryParam 命中", Argus.queryParam("foo=bar&baz=123", "baz") ?? "nil", "123")
        equal("queryParam 缺失", Argus.queryParam("foo=bar&baz=123", "missing") ?? "nil", "nil")
        equal("queryParam 空串", Argus.queryParam("", "foo") ?? "nil", "nil")

        // 带 body 的完整帧（stub 非空）
        equal(
            "argus sign (带 stub)",
            Argus.sign(
                query: "aid=1967&device_id=dev_aaaaaaaa&iid=111", stubHex: "1a038b7ebfeb3807c6e7e1e0572b19ed",
                ts: 1_700_000_000, aid: 1967, deviceId: "dev_aaaaaaaa", installId: "", randField: 659_662_259
            ),
            "8oHyrVYEy1xDCDlx64ko40qC6JC9VYY/ZkjJzEl50iSFDw8Yfph1hupLxfKrA9GswSEz0Yi4goA7OQ4u+H8ECdOaLJoaIrcMiVMBZBg4Hx6ATL59Ia1hI5IMKPing8WM7vjhnbE63kPliZAC5rX1MIVh9ZZ/7MVesx9UwZ28duGjHtdCIQK6i0NjrOrzP9eyVOUrK/UT214MtH4lihn52kdgtnqoS+bWrWsPrLaOVS+WU2IRVviUMCK1735+QQMCni6aR4vm+oVTjHtgpjsy6ElW"
        )

        print(failed == 0 ? "[PASS] Argus/Ladon 签名全部通过（\(passed) 项）" : "[FAIL] \(failed) 项失败，\(passed) 项通过")
        if failed > 0 { exit(1) }
    }
}

@main struct ArgusTestMain {
    static func main() {
        var tests = ArgusTests()
        tests.run()
        exit(0)
    }
}
