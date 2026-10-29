// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

// MARK: - 全屏播放窗口
//
// 全屏不是系统 AVPlayerView 的全屏，而是自建独立 NSWindow：
// 与主窗口共用同一个 AVPlayer 与 Model，因此进度、弹幕、选集等状态天然同步

// MARK: - 全屏窗口

private final class PlaybackWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class FullscreenPlayback: NSObject, ObservableObject, NSWindowDelegate {
    let player: AVPlayer
    weak var model: Model?
    private var monitor: Any?
    private var window: NSWindow?
    init(player: AVPlayer, model: Model? = nil) { self.player = player; self.model = model; super.init() }
    func show() {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        guard let model else { return }
        // 打开全屏时清除窗口侧残留的悬停/拖动保持，避免共享状态让全屏控件被永久暂停
        model.hoveringControls = false
        model.hoveringPlayer = false
        model.keepControlsVisible = false
        let source = NSApp.keyWindow
        let alreadyFullscreen = source?.styleMask.contains(.fullScreen) == true
        let screen = source?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let window = PlaybackWindow(contentRect: screen.frame, styleMask: alreadyFullscreen ? [.borderless] : [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = alreadyFullscreen ? [.fullScreenAuxiliary, .canJoinAllSpaces] : [.fullScreenPrimary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.backgroundColor = .black
        window.level = alreadyFullscreen ? .floating : .normal
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: FullscreenSurface(playback: self, model: model))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        if !alreadyFullscreen { window.toggleFullScreen(nil) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown, PlayerKeyCommand(keyCode: event.keyCode) == .escape {
                if self.model?.infoPanelOpen == true { self.model?.infoPanelOpen = false; self.revealControls() } else { self.close() }; return nil
            }
            // 播放/暂停、方向键已由 Model 的全局键盘监听统一处理，此处不再重复，避免双重切换
            self.revealControls()
            return event
        }
        revealControls()
    }
    func revealControls() {
        // 鼠标按住拖动时保持显示（否则拖到一半控件消失）
        model?.revealPlayerControls(keepVisible: NSEvent.pressedMouseButtons != 0)
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar]
    }
    func windowDidExitFullScreen(_ notification: Notification) { close() }
    func windowWillClose(_ notification: Notification) { cleanup(); window?.contentView = nil; window = nil }
    private func cleanup() {
        // 重置所有瞬态保持状态，避免全屏关闭后残留导致窗口模式自动隐藏被永久暂停；
        // 最后通过 reconcile 统一恢复显示（经唯一判定入口）。
        model?.infoPanelOpen = false
        model?.playerPopoverOpen = false
        model?.hoveringControls = false
        model?.hoveringPlayer = false
        model?.keepControlsVisible = false
        model?.revealPlayerControls()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func close() {
        cleanup()
        let previous = window; window = nil
        previous?.delegate = nil; previous?.close(); previous?.contentView = nil
    }
}

// MARK: - 全屏画面

/// 全屏窗口内的画面：纯播放 + 弹幕 + 悬浮控件（无系统控件）
private struct FullscreenSurface: View {
    let playback: FullscreenPlayback
    @ObservedObject var model: Model
    var body: some View {
        ZStack {
            Color.black
            PlayerSurfaceFullscreen(player: playback.player)
            DanmakuOverlay(model: model, danmaku: model.danmaku)
            PlayerOverlays(model: model, detail: model.detail, context: .fullscreen)
        }
        .animation(Theme.overlayAnimation, value: model.playerControlsVisible)
        .animation(Theme.overlayAnimation, value: model.infoPanelOpen)
        .buttonStyle(.borderless).ignoresSafeArea().preferredColorScheme(.dark).tint(.white)
    }
}
