// SPDX-License-Identifier: GPL-3.0-only
// macOS 平台集成：全屏/PiP/全局键盘/更新检查下沉至此，逻辑层只依赖 ModelPlatformInterface、不 import AppKit。
import AppKit
import AVKit
import Combine
import SwiftUI
import IOKit.pwr_mgt

/// 平台集成实现：持有 Model 生命周期内的 AppKit 资源。
@MainActor
final class MacPlatformIntegration: ModelPlatformInterface {
    private weak var model: Model?
    private var keyMonitor: Any?
    /// 播放守卫：阻止休眠 + 30 分钟无操作暂停。
    private var playbackGuard: PlaybackGuard?
    /// 主窗口最小尺寸（`NSWindow.contentMinSize`）。
    private var windowMinSize: NSSize?

    init(model: Model) { self.model = model }

    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool) {
        installKeyMonitor()
        installWindowMinSize()
        if let model {
            playbackGuard = PlaybackGuard(model: model)
            playbackGuard?.start()
        }
        // 正式运行时才自动检查更新；测试（本地 HTTP 桥）不查
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

    /// 安装主窗口最小尺寸：高 = 画面 405 + 信息栏（控件栏是覆盖层，不占高度），宽 = 画面 + 侧栏最小宽。
    /// `NavigationSplitView` 布局后会用「当前侧栏宽 + 内容区」重写 `contentMinSize`，
    /// 故主线程观察并在尺寸变化时改回。
    private func installWindowMinSize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = NSApp.windows.first(where: { $0.title == "HongGuo" }) else { return }
            let size = NSSize(width: ContentView.detailMinWidth + ContentView.railMinWidth,
                              height: ContentView.detailMinHeight + Theme.statusBarHeight)
            self.windowMinSize = size
            window.contentMinSize = size
            // 拖动分隔条会改变列宽，但侧栏最小宽固定，只需校正一次。
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

    /// 全局键盘监听（普通窗口与全屏共用），键位见 `PlayerKeyCommand`。
    /// 文本输入聚焦时放行，避免打字误触发。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            // 文本输入聚焦时放行。
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

/// 播放中持有 IOPMAssertionNoDisplaySleep，暂停/停止/退出时释放。
@MainActor
final class PlaybackGuard {
    private weak var model: Model?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var didTakeAssertion = false
    private var playingObservation: AnyCancellable?

    init(model: Model) { self.model = model }

    func start() {
        guard let model else { return }
        // 播放态由 Model 统一观察 player.rate，这里只订阅 isPlaying，避免重复 KVO。
        playingObservation = model.$isPlaying.sink { [weak self] playing in
            Task { @MainActor in self?.setSleepAssertion(playing) }
        }
        // 启动时若已在播放，立即取断言。
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
    var fullscreenPlayback: FullscreenPlayback {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback) as? FullscreenPlayback {
            return existing
        }
        let playback = FullscreenPlayback(player: player, model: self)
        objc_setAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback, playback, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return playback
    }

    /// 由 `PipSession.activate(for:)` 创建后交回 Model 持有。
    var pipController: AVPictureInPictureController? {
        get { objc_getAssociatedObject(self, &ModelAssociatedKeys.pipController) as? AVPictureInPictureController }
        set { objc_setAssociatedObject(self, &ModelAssociatedKeys.pipController, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// 画中画会话：必须长期持有（作为 pip 委托），否则 pip 停止前被释放会崩溃。
    var pipSession: PipSession {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.pipSession) as? PipSession {
            return existing
        }
        let session = PipSession(model: self)
        objc_setAssociatedObject(self, &ModelAssociatedKeys.pipSession, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }

    var updates: MacUpdates {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.updates) as? MacUpdates {
            return existing
        }
        let value = MacUpdates()
        objc_setAssociatedObject(self, &ModelAssociatedKeys.updates, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    /// 切换画中画。
    func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}

/// 画中画会话：长期被 Model 持有，作为 AVPictureInPictureController 的委托。
/// pip 活跃时销毁承载视图不能立即解绑 AVPlayerLayer（系统仍在渲染，会崩溃）；
/// 需先停 pip，在 didStop 回调后再置空 player、释放视图。
@MainActor
final class PipSession: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private weak var model: Model?
    private weak var pip: AVPictureInPictureController?
    private var retainedView: PlayerLayerHostView?
    private var retiring = false

    init(model: Model) { self.model = model; super.init() }

    /// 由承载视图创建时调用：判断支持 → 建 controller → 绑委托 → 交回 Model。
    func activate(for layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else {
            model?.pipController = nil
            return
        }
        attach(pip: controller)
        model?.pipController = controller
    }

    /// 由 PlayerSurfaceWindow 建 pip 后绑定（本会话成为长期委托）。
    func attach(pip: AVPictureInPictureController) {
        self.pip = pip
        pip.delegate = self
    }

    /// 视图即将销毁：pip 活跃则延迟清理，否则立即置空。
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
