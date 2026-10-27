// SPDX-License-Identifier: GPL-3.0-only
// Sources/PlayerCommands.swift
import Foundation
import AVFoundation

// MARK: - 播放器 UI 命令
//
// 面向界面的动作：播放/暂停、下一集、进入正式观看、切换推荐、续播、
// 切换清晰度/倍速 只调用 Playback.swift 中的引擎入口，不直接操作取流

extension Model {
    // MARK: 播放与续播

    func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.playImmediately(atRate: speed) }
    }

    func playNextEpisode() {
        guard let detail, let index = episode, index + 1 < detail.episodes.count else { return }
        if busy { pendingNext = true } else { play(index + 1, auto: true) }
    }

    func resume() {
        guard let detail else { return }
        if let cloudResume { play(cloudResume.0, position: cloudResume.1); self.cloudResume = nil; return }
        guard let saved = library.history(detail.series.id), let index = detail.episodes.firstIndex(of: saved.episodeID) else { play(0); return }
        if saved.completed && index + 1 < detail.episodes.count { play(index + 1) }
        else { play(index, position: saved.completed ? 0 : saved.position) }
    }

    // MARK: 试播

    func watchFull() {
        preview = false; activeTrial = false; saveProgress()
        let current = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 && current >= duration - 0.5 { play(episode ?? 0) }
        else if player.currentItem != nil { player.playImmediately(atRate: speed) }
        message = "已进入正式观看，可选择集数"
    }

    func moveRecommendation(_ delta: Int) {
        guard !busy, let id = detail?.series.id, let index = catalogRows.firstIndex(where: { $0.id == id }) else { return }
        if catalogRows.indices.contains(index + delta) { open(catalogRows[index + delta], trial: true) }
        else if delta > 0 && section == .home && catalogMore { loadHome(more: true) }
        else { message = "当前批次已到边界，可以换一批" }
    }

    // MARK: 播放参数

    func changeSpeed(_ value: Float) {
        guard PlaybackOptions.speeds.contains(value) else { return }
        speed = value; UserDefaults.standard.set(value, forKey: "playbackSpeed")
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }

    func changeQuality(_ value: Int) {
        guard PlaybackOptions.qualities.contains(value) else { return }
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
        if let episode { play(episode, position: CMTimeGetSeconds(player.currentTime()), autoplay: player.rate > 0, trial: activeTrial) }
    }

    /// 仅设置清晰度偏好（不触发重新播放），供「我的」页的自动清晰度开关使用
    func setQualityPreference(_ value: Int) {
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
    }
}
