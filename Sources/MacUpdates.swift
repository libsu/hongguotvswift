// SPDX-License-Identifier: GPL-3.0-only
// macOS 更新检查：只做「检查清单 → 发现新版 → 提示用户去发布页下载」，不做下载与自替换。
// 运行中的 .app 无法替换自身，且发布包未签名/公证，自更新不可靠，因此下载与安装交由用户完成。
// 纯 Foundation + CryptoKit，无 AppKit 依赖，可放在共享层。
import Foundation
import CryptoKit

struct MacManifest: Decodable {
    let schema: Int
    let bundleID: String
    let build: Int
    let version: String
    let architecture: String
    let minMacOS: Int
    let fileName: String
    let size: Int64
    let sha256: String
    let notes: String
    func validate() throws {
        // 兼容 Apple Silicon (arm64) 与 Intel (x86_64)：清单架构须匹配本机架构，避免下载错误架构的包
        guard schema == 1, bundleID == "com.hongguotvswift.app", build > 0, architecture == Self.localArchitecture,
              minMacOS >= 13, minMacOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
              size > 0, size <= 300 * 1024 * 1024,
              fileName.range(of: "^HongGuo-\(Self.localArchitecture)-[0-9][A-Za-z0-9.+-]{0,80}\\.zip$", options: .regularExpression) != nil,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw NSError(domain: "MacUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 更新清单不兼容，请查看发布页面 "])
        }
    }

    /// 本机架构标签（arm64 / x86_64），用于匹配更新清单与 zip 文件名前缀
    static var localArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}
// A separate stable asset prevents the TV Latest release from selecting a Mac-only package.
@MainActor final class MacUpdates {
    private(set) var status = ""
    private(set) var busy = false
    /// 发现的新版本；非 nil 时界面可据此提示用户去发布页
    private(set) var available: MacManifest?
    /// 是否自动检查更新，默认关闭，仅用户手动开启后才会在启动时自动检查
    var autoCheck: Bool {
        get { UserDefaults.standard.bool(forKey: "autoCheckUpdates") }
        set { UserDefaults.standard.set(newValue, forKey: "autoCheckUpdates") }
    }
    private var didAutoCheck = false
    /// 发布页：用户自行下载替换（本模块不下载，也不尝试自替换）
    static let releasePageURL = URL(string: "https://github.com/libsu/hongguotvswift/releases")!
    private let base = "https://cdn.gh-proxy.org/https://github.com/libsu/hongguotvswift/releases/download/arm/"
    private let session = URLSession(configuration: .ephemeral, delegate: AllowedRedirects(), delegateQueue: nil)
    nonisolated private static func accepted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https"
            && ["cdn.gh-proxy.org", "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "githubusercontent.com"].contains(url.host ?? "")
    }
    private final class AllowedRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(MacUpdates.accepted(request.url) ? request : nil)
        }
    }
    /// 应用启动时调用：仅当用户已开启自动检查且本次尚未检查过时，才静默检查一次
    func autoCheckIfEnabled() {
        guard autoCheck, !didAutoCheck, !busy else { return }
        didAutoCheck = true
        check()
    }

    private func check() {
        guard !busy else { return }; busy = true; available = nil
        Task {
            defer { busy = false }
            do {
                var request = URLRequest(url: URL(string: base + "mac-update-" + MacManifest.localArchitecture + ".json")!)
                request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 25
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536, Self.accepted(response.url) else { throw URLError(.badServerResponse) }
                let manifest = try JSONDecoder().decode(MacManifest.self, from: data)
                try manifest.validate()
                let current = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                if manifest.build > current { available = manifest; status = "发现 Mac \(manifest.version)：\(manifest.notes)" }
                else { status = "当前已是最新 Mac 版本" }
            } catch { status = "暂时没有可用的 Mac 更新，或更新源无法访问 " }
        }
    }
}
