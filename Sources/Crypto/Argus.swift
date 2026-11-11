// SPDX-License-Identifier: GPL-3.0-only
// x-argus / x-ladon 签名（Argus 551 帧 + Ladon 34 轮 ARX）。
// 播放接口对非法签名回 HTTP 200 + 空正文，这是此前「空响应」的根因。
// 移植自 zfdang/hongguo-open-player 的 native/argus.js（GPL-3.0-only），需逐字节一致。

import Foundation

enum Argus {
    /// 证照 ID（Argus 帧字段 6，同时用于 Ladon）。
    static let licenseID: Int64 = 1_611_921_764

    /// Simon 64/128 轮密钥，由 hex 串按 64 位小端读出。
    private static let signKey: [UInt64] = [
        0x740c_7a65_a9e0_78fc, 0x03cf_3c90_5915_e58c,
        0xd732_f2cf_d351_0e51, 0x0453_1c32_8ae8_4313,
    ]
    private static let aesKey: [UInt8] = hexBytes("d31e3718288a1027baab59f146a09a9c")
    private static let aesIV: [UInt8] = hexBytes("ea180a0336ed352fcd24e4d50018ae54")
    private static let magic: [UInt8] = [0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff]
    private static let tail: [UInt8] = [0xea, 0xfb, 0x2c, 0xfe, 0x85, 0x68, 0x51, 0x91, 0x54]

