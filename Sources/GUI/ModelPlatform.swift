// SPDX-License-Identifier: GPL-3.0-only
// macOS 前端层的平台集成：把 Model 里与 AppKit / AVKit 强耦合的交互
// （全屏播放、画中画、全局键盘监听、更新检查）下沉到此扩展
// 逻辑层（AppModel.swift）只依赖 ModelPlatformInterface 抽象，不 import AppKit
import AppKit
import AVKit
import Combine
import SwiftUI
import IOKit.pwr_mgt

/// 平台集成的具体实现：持有 Model 生命周期内的 AppKit 资源，实现 ModelPlatformInterface
@MainActor
final class MacPlatformIntegration: ModelPlatformInterface {
    private weak var model: Model?
    private var keyMonitor: Any?
    /// 播放守卫：播放中阻止系统休眠 + 30 分钟无操作暂停并提示
    private var playbackGuard: PlaybackGuard?
    /// 主窗口下拉按钮用的最小尺寸（`NSWindow.contentMinSize`）
    private var windowMinSize: NSSize?

    init(model: Model) { self.model = model }

    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool) {
        installKeyMonitor()
        installWindowMinSize()
        if let model {
            playbackGuard = PlaybackGuard(model: model)
            playbackGuard?.start()
        }
        // 正式运行时才自动检查更新；测试（走本地 HTTP 桥）时不查
        if model?.backend != nil { model?.updates.autoCheckIfEnabled() }
    }

    func platformWillShutdown() {
        model?.fullscreenPlayback.close()
    }

    func platformShutdown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        playbackGuard?.stop()
        playbackGuard = nil
    }

    /// 安装主窗口最小尺寸（拖拽门槛）：高度 = 画面 405 + 底部信息栏高度（+ 分隔线余量），
    /// 宽度 = 画面最小宽 + 侧栏最小宽（都来自 `Theme`/`ContentView`）播放器的上下控件栏是覆盖层，不占额外高度
    /// `NavigationSplitView` 会在布局后按当前列宽重新写 `contentMinSize`，令最小宽变为“当前侧栏宽 + 内容区”，
    /// 因此这里在主线程观察并在尺寸变化时把它改回上面的取值
    private func installWindowMinSize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = NSApp.windows.first(where: { $0.title == "HongGuo" }) else { return }
            let size = NSSize(width: ContentView.detailMinWidth + ContentView.railMinWidth,
                              height: ContentView.detailMinHeight + Theme.statusBarHeight)
            self.windowMinSize = size
            window.contentMinSize = size
            // 拖动分隔条会改变列宽，而侧栏最小宽是固定的，因此只需在尺寸变化时校正一次即可
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, let size = self.windowMinSize, window.contentMinSize != size else { return }
                    window.contentMinSize = size
                }
            }
        }
    }

    /// 侧栏最小宽度，与 `ContentView.railMinWidth`（及 `.navigationSplitViewColumnWidth(min:)`）保持一致
    private static var railMinWidth: CGFloat { ContentView.railMinWidth }

    /// 安装全局键盘监听：空格播放/暂停、方向键快进快退/切换作品，普通窗口与全屏共用
    /// 键位定义见 `PlayerKeyCommand`；排除文本输入焦点（搜索框、评论输入等），避免打字时误触发
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            // 文本输入控件聚焦时放行，交给文本框处理
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            switch PlayerKeyCommand(keyCode: event.keyCode) {
            case .togglePlayback:
                if model.showDetail { model.togglePlayback() }; return nil
            case .skip(let seconds):
                model.skipPlayback(seconds); return nil
            case .moveRecommendation(let delta):
                if model.preview { model.moveRecommendation(delta) }; return nil
            case .escape, .none:
                return event
            }
        }
    }
}

// MARK: - 播放守卫（阻止休眠）

/// 播放守卫：播放中持有 IOPMAssertionNoDisplaySleep，阻止系统进入睡眠/显示器休眠；
/// 暂停、停止或退出时释放断言
@MainActor
final class PlaybackGuard {
    private weak var model: Model?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var didTakeAssertion = false
    private var playingObservation: AnyCancellable?

    init(model: Model) { self.model = model }

