// SPDX-License-Identifier: GPL-3.0-only
// tvOS 通用可复用小组件：筛选/页签胶囊、导航页签按钮、空态、加载态、状态栏。
// 各栏目（首页/找剧/榜单/我的/搜索）共享，统一焦点视觉与布局语义。
import SwiftUI
import UIKit

// MARK: - 通用胶囊按钮（配置化）

/// 所有「胶囊形三态按钮」的统一实现：默认/聚焦/选中三态视觉 + 焦点绑定 + 可选图标。
/// 通过配置项覆盖各栏目的胶囊、动作按钮、筛选钮等，消除重复样板。
struct TVCapsuleButton: View {
    let title: String
    var icon: String? = nil
    var selected: Bool = false
    var enabled: Bool = true
    /// 选中态时不下发 action（用于「当前项不重复触发」的筛选胶囊）。
    var guardOnSelected: Bool = false
    var focusKey: String
    var focus: FocusState<String?>.Binding
    var font: Font = .body.weight(.semibold)
    var paddingH: CGFloat = 16
    var paddingV: CGFloat = 8
    let action: () -> Void

    var body: some View {
        let focused = focus.wrappedValue == focusKey
        return Button {
            if guardOnSelected && selected { return }
            action()
        } label: {
            Group {
                if let icon { Label(title, systemImage: icon) }
                else { Text(title) }
            }
            .font(font)
            .padding(.horizontal, paddingH)
            .padding(.vertical, paddingV)
            .modifier(TVControlStyle(selected: selected, focused: focused))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.borderless)
        .focused(focus, equals: focusKey)
        .disabled(!enabled)
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// MARK: - 筛选胶囊（通用）

/// 筛选胶囊的通用选项：`id` 兼作焦点关键字与 ForEach 唯一标识，`value` 为业务选中值。
struct TVFilterOption: Identifiable {
    let id: String
    let title: String
    let value: String
}

/// 一组筛选胶囊（类型/题材/榜单等）的水平排列：内部用 ForEach 驱动，统一选中高亮与焦点。
/// 各栏目只需提供选项数组 + 当前值 + 选中回调，不再逐个手写胶囊。
struct TVFilterRow: View {
    let options: [TVFilterOption]
    let current: String
    var focus: FocusState<String?>.Binding
    let onSelect: (String) -> Void

    var body: some View {
        ForEach(options) { option in
            TVCapsuleButton(
                title: option.title,
                value: option.value,
                current: current,
                focusKey: option.id,
                focus: focus,
                action: { onSelect(option.value) }
            )
        }
    }
}

// MARK: - 便捷工厂（集中各类胶囊的视觉语义，避免到处传参数）

extension TVCapsuleButton {
    /// 筛选胶囊（题材/类型/榜单/我的等）：选中态即「当前项」不重复触发，紧凑字号与留白。
    init(title: String, value: String, current: String, focusKey: String,
         focus: FocusState<String?>.Binding, action: @escaping () -> Void) {
        self.init(title: title, selected: current == value, guardOnSelected: true,
                  focusKey: focusKey, focus: focus, font: .body,
                  paddingH: 14, paddingV: 7, action: action)
    }

    /// 选项胶囊（播放器倍速/清晰度、首页频道）：单选高亮当前项，无「选中不重复触发」限制。
    init(optionTitle title: String, selected: Bool, focusKey: String,
         focus: FocusState<String?>.Binding, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, focusKey: focusKey, focus: focus,
                  paddingH: 20, paddingV: 10, action: action)
    }
}

// MARK: - 导航页签按钮

/// 顶部横向焦点导航栏的页签按钮（首页/找剧/榜单/我的）。
struct TVTabButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let focused: Bool
    let action: () -> Void

    var body: some View {
        return Button(action: action) {
            HStack(spacing: 18) {
                // 图标固定宽度，保证各按钮文字起点对齐。
                Image(systemName: icon)
                    .frame(width: 22, alignment: .center)
                Text(title)
                    .fixedSize()
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 140, alignment: .center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .modifier(TVControlStyle(selected: selected, focused: focused))
        }
        .buttonStyle(.borderless)
        .animation(.easeInOut(duration: 0.15), value: focused)
    }
}

// MARK: - 空态 / 加载态 / 状态栏

struct TVEmptyView: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 52)).foregroundStyle(Color.accentColor)
            Text(title).font(.title2.bold()).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TVLoadingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 通用封面图：主卡片区（TVPosterCard）与播放器信息页（相关作品）共用的海报封面。
/// 拉取/缓存复用共享层的 `CoverCache` + `CoverDownloader`（磁盘缓存、并发限流、同 URL 去重），
/// 只拿本地路径后由 UIKit 解码显示，避免每次进栏目重新下载。
struct TVCoverImage: View {
    let url: String
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 12
    @State private var localURL: URL?

    var body: some View {
        Group {
            if let localURL, let image = UIImage(contentsOfFile: localURL.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.18))
                    .overlay(Image(systemName: "film").foregroundStyle(.secondary))
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .cornerRadius(cornerRadius)
        .task(id: url) { await load() }
    }

    @MainActor
    private func load() async {
        guard let remote = URL(string: url) else { return }
        if let cached = CoverCache.shared.cachedURL(for: url) { localURL = cached; return }
        do {
            let local = try await CoverDownloader.shared.download(urlString: url, url: remote)
            guard !Task.isCancelled else { return }
            localURL = local
        } catch {
            // 封面非关键资源，失败时保留占位图即可
        }
    }
}

/// 底部状态信息栏：单行、紧凑、不换行，降低占用的垂直高度。
struct TVStatusBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 64)
            .frame(height: 20)
    }
}
