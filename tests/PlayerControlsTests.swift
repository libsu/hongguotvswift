// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

// 播放控件显隐的回归测试。
// 控件状态自重构后统一由 `Model.playerControlsVisible` / `infoPanelOpen` / `playerPopoverOpen` / `hoveringPlayer`
// 驱动，`FullscreenPlayback` 只负责把窗口事件转发给 `Model.revealPlayerControls`（见 `PlayerChrome`）。

@main struct PlayerControlsTests {
    /// 自动隐藏延时（`PlayerChrome` 中为 2.5s），留出余量
    private static let autoHideWait: UInt64 = 2_900_000_000

    @MainActor static func main() async throws {
        _ = NSApplication.shared

        // 1. 显示后无操作 → 自动隐藏（整个控件层，含背景，一起淡出）
        let model = await makeModel()
        model.hidePlayerControls()
        assert(!model.playerControlsVisible)
        model.revealPlayerControls()
        assert(model.playerControlsVisible, "Revealing controls must make them visible immediately")
        try await Task.sleep(nanoseconds: autoHideWait)
        assert(!model.playerControlsVisible, "The complete HUD, including its background, must disappear")

        // 2. 选集面板展开时锁定控件（否则自动隐藏会撤掉面板的锚点）
        model.revealPlayerControls()
        model.infoPanelOpen = true
        try await Task.sleep(nanoseconds: autoHideWait)
        assert(model.playerControlsVisible, "Episode selection must keep the controls visible")
        model.infoPanelOpen = false

        // 3. 清晰度/倍速 popover 展开时同样锁定
        model.playerPopoverOpen = true
        try await Task.sleep(nanoseconds: autoHideWait)
        assert(model.playerControlsVisible, "An open popover must keep the controls visible")
        model.playerPopoverOpen = false

        // 4. 鼠标悬停在播放区时同样锁定
        model.hoveringPlayer = true
        try await Task.sleep(nanoseconds: autoHideWait)
        assert(model.playerControlsVisible, "Hovering the player must keep the controls visible")
        model.hoveringPlayer = false

        // 5. 隐藏会同时收起选集面板
        model.infoPanelOpen = true
        model.hidePlayerControls()
        assert(!model.playerControlsVisible && !model.infoPanelOpen, "Hiding must also close the episode panel")

        // 6. 全屏窗口：展示时的全屏选项、Esc 收起面板、关闭时的状态复位
        let playback = FullscreenPlayback(player: model.player, model: model)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let options = playback.window(window, willUseFullScreenPresentationOptions: [])
        assert(options.contains(.fullScreen) && options.contains(.autoHideDock) && options.contains(.autoHideMenuBar))
        playback.revealControls()
        assert(model.playerControlsVisible, "Fullscreen mouse activity must reveal the controls")
        model.infoPanelOpen = true
        playback.close()
        assert(!model.infoPanelOpen, "Closing fullscreen must reset the episode panel")
        assert(model.playerControlsVisible, "Closing fullscreen must leave the controls visible")

        // 7. PiP 承载视图解绑后不再持有播放器
        let view = AVPlayerView()
        view.player = playback.player
        view.player = nil
        assert(view.player == nil)

        print("Player HUD auto-hide, panel/popover/hover locks, hide reset and fullscreen lifecycle: PASS")
    }

    /// 构造一个不联网、不读缓存目录的 Model：控件显隐与网络/媒体状态无关
    @MainActor private static func makeModel() async -> Model {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = Model(resourcesURL: nil,
                          library: LocalLibrary(file: directory.appendingPathComponent("library.json")),
                          restoreSession: false,
                          bridgeURL: URL(string: "http://127.0.0.1:9/test/"),
                          session: URLSession(configuration: .ephemeral))
        try? await Task.sleep(nanoseconds: 50_000_000)
        return model
    }
}
