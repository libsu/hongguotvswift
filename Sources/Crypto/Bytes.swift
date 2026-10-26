// SPDX-License-Identifier: GPL-3.0-only
// 关键差异：上游 Byte 是有符号(-128..127)，Swift UInt8 无符号(0..255)。
// 因此所有「取无符号字节值」的地方统一用 [UInt8] 的 Int 值(0..255)表达，
// 与 上游 的 Byte.u() (= toInt() and 255) 对齐。
import Foundation
import CommonCrypto

// MARK: - 十六进制

/// 上游: hex(String) -> ByteArray（两位一组转字节）
func hexBytes(_ value: String) -> [UInt8] {
    precondition(value.count % 2 == 0, "hex 长度必须为偶数")
    var out: [UInt8] = []
    out.reserveCapacity(value.count / 2)
    var i = value.startIndex
    while i < value.endIndex {
        let j = value.index(i, offsetBy: 2)
        let byte = UInt8(value[i..<j], radix: 16)!
        out.append(byte)
        i = j
    }
    return out
}

/// 上游: ByteArray.hex() -> 小写十六进制字符串
func hexString(_ data: [UInt8]) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Base64（与 上游 手写一致，支持 url-safe 输入、等号填充）

private let b64Alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

/// 上游: decode64(s: String) —— 手写 base64 解码（容忍 -_ 且容忍缺少填充）
func decode64(_ s: String) -> [UInt8] {
    let normalized = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    precondition(normalized.count % 4 != 1, "Invalid Base64 length")
    let padded = normalized.padding(toLength: ((normalized.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
    var out: [UInt8] = []
    var acc = 0
    var accBits = 0
    for c in padded {
        if c == "=" { break }
        guard let v = b64Alphabet.firstIndex(of: c) else { preconditionFailure("Invalid Base64 character \(c)") }
        acc = (acc << 6) | v
        accBits += 6
        if accBits >= 8 {
            accBits -= 8
            out.append(UInt8(truncatingIfNeeded: acc >> accBits))
        }
    }
    return out
}

/// 上游: ByteArray.base64() —— 手写 base64 编码（标准字母表 + 等号填充）
func base64Encode(_ data: [UInt8]) -> String {
    var sb = ""
    var i = 0
    while i < data.count {
        let b0 = Int(data[i])
        sb.append(b64Alphabet[b0 >> 2])
        if i + 1 < data.count {
            let b1 = Int(data[i + 1])
            sb.append(b64Alphabet[((b0 & 3) << 4) | (b1 >> 4)])
            if i + 2 < data.count {
                let b2 = Int(data[i + 2])
                sb.append(b64Alphabet[((b1 & 15) << 2) | (b2 >> 6)])
                sb.append(b64Alphabet[b2 & 63])
            } else {
                sb.append(b64Alphabet[(b1 & 15) << 2])
                sb.append("=")
            }
        } else {
            sb.append(b64Alphabet[(b0 & 3) << 4])
            sb.append("=")
            sb.append("=")
        }
        i += 3
    }
    return sb
}

// MARK: - 字节序

/// 上游: le32(n) —— 小端 4 字节
func le32(_ n: Int32) -> [UInt8] {
    let v = UInt32(bitPattern: n)
    return [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
}
/// 上游: le32(n: Int) 重载 —— 接收 Int
func le32(_ n: Int) -> [UInt8] { le32(Int32(truncatingIfNeeded: n)) }

/// 上游: be32(n) —— 大端 4 字节
func be32(_ n: Int32) -> [UInt8] {
    let v = UInt32(bitPattern: n)
    return [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}
func be32(_ n: Int) -> [UInt8] { be32(Int32(truncatingIfNeeded: n)) }

/// 上游: le64(n) —— 小端 8 字节
func le64(_ n: Int64) -> [UInt8] {
    let v = UInt64(bitPattern: n)
    return (0..<8).map { UInt8((v >> ($0 * 8)) & 0xff) }
}
func le64(_ n: Int) -> [UInt8] { le64(Int64(n)) }

// MARK: - 读整数（ByteArray.i32/u32/i64，默认大端）

func readI32(_ data: [UInt8], _ at: Int, little: Bool = false) -> Int32 {
    if little {
        var v: UInt32 = 0
        v |= UInt32(data[at]) | (UInt32(data[at + 1]) << 8) | (UInt32(data[at + 2]) << 16) | (UInt32(data[at + 3]) << 24)
        return Int32(bitPattern: v)
    } else {
        var v: UInt32 = 0
        v |= (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16) | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
        return Int32(bitPattern: v)
    }
}

/// 上游: u32(at) = i32(at).toLong() and 0xffffffffL
func readU32(_ data: [UInt8], _ at: Int) -> UInt32 {
    UInt32(bitPattern: readI32(data, at))
}

/// 上游: i64(at, little) —— 大端为默认
func readI64(_ data: [UInt8], _ at: Int, little: Bool = false) -> Int64 {
    var v: UInt64 = 0
    if little {
        for i in 0..<8 { v |= UInt64(data[at + i]) << (i * 8) }
    } else {
        for i in 0..<8 { v |= UInt64(data[at + i]) << ((7 - i) * 8) }
    }
    return Int64(bitPattern: v)
}

// MARK: - 摘要 / 加密

/// 上游: digest(algorithm, value) —— 支持 SHA-256/512、MD5
func digest(_ algorithm: String, _ value: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: digestLength(algorithm))
    var len = 0
    value.withUnsafeBufferPointer { ptr in
        if algorithm == "MD5" {
            // 协议兼容需要 MD5（上游弹幕/评论签名强制），无法替换为 SHA-256。
            // CommonCrypto 仍将其标记为弃用，此处为有意为之。
            CC_MD5(ptr.baseAddress, CC_LONG(value.count), &out)
            len = 16
        } else if algorithm == "SHA-256" {
            CC_SHA256(ptr.baseAddress, CC_LONG(value.count), &out)
            len = 32
        } else if algorithm == "SHA-512" {
            CC_SHA512(ptr.baseAddress, CC_LONG(value.count), &out)
            len = 64
        }
    }
    return Array(out.prefix(len))
}

private func digestLength(_ algorithm: String) -> Int {
    switch algorithm {
    case "MD5": return Int(CC_MD5_DIGEST_LENGTH)
    case "SHA-256": return Int(CC_SHA256_DIGEST_LENGTH)
    case "SHA-512": return Int(CC_SHA512_DIGEST_LENGTH)
    default: return 64
    }
}

/// 上游: sm3(value) —— 见 SM3.swift
func sm3(_ value: [UInt8]) -> [UInt8] { SM3.digest(value) }

/// 上游: aes("CBC", key, iv, data) —— AES/CBC/NoPadding 解密
func aesDecrypt(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: data.count)
    var outLen = 0
    let status = key.withUnsafeBufferPointer { kPtr in
        iv.withUnsafeBufferPointer { ivPtr in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), // CBC + NoPadding
                kPtr.baseAddress, key.count, ivPtr.baseAddress,
                data, data.count, &out, out.count, &outLen)
        }
    }
    guard status == kCCSuccess else { preconditionFailure("AES 解密失败") }
    return Array(out.prefix(outLen))
}

/// AES/CBC/NoPadding 加密（供 DeviceRegister.ttEncrypt 用）。输入须为 16 字节整数倍。
func aesEncryptCBC(_ key: [UInt8], _ iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
    precondition(data.count % 16 == 0, "AES/CBC/NoPadding 输入须为 16 字节整数倍")
    var out = [UInt8](repeating: 0, count: data.count)
    var outLen = 0
    let status = key.withUnsafeBufferPointer { kPtr in
        iv.withUnsafeBufferPointer { ivPtr in
            CCCrypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), // CBC + NoPadding
                kPtr.baseAddress, key.count, ivPtr.baseAddress,
                data, data.count, &out, out.count, &outLen)
        }
    }
    guard status == kCCSuccess else { preconditionFailure("AES 加密失败") }
    return Array(out.prefix(outLen))
}

