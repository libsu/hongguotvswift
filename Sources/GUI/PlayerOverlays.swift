// SPDX-License-Identifier: GPL-3.0-only
// Sources/GUI/PlayerOverlays.swift
import SwiftUI

// MARK: - 覆盖层

/// 播放覆盖层场景：决定 PiP 传输控件与右上角按钮语义
enum PlayerChromeContext {
    case window
    case fullscreen

    var showsTransport: Bool { self == .window }
    var corner: PlayerCorner { self == .window ? .enterFullscreen : .exitFullscreen }
}

/// 播放区覆盖层：全屏/窗口共用布局，仅右上角按钮语义与 PiP 开关不同
struct PlayerOverlays: View {
    @ObservedObject var model: Model
    let detail: Detail?
    let context: PlayerChromeContext

    var body: some View {
        // 需要实时高度计算信息面板上限，避免面板盖住底部控件栏
        GeometryReader { proxy in
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
                if let detail, model.playerControlsVisible {
                    VStack { Spacer(); PlayerBottomBar(model: model, detail: detail, showsTransport: context.showsTransport) }
                        .transition(.opacity)
                }
                // 信息面板叠在控件栏之上，不占控件栏位置；上限 = 播放区高度 - 控件栏高度
                if let detail, model.infoPanelOpen {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        PlayerInfoPanel(model: model, detail: detail)
                            .frame(maxHeight: max(0, proxy.size.height - Theme.playerBarHeight))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var cornerButton: some View {
        PlayerCornerButton(model: model, corner: context.corner)
            .buttonStyle(.plain)
            .padding(Theme.overlayPadding)
    }
}
