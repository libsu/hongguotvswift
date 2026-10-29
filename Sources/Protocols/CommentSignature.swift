// SPDX-License-Identifier: GPL-3.0-only
// Argus/Simon 结构来源于 tr4acex/TikTok-Encryption (MIT)
// Gorgon/Ladon 复用现有 GPL core Signer 算法 + 评论协议参数
import Foundation
import CommonCrypto
import Security

final class CommentSignature {
    private func md5(_ b: [UInt8]) -> [UInt8] { digest("MD5", b) }

    private func hex(_ s: String) -> [UInt8] { hexBytes(s) }

    private func le(_ n: Int64) -> [UInt8] { le64(n) }

    private func word(_ b: [UInt8], _ at: Int) -> Int64 { readI64(b, at, little: true) }

    private func pad(_ b: [UInt8]) -> [UInt8] {
        var out = b
        let padLen = 16 - b.count % 16
        if padLen == 16 { return out }
        out.append(contentsOf: [UInt8](repeating: UInt8(padLen), count: padLen))
        return out
    }

    private func sm3(_ b: [UInt8]) -> [UInt8] { SM3.digest(b) }

    /// proto：字段编码（tag 用 varint，字符串/字节用 length-delimited）
    /// 保持传入顺序（对齐 上游 linkedMapOf 的插入顺序）
    private func proto(_ fields: [(Int, Any)]) -> [UInt8] {
        var out: [UInt8] = []
        func variable(_ value: Int64) {
            var n = UInt64(bitPattern: value)
            while n > 0x7f {
                out.append(UInt8(n & 0x7f) | 0x80)
                n >>= 7
            }
            out.append(UInt8(n))
        }
        for (tag, value) in fields {
            if let number = value as? NSNumber {
                let v = number.int64Value
                variable(Int64(tag) << 3)
                variable(v)
            } else {
                let bytes: [UInt8] = (value as? [UInt8]) ?? Array(String(describing: value).utf8)
                variable((Int64(tag) << 3) | 2)
                variable(Int64(bytes.count))
                out.append(contentsOf: bytes)
            }
        }
        return out
    }

