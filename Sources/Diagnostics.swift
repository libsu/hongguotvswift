// SPDX-License-Identifier: GPL-3.0-only
// 轻量诊断日志：写文件 + 标准输出，便于测试时排查。
// 规则：凭据（cookie/sessionid/验证码/手机号）绝不落日志；只记录操作、状态码、耗时与脱敏摘要。
import Foundation

/// 日志级别。
enum LogLevel: Int, Comparable {
    case debug = 0, info = 1, warn = 2, error = 3
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        }
    }
}

/// 全局诊断日志器。
final class Log {
    static let shared = Log()

    var minimumLevel: LogLevel = .info

    private var file: FileHandle?
    private let queue = DispatchQueue(label: "com.hongguotvswift.app.log")
    private let formatter: DateFormatter
    private var currentSize: UInt64 = 0
    private let maxSize: UInt64 = 2 * 1024 * 1024
    private let fileURL: URL
    private var opened = false

    init(level: LogLevel = .info) {
        // 默认 info；可用 `defaults write com.hongguotvswift.app logLevel debug` 调到 debug（含每次取流分段）。
        if let raw = UserDefaults.standard.string(forKey: "logLevel") {
            switch raw.lowercased() {
            case "debug": self.minimumLevel = .debug
            case "warn": self.minimumLevel = .warn
            case "error": self.minimumLevel = .error
            default: self.minimumLevel = level
            }
        } else {
            self.minimumLevel = level
        }
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HongguoTVMac", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("debug.log")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        df.locale = Locale(identifier: "en_US_POSIX")
        self.formatter = df
        openFile()
    }

    // MARK: - 输出

    func debug(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { log(.debug, message(), file: file, line: line) }
    func info(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { log(.info, message(), file: file, line: line) }
    func warn(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { log(.warn, message(), file: file, line: line) }
    func error(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { log(.error, message(), file: file, line: line) }

    private func log(_ level: LogLevel, _ message: String, file: String, line: Int) {
        guard level >= minimumLevel else { return }
        let source = (file as NSString).lastPathComponent
        let ts = formatter.string(from: Date())
        let lineText = "\(ts) [\(level.label)] \(source):\(line) \(message)\n"
        // 脱敏：擦掉疑似 Cookie / sessionid 的值，避免凭据泄漏。
        let safe = redact(lineText)
        queue.async { [weak self] in
            guard let self else { return }
            fputs(safe, stderr) // 同时打到 stderr，便于在模拟器/终端直接看
            self.write(safe)
        }
    }

    private func write(_ line: String) {
        guard let file else { return }
        if let data = line.data(using: .utf8) {
            currentSize += UInt64(data.count)
            try? file.write(contentsOf: data)
        }
        if currentSize >= maxSize { rotate() }
    }

    private func openFile() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: fileURL)
        if let file {
            _ = try? file.seekToEnd()
            currentSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
            opened = true
        }
    }

    private func rotate() {
        try? file?.close()
        let rotated = fileURL.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
        _ = try? FileManager.default.removeItem(atPath: fileURL.path)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        file = try? FileHandle(forWritingTo: fileURL)
        currentSize = 0
    }

    /// 日志文件路径（便于测试时定位）。
    var path: String { fileURL.path }

    func flush() {
        queue.sync { try? file?.synchronize() }
    }

    /// 设计目标：关闭日志文件句柄（释放资源）。
    /// 应用 shutdown 目前走 backend.accountClose() 等，日志器 close 从未被调；保留以备优雅退出时刷新并关闭日志。
    func close() {
        queue.sync { try? file?.close(); file = nil }
    }

    // MARK: - 脱敏

    /// 擦除疑似敏感值。保守策略：把形如 `name=value` 的 value 替换为 `***`。
    private func redact(_ text: String) -> String {
        let sensitiveKeys = ["cookie", "sessionid", "session_id", "passport_csrf_token", "code", "credentials", "mobile"]
        var out = text
        for key in sensitiveKeys {
            // 匹配 key=value 或 key=较长 token 的场景
            let pattern = "(?i)(\\b\(NSRegularExpression.escapedPattern(for: key))\\b[=:][ ]*)([^\\s,;\\]]+)"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(out.startIndex..<out.endIndex, in: out)
                out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "$1***")
            }
        }
        return out
    }
}

/// 设计目标：便捷 top-level 函数，供各处直接调用（等价 Log.shared.debug/info/warn/error）。
/// 当前各处统一直接用 Log.shared.<level>，这四个包装未使用；保留以提供更短的调用入口。
func logDebug(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { Log.shared.debug(message(), file: file, line: line) }
func logInfo(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { Log.shared.info(message(), file: file, line: line) }
func logWarn(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { Log.shared.warn(message(), file: file, line: line) }
func logError(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) { Log.shared.error(message(), file: file, line: line) }
