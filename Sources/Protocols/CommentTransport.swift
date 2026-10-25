// SPDX-License-Identifier: GPL-3.0-only
// 评论列表的匿名只读传输层（含签名）。绝不携带账号凭据。
import Foundation

final class CommentTransport {
    private let http: HongguoHTTP
    private let signature = CommentSignature()
    private let clock: () -> Int64

    init(http: HongguoHTTP = HongguoHTTP(), clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.clock = clock
    }

    func read(episode: String, payload: [String: Any], source: Int, channel: Int) async throws -> [String: Any] {
        let query: [String: String] = [
            "aid": "8662", "app_name": "novelread", "version_code": "73532", "version_name": "7.3.5.32",
            "manifest_version_code": "73532", "update_version_code": "73532", "channel": "update_64",
            "device_platform": "android", "os": "android", "ssmix": "a", "device_type": "25053RT47C",
            "device_brand": "Redmi", "language": "zh", "os_api": "36", "os_version": "16",
            "resolution": "1280*2772", "dpi": "520", "ac": "wifi",
            "device_id": "7397450988462912345", "iid": "7397450988462912346",
            "_rticket": String(clock()),
        ]
        // 上游: query.toSortedMap().entries... 按 key 排序后 URL 编码
        let encoded = query.keys.sorted().map { "\(UrlEncode($0))=\(UrlEncode(query[$0]!))" }.joined(separator: "&")
        let url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/commentapi/comment/list/\(episode)/v1/?\(encoded)"
        var headers: [String: String] = [
            "User-Agent": "com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",
            "Accept": "application/json",
            "X-XS-From-Web": "0",
            "Sdk-Version": "2",
            "Comment-Source": String(source),
            "Server-Channel": String(channel),
        ]
        for (k, v) in signature.headers(query: encoded, now: clock()) { headers[k] = v }
        let body = try! JSONSerialization.data(withJSONObject: payload)
        // followRedirects(false) —— 评论传输层禁止跟随重定向
        let response = try await http.request(url, method: "POST", headers: headers, body: body, limit: 2 * 1024 * 1024, followRedirects: false)
        guard (200..<300).contains(response.statusCode) else { throw ContentError("评论读取失败（HTTP \(response.statusCode)）", statusCode: response.statusCode) }
        guard response.data.count <= 2 * 1024 * 1024 else { throw ContentError("评论响应过大") }
        return try parseJSON(response.data)
    }
}

/// URLEncoder.encode 语义：保留字母数字和 -_.*，其余按 %XX（大写）转义。
private func UrlEncode(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.*")
    return s.addingPercentEncoding(withAllowedCharacters: allowed)!
        .replacingOccurrences(of: "+", with: "%20")
}
