// SPDX-License-Identifier: GPL-3.0-only
// 关键：所有站点请求直连官方 HTTPS，用同一 URLSession（ephemeral + 超时），
// 请求头 User-Agent / Accept / X-* 照搬 VendorConstants 或按上游逐条设置。
import Foundation

/// 内容层请求错误。对应 上游 的 ContentHttpException / IOException 语义。
struct ContentError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    let statusCode: Int
    init(_ message: String, statusCode: Int = 0) {
        self.message = message
        self.statusCode = statusCode
    }
    var description: String { message }
    var errorDescription: String? { message }
    var localizedDescription: String { message }
}

/// 对齐 上游 的 is-successful 判断：2xx。
private extension HTTPURLResponse {
    var isSuccessful: Bool { (200..<300).contains(statusCode) }
}

/// 共享标签：确定某 IOException 是否属于「临时」类，供 bounded retry 判断。
/// Swift 侧 URLSession 的临时错误通过 URLError 表达，此处按状态码与错误域判断。
func isTransientNetworkError(_ error: Error) -> Bool {
    if let content = error as? ContentError {
        return [500, 502, 503, 504].contains(content.statusCode)
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
            return true
        // SSL/TLS 握手瞬断（证书链未加载、网络抖动导致的握手失败）值得重试；
        // 证书真失效时重试一次也仅多一次往返，无副作用。
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return true
        default: return false
        }
    }
    return false
}

/// 共享 HTTP 客户端，供各协议对象复用。对齐 上游 各处的 timeout：
/// - ContentRepository: connect 15s / read 30s / call 45s
/// - 评论/弹幕: call 20s / followRedirects(false)
/// 这里用统一的 ephemeral 配置 + 30s 超时，需要更细的控制在 HTTPRequest 里设。
final class HongguoHTTP {
    let session: URLSession

    init(session: URLSession = HongguoHTTP.defaultSession()) {
        self.session = session
    }

    static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    struct Response {
        let data: Data
        let statusCode: Int
        let headers: [String: String]
        func value(forHeaderField name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// 发一个 GET/POST 请求并读取响应体（带上限）。遵循/禁止重定向由 followRedirects 控制（需 delegate）。
    func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        limit: Int = 16 * 1024 * 1024,
        followRedirects: Bool = true
    ) async throws -> Response {
        guard let target = URL(string: url) else { throw ContentError("请求地址异常") }
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.timeoutInterval = method == "POST" ? 45 : 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body { req.httpBody = body }

        // 用一次性的 delegate 会话以严格做 followRedirects 与响应头捕获。
        let delegate = SessionDelegate(followRedirects: followRedirects)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { s.invalidateAndCancel() }
        let (data, response) = try await s.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let http, !(200..<300).contains(status) {
            let safeUrl = (http.url?.host ?? "") + (http.url?.path ?? "")
            Log.shared.warn("HTTP \(status) \(method) \(safeUrl)")
        }
        var respHeaders: [String: String] = [:]
        if let http {
            for (k, v) in http.allHeaderFields { respHeaders[String(describing: k)] = String(describing: v) }
        }
        return Response(data: data, statusCode: status, headers: respHeaders)
    }

    /// 读取文本，等价 上游 text()：校验 state、限制大小、UTF-8 解码。
    func text(
        _ url: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        method: String = "GET",
        limit: Int = 16 * 1024 * 1024,
        retryTransient: Bool = false,
        followRedirects: Bool = true
    ) async throws -> String {
        func fetch() async throws -> String {
            let resp = try await request(url, method: method, headers: headers, body: body, limit: limit, followRedirects: followRedirects)
            if !(200..<300).contains(resp.statusCode) {
                throw ContentError("内容请求失败（HTTP \(resp.statusCode)）", statusCode: resp.statusCode)
            }
            if resp.data.count > limit { throw ContentError("内容响应过大") }
            guard let text = String(data: resp.data, encoding: .utf8) else { throw ContentError("内容响应无法解码") }
            return text
        }
        do { return try await fetch() }
        catch {
            if !retryTransient || !isTransientNetworkError(error) || Task.isCancelled { throw error }
            // 对瞬态错误最多重试两次（共 3 次尝试），指数退避。
            for attempt in 1...2 {
                try await Task.sleep(nanoseconds: UInt64(700_000_000 * attempt))
                try Task.checkCancellation()
                do { return try await fetch() }
                catch {
                    let retryable = isTransientNetworkError(error)
                    if attempt == 2 || !retryable || Task.isCancelled { throw error }
                }
            }
            throw ContentError("请求暂时失败，请稍后重试")
        }
    }
}

// MARK: - URLSession 委托（重定向控制）

final class SessionDelegate: NSObject, URLSessionTaskDelegate {
    let followRedirects: Bool
    init(followRedirects: Bool) { self.followRedirects = followRedirects }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if followRedirects { completionHandler(request) } else { completionHandler(nil) }
    }
}

// MARK: - JSON 辅助（对齐 上游 org.json 的宽容取值）

extension Dictionary where Key == String, Value == Any {
    /// JSONObject.str(key)：若为 null 返回 ""，否则 optString().trim()。
    func str(_ key: String) -> String {
        guard let v = self[key], !(v is NSNull) else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }
    func optInt(_ key: String, _ def: Int = 0) -> Int {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? Int { return n }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) ?? def }
        return def
    }
    func optLong(_ key: String, _ def: Int64 = 0) -> Int64 {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber { return n.int64Value }
        if let n = v as? Int { return Int64(n) }
        if let s = v as? String { return Int64(s) ?? def }
        return def
    }
    func optDouble(_ key: String, _ def: Double = 0) -> Double {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let n = v as? NSNumber { return n.doubleValue }
        if let n = v as? Double { return n }
        if let s = v as? String { return Double(s) ?? def }
        return def
    }
    func optBool(_ key: String, _ def: Bool = false) -> Bool {
        guard let v = self[key], !(v is NSNull) else { return def }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return def
    }
    func obj(_ key: String) -> [String: Any]? {
        (self[key] as? [String: Any])
    }
    func array(_ key: String) -> [[String: Any]]? {
        (self[key] as? [[String: Any]])
    }
    func str(_ key: String, _ def: String) -> String {
        let s = str(key); return s.isEmpty ? def : s
    }
    func optString(_ key: String) -> String {
        guard let v = self[key], !(v is NSNull) else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
}

/// 上游: cleanUrl(s) —— 反转义 URL 里的 \/ 与实体。
func cleanUrl(_ s: String) -> String {
    s.replacingOccurrences(of: "\\/", with: "/")
        .replacingOccurrences(of: "\\u002F", with: "/", options: .caseInsensitive)
        .replacingOccurrences(of: "\\u0026", with: "&")
        .replacingOccurrences(of: "&amp;", with: "&")
}

/// 解析 JSON 为 [String: Any]（上游 JSONObject 的等价物）。
func parseJSON(_ s: String) throws -> [String: Any] {
    guard let data = s.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw ContentError("响应格式异常，请稍后重试")
    }
    return obj
}

func parseJSON(_ data: Data) throws -> [String: Any] {
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw ContentError("响应格式异常，请稍后重试")
    }
    return obj
}

/// 序列化 [String: Any] 为 JSON 字符串（上游 JSONObject.toString()）。
func jsonString(_ object: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

/// 序列化任意 JSON 结构为字符串。
func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}
