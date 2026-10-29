// SPDX-License-Identifier: GPL-3.0-only
// Sources/GUI/PlayerSurfaces.swift
import SwiftUI
import AVKit

// MARK: - 宿主视图抽象

/// 统一 `AVPlayerView` 与 `PlayerLayerHostView` 的播放器挂载点（两者属性路径不同）
@MainActor
protocol PlayerSurfaceHosting: NSView {
    func setPlayer(_ player: AVPlayer?)
}

extension AVPlayerView: PlayerSurfaceHosting {
    func setPlayer(_ player: AVPlayer?) { self.player = player }
}

extension PlayerLayerHostView: PlayerSurfaceHosting {
    func setPlayer(_ player: AVPlayer?) { self.playerLayer.player = player }
}

@MainActor
private func makeBareAVPlayerView(videoGravity: AVLayerVideoGravity = .resizeAspect) -> AVPlayerView {
    let view = AVPlayerView()
    view.videoGravity = videoGravity
    return view
}

private extension AVPlayerView {
    /// 试播悬浮控件的倍速选项：取自 `PlaybackOptions.speeds`，与自绘控件栏同源
    static let trialSpeeds: [AVPlaybackSpeed] = PlaybackOptions.speeds.map {
        AVPlaybackSpeed(rate: $0, localizedName: "\($0)×")
    }
}

// MARK: - 表面配置

/// 预览 / 窗口 / 全屏三处差异的唯一真源：控件样式、全屏开关、倍速、PiP 策略
/// 三种表面共用 `PlayerSurface` 的 make/update/teardown，调整策略只改这里，避免漏改 PiP 清理。
struct SurfaceConfiguration {
    /// 仅 `AVPlayerView` 生效。
    var controlsStyle: AVPlayerViewControlsStyle = .none
    /// 均为 false：自定义全屏与弹幕/评论/选集已替代系统入口。
    var showsFullScreenToggleButton = false
    /// 仅 `.floating` 有意义；nil 不注入。
    var speeds: [AVPlaybackSpeed]? = nil
    var pip: SurfacePiP = .disabled

    /// 系统 PiP（预览）/ `pipSession` 托管（窗口）/ 关闭（全屏）。
    enum SurfacePiP {
        case system                 // AVPlayerView；Coordinator 作为 PiP 委托
        case session(Model?)        // PlayerLayerHostView；生命周期归 model.pipSession
        case disabled
    }

    /// 供静态 `dismantleNSView` 读取。
    var model: Model? {
        if case .session(let model) = pip { return model }
        return nil
    }
}

// MARK: - 通用表面

/// 播放表面基类（泛型参数为宿主视图类型）：统一 make/update/dismantle；
/// 三个具体表面是它的薄包装（见文件末尾）。
@MainActor
struct PlayerSurface<Host: NSView & PlayerSurfaceHosting>: NSViewRepresentable {
    typealias NSViewType = Host

    let player: AVPlayer
    let configuration: SurfaceConfiguration

    func makeCoordinator() -> SurfaceCoordinator {
        SurfaceCoordinator(model: configuration.model, pipStrategy: configuration.pip)
    }

    func makeNSView(context: Context) -> Host {
        let view = makeHost()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: Host, context: Context) {
        // 只重绑 player；控件样式与 PiP 激活只在建视图时做一次。
        view.setPlayer(player)
    }

    static func dismantleNSView(_ view: Host, coordinator: SurfaceCoordinator) {
        teardown(view, coordinator: coordinator)
    }

    // MARK: - 宿主视图创建

    /// 宿主类型与 PiP 策略 1:1 绑定（工厂保证），故强制转换安全。
    private func makeHost() -> Host {
        switch configuration.pip {
        case .system, .disabled:
            return makeBareAVPlayerView() as! Host
        case .session:
            return PlayerLayerHostView() as! Host
        }
    }

    // MARK: - 一次性配置

    private func configure(_ view: Host, coordinator: SurfaceCoordinator) {
        if let avView = view as? AVPlayerView {
            avView.controlsStyle = configuration.controlsStyle
            avView.showsFullScreenToggleButton = configuration.showsFullScreenToggleButton
            if let speeds = configuration.speeds { avView.speeds = speeds }
        }
        if let playerLayerView = view as? PlayerLayerHostView {
            playerLayerView.playerLayer.videoGravity = .resizeAspect
        }
        attachPiP(view, coordinator: coordinator)
        view.setPlayer(player)
    }

