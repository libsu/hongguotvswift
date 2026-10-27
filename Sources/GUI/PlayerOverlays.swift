// SPDX-License-Identifier: GPL-3.0-only
// Sources/GUI/PlayerOverlays.swift
import SwiftUI

// MARK: - 覆盖层

/// 覆盖层所在场景：决定是否显示 PiP 等传输控件，以及右上角按钮语义。
enum PlayerChromeContext {
    case window
    case fullscreen

    var showsTransport: Bool { self == .window }
    var corner: PlayerCorner { self == .window ? .enterFullscreen : .exitFullscreen }
}

/// 播放区悬浮覆盖层（右上角全屏入口 + 顶部栏 + 底部栏 + 信息面板）
/// 全屏与非全屏共用一套布局，仅右上角按钮语义与底部栏传输控件（PiP）不同，
/// 消除 FullscreenSurface 与 EpisodeView 的重复实现
struct PlayerOverlays: View {
    @ObservedObject var model: Model
    let detail: Detail?
    let context: PlayerChromeContext

    var body: some View {
        ZStack {
            if model.playerControlsVisible {
                VStack {
                    HStack {
                        Spacer()
                        cornerButton
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
            // 顶部悬浮栏（仅试播场景的上一部/下一部/观看全集）
            if model.playerControlsVisible {
                VStack { PlayerTopBar(model: model); Spacer() }
                    .transition(.opacity)
            }
            // 底部渐变栏
            if let detail, model.playerControlsVisible {
                VStack { Spacer(); PlayerBottomBar(model: model, detail: detail, showsTransport: context.showsTransport) }
                    .transition(.opacity)
            }
            // 底部信息面板（选集/相关作品）：叠在控件栏之上，不占控件栏的位置
            // 高度由内容决定，限制在 Theme.infoPanelMinHeight…infoPanelMaxHeight 区间（见 PlayerInfoPanel）
            if let detail, model.infoPanelOpen {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    PlayerInfoPanel(model: model, detail: detail)
                        .frame(minHeight: Theme.infoPanelMinHeight, maxHeight: Theme.infoPanelMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
    }

    private var cornerButton: some View {
        PlayerCornerButton(model: model, corner: context.corner)
            .buttonStyle(.plain)
            .padding(Theme.overlayPadding)
    }
}
