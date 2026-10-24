// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// 登录凭据。cookie 是登录态；deviceId/installId 是注册过的设备；device 是附加设备指纹。
struct AccountCredentials {
    let cookie: String
    let deviceId: String
    let installId: String
    let device: [String: String]

    func toJson() -> String {
        let obj: [String: Any] = ["cookie": cookie, "deviceId": deviceId, "installId": installId, "device": device]
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
    static func fromJson(_ value: String) throws -> AccountCredentials {
        guard let data = value.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "HongguoAccount", code: 1, userInfo: [NSLocalizedDescriptionKey: "登录态格式异常"])
        }
        let cookie = json["cookie"] as? String ?? ""
        let deviceId = json["deviceId"] as? String ?? ""
        let installId = json["installId"] as? String ?? ""
        let device = (json["device"] as? [String: Any])?.compactMapValues { $0 as? String } ?? [:]
        return AccountCredentials(cookie: cookie, deviceId: deviceId, installId: installId, device: device)
    }
}

struct CloudProfile {
    let id: String
    let nickname: String
}

struct CloudProgress {
    let series: Series
    let episodeId: String
    let episodeIndex: Int
    let position: Int64
    let duration: Int64
    let updatedAt: Int64
    let episodeCount: Int
}

struct CloudFavorite {
    let series: Series
    let collectedAt: Int64
}

struct CloudReservation {
    let series: Series
    let online: Bool
    let publishAt: Int64
    let publishText: String
}

/// 账号操作失败的异常。
struct AccountError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    let code: Int?
    let canRetryCode: Bool
    init(_ message: String, code: Int? = nil, canRetryCode: Bool = false) {
        self.message = message; self.code = code; self.canRetryCode = canRetryCode
    }
    var description: String { message }
    var errorDescription: String? { message }
    var localizedDescription: String { message }
}

/// 打码手机号 + 重试秒数（WebLogin 发送验证码返回；Mac 仅扫码登录，此类型仅为完整性保留）。
struct SentCode {
    let maskedMobile: String
    let retrySeconds: Int
}

/// 上游 EpisodeSummary.total —— 从 badge 解析总集数。
func episodeTotal(_ badge: String) -> Int {
    let pattern = #"(?:全|共|更新至)\s*(\d+)\s*集"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let m = regex.firstMatch(in: badge, range: NSRange(badge.startIndex..<badge.endIndex, in: badge)),
          m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: badge), let v = Int(badge[r]), v > 0 else { return 0 }
    return v
}