    /// 生成播放接口所需的签名头。`query` 为已编码查询串。
    static func headers(query: String, body: [UInt8], ts: Int64, aid: Int64, deviceId: String, installId: String, random: () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }) -> [String: String] {
        let stubHex = body.isEmpty ? "" : hexString(digest("MD5", body))
        let ladon = Ladon.encrypt(khronos: ts, licenseID: licenseID, aid: aid, random: ladonRandom(random))
        let argus = sign(query: query, stubHex: stubHex, ts: ts, aid: aid, deviceId: deviceId, installId: installId, randField: Int64(random()))
        var out: [String: String] = [
            "x-ss-req-ticket": String(ts * 1000),
            "x-khronos": String(ts),
            "x-ladon": ladon,
            "x-argus": argus,
        ]
        if !stubHex.isEmpty { out["x-ss-stub"] = stubHex.uppercased() }
        return out
    }

    /// 4 字节小端随机数。
    private static func ladonRandom(_ random: () -> UInt32) -> [UInt8] { le32(Int32(bitPattern: random())) }

    // MARK: - Argus 551 帧

    static func sign(query: String, stubHex: String, ts: Int64, aid: Int64, deviceId: String, installId: String, randField: Int64) -> String {
        var bean = ProtoBuf()
            .varint(1, 1_077_940_818)
            .varint(2, 2)
            .varint(3, randField)
            .utf8(4, String(aid == 0 ? 1967 : aid))
            .utf8(5, deviceId)
            .utf8(6, String(licenseID))
            .utf8(7, queryParam(query, "version_name") ?? "")
            .utf8(8, "v04.04.05-ov-android")
            .varint(9, 134_744_640)
            .bytes(10, [UInt8](repeating: 0, count: 8))
            .varint(11, 0)
            .varint(12, (ts << 1) & 0xffff_ffff)
            .bytes(13, bodyHash(stubHex))
            .bytes(14, queryHash(query))
            .protobuf(15, ProtoBuf().varint(1, 1).varint(2, 1).varint(3, 1).varint(7, 0xC792_ECCC))
            .utf8(16, installId)
            .utf8(20, "none")
            .varint(21, 738)
            .protobuf(23, ProtoBuf().utf8(1, "NX551J").varint(2, 8196).varint(4, 0x80E0_D800))
            .varint(25, 2)

        let padded = pkcs7Pad(bean.encode())
        let simonEncrypted = simonEncrypt(padded)

        // MAGIC8 + 密文 + TAIL9，从第 8 字节起循环异或 MAGIC8，再整体反转。
        var un = magic + simonEncrypted + tail
        for i in 8..<un.count { un[i] ^= magic[i % 8] }
        un.reverse()

        let final = pkcs7Pad(un + [0x61, 0x6f]) // "ao"
        let encrypted = aesEncryptCBC(aesKey, aesIV, final)
        return base64Encode([0xf2, 0x81] + encrypted)
    }

    static func bodyHash(_ stubHex: String) -> [UInt8] {
        // hexBytes 对非法输入会 precondition 崩溃，先校验。
        let isHex = !stubHex.isEmpty && stubHex.count % 2 == 0 && stubHex.allSatisfy(\.isHexDigit)
        let data = isHex ? hexBytes(stubHex) : [UInt8](repeating: 0, count: 16)
        return Array(sm3(data).prefix(6))
    }

    static func queryHash(_ query: String) -> [UInt8] {
        guard !query.isEmpty else {
            return Array(sm3([UInt8](repeating: 0, count: 16)).prefix(6))
        }
        return Array(sm3(Array(query.utf8)).prefix(6))
    }

    /// 取查询串参数；解码失败保留原文。
    static func queryParam(_ query: String, _ name: String) -> String? {
        guard !query.isEmpty else { return nil }
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            let eq = part.firstIndex(of: "=")
            let rawKey = eq.map { String(part[part.startIndex..<$0]) } ?? String(part)
            let key = rawKey.removingPercentEncoding ?? rawKey
            guard key == name else { continue }
            guard let eq else { return "" }
            let rawValue = String(part[part.index(after: eq)...])
            return rawValue.removingPercentEncoding ?? rawValue
        }
        return nil
    }

    // MARK: - Simon 64/128

    static func simonKeyExpansion(_ k: [UInt64]) -> [UInt64] {
        let z: UInt64 = 0x3DC9_4C3A_046D_678B
        var key = [UInt64](repeating: 0, count: 72)
        for i in 0..<4 { key[i] = k[i] }
        for i in 4..<72 {
            var tmp = rotr64(key[i - 1], 3) ^ key[i - 3]
            tmp ^= rotr64(tmp, 1)
            let bit = (z >> UInt64((i - 4) % 62)) & 1
            key[i] = ~key[i - 4] ^ tmp ^ bit ^ 3
        }
        return key
    }

    /// Simon 64/128 单块加密（测试直接调用）。
    static func simonEncrypt(_ xInput: UInt64, _ x1Input: UInt64, _ k: [UInt64]) -> (UInt64, UInt64) {
        var xi = xInput
        var xi1 = x1Input
        for roundKey in simonKeyExpansion(k) {
            let tmp = xi1
            let f = rotl64(xi1, 1) & rotl64(xi1, 8)
            xi1 = xi ^ f ^ rotl64(xi1, 2) ^ roundKey
            xi = tmp
        }
        return (xi, xi1)
    }

    private static func simonEncrypt(_ block: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(block.count)
        var i = 0
        while i < block.count {
            let (c0, c1) = simonEncrypt(readU64LE(block, i), readU64LE(block, i + 8), signKey)
            out += writeU64LE(c0)
            out += writeU64LE(c1)
            i += 16
        }
        return out
    }

    // MARK: - Ladon

    enum Ladon {
        static func encrypt(khronos: Int64, licenseID: Int64, aid: Int64, random: [UInt8]) -> String {
            let data = Array("\(khronos)-\(licenseID)-\(aid)".utf8)
            let md5Hex = hexString(digest("MD5", random + Array(String(aid).utf8)))
            let table = expandTable(md5Hex)

            let padValue = 16 - data.count % 16
            let input = data + [UInt8](repeating: UInt8(padValue), count: padValue)
            var out: [UInt8] = []
            out.reserveCapacity(input.count)
            var offset = 0
            while offset < input.count {
                out += encryptBlock(table, input, offset)
                offset += 16
            }
            return base64Encode(random + out)
        }

        private static func expandTable(_ md5Hex: String) -> [UInt64] {
            var ht = [UInt8](repeating: 0, count: 288)
            let src = Array(md5Hex.utf8)
            for i in 0..<min(32, src.count) { ht[i] = src[i] }
            var b0 = readU64LE(ht, 0)
            var b8 = readU64LE(ht, 8)
            var temp = [readU64LE(ht, 16), readU64LE(ht, 24)]
            for i in 0..<34 {
                var x8 = rotr64(b8, 8) &+ b0
                x8 ^= UInt64(i)
                temp.append(x8)
                x8 ^= rotl64(b0, 3)
                let at = (i + 1) * 8
                for (n, byte) in writeU64LE(x8).enumerated() { ht[at + n] = byte }
                b0 = x8
                b8 = temp.removeFirst()
            }
            return (0..<36).map { readU64LE(ht, $0 * 8) }
        }

        private static func encryptBlock(_ table: [UInt64], _ data: [UInt8], _ at: Int) -> [UInt8] {
            var data0 = readU64LE(data, at)
            var data1 = readU64LE(data, at + 8)
            for i in 0..<34 {
                data1 = table[i] ^ (data0 &+ rotr64(data1, 8))
                data0 = data1 ^ rotl64(data0, 3)
            }
            return writeU64LE(data0) + writeU64LE(data1)
        }
    }
}

