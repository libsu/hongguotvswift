// SPDX-License-Identifier: GPL-3.0-only
// Log 文件写入自检：验证日志确实落到 Application Support/debug.log。
import Foundation

@main struct LogSmoke {
    static func main() {
        let log = Log.shared
        log.info("info 级别日志")
        log.debug("debug 级别（默认不输出）")
        log.warn("warn 级别日志 cookie=secret123 应被脱敏")
        log.error("error 级别日志")
        log.flush()
        let path = log.path
        guard FileManager.default.fileExists(atPath: path) else {
            print("[FAIL] 日志文件不存在: \(path)")
            exit(1)
        }
        let content = try! String(contentsOfFile: path, encoding: .utf8)
        guard content.contains("info 级别日志") && content.contains("warn 级别日志") else {
            print("[FAIL] 日志内容缺失")
            exit(1)
        }
        // 默认 info 级别，debug 不应写入
        if content.contains("debug 级别") {
            print("[FAIL] debug 级别不应在 info 下写入")
            exit(1)
        }
        // 脱敏：cookie 值应为 ***
        if content.contains("secret123") {
            print("[FAIL] 敏感值未脱敏")
            exit(1)
        }
        print("[PASS] 日志写入 + 级别过滤 + 脱敏通过（\(path)）")
    }
}
