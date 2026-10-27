// SPDX-License-Identifier: GPL-3.0-only
// 播放设备注册与缓存。
//
// 取流接口（/novel/player/multi_video_model/v1/）会拒绝未注册的匿名设备：
// 使用随机 device_id/iid 时表现为「HTTP 200 但 body 为空」，使用内置旧设备时返回 110001。
// 因此取流前必须通过 DeviceRegister 注册一台设备，并持久化 device_id / install_id / cdid / openudid。
import Foundation

/// 一台已注册的播放设备。字段均来自注册响应或注册请求本身。
struct PlayerDevice: Codable, Equatable {
    let deviceId: String
    let installId: String
    let cdid: String
    let openudid: String

    var isValid: Bool {
        isValidNumericId(deviceId) && isValidNumericId(installId)
            && !cdid.isEmpty && !openudid.isEmpty
    }
}

/// 负责获取（必要时注册）并缓存播放设备。
/// 使用 actor 串行化「并发取流只注册一次」，避免自动连播/预加载同时触发多次注册。
actor PlayerDeviceSource {
    private static let storeKey = "playerDevice"

    private let http: HongguoHTTP
    private let clock: () -> Int64
    private let defaults: UserDefaults
    private var cached: PlayerDevice?
    private var inFlight: Task<PlayerDevice, Error>?

    init(
        http: HongguoHTTP,
        clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        defaults: UserDefaults = .standard
    ) {
        self.http = http
        self.clock = clock
        self.defaults = defaults
    }

    /// 已缓存/已持久化的设备优先；否则注册一次。
    func obtain() async throws -> PlayerDevice {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        if let stored = load() {
            cached = stored
            return stored
        }
        let task = Task { try await self.register() }
        inFlight = task
        defer { inFlight = nil }
        let device = try await task.value
        cached = device
        save(device)
        return device
    }

    /// 上游拒绝该设备（110001/10001/10002）时丢弃缓存，下一次 obtain() 会重新注册。
    func invalidate() {
        cached = nil
        inFlight = nil
        defaults.removeObject(forKey: Self.storeKey)
    }

    private func load() -> PlayerDevice? {
        guard let raw = defaults.string(forKey: Self.storeKey),
              let data = raw.data(using: .utf8),
              let device = try? JSONDecoder().decode(PlayerDevice.self, from: data),
              device.isValid else { return nil }
        return device
    }

    private func save(_ device: PlayerDevice) {
        guard let data = try? JSONEncoder().encode(device),
              let raw = String(data: data, encoding: .utf8) else { return }
        defaults.set(raw, forKey: Self.storeKey)
    }

    /// 注册一台新设备。cdid/openudid 一并写进注册请求，保证后续取流参数与注册时一致。
    private func register() async throws -> PlayerDevice {
        let now = clock()
        let cdid = UUID().uuidString
        let openudid = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        var device = VendorConstants.device
        device["cdid"] = cdid
        device["openudid"] = openudid

        let body = DeviceRegister.payload(device: device, now: now)
        let headers = DeviceRegister.headers(body: body, device: device, now: now)
        var lastError: Error?
        for registrationURL in DeviceRegister.urls() {
            do {
                let response = try await http.request(
                    registrationURL,
                    method: "POST",
                    headers: headers,
                    body: Data(body),
                    limit: 2 * 1024 * 1024
                )
                guard (200..<300).contains(response.statusCode) else {
                    throw ContentError("播放设备注册失败（HTTP \(response.statusCode)）", statusCode: response.statusCode)
                }
                guard let text = String(data: response.data, encoding: .utf8), !text.isEmpty else {
                    throw ContentError("播放设备注册响应为空", statusCode: response.statusCode, retryable: true)
                }
                guard let registered = DeviceRegister.parse(text) else {
                    throw ContentError("播放设备注册响应异常")
                }
                let player = PlayerDevice(
                    deviceId: registered.deviceId,
                    installId: registered.installId,
                    cdid: cdid,
                    openudid: openudid
                )
                guard player.isValid else { throw ContentError("播放设备注册信息无效") }
                Log.shared.info("player device registered device_id=\(player.deviceId) install_id=\(player.installId)")
                return player
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                let host = URL(string: registrationURL)?.host ?? registrationURL
                Log.shared.warn("播放设备注册失败 host=\(host)：\(error.localizedDescription)")
            }
        }
        throw lastError ?? ContentError("播放设备注册失败")
    }
}
