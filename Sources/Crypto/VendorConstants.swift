// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum VendorConstants {
    static let VIDEO_UA = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
    static let APP_UA = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

    static let device: [String: String] = [
        "iid": "1905892595382586",
        "device_id": "1905892595378490",
        "ac": "wifi",
        "channel": "update_64",
        "aid": "8662",
        "app_name": "novelread",
        "version_code": "71332",
        "version_name": "7.1.3.32",
        "device_platform": "android",
        "os": "android",
        "ssmix": "a",
        "device_type": "25053RT47C",
        "device_brand": "Redmi",
        "language": "zh",
        "os_api": "36",
        "os_version": "16",
        "manifest_version_code": "71332",
        "resolution": "1280*2772",
        "dpi": "520",
        "update_version_code": "71332",
        "host_abi": "arm64-v8a",
        "dragon_device_type": "phone",
        "pv_player": "71332",
        "compliance_status": "0",
        "need_personal_recommend": "1",
        "player_so_load": "1",
        "is_android_pad_screen": "0",
    ]

    /// sbox（base64 解码后的 1024 字节），由 VendorConstants_Generated.swift 提供常量。
    static var sbox: [UInt8] = decode64(VendorConstants_Generated.sboxBase64)
    /// hashTable
    static let hashTable: [Int32] = VendorConstants_Generated.hashTable
}
