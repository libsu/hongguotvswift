// SPDX-License-Identifier: GPL-3.0-only
// verify Swift CommentSignature matches the 上游 gold vectors.
import Foundation

@main struct CommentSignatureAlignment {
    static func main() {
        let query = "aid=8662&device_id=123"
        let now: Int64 = 1700000000123
        let nonce: [UInt8] = Array(0..<11).map { UInt8($0) }
        let headers = CommentSignature().headers(query: query, now: now, nonce: nonce)

        assert(headers["X-Gorgon"] == "840420e100007c44bd0bfe74163888622f1454edf858fca6234c",
               "X-Gorgon = \(headers["X-Gorgon"] ?? "nil")")
        assert(headers["X-Ladon"] == "AgMEBVbVr6bCGXEl3RbL1aAkpFGUXoV+4yYWolKDMC0DpDXW",
               "X-Ladon = \(headers["X-Ladon"] ?? "nil")")
        let expectedArgus = "PMxPj+JImxTKEfQuAsVmWpqWW55ysbz50VgZsw7nAusOgw1l8frdM9uBXSga5sP42uqiFTi9IcF4fLQ1tKcCzvCOSimC41NEVEjNJLzfEjRxKwyqbtbQ2qLvZl/PhMRPjEMMqLnDX064CGeH7Rt9JbxGmLTNLw4v83XXXrMDozK17tDXIJ3nJPCCh70TOfOE//cWmfoxWrWZ68qMlErAsRCe"
        assert(headers["X-Argus"] == expectedArgus,
               "X-Argus = \(headers["X-Argus"] ?? "nil")")
        print("[PASS] CommentSignature 对齐通过（Gorgon/Ladon/Argus 逐字节一致）")
    }
}
