// SPDX-License-Identifier: GPL-3.0-only
// Sources/PlayerChrome.swift
import Foundation
import AVFoundation

// MARK: - 播放选项常量（唯一真源）

/// 清晰度与倍速的可选值：自绘底部控件栏与系统 `AVPlayerView` 悬浮控件都从这里取，避免两处硬编码漂移。
enum PlaybackOptions {
    /// 清晰度上限，0 表示自动（跟随源的最高可用清晰度）
    static let qualities = [0, 480, 720, 1080]
    /// 可选倍速
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
}

// MARK: - 播放器控件显隐

extension Model {

    func revealPlayerControls(keepVisible: Bool = false) {
        if !playerControlsVisible {
            playerControlsVisible = true
            playbackClock.update(player.currentTime().seconds)
        }
        scheduleControlsAutoHide(keepVisible: keepVisible)
    }

    private func scheduleControlsAutoHide(keepVisible: Bool) {
        controlsHideTask?.cancel()
        controlsHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, let self else { return }
            if keepVisible || self.infoPanelOpen || self.playerPopoverOpen || self.hoveringPlayer {
                self.scheduleControlsAutoHide(keepVisible: false)
            } else {
                self.playerControlsVisible = false
            }
        }
    }

    /// 隐藏播放控件
    func hidePlayerControls() {
        controlsHideTask?.cancel(); controlsHideTask = nil
        playerControlsVisible = false
        infoPanelOpen = false
    }

    func skipPlayback(_ seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600))
    }
}
