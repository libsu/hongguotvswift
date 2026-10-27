// SPDX-License-Identifier: GPL-3.0-only
// 直译 desktop-mac/backend/.../MacAccount.kt —— 账号会话编排（跨平台共享，原名带 Mac 前缀易误导）。
// 凭据只存内存；登录态由 Model 持久化到钥匙串（SessionKeychain）。
import Foundation

@MainActor
final class AccountSession {
    private let client: CloudAccountClient
    private var credentials: AccountCredentials?
    private var profile: CloudProfile?
    private var login: WebLogin?
    private var loginID = ""

    init(http: HongguoHTTP) {
        self.client = CloudAccountClient(http: http)
    }

    /// 死代码：当前无调用方。
    func snapshot() -> AccountCredentials? { credentials }

    /// 处理一个 account/<action>，返回 JSON 结构（供 Model 复用 Decodable 解码）。
    func handle(action: String, query: [String: String], body: [String: Any]) async throws -> [String: Any] {
        let started = Date()
        do {
            let result = try await dispatch(action: action, query: query, body: body)
            Log.shared.info("account \(action) ok \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return result
        } catch {
            Log.shared.warn("account \(action) failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func dispatch(action: String, query: [String: String], body: [String: Any]) async throws -> [String: Any] {
        switch action {
        case "status": return user()
        case "restore":
            guard let credStr = body["credentials"] as? String else { throw AccountError("登录态缺失") }
            let next = try AccountCredentials.fromJson(credStr)
            let verified = try await client.profile(credentials: next)
            credentials = next; profile = verified
            return user()
        case "qr":
            login?.cancel(); credentials = nil; profile = nil
            let web = WebLogin(http: HongguoHTTP())
            let qr = try await web.qr()
            login = web; loginID = UUID().uuidString
            return ["image": base64Encode(qr.image), "expiresIn": qr.expiresIn, "loginID": loginID]
        case "poll":
            let requestedID = query["loginID"] ?? ""
            guard requestedID == loginID else { throw AccountError("登录会话已变化，请重新扫码") }
            guard let current = login else { throw AccountError("登录会话不存在，请重新扫码") }
            let loggedIn = try await current.poll()
            guard loggedIn else { return ["loggedIn": false] }
            let device = try await client.registerDevice()
            guard let device else { throw AccountError("账号设备初始化失败") }
            let next = try await current.credentials()
            let full = AccountCredentials(cookie: next.cookie, deviceId: device.deviceId, installId: device.installId, device: ["device_id": device.deviceId, "iid": device.installId])
            let verified = try await client.profile(credentials: full)
            credentials = full; profile = verified; login = nil
            return user(export: true)
        case "cancel":
            if let cancelID = body["loginID"] as? String, cancelID == loginID, !loginID.isEmpty {
                login?.cancel(); login = nil; loginID = ""; credentials = nil; profile = nil
            }
            return ["ok": true]
        case "logout":
            login?.cancel(); login = nil; loginID = ""; credentials = nil; profile = nil
            return ["ok": true]
        case "history":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            let rows = try await client.history(credentials: credentials)
            return ["items": rows.map { itemJSON($0.series, episodeID: $0.episodeId, episodeIndex: $0.episodeIndex, position: Double($0.position) / 1000.0, duration: Double($0.duration) / 1000.0) }]
        case "favorites":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            let rows = try await client.favorites(credentials: credentials)
            return ["items": rows.map { ["series": seriesJSON($0.series)] }]
        case "favorite":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            guard let id = body["id"] as? String else { throw AccountError("剧集编号缺失") }
            let add = (body["add"] as? Bool) ?? false
            try await client.setFavorite(credentials: credentials, seriesId: id, add: add)
            let confirmed = try await client.favorites(credentials: credentials).contains { $0.series.id == id }
            guard confirmed == add else { throw AccountError("账户收藏尚未确认，请刷新列表核对") }
            return ["ok": true]
        case "reservations":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            let online = (query["online"] ?? "true") != "false"
            let rows = try await client.reservations(credentials: credentials, online: online)
            return ["items": rows.map { ["series": seriesJSON($0.series), "online": $0.online, "publishText": $0.publishText] }]
        case "reserve":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            guard let id = body["id"] as? String else { throw AccountError("剧集编号缺失") }
            let work = RelatedWork(series: Series(id: id, title: "预约作品", cover: "", description: "", badge: ""), season: "", upcoming: true)
            try await client.reserve(credentials: credentials, work: work)
            let confirmed = try await client.reservations(credentials: credentials, online: false).contains { $0.series.id == id }
            return ["ok": true, "confirmed": confirmed]
        case "upload":
            guard let credentials else { throw AccountError("请先扫码登录红果账号") }
            guard let seriesObj = body["series"] as? [String: Any],
                  let episodeID = body["episodeID"] as? String,
                  let episodeIndex = intValue(body["episodeIndex"]),
                  let position = int64Value(body["position"]),
                  let duration = int64Value(body["duration"]) else {
                throw AccountError("上传参数缺失")
            }
            let series = Series(id: seriesObj.str("id"), title: seriesObj.str("title"), cover: seriesObj.str("cover"), description: seriesObj.str("description"), badge: seriesObj.str("badge"), tags: seriesObj.str("tags"))
            let episodeCount = intValue(body["episodeCount"]) ?? 0
            let progress = CloudProgress(series: series, episodeId: episodeID, episodeIndex: episodeIndex, position: position, duration: duration, updatedAt: clock(), episodeCount: episodeCount)
            try await client.upload(credentials: credentials, progress: progress, episodeCount: episodeCount)
            return ["ok": true]
        default:
            throw AccountError("账号操作不受支持")
        }
    }

    private func clock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func intValue(_ v: Any?) -> Int? {
        switch v {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
    private func int64Value(_ v: Any?) -> Int64? {
        switch v {
        case let n as Int64: return n
        case let n as Int: return Int64(n)
        case let n as NSNumber: return n.int64Value
        case let n as Double: return Int64(n)
        case let s as String: return Int64(s)
        default: return nil
        }
    }

    private func user(export: Bool = false) -> [String: Any] {
        var obj: [String: Any] = ["loggedIn": profile != nil]
        if let profile {
            obj["id"] = profile.id
            obj["nickname"] = profile.nickname
        }
        if export, let credentials { obj["credentials"] = credentials.toJson() }
        return obj
    }

    private func seriesJSON(_ s: Series) -> [String: Any] {
        ["id": s.id, "title": s.title, "cover": s.cover, "description": s.description, "badge": s.badge, "tags": s.tags]
    }

    private func itemJSON(_ series: Series, episodeID: String, episodeIndex: Int, position: Double, duration: Double) -> [String: Any] {
        ["series": seriesJSON(series), "episodeID": episodeID, "episodeIndex": episodeIndex, "position": position, "duration": duration]
    }

    func close() {
        login?.cancel(); credentials = nil; profile = nil
    }
}