// MARK: - 不可变 ProtoBuf 构造器

/// 只支持 varint 与长度前缀两种字段，与签名帧结构对应。
struct ProtoBuf {
    private enum Field {
        case varint(Int, UInt64)
        case blob(Int, [UInt8])
    }
    private var fields: [Field] = []

    /// 不可变构造器：返回追加字段后的副本，便于链式书写。
    @discardableResult
    func varint(_ tag: Int, _ value: Int) -> ProtoBuf { varint(tag, UInt64(bitPattern: Int64(value))) }

    @discardableResult
    func varint(_ tag: Int, _ value: Int64) -> ProtoBuf { varint(tag, UInt64(bitPattern: value)) }

    @discardableResult
    func varint(_ tag: Int, _ value: UInt64) -> ProtoBuf {
        var copy = self
        copy.fields.append(.varint(tag, value))
        return copy
    }

    @discardableResult
    func bytes(_ tag: Int, _ data: [UInt8]) -> ProtoBuf {
        var copy = self
        copy.fields.append(.blob(tag, data))
        return copy
    }

    @discardableResult
    func utf8(_ tag: Int, _ value: String) -> ProtoBuf { bytes(tag, Array(value.utf8)) }

    @discardableResult
    func protobuf(_ tag: Int, _ nested: ProtoBuf) -> ProtoBuf { bytes(tag, nested.encode()) }

    func encode() -> [UInt8] {
        var out: [UInt8] = []
        for field in fields {
            switch field {
            case let .varint(tag, value):
                out += varintEncode32((UInt64(tag) << 3) | 0)
                out += varintEncode32(value)
            case let .blob(tag, data):
                out += varintEncode32((UInt64(tag) << 3) | 2)
                out += varintEncode32(UInt64(data.count))
                out += data
            }
        }
        return out
    }
}

// MARK: - 64 位小端与轮转

private func readU64LE(_ data: [UInt8], _ at: Int) -> UInt64 {
    UInt64(bitPattern: readI64(data, at, little: true))
}

private func writeU64LE(_ value: UInt64) -> [UInt8] {
    le64(Int64(bitPattern: value))
}

private func rotl64(_ x: UInt64, _ n: Int) -> UInt64 {
    let s = UInt64(n & 63)
    return s == 0 ? x : (x << s) | (x >> (64 - s))
}

private func rotr64(_ x: UInt64, _ n: Int) -> UInt64 {
    let s = UInt64(n & 63)
    return s == 0 ? x : (x >> s) | (x << (64 - s))
}

private func pkcs7Pad(_ data: [UInt8]) -> [UInt8] {
    let pad = 16 - data.count % 16
    return data + [UInt8](repeating: UInt8(pad), count: pad)
}
