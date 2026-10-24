// SPDX-License-Identifier: GPL-3.0-only
// 设备注册（POST /service/2/device_register/）：匿名，不需要账号，不带签名头。
// body = ttEncrypt(gzip(JSON))，ttEncrypt 用 AES-128-CBC/NoPadding + SHA-512 KDF。
import Foundation

enum DeviceRegister {
    static let HOST = "https://log5-applog-lf.fqnovel.com"
    static let PATH = "/service/2/device_register/"
    static let QUERY = "?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

    private static let MAGIC: [UInt8] = [0x74, 0x63, 0x05, 0x10, 0x00, 0x00]
    private static let KDF_SALT = hexBytes("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

    struct Registered {
        let deviceId: String
        let installId: String
        let deviceToken: String
        let newUser: Bool
        let cookies: [String: String]
    }

    /// ttEncrypt：MAGIC || rnd[32] || AES-128-CBC(SHA512(SHA512(rnd)+KDF_SALT) 前 32 字节, PKCS7(SHA512(data)||data))。
    static func ttEncrypt(_ data: [UInt8]) -> [UInt8] {
        var rnd = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { rnd[i] = UInt8.random(in: 0...255) }
        let derived = digest("SHA-512", digest("SHA-512", rnd) + KDF_SALT)
        var body = digest("SHA-512", data) + data
        let padding = UInt8(16 - (body.count % 16))
        // 上游: ByteArray(padding) { padding.toByte() } —— 始终填充 1..16 字节（PKCS7）。
        body.append(contentsOf: [UInt8](repeating: padding, count: Int(padding)))
        let encrypted = aesEncryptCBC(Array(derived[0..<16]), Array(derived[16..<32]), body)
        return MAGIC + rnd + encrypted
    }

    static func gzip(_ data: [UInt8]) -> [UInt8] { Gzip.compress(data) }

    /// 组装注册请求体：ttEncrypt(gzip(JSON))。
    static func payload(device: [String: String], now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [UInt8] {
        func value(_ key: String, _ fallback: String) -> String {
            device[key]?.isEmpty == false ? device[key]! : fallback
        }
        var json: [String: Any] = [:]
        json["magic_tag"] = "ss_app_log"
        var header: [String: Any] = [:]
        header["display_name"] = "红果免费短剧"
        header["update_version_code"] = 73932; header["manifest_version_code"] = 73932
        header["app_version_minor"] = "7.3.9.32"; header["aid"] = 8662
        header["channel"] = value("channel", "69310258a"); header["package"] = "com.phoenix.read"
        header["app_version"] = "7.3.9.32"; header["version_code"] = 73932
        header["sdk_version"] = "3.7.0-rc.34-fanqie-xiaoshuo"; header["sdk_target_version"] = 29
        header["git_hash"] = "3a88f4e"
        header["os"] = "Android"; header["os_version"] = value("os_version", "12")
        header["os_api"] = Int(value("os_api", "32")) ?? 32
        header["device_model"] = value("device_type", "AOSP on Intel Platform")
        header["device_brand"] = value("device_brand", "SAMSUNG")
        header["device_manufacturer"] = value("device_brand", "Intel")
        header["cpu_abi"] = value("host_abi", "arm64-v8a"); header["release_build"] = "b5e187f"
        header["density_dpi"] = Int(value("dpi", "360")) ?? 360
        header["display_density"] = "mdpi"
        header["resolution"] = value("resolution", "1440x2560").replacingOccurrences(of: "*", with: "x")
        header["language"] = "zh"; header["timezone"] = 8; header["access"] = "wifi"; header["not_request_sender"] = 0
        header["carrier"] = "CHINA MOBILE"; header["mcc_mnc"] = "46000"
        header["rom"] = "eng.root.20231116.160340"
        header["rom_version"] = value("rom_version", "W528JS release-keys")
        header["cdid"] = value("cdid", UUID().uuidString)
        header["sig_hash"] = "56a962410c494bbaf0b58dba20cae56f"
        header["openudid"] = value("openudid", String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)))
        header["clientudid"] = UUID().uuidString
        header["ipv6_list"] = []
        header["region"] = "CN"; header["tz_name"] = "Asia/Shanghai"; header["tz_offset"] = 28800
        header["sim_region"] = "cn"; header["sim_serial_number"] = []
        header["oaid_may_support"] = false
        header["req_id"] = UUID().uuidString
        header["device_platform"] = "android"
        var custom: [String: Any] = [:]
        custom["account_region_src"] = "fallback"; custom["host_bit"] = 64
        custom["account_region"] = "cn"
        custom["dragon_device_type"] = value("dragon_device_type", "pad")
        header["custom"] = custom
        header["pre_installed_channel"] = ""
        header["apk_first_install_time"] = now
        header["is_system_app"] = 0; header["sdk_flavor"] = "china"; header["guest_mode"] = 0
        json["header"] = header
        json["_gen_time"] = now
        let jsonData = try! JSONSerialization.data(withJSONObject: json)
        return ttEncrypt(gzip(Array(jsonData)))
    }

    /// 注册请求头。**刻意不加签名头**。
    static func headers(body: [UInt8], device: [String: String], now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> [String: String] {
        let ua = device["user_agent"]?.isEmpty == false ? device["user_agent"]! : VendorConstants.APP_UA
        return [
            "User-Agent": ua,
            "Content-Type": "application/octet-stream;tt-data=a",
            "log-encode-type": "gzip",
            "x-ss-dp": "8662",
            "x-ss-req-ticket": String(now),
            "x-vc-bdturing-sdk-version": "4.0.3.cn",
            "lc": "101",
            "sdk-version": "2",
            "passport-sdk-version": "5051452",
            "x-neptune": "-8|50:51:59:30:40:47:49:39",
            "x-ss-stub": hexString(digest("MD5", body)).uppercased(),
        ]
    }

    static func url() -> String { HOST + PATH + QUERY }

    /// 解析注册响应。device_id/install_id 为 0 或空返回 nil。
    static func parse(_ body: String, setCookies: [String] = []) -> Registered? {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        func strKey(_ key: String) -> String {
            if let s = json[key] as? String, !s.isEmpty { return s }
            if let n = json[key] as? NSNumber { return n.stringValue }
            return ""
        }
        let device = strKey("device_id_str").isEmpty ? strKey("device_id") : strKey("device_id_str")
        let install = strKey("install_id_str").isEmpty ? strKey("install_id") : strKey("install_id_str")
        if device.isEmpty || install.isEmpty || device == "0" || install == "0" { return nil }

        var cookies: [String: String] = [:]
        for header in setCookies {
            if let pair = header.split(separator: ";", maxSplits: 1).first {
                let trimmed = pair.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("=") {
                    let name = String(trimmed.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty && !value.isEmpty { cookies[name] = value }
                }
            }
        }
        let token = (json["device_token"] as? String) ?? ""
        let newUser = (json["new_user"] as? NSNumber)?.intValue == 1
        return Registered(deviceId: device, installId: install, deviceToken: token, newUser: newUser, cookies: cookies)
    }
}
