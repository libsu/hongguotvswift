// SPDX-License-Identifier: GPL-3.0-only
// 对齐测试：复刻 上游-tv MediaCryptoTest，用 NIST AES-CTR 向量 + MP4 容器 fixture 验证。
import Foundation

func hex(_ value: String) -> [UInt8] { hexBytes(value) }
func be32Arr(_ n: Int32) -> [UInt8] { be32(n) }

struct MediaCryptoAlignment {
    static func box(_ type: String, _ body: [UInt8]) -> [UInt8] {
        be32(Int32(body.count + 8)) + Array(type.utf8) + body
    }
    static func fixture(codec: String = "avc1", auxSize: Int = 8) -> [UInt8] {
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        func moov(_ offset: Int) -> [UInt8] {
            let entry = box("encv", [UInt8](repeating: 0, count: 78) + box("sinf", box("frma", Array(codec.utf8))))
            let stsd = box("stsd", [UInt8](repeating: 0, count: 4) + be32(1) + entry)
            let stsz = box("stsz", [UInt8](repeating: 0, count: 4) + be32(16) + be32(1))
            let stsc = box("stsc", [UInt8](repeating: 0, count: 4) + be32(1) + be32(1) + be32(1) + be32(1))
            let stco = box("stco", [UInt8](repeating: 0, count: 4) + be32(1) + be32(4096))
            let saiz = box("saiz", [UInt8](repeating: 0, count: 4) + [UInt8(auxSize)] + be32(1))
            let saio = box("saio", [UInt8](repeating: 0, count: 4) + be32(1) + be32(Int32(offset)))
            return box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd + stsz + stsc + stco + saiz + saio)))) + box("free", Array(iv[0..<8])))
        }
        let ftyp = box("ftyp", Array("isom0000".utf8))
        let initial = ftyp + moov(0)
        return ftyp + moov(initial.count - 8)
    }

    static func assertEq(_ got: [UInt8], _ want: [UInt8], _ msg: String) {
        precondition(got == want, "\(msg)\n  got  \(hexString(got))\n  want \(hexString(want))")
    }

    static func run() {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        let encrypted = hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee")

        print("step1 NIST-CTR 全范围...")
        let prefix = [UInt8](repeating: 0x66, count: 23)
        let source = prefix + encrypted + [UInt8](repeating: 0x77, count: 12)
        let expected = prefix + plain + [UInt8](repeating: 0x77, count: 12)
        let prepared = MediaCrypto.Prepared(header: [], samples: [MediaCrypto.Sample(start: 23, end: 87, iv: iv)])
        for start in 0..<source.count {
            for length in 1...min(29, source.count - start) {
                let seg = Array(source[start..<(start + length)])
                let exp = Array(expected[start..<(start + length)])
                let got = try! MediaCrypto.decrypt(seg, start: Int64(start), key: key, prepared: prepared)
                if got != exp {
                    print("[FAIL] NIST CTR \(start)+\(length)")
                    print("   got  \(hexString(got))")
                    print("   want \(hexString(exp))")
                    exit(1)
                }
            }
        }
        print("  ok")

        // 子样本保留明文并继续 CTR 偏移
        print("step2 子样本...")
        let src2 = [UInt8]([1, 2, 3]) + Array(encrypted[0..<21]) + [UInt8]([4, 5]) + Array(encrypted[21..<64])
        let exp2 = [UInt8]([1, 2, 3]) + Array(plain[0..<21]) + [UInt8]([4, 5]) + Array(plain[21..<64])
        let prepared2 = MediaCrypto.Prepared(header: [], samples: [
            MediaCrypto.Sample(start: 3, end: 24, iv: iv),
            MediaCrypto.Sample(start: 26, end: 69, iv: iv, encryptedOffset: 21),
        ])
        let got2 = try! MediaCrypto.decrypt(src2, start: 0, key: key, prepared: prepared2)
        if got2 != exp2 {
            print("[FAIL] 子样本整体")
            print("   got  \(hexString(got2))")
            print("   want \(hexString(exp2))")
            exit(1)
        }
        let got2b = try! MediaCrypto.decrypt(Array(src2[22..<47]), start: 22, key: key, prepared: prepared2)
        if got2b != Array(exp2[22..<47]) {
            print("[FAIL] 子样本范围")
            print("   got  \(hexString(got2b))")
            print("   want \(hexString(Array(exp2[22..<47])))")
            exit(1)
        }
        print("  ok")

        // MP4 容器：header 恢复 avc1、样本索引、headerEnd
        print("step3 MP4 prepare...")
        let data = fixture()
        let p = try! MediaCrypto.prepare(data, key: key)
        // 用字节序列查找，等价 上游 String(header).contains（header 含二进制，不能用 UTF-8 严格解码）
        func headerContains(_ s: String) -> Bool {
            let needle = Array(s.utf8)
            let h = p.header
            for i in 0...(h.count - needle.count) where Array(h[i..<(i + needle.count)]) == needle { return true }
            return false
        }
        if !headerContains("avc1") || headerContains("encv") || headerContains("sinf") {
            print("header 恢复失败")
            exit(1)
        }
        if p.samples.count != 1 || p.samples[0].start != 4096 || p.samples[0].end != 4112 {
            print("样本索引错误: count=\(p.samples.count) start=\(p.samples.first?.start ?? -1) end=\(p.samples.first?.end ?? -1)")
            exit(1)
        }
        let he = try! MediaCrypto.headerEnd(data, total: 5000)
        if he != data.count {
            print("headerEnd 错误: \(he) != \(data.count)")
            exit(1)
        }
        print("  ok")

        print("MediaCrypto 对齐全部通过（NIST CTR 向量 + MP4 容器 fixture）")
    }
}

@main struct MediaCryptoAlignmentMain {
    static func main() { MediaCryptoAlignment.run() }
}