    func headers(query: String, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000), nonce: [UInt8]? = nil) -> [String: String] {
        let nonce = nonce ?? {
            var b = [UInt8](repeating: 0, count: 11)
            for i in 0..<11 { b[i] = UInt8.random(in: 0...255) }
            return b
        }()
        precondition(nonce.count == 11)
        let ts = now / 1000
        let first = ((Int(nonce[0]) % 7 + 1) << 5)
        let second = 0xe0 | (Int(nonce[1]) & 15)

        var input = Array(md5(Array(query.utf8)).prefix(4))
        input.append(contentsOf: [UInt8](repeating: 0, count: 8))
        input.append(contentsOf: hex("00010704"))
        input.append(contentsOf: le32(Int32(truncatingIfNeeded: ts)))

        let key = [0x4a, 0, 0x16, second, 0x47, 0x6c, 0, first]
        var box = (0..<256).map { $0 }
        var j = 0
        for i in box.indices {
            j = (j + box[i] + key[i % 8]) & 255
            box.swapAt(i, j)
        }
        j = 0
        for n in input.indices {
            let i = n + 1
            j = (j + box[i]) & 255
            box.swapAt(i, j)
            input[n] = UInt8(UInt8(input[n]) ^ UInt8(box[(box[i] + box[j]) & 255]))
        }
        for i in input.indices {
            let v = Int(input[i])
            let swapped = ((v << 4) | (v >> 4)) & 255
            let next = Int(input[(i + 1) % input.count])
            let reversed = Int(UInt32(bitPattern: Int32(swapped ^ next)).byteSwapped) >> 24
            input[i] = UInt8((reversed ^ 0xeb) & 255)
        }

        let gorgonBytes: [UInt8] = [0x84, 4, UInt8(first), UInt8(second), 0, 0] + input
        return [
            "X-Gorgon": hexString(gorgonBytes),
            "X-Khronos": String(ts),
            "X-SS-Req-Ticket": String(now),
            "X-SS-STUB": "",
            "X-Argus": argus(query: query, ts: ts, nonce: nonce),
            "X-Ladon": ladon(ts: ts, salt: Array(nonce[2..<6])),
        ]
    }

    private func ladon(ts: Int64, salt: [UInt8]) -> String {
        // 上游: md5(...).hexString().toByteArray() —— 取 md5 摘要的 ASCII 十六进制文本字节
        let asciiText = hexString(md5(salt + Array("8662".utf8)))
        let aBytes = Array(asciiText.utf8)
        var queue: [Int64] = []
        queue.append(word(aBytes, 16))
        queue.append(word(aBytes, 24))
        var left = word(aBytes, 0)
        var right = word(aBytes, 8)
        var keys = [Int64](repeating: 0, count: 34)
        for i in keys.indices {
            keys[i] = left
            let next = (rotateRight64(right, 8) &+ left) ^ Int64(i)
            queue.append(next)
            left = next ^ rotateLeft64(left, 3)
            right = queue.removeFirst()
        }
        let data = pad(Array("\(ts)-1611921764-3019".utf8))
        var result: [UInt8] = salt
        var at = 0
        while at < data.count {
            var a = word(data, at)
            var b = word(data, at + 8)
            for k in keys {
                b = k ^ (a &+ rotateRight64(b, 8))
                a = b ^ rotateLeft64(a, 3)
            }
            result.append(contentsOf: le(a))
            result.append(contentsOf: le(b))
            at += 16
        }
        return base64Encode(result)
    }

    private func argus(query: String, ts: Int64, nonce: [UInt8]) -> String {
        let random = Int64(UInt32(bitPattern: readI32(nonce, 6, little: true)))
        let nested = proto([
            (1, Int64(2 + (Int(nonce[10]) % 49) * 2)),
            (2, Int64(1388734)), (3, Int64(1388734)), (4, Int64(1388734)),
        ])
        let message = proto([
            (1, Int64(0x40401252)), (2, Int64(2)), (3, random), (4, "3019"), (6, "1611921764"),
            (7, "6.8.1.32"), (8, "v04.07.01-ml-android"), (9, Int64(135135744)), (10, [UInt8](repeating: 0, count: 8)),
            (12, ts * 2), (13, Array(sm3([UInt8](repeating: 0, count: 16)).prefix(6))),
            (14, Array(sm3(Array(query.utf8)).prefix(6))), (15, nested), (20, "none"), (21, Int64(738)),
        ])
        let secret = hex("ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")
        let derived = sm3(secret + hex("3ccc567b") + secret)
        var keys = [Int64](repeating: 0, count: 72)
        for i in 0..<4 { keys[i] = word(derived, i * 8) }
        for i in 4..<72 {
            let x = rotateRight64(keys[i - 1], 3) ^ keys[i - 3]
            let shift = (i - 4) % 62
            let bit = (Int64(0x3dc94c3a046d678b) >> shift) & 1
            keys[i] = (~keys[i - 4]) ^ x ^ rotateRight64(x, 1) ^ bit ^ 3
        }
        let blocks = pad(message)
        var encrypted: [UInt8] = []
        var at = 0
        while at < blocks.count {
            var a = word(blocks, at)
            var b = word(blocks, at + 8)
            for k in keys {
                let next = a ^ (rotateLeft64(b, 1) & rotateLeft64(b, 8)) ^ rotateLeft64(b, 2) ^ k
                a = b; b = next
            }
            encrypted.append(contentsOf: le(a))
            encrypted.append(contentsOf: le(b))
            at += 16
        }
        let mask = hex("d04ffdffd04ffdff")
        var scrambled = [UInt8](repeating: 0, count: encrypted.count)
        for i in encrypted.indices { scrambled[i] = UInt8(encrypted[i]) ^ mask[i % 8] }
        let container = hex("a6e783ee7001100918") + (mask + scrambled).reversed() + hex("567b")
        let key = md5(Array(secret.prefix(16)))
        let iv = md5(Array(secret[16..<32]))
        let ciphertext = aesCBCEncryptPKCS7(key: key, iv: iv, data: container)
        return base64Encode(hex("3ccc") + ciphertext)
    }

    private func rotateLeft64(_ v: Int64, _ n: Int) -> Int64 {
        let u = UInt64(bitPattern: v)
        let shift = UInt64(n & 63)
        return Int64(bitPattern: (u << shift) | (u >> (64 - shift)))
    }
    private func rotateRight64(_ v: Int64, _ n: Int) -> Int64 {
        let u = UInt64(bitPattern: v)
        let shift = UInt64(n & 63)
        return Int64(bitPattern: (u >> shift) | (u << (64 - shift)))
    }
}

/// AES/CBC/PKCS5 加密（仅用于 Argus 容器加密）
func aesCBCEncryptPKCS7(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: data.count + 16)
    var outLen = 0
    let status = key.withUnsafeBufferPointer { kPtr in
        iv.withUnsafeBufferPointer { ivPtr in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    kPtr.baseAddress, key.count, ivPtr.baseAddress,
                    data, data.count, &out, out.count, &outLen)
        }
    }
    guard status == kCCSuccess else { fatalError("AES-CBC 加密失败") }
    return Array(out.prefix(outLen))
}
