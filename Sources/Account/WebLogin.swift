// SPDX-License-Identifier: GPL-3.0-only
// 官网登录会话：CSRF Cookie 贯穿 get_qrcode / check_qrconnect / account info。
import Foundation

final class WebLogin {
    private let http: HongguoHTTP
    private let clock: () -> Int64
    private var cookies: [String: String] = [:]   // name -> value（域名范围为官网根域）
    private var activeTask: Task<Void, Never>?

    private let BASE = "https://hongguoduanju.com"
    private static let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private var token = ""

    struct Qr {
        let image: [UInt8]
        let expiresIn: Int
    }

    init(http: HongguoHTTP, clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.http = http
        self.clock = clock
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - 请求

    private func cookieHeader() -> String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func setCookies(from header: String?) {
        guard let header else { return }
        for line in header.split(separator: ",") {
            let pair = line.split(separator: ";", maxSplits: 1).first ?? ""
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("=") else { continue }
            let name = String(trimmed.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !value.isEmpty { cookies[name] = value }
        }
    }

    private func call(path: String, data: [String: String]? = nil, params: [String: String] = [:]) async throws -> [String: Any] {
        var baseParams: [String: String] = [
            "aid": "513755", "passport_jssdk_version": "3.4.10", "passport_jssdk_type": "normal",
            "account_sdk_source": "web", "is_from_ttaccountsdk": "1", "language": "zh",
        ]
        for (k, v) in params { baseParams[k] = v }
        var components = URLComponents(string: BASE + path)!
        components.queryItems = baseParams.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let url = components.url!.absoluteString

        var headers: [String: String] = [
            "User-Agent": Self.UA,
            "Referer": BASE + "/",
            "Origin": BASE,
            "Accept": "application/json, text/javascript",
        ]
        if let csrf = cookies["passport_csrf_token"], !csrf.isEmpty {
            headers["x-tt-passport-csrf-token"] = csrf
        }
        let cookieValue = cookieHeader()
        if !cookieValue.isEmpty { headers["Cookie"] = cookieValue }

        var body: Data? = nil
        if let data {
            var comps = URLComponents()
            comps.queryItems = data.map { URLQueryItem(name: $0.key, value: $0.value) }
            body = comps.percentEncodedQuery?.data(using: .utf8)
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        }

        let response = try await http.request(url, method: body != nil ? "POST" : "GET", headers: headers, body: body, limit: 2 * 1024 * 1024, followRedirects: false)
        if let setCookie = response.value(forHeaderField: "Set-Cookie") { setCookies(from: setCookie) }
        guard response.data.count <= 2 * 1024 * 1024 else { throw AccountError("账号接口响应过大") }
        guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else { throw AccountError("账号接口返回空响应，请稍后重试") }
        guard let obj = try? parseJSON(text) else {
            throw AccountError("账号接口响应异常")
        }
        return obj
    }

    private func checked(_ reply: [String: Any]) throws -> [String: Any] {
        guard let data = reply.obj("data") else { throw AccountError("官网登录返回格式异常") }
        if (reply["message"] as? String) != "success" {
            let code = data.optInt("error_code", -1)
            if data["verify_center_decision_conf"] != nil {
                throw AccountError("红果要求完成滑块验证，请改用扫码登录", code: code)
            }
            let desc = data.str("description").isEmpty ? "官网登录失败" : data.str("description")
            throw AccountError("\(desc)（错误码 \(code)）", code: code, canRetryCode: code == 1102)
        }
        return data
    }

    // MARK: - 扫码登录

    func qr() async throws -> Qr {
        let data = try checked(try await call(path: "/passport/web/get_qrcode/", params: ["next": BASE + "/"]))
        guard let t = data["token"] as? String, !t.isEmpty else { throw AccountError("二维码获取失败") }
        token = t
        let qrcode = data["qrcode"] as? String ?? ""
        let encoded = qrcode.components(separatedBy: "base64,").last ?? ""
        let expiry = data.optLong("expire_time", 180)
        let now = clock() / 1000
        let seconds: Int
        if expiry > 1_000_000_000 { seconds = min(600, max(0, Int(expiry - now))) }
        else { seconds = min(600, max(0, Int(expiry))) }
        return Qr(image: decode64(encoded), expiresIn: seconds)
    }

    /// 返回 false 表示仍在等待用户扫码/确认。
    func poll() async throws -> Bool {
        guard !token.isEmpty else { throw AccountError("请先获取二维码") }
        let reply = try await call(path: "/passport/web/check_qrconnect/", params: ["next": BASE + "/", "token": token])
        let data = try checked(reply)
        let status = data["status"] as? String ?? data.str("status")
        if status == "5" || status == "expired" { throw AccountError("二维码已过期，请重新获取") }
        if status == "3" || status == "confirmed" {
            let redirect = data.str("redirect_url")
            if !redirect.isEmpty { try await finishRedirect(redirect) }
        }
        return hasSession()
    }

    private func finishRedirect(_ value: String) async throws {
        guard var url = URL(string: BASE)?.appendingPathComponent(value.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            ?? URL(string: value, relativeTo: URL(string: BASE)) else {
            throw AccountError("登录确认地址无效")
        }
        // 规范化：相对路径解析到官网根。
        if url.absoluteString.hasPrefix("https://hongguoduanju.com/") { /* ok */ }
        else if let resolved = URL(string: value, relativeTo: URL(string: BASE)) { url = resolved }
        else { throw AccountError("登录确认地址无效") }

        for _ in 0..<5 {
            guard url.scheme == "https", url.host == "hongguoduanju.com" else { throw AccountError("登录确认跳转到不支持的站点") }
            let response = try await http.request(url.absoluteString, method: "GET", headers: ["User-Agent": Self.UA, "Referer": BASE + "/"], limit: 2 * 1024 * 1024, followRedirects: false)
            if let setCookie = response.value(forHeaderField: "Set-Cookie") { setCookies(from: setCookie) }
            guard (200..<400).contains(response.statusCode) else { throw AccountError("登录确认失败（HTTP \(response.statusCode)）") }
            if let location = response.value(forHeaderField: "Location"), !location.isEmpty {
                if let next = URL(string: location, relativeTo: url) { url = next; continue }
            }
            return
        }
        throw AccountError("登录确认跳转次数过多")
    }

    private func hasSession() -> Bool {
        cookies.keys.contains("sessionid") || cookies.keys.contains("sessionid_ss")
    }

    func credentials() async throws -> AccountCredentials {
        guard hasSession() else { throw AccountError("官网尚未下发登录态，请先在手机确认登录") }
        _ = try checked(try await call(path: "/passport/account/info/v2/"))
        let header = cookieHeader()
        return AccountCredentials(cookie: header, deviceId: "", installId: "", device: [:])
    }
}
