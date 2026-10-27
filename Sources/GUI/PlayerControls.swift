// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

// MARK: - 播放控件
//
// 控件：交互层、顶部栏、底部栏与进度条
// 显隐统一由 `Model.playerControlsVisible` 驱动（见 `revealPlayerControls`）

// MARK: - 交互层

/// 透明交互层：点击画面切换控件显隐；鼠标移动时显示控件并刷新自动隐藏计时
struct PlayerTapLayer: View {
    @ObservedObject var model: Model

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                model.playerControlsVisible ? model.hidePlayerControls() : model.revealPlayerControls()
            }
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    model.hoveringPlayer = true
                    model.revealPlayerControls()
                case .ended:
                    model.hoveringPlayer = false
                }
            }
    }
}

// MARK: - 顶部栏

/// 顶部悬浮操作栏：仅试播场景的上一部/下一部/观看全集
struct PlayerTopBar: View {
    @ObservedObject var model: Model

    var body: some View {
        HStack {
            Spacer()
            if model.preview {
                Button("上一部") { model.moveRecommendation(-1) }
                Button("下一部") { model.moveRecommendation(1) }
                Button("观看全集") { model.watchFull() }
            }
        }
        .padding(Theme.spacingXL)
    }
}

// MARK: - 底部栏

/// 底部控件栏：进度条、播放/暂停、时间、选集/下一集/收藏/弹幕/清晰度/倍速、PiP/投屏
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
            // 时间 + 进度条由 PlaybackClock（AVPlayer 周期时间观察者）驱动，
            // 不再在 SwiftUI TimelineView 里自行采样 currentTime，避免跳动
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
    }

    // MARK: - 布局

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
        pickerCapsule(Self.qualityLabel(model.quality), kind: .quality, minWidth: 64)
        pickerCapsule("倍速" + speedText(model.speed), kind: .speed, minWidth: 72)
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

    /// 弹幕开关：读写 `DanmakuStore.enabled`，渲染见 `DanmakuViews` 的 `DanmakuOverlay`
    /// 开关常显在控件栏；失败的自动退避重试状态不在栏内展示，避免占用空间
    private var danmakuControl: some View {
        Toggle("弹幕", isOn: $model.danmaku.enabled)
            .playerToggle()
            .help("按视频时间同步的真实弹幕；暂停、拖动和倍速同步")
    }

    /// 图标按钮
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
        // 由系统 .popover 承载选项：点击外部/再次点按会自动收起
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
        .padding(4)
        .frame(minWidth: 84)
        .onAppear { model.playerPopoverOpen = true; model.revealPlayerControls() }
        .onDisappear { model.playerPopoverOpen = false; model.revealPlayerControls() }
    }

    private func optionRow(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.spacingMD) {
                Text(text).font(.subheadline).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: Theme.spacingLG)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, Theme.capsuleVPadding)
            .contentShape(Rectangle())
            .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 辅助

    /// 清晰度文案的唯一真源：按钮标签与弹出面板选项共用（0 表示自动）
    private static func qualityLabel(_ quality: Int) -> String {
        quality == 0 ? "自动" : "\(quality)P"
    }

    private func speedText(_ value: Float) -> String { String(format: "%g×", value) }
}

// MARK: - 进度条（独立订阅）

/// 进度条 + 时间文本 单独订阅 PlaybackClock：进度刷新只重绘这一小块，
/// 不会带动包含大量按钮的整条控件栏（以及上层视图树）重算
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

/// 右上角全屏入口的语义：进入 vs 退出。
enum PlayerCorner {
    case enterFullscreen
    case exitFullscreen
}

/// 右上角全屏按钮：试播页（plain）与正式/全屏（circle）共用同一套图标与动作。
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
