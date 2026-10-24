// SPDX-License-Identifier: GPL-3.0-only
// 账号层加密/GZIP 自检（无网络）。
import Foundation

@main struct AccountCryptoSanity {
    static func main() {
        // GZIP 往返
        let input = Array("红果免费短剧 account layer gzip round-trip".utf8)
        let compressed = Gzip.compress(input)
        assert(!compressed.isEmpty, "gzip 压缩不应为空")
        assert(compressed[0] == 0x1f && compressed[1] == 0x8b, "gzip 魔数")
        let restored = Gzip.decompress(compressed)
        assert(restored == input, "gzip 往返不一致")

        // ttEncrypt 结构：MAGIC(6) + rnd(32) + AES 密文（16 字节整数倍）
        let payload = Array("{\"magic_tag\":\"ss_app_log\"}".utf8)
        let encrypted = DeviceRegister.ttEncrypt(payload)
        assert(encrypted.count >= 6 + 32 + 16, "ttEncrypt 长度异常")
        assert(Array(encrypted[0..<6]) == [0x74, 0x63, 0x05, 0x10, 0x00, 0x00], "ttEncrypt MAGIC")

        // DeviceRegister.parse：全 0 或空应返回 nil
        assert(DeviceRegister.parse("{\"device_id\":0,\"install_id\":0}") == nil, "全 0 应返回 nil")
        assert(DeviceRegister.parse("{\"device_id\":\"123\",\"install_id\":\"456\",\"new_user\":1}") != nil, "valid 应非 nil")
        let parsed = DeviceRegister.parse("{\"device_id\":\"123\",\"install_id\":\"456\",\"device_token\":\"tok\",\"new_user\":1}")
        assert(parsed?.deviceId == "123" && parsed?.installId == "456" && parsed?.newUser == true)

        // AccountCredentials 往返
        let creds = AccountCredentials(cookie: "sessionid=x", deviceId: "d", installId: "i", device: ["device_id": "d", "iid": "i"])
        let round = try! AccountCredentials.fromJson(creds.toJson())
        assert(round.cookie == "sessionid=x" && round.deviceId == "d" && round.installId == "i")

        print("[PASS] 账号层 GZIP / ttEncrypt / Parse / Credentials 自检通过")
    }
}
