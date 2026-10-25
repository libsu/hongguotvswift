// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AppKit
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
        // 兼容 Apple Silicon (arm64) 与 Intel (x86_64)：清单架构必须匹配本机架构，避免下载错误架构的包。
        guard schema == 1, bundleID == "com.hongguotvswift.app", build > 0, architecture == Self.localArchitecture,
              minMacOS >= 13, minMacOS <= ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
              size > 0, size <= 300 * 1024 * 1024,
              fileName.range(of: "^HongGuo-\(Self.localArchitecture)-[0-9][A-Za-z0-9.+-]{0,80}\\.zip$", options: .regularExpression) != nil,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw NSError(domain: "MacUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mac 更新清单不兼容，请查看发布页面。"])
        }
    }

    /// 本机架构标签（arm64 / x86_64），用于匹配更新清单与 zip 文件名前缀。
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
@MainActor final class MacUpdates: ObservableObject {
    @Published var status = "Mac 更新独立发布，TV 仍为主要维护目标"
    @Published var busy = false
    @Published var available: MacManifest?
    /// 是否自动检查更新，默认关闭，仅用户手动开启后才会在启动时自动检查。
    @Published var autoCheck = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }
    private var didAutoCheck = false
    private let base = "https://gitcode.com/tsukiyo-zero/hongguoTV/releases/download/mac-stable/"
    private let session = URLSession(configuration: .ephemeral, delegate: AllowedRedirects(), delegateQueue: nil)
    nonisolated private static func accepted(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && ["gitcode.com", "file-cdn.gitcode.com"].contains(url.host ?? "")
    }
    private final class AllowedRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(MacUpdates.accepted(request.url) ? request : nil)
        }
    }
    /// 应用启动时调用：仅当用户已开启自动检查且本次尚未检查过时，才静默检查一次。
    func autoCheckIfEnabled() {
        guard autoCheck, !didAutoCheck, !busy else { return }
        didAutoCheck = true
        check()
    }

    func check() {
        guard !busy else { return }; busy = true; available = nil
        Task {
            defer { busy = false }
            do {
                var request = URLRequest(url: URL(string: base + "mac-update.json")!)
                request.cachePolicy = .reloadIgnoringLocalCacheData; request.timeoutInterval = 25
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536, Self.accepted(response.url) else { throw URLError(.badServerResponse) }
                let manifest = try JSONDecoder().decode(MacManifest.self, from: data)
                try manifest.validate()
                let current = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
                if manifest.build > current { available = manifest; status = "发现 Mac \(manifest.version)：\(manifest.notes)" }
                else { status = "当前已是最新 Mac 版本" }
            } catch { status = "暂时没有可用的 Mac 更新，或更新源无法访问。" }
        }
    }
    func download() {
        guard !busy, let manifest = available else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                try manifest.validate()
                let (temporary, response) = try await session.download(from: URL(string: base + manifest.fileName)!)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200, Self.accepted(response.url) else { throw URLError(.badServerResponse) }
                let size = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber
                guard size?.int64Value == manifest.size else { throw URLError(.cannotDecodeContentData) }
                let input = try FileHandle(forReadingFrom: temporary); defer { try? input.close() }
                var digest = SHA256()
                while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else { throw URLError(.cannotDecodeContentData) }
                let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("HongGuo/" + UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(manifest.fileName)
                try FileManager.default.copyItem(at: temporary, to: destination)
                status = "下载和校验完成：请解压后退出旧版，将新版拖入应用程序替换。"
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { status = "更新下载或校验失败，请重试。" }
        }
    }
}
