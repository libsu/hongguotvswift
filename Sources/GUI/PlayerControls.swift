// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

// MARK: - 播放控件（交互层 / 底部栏 / 进度条）
// 显隐统一由 `reconcileControls(_:)` 判定（见 PlayerChrome）

// MARK: - 交互层

/// 透明交互层：点击画面切换显隐
/// hover 不在这里做——它只覆画面层，点控件栏会被误判为离开播放区；见 `PlayerZone`
struct PlayerTapLayer: View {
    @ObservedObject var model: Model

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                model.togglePlayerControls()
            }
    }
}

/// 播放区 hover：进入/移动 → `notePlaybackHover`（隐藏则显示，显示则重置计时）
/// 覆盖整个播放区；全屏由 `FullscreenPlayback` 的鼠标事件监听处理
struct PlayerZone: ViewModifier {
    @ObservedObject var model: Model

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: model.notePlaybackHover()
            case .ended: if model.hoveringPlayer { model.hoveringPlayer = false }
            }
        }
    }
}

/// 控件区 hover：置 `hoveringControls`，区分「停在控件上」与「停在画面上」——
/// 停在控件上时暂停自动隐藏（对齐 macOS 原生播放器）
struct ControlHoverZone: ViewModifier {
    @ObservedObject var model: Model

    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: if !model.hoveringControls { model.hoveringControls = true }
            case .ended: if model.hoveringControls { model.hoveringControls = false }
            }
        }
    }
}

// MARK: - 底部栏

struct PlayerBottomBar: View {
    @ObservedObject var model: Model
    let detail: Detail
    var showsTransport: Bool = true

    private enum PickerKind { case quality, speed }
    @State private var expandedPicker: PickerKind?

    private static let qualities = PlaybackOptions.qualities
    private static let speeds = PlaybackOptions.speeds

    var body: some View {
        HStack(spacing: Theme.spacingXXL) {
            playPauseButton
            // 进度由 PlaybackClock（AVPlayer 周期观察者）驱动，不用 TimelineView 采样，避免跳动
            PlayerProgress(clock: model.playbackClock, player: model.player)
            episodeControls
            favoriteButton
            danmakuControl
            pickerControls
            if showsTransport { pictureInPictureButton }
        }
        .padding(.horizontal, Theme.playerBarHPadding).padding(.vertical, Theme.playerBarVPadding)
        .background(Theme.playerBarGradient)
        .tint(.white)
        .modifier(ControlHoverZone(model: model))
    }

    private var playPauseButton: some View {
        iconButton(model.isPlaying ? "pause.fill" : "play.fill", help: model.isPlaying ? "暂停" : "播放", font: .title2) {
            model.togglePlayback()
        }
    }

    @ViewBuilder
    private var episodeControls: some View {
        iconButton("list.bullet", help: "选集") {
            model.infoPanelOpen.toggle()
            model.revealPlayerControls()
        }
        if !model.preview, let episode = model.episode {
            iconButton("forward.end.fill", help: "下一集") { model.play(episode + 1) }
                .disabled(episode + 1 >= detail.episodes.count)
        }
    }

    @ViewBuilder
    private var pickerControls: some View {
        pickerCapsule(Self.qualityLabel(model.quality), kind: .quality, minWidth: 75)
        pickerCapsule("倍速" + speedText(model.speed), kind: .speed, minWidth: 90)
    }

    private var pictureInPictureButton: some View {
        iconButton(model.pipActive ? "pip.exit" : "pip.enter", help: "画中画") {
            model.togglePictureInPicture()
        }
    }

    private var favoriteButton: some View {
        let isFavorite = model.favoriteActive(detail.series)
        return iconButton(isFavorite ? "star.fill" : "star",
                           help: isFavorite ? "取消收藏" : "收藏",
                           font: .body.weight(.semibold),
                           color: isFavorite ? .white : .white.opacity(0.55)) {
            model.toggleFavorite(detail.series)
        }
    }

