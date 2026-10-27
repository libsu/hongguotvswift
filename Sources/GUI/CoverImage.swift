// SPDX-License-Identifier: GPL-3.0-only
// macOS 封面视图：负责 SwiftUI 渲染与 NSImage 解码
// 缓存、下载调度与限流等共享逻辑见 Sources/CoverCache.swift
import SwiftUI
import AppKit

struct CoverImageView: View {
    let urlString: String
    var priority: Int = .max
    /// 只持有本地文件路径，解码由视图按需完成
    @State private var localURL: URL?

    var body: some View {
        Group {
            if let localURL, let image = NSImage(contentsOf: localURL) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) { await load() }
    }

    @MainActor
    private func load() async {
        guard let url = URL(string: urlString) else { Log.shared.warn("cover 失败：空/非法 URL \(urlString)"); return }
        if let cached = CoverCache.shared.cachedURL(for: urlString) { localURL = cached; return }
        do {
            let local = try await CoverDownloader.shared.download(urlString: urlString, url: url, priority: priority)
            guard !Task.isCancelled else { Log.shared.debug("cover 取消：\(urlString)"); return }
            localURL = local
            Log.shared.debug("cover 成功：\(urlString)")
        } catch {
            if !Task.isCancelled { Log.shared.warn("cover 下载失败：\(urlString) \(error.localizedDescription)") }
        }
    }
}
