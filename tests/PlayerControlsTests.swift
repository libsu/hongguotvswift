// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

@main struct PlayerControlsTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let playback = FullscreenPlayback(player: AVPlayer())
        playback.revealControls()
        assert(playback.controlsVisible)
        try await Task.sleep(nanoseconds: 2_900_000_000)
        assert(!playback.controlsVisible, "The complete HUD, including its background, must disappear")
        playback.revealControls(); assert(playback.controlsVisible)
        playback.panelOpen = true
        try await Task.sleep(nanoseconds: 2_900_000_000)
        assert(playback.controlsVisible, "Episode selection must keep the controls visible")
        playback.panelOpen = false; playback.revealControls()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let options = playback.window(window, willUseFullScreenPresentationOptions: [])
        assert(options.contains(.fullScreen) && options.contains(.autoHideDock) && options.contains(.autoHideMenuBar))
        playback.close()
        let view = AVPlayerView()
        view.player = playback.player; view.player = nil
        print("Complete full-screen HUD hiding, reveal and cleanup: PASS")
    }
}