    private func attachPiP(_ view: Host, coordinator: SurfaceCoordinator) {
        switch configuration.pip {
        case .system:
            guard let avView = view as? AVPlayerView else { return }
            avView.allowsPictureInPicturePlayback = true
            avView.pictureInPictureDelegate = coordinator
        case .session:
            guard let playerLayerView = view as? PlayerLayerHostView, let model = coordinator.model else { return }
            model.pipSession.activate(for: playerLayerView.playerLayer)
        case .disabled:
            if let avView = view as? AVPlayerView { avView.allowsPictureInPicturePlayback = false }
        }
    }

    // MARK: - 拆除

    /// 静态方法拿不到 self，Model 由 Coordinator 提供。
    private static func teardown(_ view: Host, coordinator: SurfaceCoordinator) {
        switch coordinator.pipStrategy {
        case .system:
            guard let avView = view as? AVPlayerView else { break }
            // 拆除前先停 PiP，否则旧会话拖垮视图后崩溃。
            avView.allowsPictureInPicturePlayback = false
            avView.pictureInPictureDelegate = nil
            avView.player = nil
        case .session:
            // pipSession 决定立即释放还是延迟到活跃 PiP 停止（提前释放会崩溃）。
            if let playerLayerView = view as? PlayerLayerHostView, let model = coordinator.model {
                model.pipSession.retire(playerLayerView)
            }
        case .disabled:
            view.setPlayer(nil)
        }
    }
}

/// 三种表面共用：`.system` 时作为系统 PiP 委托，`.session` 时弱持有 Model 供拆除阶段读取。
@MainActor
final class SurfaceCoordinator: NSObject, @preconcurrency AVPlayerViewPictureInPictureDelegate {
    weak var model: Model?
    let pipStrategy: SurfaceConfiguration.SurfacePiP

    init(model: Model?, pipStrategy: SurfaceConfiguration.SurfacePiP) {
        self.model = model
        self.pipStrategy = pipStrategy
    }

    /// 让 App 接管 PiP 恢复界面，而非系统默认的关闭行为。
    func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool {
        false
    }

    func playerView(
        _ playerView: AVPlayerView,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - 表面工厂

extension PlayerSurface where Host == AVPlayerView {
    /// 首页试播：系统悬浮控件 + 系统 PiP。
    static func preview(player: AVPlayer) -> PlayerSurface<AVPlayerView> {
        PlayerSurface(player: player, configuration: SurfaceConfiguration(
            controlsStyle: .floating,
            showsFullScreenToggleButton: false, // 全屏由自定义实现（弹幕/评论/选集）接管
            speeds: AVPlayerView.trialSpeeds,
            pip: .system
        ))
    }

    /// 全屏：纯画面，叠加层由 `FullscreenSurface` 负责。
    static func fullscreen(player: AVPlayer) -> PlayerSurface<AVPlayerView> {
        PlayerSurface(player: player, configuration: SurfaceConfiguration(
            controlsStyle: .none,
            pip: .disabled
        ))
    }
}

extension PlayerSurface where Host == PlayerLayerHostView {
    /// 窗口内主播放：PiP 由 `model.pipSession` 托管。
    static func window(player: AVPlayer, model: Model?) -> PlayerSurface<PlayerLayerHostView> {
        PlayerSurface(player: player, configuration: SurfaceConfiguration(pip: .session(model)))
    }
}

// MARK: - AVPlayerLayer 承载视图

final class PlayerLayerHostView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }
}

// MARK: - 对外薄包装（保持原名与初始化签名不变）

/// 首页试播画面。
struct PlayerSurfacePreview: View {
    let player: AVPlayer

    var body: some View {
        PlayerSurface.preview(player: player)
    }
}

/// 窗口内主播放画面（弹幕/交互层由 `EpisodeView` 叠加）。
struct PlayerSurfaceWindow: View {
    let player: AVPlayer
    weak var model: Model?

    var body: some View {
        PlayerSurface.window(player: player, model: model)
    }
}

/// 全屏画面（弹幕与自定义控件由 `FullscreenSurface` 叠加）。
struct PlayerSurfaceFullscreen: View {
    let player: AVPlayer

    var body: some View {
        PlayerSurface.fullscreen(player: player)
    }
}
