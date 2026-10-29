// SPDX-License-Identifier: GPL-3.0-only
// Sources/PlayerChrome.swift
import Foundation
import AVFoundation

// MARK: - 播放选项常量（唯一真源）

/// 清晰度/倍速唯一真源：自绘控件栏与系统悬浮控件都从这里取，避免两处漂移
enum PlaybackOptions {
    static let qualities = [0, 480, 720, 1080]
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    /// 控件自动隐藏延时
    static let controlsAutoHideDelay: Duration = .seconds(3)
}

// MARK: - 播放器控件显隐

/// 控件显隐事件：所有变化经由 `reconcileControls(_:)`，条件不满足则不改状态（幂等）
enum ControlsVisibilityEvent {
    case show
    case hide
    /// 保持状态（面板/popover/悬停/拖动）变化
    case sync
    case timeout
}

extension Model {

    /// 二级操作进行中（面板/popover/悬停控件/按住拖动）：倒计时必须暂停，操作途中控件绝不消失
    var isControlsHeld: Bool {
        infoPanelOpen || playerPopoverOpen || hoveringControls || keepControlsVisible
    }

    /// 控件显隐的唯一判定与执行入口（视图中不做条件分支）
    func reconcileControls(_ event: ControlsVisibilityEvent) {
        switch event {
        case .hide:
            cancelControlsCountdown()
            if playerControlsVisible { playerControlsVisible = false }
            if infoPanelOpen { infoPanelOpen = false }

        case .show:
            if !playerControlsVisible {
                playerControlsVisible = true
                playbackClock.update(player.currentTime().seconds)
            }
            maintainControlsCountdown(restart: true)

        case .sync:
            guard playerControlsVisible else {
                cancelControlsCountdown()
                return
            }
            maintainControlsCountdown(restart: false)

        case .timeout:
            guard playerControlsVisible, !isControlsHeld else { return }
            playerControlsVisible = false
            cancelControlsCountdown()
        }
    }

    /// 有保持则暂停，否则开始倒计时（`restart` 强制重置）
    private func maintainControlsCountdown(restart: Bool) {
        if isControlsHeld {
            cancelControlsCountdown()
            return
        }
        if restart || controlsHideTask == nil {
            startControlsCountdown()
        }
    }

    /// 取消倒计时，不留下任何会到点隐藏的任务
    private func cancelControlsCountdown() {
        controlsHideTask?.cancel()
        controlsHideTask = nil
    }

    private func startControlsCountdown() {
        cancelControlsCountdown()
        controlsHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: PlaybackOptions.controlsAutoHideDelay)
            guard !Task.isCancelled, let self else { return }
            self.controlsHideTask = nil
            self.reconcileControls(.timeout)
        }
    }

    func revealPlayerControls(keepVisible: Bool = false) {
        keepControlsVisible = keepVisible
        reconcileControls(.show)
    }

    /// 播放区指针活动：隐藏则显示；已显示且无保持时重置倒计时（节流 0.25s，减少重建 Task）
    func notePlaybackHover() {
        if !hoveringPlayer { hoveringPlayer = true }
        if !playerControlsVisible {
            lastPlaybackHoverAt = Date()
            reconcileControls(.show)
            return
        }
        guard !isControlsHeld else { return } // 二级操作中倒计时已暂停，不重置
        let now = Date()
        guard now.timeIntervalSince(lastPlaybackHoverAt) >= 0.25 else { return }
        lastPlaybackHoverAt = now
        reconcileControls(.show)
    }

    func hidePlayerControls() {
        reconcileControls(.hide)
    }

    func togglePlayerControls() {
        reconcileControls(playerControlsVisible ? .hide : .show)
    }

    func skipPlayback(_ seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, now + seconds), preferredTimescale: 600))
    }
}