    /// 弹幕开关：读写 `DanmakuStore.enabled`失败退避重试状态不在栏内展示，避免占空间
    private var danmakuControl: some View {
        Toggle("弹幕", isOn: $model.danmaku.enabled)
            .playerToggle()
            .help("按视频时间同步的真实弹幕；暂停、拖动和倍速同步")
    }

    private func iconButton(_ systemName: String, help: String, font: Font = .body, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let color {
                    Image(systemName: systemName).foregroundStyle(color)
                } else {
                    Image(systemName: systemName)
                }
            }
            .font(font)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    // MARK: - 清晰度 / 倍速弹出面板

    private func pickerCapsule(_ text: String, kind: PickerKind, minWidth: CGFloat) -> some View {
        SelectableCapsule(label: text, isSelected: expandedPicker == kind, palette: .dark, showsChevron: true, minWidth: minWidth) {
            expandedPicker = kind
            model.revealPlayerControls()
        }
        // 系统 .popover：点击外部/再次点按自动收起
        .popover(isPresented: Binding(
            get: { expandedPicker == kind },
            set: { expandedPicker = $0 ? kind : (expandedPicker == kind ? nil : expandedPicker) }
        ), arrowEdge: .top) {
            optionsPanel(kind)
        }
    }

    @ViewBuilder
    private func optionsPanel(_ kind: PickerKind) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            switch kind {
            case .quality:
                ForEach(Self.qualities, id: \.self) { q in
                    optionRow(Self.qualityLabel(q), selected: model.quality == q) {
                        model.changeQuality(q)
                        expandedPicker = nil
                    }
                }
            case .speed:
                ForEach(Self.speeds, id: \.self) { s in
                    optionRow(speedText(s), selected: model.speed == s) {
                        model.changeSpeed(s)
                        expandedPicker = nil
                    }
                }
            }
        }
        // .padding(4)
        .frame(minWidth: 95)
        .onAppear { model.playerPopoverOpen = true; model.revealPlayerControls() }
        .onDisappear { model.playerPopoverOpen = false }
    }

    private func optionRow(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingMD) {
                Text(text).font(.subheadline).fontWeight(selected ? .semibold : .regular)
                // Spacer(minLength: Theme.spacingLG)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, Theme.capsuleVPadding)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    /// 清晰度文案唯一真源：按钮与面板共用（0 表示自动）
    private static func qualityLabel(_ quality: Int) -> String {
        quality == 0 ? "自动" : "\(quality)P"
    }

    private func speedText(_ value: Float) -> String { String(format: "%g×", value) }
}

// MARK: - 进度条（独立订阅）

/// 单独订阅 PlaybackClock，进度刷新只重绘这一小块，不牵动整条控件栏与上层视图树
private struct PlayerProgress: View {
    @ObservedObject var clock: PlaybackClock
    let player: AVPlayer

    var body: some View {
        HStack(spacing: Theme.spacingXXL) {
            Text("\(timeText(clock.time)) / \(timeText(duration))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { clock.time.isFinite ? clock.time : 0 },
                set: { player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
            ), in: 0...max(1, duration))
            .tint(.white)
        }
    }

    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? max(0, d) : 0
    }
    private func timeText(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - 右上角全屏按钮

enum PlayerCorner {
    case enterFullscreen
    case exitFullscreen
}

/// 全屏按钮：试播（plain）与正式/全屏（circle）共用图标与动作
struct PlayerCornerButton: View {
    @ObservedObject var model: Model
    let corner: PlayerCorner
    var style: Style = .circle

    enum Style {
        case circle
        case plain
    }

    var body: some View {
        Button(action: perform) {
            switch style {
            case .circle:
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
            case .plain:
                Image(systemName: symbol)
            }
        }
        .help(help)
    }

    private var symbol: String {
        switch corner {
        case .enterFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .exitFullscreen: return "arrow.down.right.and.arrow.up.left"
        }
    }

    private var help: String {
        switch corner {
        case .enterFullscreen: return "全屏"
        case .exitFullscreen: return "退出全屏 · Esc"
        }
    }

    private func perform() {
        switch corner {
        case .enterFullscreen: model.fullscreenPlayback.show()
        case .exitFullscreen: model.fullscreenPlayback.close()
        }
    }
}
