// SPDX-License-Identifier: GPL-3.0-only
// tvOS 播放器：采用 Apple 官方推荐方案——延用系统 AVPlayerViewController 的
// 播放 UI（transport bar / 进度 / 快进快退 / 清晰度 / 字幕），通过官方扩展点
// （transportBarCustomMenuItems / customInfoViewControllers / infoViewActions /
// externalMetadata）加入我们的业务能力，不再自绘播放控件。
//
// 取流/解密（ResourceLoader + AVAssetResourceLoaderDelegate）完全复用逻辑层。
// tvOS 无画中画 / 投屏 / 全屏入口，故不含这些 macOS 专属能力。
// info tab 的 SwiftUI 内容（选集/相关作品/倍速/清晰度）拆分至 TVPlayerTabs.swift。
import SwiftUI
import UIKit
import AVKit
import Combine

/// 播放器 info tab（选集 / 相关作品 / 倍速 / 清晰度）的统一固定高度。
/// 供 UIKit 桥接层（Coordinator）与 info tab SwiftUI 内容（TVPlayerTabs.swift）共用。
let infoTabHeight: CGFloat = 300

/// AVPlayerViewController 子类：拦截 Siri Remote 的 Menu（返回）键。
/// 无浮层（info tab / transport bar 未展开）时，把返回导向「退出播放回到上一级」；
/// 有浮层时交给系统（super）先用 Menu 收起浮层，符合 tvOS 层级返回惯例。
final class TVAVPlayerController: AVPlayerViewController {
    var onMenuExit: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            // 没有展开 info tab / 其他呈现的浮层时，Menu = 退出播放。
            if presentedViewController == nil {
                onMenuExit?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

/// 把 AVPlayerViewController 桥接进 SwiftUI，并配置系统播放 UI + 自定义扩展。
struct TVPlayerViewController: UIViewControllerRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TVAVPlayerController()
        controller.player = model.player
        // 采用系统播放 UI（默认 YES），不关控件。
        controller.showsPlaybackControls = true
        // 无浮层时 Menu 返回键 → 退出播放回到上一级。
        controller.onMenuExit = { [weak model] in
            guard let model else { return }
            model.saveProgress()
            model.player.pause()
            model.player.replaceCurrentItem(with: nil)
            model.showDetail = false
        }
        // tvOS 15+ 系统 transport bar 扩展与自定义 tab。
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = model.player
        // model 任一 @Published 变化（清晰度/倍速/收藏/切集）都会触发重建，
        // 让 transport bar 的菜单与 info 面板反映最新状态。
        context.coordinator.refresh(controller)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private weak var model: Model?
        private var viewControllers: [UIViewController] = []

        init(model: Model) {
            self.model = model
        }

        func attach(to controller: AVPlayerViewController) {
            // 标题/集数元数据：由 transportBarIncludesTitleView + externalMetadata 驱动。
            controller.transportBarIncludesTitleView = true
            refresh(controller)
        }

        /// 根据 model 当前状态重建 transport bar 自定义菜单与 info tab。
        func refresh(_ controller: AVPlayerViewController) {
            guard let model else { return }

            controller.transportBarCustomMenuItems = buildMenuItems(model: model)
            controller.customInfoViewControllers = buildInfoTabs(model: model)
            applyMetadata(model: model, to: controller)
        }

        // MARK: transport bar 菜单

        private func buildMenuItems(model: Model) -> [UIMenuElement] {
            var items: [UIMenuElement] = []

            // 上一集 / 下一集
            if let detail = model.detail {
                let current = model.episode ?? 0
                let prev = UIAction(title: "上一集", image: UIImage(systemName: "backward.end.fill")) { _ in
                    if current > 0 { model.play(current - 1) }
                }
                prev.attributes = current <= 0 ? .disabled : []
                items.append(prev)

                let next = UIAction(title: "下一集", image: UIImage(systemName: "forward.end.fill")) { _ in
                    if current + 1 < detail.episodes.count { model.play(current + 1) }
                }
                next.attributes = current + 1 >= detail.episodes.count ? .disabled : []
                items.append(next)
            }

            // 收藏
            if let series = model.detail?.series {
                let active = model.favoriteActive(series)
                let fav = UIAction(
                    title: active ? "取消收藏" : "收藏",
                    image: UIImage(systemName: active ? "star.fill" : "star")
                ) { [weak model] _ in
                    model?.toggleFavorite(series)
                }
                items.append(fav)
            }

            // 倍速 / 清晰度已改为 info tab（见 buildInfoTabs），不再放 transport bar 菜单。

            return items
        }

        // MARK: info tabs（选集 / 相关作品 / 倍速 / 清晰度）

        private func buildInfoTabs(model: Model) -> [UIViewController] {
            var tabs: [UIViewController] = []
            // 关键：给所有 info tab 显式设置一致的 preferredContentSize，
            // 让系统不再按「最高的 tab」自行推断高度，避免切换时抬升忽高忽低。
            let tabSize = CGSize(width: 1920, height: infoTabHeight)

            if model.detail != nil {
                let episodes = UIHostingController(rootView: TVEpisodeList(model: model))
                episodes.title = "选集"
                episodes.preferredContentSize = tabSize
                episodes.sizingOptions = .preferredContentSize
                tabs.append(episodes)
            }

            let related = UIHostingController(rootView: TVRelatedList(model: model))
            related.title = "相关作品"
            related.preferredContentSize = tabSize
            related.sizingOptions = .preferredContentSize
            tabs.append(related)

            let speed = UIHostingController(rootView: TVSpeedView(model: model))
            speed.title = "倍速"
            speed.preferredContentSize = tabSize
            speed.sizingOptions = .preferredContentSize
            tabs.append(speed)

            let quality = UIHostingController(rootView: TVQualityView(model: model))
            quality.title = "清晰度"
            quality.preferredContentSize = tabSize
            quality.sizingOptions = .preferredContentSize
            tabs.append(quality)

            viewControllers = tabs
            return tabs
        }

        // MARK: 元数据（标题 / 集数 subtitle）

        private func applyMetadata(model: Model, to controller: AVPlayerViewController) {
            guard let detail = model.detail, let item = model.player.currentItem else { return }
            let episodeText = "第 \((model.episode ?? 0) + 1) 集 / 共 \(detail.episodes.count) 集"

            let titleItem = AVMutableMetadataItem()
            titleItem.identifier = .commonIdentifierTitle
            titleItem.value = detail.series.title as NSString
            titleItem.extendedLanguageTag = "und"

            let subtitleItem = AVMutableMetadataItem()
            subtitleItem.identifier = .iTunesMetadataTrackSubTitle
            subtitleItem.value = episodeText as NSString
            subtitleItem.extendedLanguageTag = "und"

            item.externalMetadata = [titleItem, subtitleItem]
        }
    }
}

/// 播放页面：整页展示系统播放器（系统 UI + 官方扩展），不再自绘控件。
struct TVPlayerView: View {
    @ObservedObject var model: Model

    var body: some View {
        TVPlayerViewController(model: model)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}