    func start() {
        guard let model else { return }
        // 播放状态由 Model 统一观察 player.rate，这里只订阅 isPlaying，避免重复 KVO
        playingObservation = model.$isPlaying.sink { [weak self] playing in
            Task { @MainActor in self?.setSleepAssertion(playing) }
        }
        // 启动时若已播放，立即取断言
        setSleepAssertion(model.player.rate > 0)
    }

    func stop() {
        playingObservation?.cancel(); playingObservation = nil
        releaseSleepAssertion()
    }

    private func setSleepAssertion(_ active: Bool) {
        if active && !didTakeAssertion {
            var assertionID: IOPMAssertionID = 0
            let name = "HongGuo Playback" as CFString
            let reason = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     name,
                                                     &assertionID)
            if reason == kIOReturnSuccess {
                sleepAssertionID = assertionID
                didTakeAssertion = true
            }
        } else if !active && didTakeAssertion {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        if didTakeAssertion {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
            didTakeAssertion = false
        }
    }
}

// MARK: - GUI 专属存储属性（关联对象，避免污染逻辑层）

private enum ModelAssociatedKeys {
    static var fullscreenPlayback: UInt8 = 0
    static var pipController: UInt8 = 0
    static var pipSession: UInt8 = 0
    static var updates: UInt8 = 0
}

extension Model {
    /// 全屏播放控制器（macOS NSWindow 全屏）
    var fullscreenPlayback: FullscreenPlayback {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback) as? FullscreenPlayback {
            return existing
        }
        let playback = FullscreenPlayback(player: player, model: self)
        objc_setAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback, playback, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return playback
    }

    /// 系统画中画控制器（由 `PipSession.activate(for:)` 创建，交回 Model 持有）
    var pipController: AVPictureInPictureController? {
        get { objc_getAssociatedObject(self, &ModelAssociatedKeys.pipController) as? AVPictureInPictureController }
        set { objc_setAssociatedObject(self, &ModelAssociatedKeys.pipController, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 画中画会话（长期持有，作为 pip 委托） 负责在 pip 停止后安全释放承载视图，
    /// 避免 pip 活跃时销毁 PlayerLayerHostView（解绑/释放 AVPlayerLayer）导致崩溃
    var pipSession: PipSession {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.pipSession) as? PipSession {
            return existing
        }
        let session = PipSession(model: self)
        objc_setAssociatedObject(self, &ModelAssociatedKeys.pipSession, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }

    /// Mac 更新状态（GUI 专属）
    var updates: MacUpdates {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.updates) as? MacUpdates {
            return existing
        }
        let value = MacUpdates()
        objc_setAssociatedObject(self, &ModelAssociatedKeys.updates, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    /// 切换画中画（依赖 pipController）
    func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}

/// 画中画会话：长期被 Model 持有，作为 AVPictureInPictureController 的委托
/// 关键职责：播放器视图（PlayerLayerHostView）销毁时，若 pip 仍活跃，不能立即解绑/释放其 AVPlayerLayer（系统仍在渲染画中画，会崩溃），
/// 而是先请求停止 pip，并在 didStop 回调后再置空 player、释放承载视图
@MainActor
final class PipSession: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private weak var model: Model?
    private weak var pip: AVPictureInPictureController?
    private var retainedView: PlayerLayerHostView?
    private var retiring = false

    init(model: Model) { self.model = model; super.init() }

    /// 由承载视图在创建时调用：判断系统支持 → 创建 controller → 绑定委托 → 交回 Model 持有。
    /// 视图层不再关心支持判断与 controller 的创建细节。
    func activate(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else {
            model?.pipController = nil
            return
        }
        attach(pip: controller)
        model?.pipController = controller
    }

    /// 由 PlayerSurfaceWindow 创建 pip 后绑定到本会话（本会话成为 pip 的长期委托）
    func attach(pip: AVPictureInPictureController) {
        self.pip = pip
        pip.delegate = self
    }

    /// 播放器视图即将销毁时调用 pip 活跃则延迟清理，否则立即置空
    func retire(_ view: PlayerLayerHostView) {
        guard let pip, pip.isPictureInPictureActive else {
            view.playerLayer.player = nil
            self.pip = nil
            return
        }
        retainedView = view
        retiring = true
        pip.stopPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.model?.pipActive = true }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.model?.pipActive = false
            self.finishRetire()
        }
    }

    private func finishRetire() {
        guard retiring else { return }
        retiring = false
        retainedView?.playerLayer.player = nil
        retainedView = nil
        self.pip = nil
    }
}
