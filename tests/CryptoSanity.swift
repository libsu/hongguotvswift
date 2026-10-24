// SPDX-License-Identifier: GPL-3.0-only
// SM3 / base64 / hex / sbox 基础自检（标准向量）。
import Foundation

@main struct CryptoSanity {
    static func main() {
        // SM3 标准向量：SM3("abc") = 66c7f0f4...
        let abc = sm3(Array("abc".utf8))
        assert(hexString(abc) == "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",
               "SM3('abc') = \(hexString(abc))")
        // 空串
        let empty = sm3([])
        assert(hexString(empty) == "1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b",
               "SM3('') = \(hexString(empty))")
        // sbox 应为 1024 字节（4 × 256）
        assert(VendorConstants.sbox.count == 1024, "sbox = \(VendorConstants.sbox.count) 字节")
        // base64 往返
        let data: [UInt8] = [0x00, 0xff, 0x7f, 0x80, 0x41, 0x42, 0x43]
        assert(decode64(base64Encode(data)) == data, "base64 往返")
        print("[PASS] SM3 / sbox / base64 自检通过")
    }
}
