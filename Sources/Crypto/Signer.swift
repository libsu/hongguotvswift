// SPDX-License-Identifier: GPL-3.0-only
// 只输出 hash 分支 0。
//
// 对齐约定：
//  - 上游 Int(32 位 wrap)   -> Swift 用 Int32 配合 &+ &- &<< 等 wrap 运算符，位运算用 & | ^ ~
//  - 上游 Int ushr(逻辑右移) -> 先转 UInt32 再 >>，再转回 Int32(bitPattern:)
//  - 上游 Long(64 位)        -> Swift Int64，rotate 用 UInt64
//  - 上游 ByteArray          -> [UInt8]
import Foundation

final class Signer {
    struct Request {
        let url: String
        let headers: [String: String]
        let body: [UInt8]?
    }

    private let clock: () -> Int64
    private let device: [String: String]
    private let random: () -> Double

    init(clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         device: [String: String] = VendorConstants.device,
         random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.clock = clock
        self.device = device
        self.random = random
    }

    // MARK: - 基础工具（对应 上游 private fun）

    private func rand() -> Int32 { Int32(bitPattern: UInt32((random() * 4294967296.0).rounded(.down))) }
    private func unsigned(_ v: Int32) -> UInt32 { UInt32(bitPattern: v) }

    private func varint(_ value: Int64) -> [UInt8] {
        var n = UInt64(bitPattern: value)
        var out: [UInt8] = []
        while n > 127 {
            out.append(UInt8((n & 127) | 128))
            n = n >> 7
        }
        out.append(UInt8(n))
        return out
    }

    private enum FieldType { case string, sint, float }
    private struct Field { let tag: Int; let value: Any; let type: FieldType }
    private func f(_ tag: Int, _ value: Any, _ type: FieldType = .string) -> Field { Field(tag: tag, value: value, type: type) }

    private func proto(_ fields: [Field]) -> [UInt8] {
        var out: [UInt8] = []
        for field in fields {
            switch field.type {
            case .sint:
                let n: Int64
                if let v = field.value as? Int { n = Int64(v) }
                else if let v = field.value as? Int32 { n = Int64(v) }
                else { n = field.value as! Int64 }
                out += varint(Int64(field.tag) << 3)
                out += varint(n < 0 ? -n * 2 - 1 : n * 2)
            case .float:
                let f0: Float
                if let v = field.value as? Double { f0 = Float(v) }
                else { f0 = Float(truncating: field.value as! NSNumber) }
                out += varint((Int64(field.tag) << 3) | 5)
                var v = f0.bitPattern
                for _ in 0..<4 { out.append(UInt8(v & 0xff)); v >>= 8 }
            case .string:
                let bytes: [UInt8]
                if let b = field.value as? [UInt8] { bytes = b }
                else { bytes = Array((field.value as! String).utf8) }
                if !bytes.isEmpty {
                    out += varint((Int64(field.tag) << 3) | 2)
                    out += varint(Int64(bytes.count))
                    out += bytes
                }
            }
        }
        return out
    }
    private func proto(_ fields: Field...) -> [UInt8] { proto(fields) }

    private func getIv(_ initial: Int32, _ data: [UInt8]) -> Int32 {
        var value = initial
        for (i, byte) in data.enumerated() {
            let b = Int32(byte)
            if i & 1 == 0 {
                value = Int32(bitPattern: (UInt32(bitPattern: value) >> 4) ^ UInt32(bitPattern: value) ^ (UInt32(bitPattern: value) << 6) ^ UInt32(bitPattern: b))
            } else {
                value = ~Int32(bitPattern: (UInt32(bitPattern: value) >> 7) ^ UInt32(bitPattern: value) ^ (UInt32(bitPattern: b) | (UInt32(bitPattern: value) << 12)))
            }
        }
        return value
    }
    private func iv(_ query: [UInt8], _ body: [UInt8], _ ts: Int32) -> Int32 {
        getIv(getIv(getIv(Int32(bitPattern: 0x20230928), query), body), le32(ts))
    }

