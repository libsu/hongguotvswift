// SPDX-License-Identifier: GPL-3.0-only
// tvOS 播放器：沿用系统 AVPlayerViewController 的 UI（transport bar/进度/清晰度/字幕），
// 通过官方扩展点（transportBarCustomMenuItems / customInfoViewControllers / externalMetadata）扩展业务能力，不自绘控件。
// 取流/解密复用逻辑层；tvOS 无画中画/投屏/全屏，故不含 macOS 专属能力。
import SwiftUI
import UIKit
import AVKit
import Combine

/// info tab 固定高度，UIKit 桥接层与 TVPlayerTabs 共用。
let infoTabHeight: CGFloat = 300

/// 拦截 Menu 键：无浮层时退出播放，有浮层时交回系统收起（符合 tvOS 层级返回惯例）。
final class TVAVPlayerController: AVPlayerViewController {
    var onMenuExit: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            if presentedViewController == nil {
                onMenuExit?()
                return
            }
        }
        super.pressesBegan(presses, with: event)
    }
}

/// 把 AVPlayerViewController 桥接进 SwiftUI。
struct TVPlayerViewController: UIViewControllerRepresentable {
    @ObservedObject var model: Model

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = TVAVPlayerController()
        controller.player = model.player
        controller.showsPlaybackControls = true
        controller.onMenuExit = { [weak model] in
            guard let model else { return }
            model.saveProgress()
            model.player.pause()
            model.player.replaceCurrentItem(with: nil)
            model.showDetail = false
        }
        context.coordinator.attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = model.player
        // 任一 @Published 变化（清晰度/倍速/收藏/切集）都会触发重建，
        // 让 transport bar 菜单与 info 面板反映最新状态。
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
            controller.transportBarIncludesTitleView = true
            refresh(controller)
        }

        func refresh(_ controller: AVPlayerViewController) {
            guard let model else { return }

            controller.transportBarCustomMenuItems = buildMenuItems(model: model)
            controller.customInfoViewControllers = buildInfoTabs(model: model)
            applyMetadata(model: model, to: controller)
        }

        // MARK: transport bar 菜单

        private func buildMenuItems(model: Model) -> [UIMenuElement] {
            var items: [UIMenuElement] = []

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

            return items
        }

        // MARK: info tabs

        private func buildInfoTabs(model: Model) -> [UIViewController] {
            var tabs: [UIViewController] = []
            // 所有 tab 显式设置一致的 preferredContentSize，避免系统按「最高的 tab」推断高度、
            // 切换时抬升忽高忽低（注：并未完全解决）。
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

/// 播放页面：整页展示系统播放器。
struct TVPlayerView: View {
    @ObservedObject var model: Model

    var body: some View {
        TVPlayerViewController(model: model)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}
