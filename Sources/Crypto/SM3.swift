// SPDX-License-Identifier: GPL-3.0-only
// GM/T 0004-2012 SM3 摘要，输出 256 位。
// 对齐要点：上游 Int 是 32 位 wrap-around，Swift 用 Int32 + 溢出运算符(&+, &<<, &>>)。
import Foundation

enum SM3 {
    private static let iv: [UInt32] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
    ]
    private static let t: [UInt32] = (0..<64).map { UInt32(bitPattern: ($0 < 16 ? Int32(bitPattern: 0x79cc4519) : Int32(bitPattern: 0x7a879d8a))) }

    static func digest(_ data: [UInt8]) -> [UInt8] {
        let len = data.count
        let paddedLen = (((len + 8) / 64) + 1) * 64
        var padded = [UInt8](repeating: 0, count: paddedLen)
        padded.replaceSubrange(0..<len, with: data)
        padded[len] = 0x80
        let bitLen = UInt64(len) * 8
        for i in 0..<8 {
            padded[paddedLen - 1 - i] = UInt8((bitLen >> (i * 8)) & 0xff)
        }

        var v: [UInt32] = iv
        var w = [UInt32](repeating: 0, count: 68)
        var w1 = [UInt32](repeating: 0, count: 64)

        var offset = 0
        while offset < paddedLen {
            for j in 0..<16 {
                w[j] = readU32(padded, offset + j * 4)
            }
            for j in 16..<68 {
                w[j] = p1(w[j - 16] ^ w[j - 9] ^ rotl(w[j - 3], 15)) ^ rotl(w[j - 13], 7) ^ w[j - 6]
            }
            for j in 0..<64 {
                w1[j] = w[j] ^ w[j + 4]
            }

            var a = v[0], b = v[1], c = v[2], d = v[3]
            var e = v[4], f = v[5], g = v[6], h = v[7]

            for j in 0..<64 {
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t[j], j % 32), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let tt1 = (ff(a, b, c, j) &+ d &+ ss2 &+ w1[j])
                let tt2 = (gg(e, f, g, j) &+ h &+ ss1 &+ w[j])
                d = c
                c = rotl(b, 9)
                b = a
                a = tt1
                h = g
                g = rotl(f, 19)
                f = e
                e = p0(tt2)
            }

            v[0] = v[0] ^ a; v[1] = v[1] ^ b; v[2] = v[2] ^ c; v[3] = v[3] ^ d
            v[4] = v[4] ^ e; v[5] = v[5] ^ f; v[6] = v[6] ^ g; v[7] = v[7] ^ h

            offset += 64
        }

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            let x = v[i]
            out[i * 4] = UInt8((x >> 24) & 0xff)
            out[i * 4 + 1] = UInt8((x >> 16) & 0xff)
            out[i * 4 + 2] = UInt8((x >> 8) & 0xff)
            out[i * 4 + 3] = UInt8(x & 0xff)
        }
        return out
    }

    private static func readU32(_ b: [UInt8], _ at: Int) -> UInt32 {
        (UInt32(b[at]) << 24) | (UInt32(b[at + 1]) << 16) | (UInt32(b[at + 2]) << 8) | UInt32(b[at + 3])
    }

    private static func rotl(_ x: UInt32, _ n: Int) -> UInt32 {
        let nn = UInt32(n & 31)
        return (x << nn) | (x >> (32 - nn))
    }
    private static func p0(_ x: UInt32) -> UInt32 { x ^ rotl(x, 9) ^ rotl(x, 17) }
    private static func p1(_ x: UInt32) -> UInt32 { x ^ rotl(x, 15) ^ rotl(x, 23) }
    private static func ff(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ j: Int) -> UInt32 {
        (j < 16) ? (x ^ y ^ z) : ((x & y) | (x & z) | (y & z))
    }
    private static func gg(_ x: UInt32, _ y: UInt32, _ z: UInt32, _ j: Int) -> UInt32 {
        (j < 16) ? (x ^ y ^ z) : ((x & y) | (~x & z))
    }
}