    func branch(query: String, body: [UInt8]?, ts: Int32) -> Int32 {
        let q = Array(query.utf8)
        let b = body != nil ? digest("MD5", body!) : [UInt8](repeating: 0, count: 16)
        return Int32(bitPattern: (UInt32(bitPattern: iv(sm3(q), b, ts)) & 15) % 3)
    }

    private func sumMd5(_ data: [UInt8]) -> Int32 {
        var check = Int32(bitPattern: 0x20220420)
        for i in 0..<12 {
            let temp: Int32 = (i & 1 == 0)
                ? Int32(bitPattern: (UInt32(bitPattern: check) >> 3) ^ UInt32(bitPattern: check))
                : Int32(bitPattern: (UInt32(bitPattern: check) >> 5) ^ UInt32(bitPattern: check))
            if i & 1 == 0 {
                check = Int32(data[i]) ^ (check << 7)
            } else {
                let b = Int32(data[i])
                check = ~Int32(bitPattern: UInt32(bitPattern: b) | UInt32(bitPattern: check << 11))
            }
            check = check ^ temp
        }
        return Int32(bitPattern: (UInt32(bitPattern: check) | 4) ^ 0x1000000)
    }

    private func ror32(_ v: Int32, _ n: Int) -> Int32 {
        let u = UInt32(bitPattern: v)
        let nn = UInt32(n & 31)
        return Int32(bitPattern: (u >> nn) | (u << (32 - nn)))
    }

