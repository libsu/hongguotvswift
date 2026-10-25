// SPDX-License-Identifier: GPL-3.0-only
// macOS 前端层的平台集成：把 Model 里与 AppKit / AVKit 强耦合的交互
// （全屏播放、画中画、全局键盘监听、更新检查）下沉到此扩展。
// 逻辑层（HongguoMac.swift）只依赖 ModelPlatformInterface 抽象，不 import AppKit。
import AppKit
import AVKit
import SwiftUI

/// 平台集成的具体实现：持有 Model 生命周期内的 AppKit 资源，实现 ModelPlatformInterface。
@MainActor
final class MacPlatformIntegration: ModelPlatformInterface {
    private weak var model: Model?
    private var keyMonitor: Any?

    init(model: Model) { self.model = model }

    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool) {
        installKeyMonitor()
        // 正式原生运行（无桥接 URL）才会自动检查更新；测试走注入桥时不查。
        if model?.backend != nil { model?.updates.autoCheckIfEnabled() }
    }

    func platformWillShutdown() {
        model?.fullscreenPlayback.close()
    }

    func platformShutdown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    /// 安装全局键盘监听：空格播放/暂停、方向键快进快退/切换作品，普通窗口与全屏共用。
    /// 排除文本输入焦点（搜索框、评论输入等），避免打字时误触发。
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model else { return event }
            // 文本输入控件聚焦时放行，交给文本框处理。
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            switch event.keyCode {
            case 49: // 空格
                if model.showDetail { model.togglePlayback() }; return nil
            case 123: model.skipPlayback(-10); return nil
            case 124: model.skipPlayback(10); return nil
            case 125, 126:
                if model.preview { model.moveRecommendation(event.keyCode == 125 ? 1 : -1) }; return nil
            default: return event
            }
        }
    }
}

// MARK: - GUI 专属存储属性（关联对象，避免污染逻辑层）

private enum ModelAssociatedKeys {
    static var fullscreenPlayback: UInt8 = 0
    static var pipController: UInt8 = 0
    static var updates: UInt8 = 0
}

extension Model {
    /// 全屏播放控制器（macOS NSWindow 全屏）。
    var fullscreenPlayback: FullscreenPlayback {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback) as? FullscreenPlayback {
            return existing
        }
        let playback = FullscreenPlayback(player: player, model: self)
        objc_setAssociatedObject(self, &ModelAssociatedKeys.fullscreenPlayback, playback, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return playback
    }

    /// 系统画中画控制器（由 ImmersiveVideo 创建并持有）。
    var pipController: AVPictureInPictureController? {
        get { objc_getAssociatedObject(self, &ModelAssociatedKeys.pipController) as? AVPictureInPictureController }
        set { objc_setAssociatedObject(self, &ModelAssociatedKeys.pipController, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Mac 更新状态（GUI 专属）。
    var updates: MacUpdates {
        if let existing = objc_getAssociatedObject(self, &ModelAssociatedKeys.updates) as? MacUpdates {
            return existing
        }
        let value = MacUpdates()
        objc_setAssociatedObject(self, &ModelAssociatedKeys.updates, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    /// 切换画中画（依赖 pipController）。
    func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else { pip.startPictureInPicture() }
    }
}
