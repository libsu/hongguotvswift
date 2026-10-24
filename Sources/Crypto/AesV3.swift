// SPDX-License-Identifier: GPL-3.0-only
// 协议专用变换（非标准 AES）。
// 上游 Int 为 32 位 wrap，Swift 用 Int(0..255) 表达字节、Int32/UInt32 表达 32 位运算，
// 所有 & 掩码到 255/32 位以确保与 上游 一致。
import Foundation

struct AesV3 {
    private let word: Int
    private let box: [Int]
    private let con: [Int]
    private let order: [Int]
    private let keys: [[Int]]

    private static let conTable = [
        [1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3],
    ]
    private static let orderTable = [
        [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
        [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
        [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
        [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
    ]

    init(key: [UInt8], timestamp: Int) {
        let word = timestamp & 3
        self.word = word
        self.box = Array(VendorConstants.sbox[word * 256..<(word + 1) * 256]).map { Int($0) }
        self.con = Self.conTable[word]
        self.order = Self.orderTable[word]

        let initial = [Int(bitPattern: 0xca025ddc), Int(bitPattern: 0x823dc546), Int(bitPattern: 0xc9420583), Int(bitPattern: 0xc298225f)][word]
        let le = le32(initial)
        let combined = le + le + le + le
        let xorBuf = xor(combined, Array(key))
        var expanded = (xorBuf + [UInt8](repeating: 0, count: 32)).map { Int($0) }

        var rounds = 8
        for i in 4..<12 {
            let at = 4 * (i - 1)
            var a = expanded[at], b = expanded[at + 1], c = expanded[at + 2], d = expanded[at + 3]
            if i & 3 == 0 {
                let t = ((initial >> (rounds & 24)) ^ box[b]) & 255
                b = box[c]; c = box[d]; d = box[a]; a = t
            }
            rounds += 2
            expanded[at + 4] = a ^ expanded[at - 12]
            expanded[at + 5] = b ^ expanded[at - 11]
            expanded[at + 6] = c ^ expanded[at - 10]
            expanded[at + 7] = d ^ expanded[at - 9]
        }
        self.keys = (0..<12).map { Array(expanded[$0 * 4..<$0 * 4 + 4]) }
    }

    private func block(_ value: [UInt8]) -> [UInt8] {
        var rows = (0..<4).map { i in (0..<4).map { j in Int(value[i * 4 + j]) } }
        func addCon(_ offset: Int) {
            for i in 0..<4 { for j in 0..<4 { rows[i][j] = rows[i][j] ^ keys[offset + i][con[j]] } }
        }
        addCon(0)
        for round in 1...2 {
            for i in 0..<4 { for j in 0..<4 { rows[i][j] = box[rows[i][j]] } }
            let before = rows.map { $0 }
            for i in 0..<4 { rows[i] = before[con[i]] }
            let flat = rows.flatMap { $0 }
            for i in 0..<16 { rows[i / 4][i % 4] = flat[order[i]] }
            if round == 1 {
                for i in 0..<4 {
                    let old = rows[i]
                    rows[i] = (0..<4).map { old[con[$0]] }
                }
                func xt(_ x: Int) -> Int { ((x << 1) ^ ((x & 128 != 0) ? 0x1b : 0)) & 255 }
                for i in 0..<4 {
                    let t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i]
                    let u = rows[0][i]
                    rows[0][i] = rows[0][i] ^ t ^ xt(rows[0][i] ^ rows[1][i])
                    rows[1][i] = rows[1][i] ^ t ^ xt(rows[1][i] ^ rows[2][i])
                    rows[2][i] = rows[2][i] ^ t ^ xt(rows[2][i] ^ rows[3][i])
                    rows[3][i] = rows[3][i] ^ t ^ xt(rows[3][i] ^ u)
                }
            }
            addCon(round * 4)
        }
        for i in 0..<4 { for j in 0..<4 { rows[i][j] = rows[i][j] ^ keys[4 + i][j] } }
        return rows.flatMap { $0 }.map { UInt8($0 & 0xff) }
    }

    func encrypt(source: [UInt8], iv: [UInt8]) -> [UInt8] {
        precondition(source.count >= 248, "source.size >= 248")
        var plaintext = [UInt8](repeating: 0, count: 32)
        for i in 0..<31 {
            let at = i * 8
            let b0 = Int(source[at]), b1 = Int(source[at + 1]), b2 = Int(source[at + 2]), b3 = Int(source[at + 3])
            let b4 = Int(source[at + 4]), b5 = Int(source[at + 5]), b6 = Int(source[at + 6]), b7 = Int(source[at + 7])
            let v = ((b0 >> 4) & 2) | (b1 & 64) | ((b2 >> 2) & 1) | ((b3 << 3) & 128) | ((b4 >> 1) & 4) | ((b5 << 3) & 16) | ((b6 << 5) & 32) | ((b7 >> 4) & 8)
            plaintext[i] = UInt8(v)
        }
        plaintext[31] = 1
        let first = block(xor(Array(plaintext[0..<16]), Array(iv)))
        let second = block(xor(Array(plaintext[16..<32]), first))
        let key = first + second
        var out = source
        for i in 0..<31 {
            let at = i * 8
            let k = Int(key[i])
            out[at] = UInt8((Int(out[at]) & 0xdf) | ((k << 4) & 32))
            out[at + 1] = UInt8((Int(out[at + 1]) & 0xbf) | (k & 64))
            out[at + 2] = UInt8((Int(out[at + 2]) & 0xfb) | ((k << 2) & 4))
            out[at + 3] = UInt8((Int(out[at + 3]) & 0xef) | ((k >> 3) & 16))
            out[at + 4] = UInt8((Int(out[at + 4]) & 0xf7) | ((k + k) & 8))
            out[at + 5] = UInt8((Int(out[at + 5]) & 0xfd) | ((k >> 3) & 2))
            out[at + 6] = UInt8((Int(out[at + 6]) & 0xfe) | ((k >> 5) & 1))
            out[at + 7] = UInt8((Int(out[at + 7]) & 0x7f) | ((k << 4) & 128))
        }
        return [key.last!] + out
    }
}