    func hashF13(query: [UInt8], body: [UInt8], ts: Int32) -> [UInt8] {
        let ivVal = iv(query, body, ts)
        let ivU = UInt32(bitPattern: ivVal)
        let index = Int((ivU & 15) / 3)
        precondition((ivU & 15) % 3 == 0, "Unsupported hash branch")

        let ivV1Tbl: [Int32] = [
            Int32(bitPattern: 0xc4a78580), Int32(bitPattern: 0xb3c0fd39), Int32(bitPattern: 0xc58c5686),
            Int32(bitPattern: 0xc9aa3ba7), Int32(bitPattern: 0xf5a7adf2), Int32(bitPattern: 0x963c2ed1),
        ]
        let ivV1 = ivV1Tbl[index]
        let count = ivV1 &+ ts
        let tt = VendorConstants.hashTable.map { ror32($0, Int((count &+ 1) & 255)) }
        let shift = Int((count &+ 2) & 7)

        let padVals: [Int32] = [0xfa, 0x45, 0x61, 0xd7]
        let pad = padVals.map { UInt8(truncatingIfNeeded: (UInt32(bitPattern: ($0 | ($0 << 8))) >> UInt32(shift)) & 0xff) }

        let data = query + body + le32(ts) + pad + hexBytes("00000000000001a0")

        var di: [Int32] = []
        for at in stride(from: 0, to: data.count, by: 4) {
            di.append(readI32(data, at))
        }
        for i in 0..<112 {
            let x = di[i + 1], y = di[i + 14]
            let rol14x = Int32(bitPattern: (UInt32(bitPattern: x) << 14) | (UInt32(bitPattern: x) >> 18))
            let rol25x = Int32(bitPattern: (UInt32(bitPattern: x) << 25) | (UInt32(bitPattern: x) >> 7))
            let shr3x = Int32(bitPattern: UInt32(bitPattern: x) >> 3)
            let rol13y = Int32(bitPattern: (UInt32(bitPattern: y) << 13) | (UInt32(bitPattern: y) >> 19))
            let rol15y = Int32(bitPattern: (UInt32(bitPattern: y) << 15) | (UInt32(bitPattern: y) >> 17))
            let shr10y = Int32(bitPattern: UInt32(bitPattern: y) >> 10)
            let term = di[i] &+ di[i + 9] &+ (rol14x ^ rol25x ^ shr3x) &+ (rol13y ^ rol15y ^ shr10y)
            di.append(term)
        }

        let initialInit: [Int32] = [
            Int32(bitPattern: 0x7aba4fc8), Int32(bitPattern: 0x67166507), Int32(bitPattern: 0x6403fa00), Int32(bitPattern: 0x340f512f),
            984304912, Int32(bitPattern: 3005047866), Int32(bitPattern: 2874125293), Int32(bitPattern: 2152413264),
        ]
        let initial = initialInit.map { ror32($0, Int(count)) }

        let chosenTbl: [[Int]] = [
            [101, 5, 7, 6, 3, 2, 1, 0, 5, 4, 3],
            [96, 0, 6, 7, 5, 3, 2, 1, 5, 4, 4],
            [96, 7, 6, 2, 1, 4, 0, 5, 4, 3, 5],
            [99, 3, 6, 2, 4, 5, 1, 0, 0, 7, 6],
            [96, 0, 5, 6, 7, 3, 1, 2, 5, 4, 4],
            [100, 2, 0, 3, 5, 4, 6, 7, 2, 1, 5],
        ]
        let chosen = chosenTbl[index]

        var d = initial
        for i in 0..<chosen[0] {
            let base = Int(ivV1 &+ Int32(i))
            let n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
            let rol26 = ror32(d[chosen[1]], -26) // 左移 26 位 = 右移 -26
            let rol21 = ror32(d[chosen[1]], -21)
            let rol7 = ror32(d[chosen[1]], -7)
            let n2 = rol26 ^ rol21 ^ rol7
            let ttBase = base & 63
            let n4 = di[base & 127] &+ n1 &+ n2 &+ tt[ttBase] &+ d[chosen[5]]
            let rol30 = ror32(d[chosen[2]], -30)
            let rol19 = ror32(d[chosen[2]], -19)
            let rol10 = ror32(d[chosen[2]], -10)
            let n5 = rol30 ^ rol19 ^ rol10
            let n6 = (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
            let old = d[chosen[9]]
            d.remove(at: 7)
            d.insert(0, at: 0)
            // 上游: d.add(0, d.removeAt(7)) —— 把索引7的元素移到最前
            let removed = d.remove(at: 7)
            d.insert(removed, at: 0)
            d[chosen[10]] = n5 &+ n6 &+ n4
            d[chosen[8]] = old &+ n4
        }

        var ret: [UInt8] = []
        for i in 0..<8 { ret += be32(d[i] &+ initial[i]) }
        let folded = xor(Array(ret[0..<16]), Array(ret[16..<32]))
        return folded + le32(sumMd5(folded))
    }

    func gorgon(query: String, body: [UInt8]?, ts: Int32, random: Int32) -> String {
        let qMc = Array(digest("MD5", Array(query.utf8))[0..<4])
        let bMc = body != nil ? Array(digest("MD5", body!)[0..<4]) : [UInt8](repeating: 0, count: 4)
        let input = qMc + bMc + [UInt8](repeating: 0, count: 4) + le32(67503104) + be32(ts)

        let key: [Int32] = [
            0x4a, 0x40, 0x16, Int32((UInt32(bitPattern: random) >> 8) & 255),
            0x47, 0x6c, 1, random & 255,
        ]
        var s = (0..<256).map { Int32($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % 8])) & 255
            s.swapAt(i, j)
        }
        j = 0
        var out = [UInt8](repeating: 0, count: input.count)
        for n in 0..<input.count {
            let i = n + 1
            j = (j + Int(s[i])) & 255
            let y = s[j]
            s[i] = y
            let v = UInt8((Int(input[n]) ^ Int(s[(Int(y) + Int(y)) & 255])) & 0xff)
            out[n] = v
        }
        for i in 0..<out.count {
            let cur = Int(out[i])
            let value = ((cur >> 4) | (cur << 4)) & 255
            let next = Int(out[(i + 1 < out.count) ? i + 1 : 0])
            let reversed = UInt32((next ^ value) & 255).byteSwapped >> 24
            out[i] = UInt8(truncatingIfNeeded: ~Int32(bitPattern: reversed ^ 20))
        }
        return hexString(hexBytes("8404") + [UInt8(truncatingIfNeeded: random), UInt8((UInt32(bitPattern: random) >> 8) & 0xff), 0x40, 1] + out)
    }

    private func deviceProto() -> [UInt8] {
        proto(
            f(1, 1, .sint), f(2, 2, .sint), f(3, "8662"), f(4, device["device_id"]!), f(5, "Ai6svO3PyrwDOUSmO6ZcResxu"),
            f(6, "!noperm!"), f(7, -888888, .sint), f(8, -888888, .sint), f(9, 3, .sint), f(10, -888888, .sint),
            f(11, "!notset!"), f(12, "Asia/Shanghai,8"), f(13, "zh_CN"), f(14, 4, .sint), f(16, 255.24993896484375, .float),
            f(17, 35.58599090576172, .float), f(18, 3.467449188232422, .float), f(19, 3.467449188232422, .float),
            f(20, 255.1754913330078, .float), f(21, 42.17544174194336, .float), f(22, "16"), f(23, 41, .sint),
            f(24, 36, .sint), f(25, 1728388016635, .sint), f(26, 1728388016635, .sint), f(27, 1728388016635, .sint),
            f(28, 1728388016637, .sint), f(29, -1, .sint), f(30, "25053RT47C"), f(31, "Redmi"), f(32, "25053RT47C"),
            f(33, "25053RT47C"), f(34, "Xiaomi"), f(35, "Redmi"), f(36, "Redmi"), f(38, 31, .sint)
        )
    }

    private func xmxor(data: [UInt8], key: [UInt8]) -> [UInt8] {
        var encoded = [Int32](repeating: 0, count: data.count)
        for i in 0..<data.count {
            let at = (i * 4) & 28
            let d0 = Int32(key[at]), d1 = Int32(key[at + 1])
            let v = Int32(data[i])
            var d2: Int32 = Int32(bitPattern: ((UInt32(bitPattern: v) << 4) | (UInt32(bitPattern: v) >> 4)) & 255) &+ d0
            d2 = ~d2 ^ d1
            d2 = Int32(bitPattern: ((UInt32(bitPattern: d2) & 255) << 3) | ((UInt32(bitPattern: d2) & 255) >> 5)) & 255
            d2 = (d2 &+ d1) & 255
            d2 = (d2 ^ d0) & 255
            encoded[data.count - i - 1] = ~d2 & 255
        }
        let last = encoded.last! ^ encoded[encoded.count - 2]
        let first = encoded[0]
        encoded[0] = ((~last) &+ first) & 255
        encoded[1] = ((encoded[0] ^ encoded.last! ^ 254) &+ encoded[1]) & 255
        let rotPart = Int32(bitPattern: (UInt32(bitPattern: (encoded[1] << 3) | (encoded[1] >> 5))) & 255)
        let mid = (last &- first) ^ rotPart ^ 2
        encoded[2] = (encoded[2] &+ mid) & 255
        for i in 0..<(encoded.count - 4) {
            let r5: Int32 = Int32(bitPattern: ((UInt32(bitPattern: encoded[i + 2]) << 3) | (UInt32(bitPattern: encoded[i + 2]) >> 5)) & 255)
            let temp = (r5 ^ encoded[i + 1] ^ Int32(i + 3)) & 255
            encoded[i + 3] = ((~temp) &+ encoded[i + 3]) & 255
        }
        encoded[encoded.count - 1] = encoded.last! ^ encoded[encoded.count - 2]
        var v0 = encoded[0] ^ encoded[1]
        var sum: Int32 = 0
        for i in 1..<encoded.count { sum &+= encoded[i] }
        v0 = (v0 &+ sum) & 255
        encoded[0] = v0
        return encoded.map { UInt8(truncatingIfNeeded: $0) }
    }

    func medusa(url: String, body: [UInt8]?, ts: Int32) -> String {
        let bodyMd5 = body != nil ? digest("MD5", body!) : [UInt8](repeating: 0, count: 16)
        let query = Array(url[url.firstIndex(of: "?")!...].dropFirst().utf8)
        let querySm3 = sm3(query)
        let queryBodyTs = hashF13(query: querySm3, body: bodyMd5, ts: ts)
        let nested = proto(f(1, 111, .sint), f(2, 10, .sint), f(3, 694367, .sint), f(5, 586952199, .sint))
        let messageRand = unsigned(rand())
        let envLaunch = Int(random() * 21) + 100
        let envPid = Int(random() * 2000) + 10001
        let version = device["version_name"]!
        let env = proto(
            f(1, envLaunch, .sint), f(2, 146331399, .sint), f(3, 146331396, .sint), f(5, 7, .sint),
            f(6, "v04.06.04.03-bugfix"), f(7, envPid, .sint), f(12, deviceProto()),
            f(13, proto(f(1, Int(clock() / 1000), .sint), f(2, -2, .sint), f(4, 200, .sint))), f(14, version)
        )
        let queryHash = sm3(query + bodyMd5 + Array("none".utf8))
        let jsonStr = """
        {"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}
        """
        let message = proto(
            f(1, hexBytes("f7e85ffad7d7dc3bd62ac87057cf6118")), f(2, 3, .sint), f(3, Int(messageRand), .sint),
            f(4, "8662"), f(5, device["device_id"]!), f(6, "1588093228"), f(7, version), f(8, "v04.06.04-ml-android"),
            f(9, 67503104, .sint), f(10, hexBytes("4001000000000000")), f(12, ts, .sint), f(13, queryBodyTs),
            f(14, Array(querySm3[0..<6])), f(15, nested), f(16, "AXYQOS6n2m60x1fVZHIrH3iol"), f(17, ts, .sint),
            f(19, queryHash), f(20, "none"), f(21, 312, .sint), f(23, env), f(24, jsonStr)
        )
        let r = rand()
        let signKey = hexBytes("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
        let hash = sm3(signKey + le32(r) + signKey)
        let rU = UInt32(bitPattern: r)
        let d1 = Int32((rU >> 16) & 255)
        let d1s = Int32(d1)
        let inner = Int32(bitPattern: ((UInt32(bitPattern: d1s) << 11) | (rU >> 24)) ^ (UInt32(bitPattern: d1s) >> 5) ^ UInt32(bitPattern: d1s))
        let seed = le32(~inner)
        var transformed = Array((hexBytes("4001000000000000") + xmxor(data: message, key: hash)).reversed())
        for i in 0..<transformed.count {
            let sIdx = (~i) & 3
            transformed[i] = transformed[i] ^ seed[sIdx]
        }
        let check = UInt32(((UInt32(querySm3[0]) & 63) << 14) | 0x18000001 | ((UInt32(queryBodyTs[0]) & 63) << 8))
        let packed = [UInt8]([0x35]) + le32(rand()) + le32(Int32(bitPattern: check)) + transformed + [UInt8((UInt32(bitPattern: r) >> 16) & 0xff), UInt8((UInt32(bitPattern: r) >> 24) & 0xff)]
        let encrypted = AesV3(key: hexBytes("f1593376766ea98d34f31b057a9d5be4"), timestamp: Int(ts)).encrypt(source: packed, iv: hexBytes("1fe109a4125283f418de9e051a969e12"))
        let versionBytes = hexBytes("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
        var prefix: [UInt8] = []
        for i in stride(from: 0, to: 20, by: 4) {
            let v = readI32(versionBytes, i, little: true)
            prefix += le32(v ^ ts)
        }
        return base64Encode(prefix + [UInt8(truncatingIfNeeded: r), UInt8((UInt32(bitPattern: r) >> 8) & 0xff), 0, 1] + encrypted)
    }

    private func ror64(_ v: Int64, _ n: Int) -> Int64 {
        let u = UInt64(bitPattern: v)
        let nn = UInt64(n & 63)
        return Int64(bitPattern: (u >> nn) | (u << (64 - nn)))
    }

    func helios(ts: Int32) -> String {
        let random = rand()
        let ascii = Array(hexString(digest("MD5", le32(random) + Array("8662".utf8))).utf8)
        var words: [Int64] = []
        for i in 0..<4 { words.append(readI64(ascii, i * 8, little: true)) }
        var table: [Int64] = [words[0]]
        var b0 = words.removeFirst()
        var b8 = words.removeFirst()
        for i in 0..<34 {
            var x8 = (ror64(b8, 8) &+ b0) ^ Int64(i)
            words.append(x8)
            x8 = x8 ^ ror64(b0, 61)
            table.append(x8)
            b0 = x8
            b8 = words.removeFirst()
        }
        let text = Array("\(Int(ts))-1588093228-8662".utf8)
        let padding = 16 - (text.count % 16)
        let data = text + [UInt8](repeating: UInt8(padding), count: padding)
        var output = le32(random)
        for at in stride(from: 0, to: data.count, by: 16) {
            var a = readI64(data, at, little: true)
            var b = readI64(data, at + 8, little: true)
            for i in 0..<34 {
                b = table[i] ^ (a &+ ror64(b, 8))
                a = b ^ ror64(a, 61)
            }
            output += le64(a) + le64(b)
        }
        return base64Encode(output)
    }

    func sign(base: String, values: [String: String], body: [UInt8]? = nil) -> Request {
        let now = clock()
        let ts = Int32(now / 1000)
        var ticket = now
        var query = ""
        for offset in 0...127 {
            ticket = now + Int64(offset)
            var merged = values
            merged["ts"] = String(Int(ts))
            merged["_rticket"] = String(ticket)
            query = Self.encode(merged)
            if branch(query: query, body: body, ts: ts) == 0 {
                let url = "\(base)?\(query)"
                let random = Int32(Int((random() * 65536).rounded(.down)))
                var headers: [String: String] = [
                    "User-Agent": (body != nil) ? VendorConstants.VIDEO_UA : VendorConstants.APP_UA,
                    "Accept": "application/json; charset=utf-8,application/x-protobuf",
                    "x-ss-req-ticket": String(ticket),
                    "x-tt-request-tag": "t=0;n=0",
                    "sdk-version": "2",
                    "passport-sdk-version": "50561",
                    "x-xs-from-web": "0",
                    "x-khronos": String(Int(ts)),
                    "x-ladon": base64Encode(be32(ts)),
                    "x-argus": base64Encode(le32(ts)),
                    "x-gorgon": gorgon(query: query, body: body, ts: ts, random: random),
                    "x-helios": helios(ts: ts),
                    "x-medusa": medusa(url: url, body: body, ts: ts),
                    "x-tt-dt": "",
                ]
                if body != nil {
                    headers["Content-Type"] = "application/json; charset=UTF-8"
                    headers["x-vc-bdturing-sdk-version"] = "3.7.2.cn"
                    headers["x-ss-stub"] = hexString(digest("MD5", body!)).uppercased()
                }
                return Request(url: url, headers: headers, body: body)
            }
        }
        preconditionFailure("无法生成请求签名")
    }

    static func encode(_ values: [String: String]) -> String {
        values.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&")
    }
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowed)!
            .replacingOccurrences(of: "+", with: "%20")
            .replacingOccurrences(of: "%7E", with: "~")
    }
    private static let allowed: CharacterSet = {
        // 对应 上游 URLEncoder.encode(value, "UTF-8")：
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-_.*")
        return cs
    }()
}