/// AES-ECB 单块加密（块长 16 字节），供 CTR 模式产生 keystream。
func aesECBEncryptBlock(_ key: [UInt8], _ block: [UInt8]) -> [UInt8] {
    precondition(block.count == 16, "AES 块必须 16 字节")
    var out = [UInt8](repeating: 0, count: 16)
    var outLen = 0
    let status = key.withUnsafeBufferPointer { kPtr in
        CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            kPtr.baseAddress, key.count, nil,
            block, 16, &out, 16, &outLen)
    }
    guard status == kCCSuccess && outLen == 16 else { preconditionFailure("AES-ECB 加密失败") }
    return out
}

/// AES-CTR 解密/加密（CTR 模式，加密解密同构）。
/// counter 为 16 字节初始计数器块，按大端 128 位无符号逐块 +1 产生 keystream，与 data 异或。
/// 返回与 data 等长的结果。
func aesCTR(_ key: [UInt8], counter: [UInt8], _ data: [UInt8]) -> [UInt8] {
    precondition(counter.count == 16, "CTR 计数器必须 16 字节")
    var ctr = counter
    var out = [UInt8](repeating: 0, count: data.count)
    var offset = 0
    while offset < data.count {
        let ks = aesECBEncryptBlock(key, ctr)
        let n = min(16, data.count - offset)
        for i in 0..<n { out[offset + i] = data[offset + i] ^ ks[i] }
        // 计数器 +1（大端无符号 128 位）
        for i in stride(from: 15, through: 0, by: -1) {
            ctr[i] = ctr[i] &+ 1
            if ctr[i] != 0 { break }
        }
        offset += 16
    }
    return out
}

// MARK: - 位运算

/// 上游: xor(a, b) —— a 的长度，b 循环
func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    a.enumerated().map { i, v in v ^ b[i % b.count] }
}

/// 死代码：Int32 循环左移，当前未被调用（签名用 Signer.ror32、SM3 用私有 rotl）。
func rol(_ v: Int32, _ n: Int) -> Int32 {
    let u = UInt32(bitPattern: v)
    let nn = UInt32(n & 31)
    return Int32(bitPattern: (u << nn) | (u >> (32 - nn)))
}

/// 死代码：Int32 循环右移，当前未被调用。
func ror(_ v: Int32, _ n: Int) -> Int32 {
    let u = UInt32(bitPattern: v)
    let nn = UInt32(n & 31)
    return Int32(bitPattern: (u >> nn) | (u << (32 - nn)))
}
