// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct MacUpdateTests {
    static func main() throws {
        let arch = MacManifest.localArchitecture
        let valid: [String: Any] = ["schema": 1, "bundleID": "com.hongguotvswift.app", "build": 3, "version": "0.2.0", "architecture": arch, "minMacOS": 13, "fileName": "HongGuo-\(arch)-0.2.0-build3.zip", "size": 1024, "sha256": String(repeating: "a", count: 64), "notes": "测试"]
        func manifest(_ data: [String: Any]) throws -> MacManifest { try JSONDecoder().decode(MacManifest.self, from: JSONSerialization.data(withJSONObject: data)) }
        try manifest(valid).validate()
        // 无效字段逐一被拒：错误的 bundle id、错误架构、非法文件名、越界大小、非法哈希等。
        for (key, value): (String, Any) in [("schema", 2), ("bundleID", "com.hongguotv.nativeapp"), ("build", 0), ("fileName", "../bad.zip"), ("architecture", arch == "arm64" ? "x86_64" : "arm64"), ("size", 400 * 1024 * 1024), ("sha256", "invalid")] {
            var invalid = valid; invalid[key] = value
            do { try manifest(invalid).validate(); fatalError("Accepted invalid update: \(key)") } catch { }
        }
        print("Mac manifest identity, filename, compatibility and integrity bounds: PASS")
    }
}
