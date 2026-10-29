// SPDX-License-Identifier: GPL-3.0-only
// tvOS（Apple TV）前端入口
// tvOS 只有一个 全屏 WindowGroup，没有菜单栏 / 多窗口 / 窗口尺寸，输入靠 Siri Remote 焦点系统
import SwiftUI
import AVKit

/// tvOS 平台集成：实现 ModelPlatformInterface，规避 macOS 的 AppKit 集成
/// 无全局键盘监听、无自更新；画中画/全屏由系统 AVPlayerViewController 接管
@MainActor
final class TVPlatformIntegration: ModelPlatformInterface {
    private weak var model: Model?

    init(model: Model) { self.model = model }

    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool) {
        // tvOS 无 Mac 自更新、无全局键盘监听；启动即进入原生协议模式
    }

    func platformWillShutdown() {
        // AVPlayerViewController 由 SwiftUI 生命周期自动释放，无需额外清理
    }

    func platformShutdown() {
        // 预留：tvOS 无 AppKit 资源需要显式释放
    }
}

@main
struct HongGuoTV: App {
    @StateObject private var model: Model

    init() {
        // tvOS 默认清晰度 1080P 尊重用户后续选择
        if UserDefaults.standard.object(forKey: "playbackQuality") == nil {
            UserDefaults.standard.set(1080, forKey: "playbackQuality")
        }
        let model = Model()
        let platform = TVPlatformIntegration(model: model)
        model.platformInterface = platform
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            TVRootView(model: model)
                .preferredColorScheme(.dark)
        }
    }
}
