// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

private final class PlaybackWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class FullscreenPlayback: NSObject, ObservableObject, NSWindowDelegate {
    let player: AVPlayer
    weak var model: Model?
    private var monitor: Any?
    private var window: NSWindow?
    init(player: AVPlayer, model: Model? = nil) { self.player = player; self.model = model; super.init() }
    func show() {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        guard let model else { return }
        let source = NSApp.keyWindow
        let alreadyFullscreen = source?.styleMask.contains(.fullScreen) == true
        let screen = source?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let window = PlaybackWindow(contentRect: screen.frame, styleMask: alreadyFullscreen ? [.borderless] : [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = alreadyFullscreen ? [.fullScreenAuxiliary, .canJoinAllSpaces] : [.fullScreenPrimary]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.delegate = self
        window.backgroundColor = .black
        window.level = alreadyFullscreen ? .floating : .normal
        window.acceptsMouseMovedEvents = true
        window.contentView = NSHostingView(rootView: FullscreenSurface(playback: self, model: model))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        if !alreadyFullscreen { window.toggleFullScreen(nil) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                if self.model?.infoPanelOpen == true { self.model?.infoPanelOpen = false; self.revealControls() } else { self.close() }; return nil
            }
            // 播放/暂停、方向键已由 Model 的全局键盘监听统一处理，此处不再重复，避免双重切换。
            self.revealControls()
            return event
        }
        revealControls()
    }
    func revealControls() {
        // 鼠标按住拖动时保持显示（否则拖到一半控件消失）。
        model?.revealPlayerControls(keepVisible: NSEvent.pressedMouseButtons != 0)
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar]
    }
    func windowDidExitFullScreen(_ notification: Notification) { close() }
    func windowWillClose(_ notification: Notification) { cleanup(); window?.contentView = nil; window = nil }
    private func cleanup() {
        model?.infoPanelOpen = false
        model?.playerControlsVisible = true
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func close() {
        cleanup()
        let previous = window; window = nil
        previous?.delegate = nil; previous?.close(); previous?.contentView = nil
    }
}

private struct CleanVideo: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
private struct FullscreenSurface: View {
    let playback: FullscreenPlayback
    @ObservedObject var model: Model
    var body: some View {
        ZStack {
            Color.black
            CleanVideo(player: playback.player)
            DanmakuOverlay(model: model, danmaku: model.danmaku)
            PlayerOverlays(model: model, library: model.library, detail: model.detail, showsTransport: false, corner: .exitFullscreen)
        }
        .animation(.easeInOut(duration: 0.25), value: model.playerControlsVisible)
        .animation(.easeInOut(duration: 0.25), value: model.infoPanelOpen)
        .buttonStyle(.borderless).ignoresSafeArea().preferredColorScheme(.dark).tint(.white)
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false   // 自定义全屏（含弹幕/评论/选集）取代系统全屏
        view.allowsPictureInPicturePlayback = true // 使用系统内置画中画，自动显示“正在画中画播放”占位
        view.pictureInPictureDelegate = context.coordinator
        view.videoGravity = .resizeAspect
        view.speeds = [Float(0.5), 0.75, 1, 1.25, 1.5, 2].map { AVPlaybackSpeed(rate: $0, localizedName: "\($0)×") }
        view.player = player
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        // 销毁前先关闭系统画中画，避免视图反初始化时残留画中画会话导致崩溃。
        view.allowsPictureInPicturePlayback = false
        view.pictureInPictureDelegate = nil
        view.player = nil
    }

    /// 系统画中画委托：恢复界面走回调、开始画中画时不自动最小化主窗口，避免默认 dismiss 异常。
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        weak var view: AVPlayerView?
        func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool { false }
        func playerView(_ playerView: AVPlayerView, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            completionHandler(true)
        }
    }
}

/// 画面右上角的自定义全屏入口（系统图标）。
/// 播放/暂停、进度、音量、倍速、投屏、画中画等控件均由 AVPlayerView 的系统浮动控件提供。
struct PlayerCornerButtons: View {
    @ObservedObject var model: Model
    var body: some View {
        HStack(spacing: 8) {
            Button { model.fullscreenPlayback.show() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help("全屏")
        }.buttonStyle(.borderless).padding(10)
    }
}

// MARK: - 内嵌沉浸式播放（Apple TV 风）

/// 占满可用空间的播放器（自绘控件，不用系统浮动控件；基于 AVPlayerLayer 提供真正可用的系统画中画）。
struct ImmersivePlayer: View {
    @ObservedObject var model: Model
    var body: some View {
        ImmersiveVideo(player: model.player, model: model)
            .background(.black)
    }
}

/// 内嵌沉浸式播放的底层视图：基于 AVPlayerLayer + AVPictureInPictureController。
struct ImmersiveVideo: NSViewRepresentable {
    let player: AVPlayer
    weak var model: Model?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.view = view
        context.coordinator.model = model

        // 创建并持有系统画中画控制器，供底部栏 PiP 按钮触发。
        // 委托交给 Model 长期持有的 pipSession，避免视图销毁时委托悬空；
        // 停止 pip 后再由 pipSession 延迟释放承载视图，避免 pip 活跃时释放 AVPlayerLayer 崩溃。
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            model?.pipController = pip
            model?.pipSession.attach(pip: pip)
        }
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        context.coordinator.model = model
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        // 视图销毁交由 pipSession 处理：pip 活跃时延迟到 didStop 后再释放，避免崩溃。
        coordinator.model?.pipSession.retire(view)
    }

    final class Coordinator: NSObject {
        weak var view: PlayerLayerView?
        weak var model: Model?
    }
}

/// 承载 AVPlayerLayer 的 NSView。
final class PlayerLayerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// 透明交互层：点击画面切换控件显隐；鼠标移动时显示控件并刷新自动隐藏计时（与全屏一致 2.5 秒）。
struct PlayerTapLayer: View {
    @ObservedObject var model: Model
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture {
                if model.playerControlsVisible { model.hidePlayerControls() }
                else { model.revealPlayerControls() }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active: model.revealPlayerControls()
                case .ended: break
                }
            }
    }
}

/// 顶部悬浮操作栏：仅试播场景的上一部/下一部/观看全集（正式观看的「下一集」已移至底部选集旁）。
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
        .padding(16)
    }
}

/// 底部控件栏：进度条、播放/暂停、时间、选集/下一集/收藏/弹幕/清晰度/倍速、PiP/投屏。
struct PlayerBottomBar: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    let detail: Detail
    /// 是否显示画中画（PiP）与投屏（AirPlay）。全屏播放不显示这两个系统级传输控件。
    var showsTransport: Bool = true

    private enum PickerKind { case quality, speed }
    @State private var expandedPicker: PickerKind? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.player.rate > 0 ? "pause.fill" : "play.fill").font(.title2)
                    }.help(model.player.rate > 0 ? "暂停" : "播放").buttonStyle(.borderless)
                    Text("\(clock(model.player.currentTime().seconds)) / \(clock(duration))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    // 进度条：位于时间之后、选集之前，占据中间剩余宽度。
                    Slider(value: Binding(
                        get: { model.player.currentTime().seconds.isFinite ? model.player.currentTime().seconds : 0 },
                        set: { model.player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
                    ), in: 0...max(1, duration))
                    .tint(.white)
                    // 选集 + 下一集（正式观看）
                    Button { model.infoPanelOpen.toggle(); model.revealPlayerControls() } label: {
                        Image(systemName: "list.bullet").font(.body)
                    }.help("选集").buttonStyle(.borderless)
                    if !model.preview, let episode = model.episode {
                        Button { model.play(episode + 1) } label: {
                            Image(systemName: "forward.end.fill").font(.body)
                        }.help("下一集").buttonStyle(.borderless)
                            .disabled(episode + 1 >= detail.episodes.count)
                    }
                    // 评论入口暂时隐藏。
                    Button { model.toggleFavorite(detail.series) } label: {
                        Image(systemName: model.favoriteActive(detail.series) ? "star.fill" : "star")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(model.favoriteActive(detail.series) ? .white : Color.white.opacity(0.55))
                    }.help(model.favoriteActive(detail.series) ? "取消收藏" : "收藏").buttonStyle(.borderless)
                DanmakuControl(danmaku: model.danmaku)
                // 清晰度（自绘展开胶囊）
                pickerCapsule(icon: "", text: qualityLabel, kind: .quality)
                // 倍速（自绘展开胶囊）
                pickerCapsule(icon: "", text: "倍速" + speedText(model.speed), kind: .speed)
                if showsTransport {
                    // 画中画（PiP）
                    Button { model.togglePictureInPicture() } label: {
                        Image(systemName: model.pipActive ? "pip.exit" : "pip.enter").font(.body)
                    }.help("画中画").buttonStyle(.borderless)
                    // 投屏入口已隐藏：系统 AVRoutePickerView 实为音频路由，无法投视频画面。
                    // AirPlayPicker(player: model.player).frame(width: 32, height: 26)
                }
                }
                // 自绘展开选项行（清晰度 / 倍速）
                if let picker = expandedPicker {
                    pickerOptions(picker)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            .tint(.white)
        }
    }

    // MARK: - 自绘选择器

    private func pickerCapsule(icon: String, text: String, kind: PickerKind) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expandedPicker = (expandedPicker == kind) ? nil : kind }
            model.revealPlayerControls()
        } label: {
            HStack(spacing: 5) {
                if !icon.isEmpty { Image(systemName: icon).font(.caption) }
                Text(text).font(.caption).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).opacity(0.6)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(expandedPicker == kind ? Color.white.opacity(0.85) : Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(expandedPicker == kind ? Color.black.opacity(0.85) : .white)
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func pickerOptions(_ picker: PickerKind) -> some View {
        HStack(spacing: 8) {
            switch picker {
            case .quality:
                Spacer()
                optionChip("自动", selected: model.quality == 0) { model.changeQuality(0); expandedPicker = nil }
                ForEach([480, 720, 1080], id: \.self) { q in
                    optionChip("\(q)P", selected: model.quality == q) { model.changeQuality(q); expandedPicker = nil }
                }
            case .speed:
                Spacer()
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { s in
                    optionChip(speedText(s), selected: model.speed == s) { model.changeSpeed(s); expandedPicker = nil }
                }
            }
        }
    }

    private func optionChip(_ text: String, selected: Bool, onSelect: @escaping () -> Void) -> some View {
        Button(action: onSelect) {
            Text(text).font(.caption).fontWeight(.medium)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.white.opacity(0.85) : Color.white.opacity(0.14), in: Capsule())
                .foregroundStyle(selected ? Color.black.opacity(0.85) : Color.white)
        }.buttonStyle(.plain)
    }

    // MARK: - 辅助

    private var qualityLabel: String {
        model.quality == 0 ? "自动" : "\(model.quality)P"
    }
    private func speedText(_ value: Float) -> String {
        String(format: "%g×", value)
    }
    private var duration: Double {
        let d = model.player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? max(0, d) : 0
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct PlayerInfoPanel: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    let detail: Detail

    var body: some View {
        let current = model.episode ?? 0
        let total = detail.episodes.count
        VStack(alignment: .leading, spacing: 14) {
            // 标题行：标题 + 当前/总集数 + 上一集/下一集 + 自动下一集 + 关闭。
            HStack(spacing: 12) {
                Label("选集", systemImage: "list.bullet").font(.headline)
                Text("当前第 \(current + 1) 集 / 共 \(total) 集").font(.callout).foregroundStyle(.secondary)
                Spacer()
                // 上一集 / 下一集：复用 play(_:) 切换集，越界时禁用。
                Button { model.play(current - 1); model.infoPanelOpen = false } label: {
                    Image(systemName: "backward.end.fill").font(.body)
                }.help("上一集").buttonStyle(.borderless).disabled(current <= 0 || model.busy)
                Button { model.play(current + 1); model.infoPanelOpen = false } label: {
                    Image(systemName: "forward.end.fill").font(.body)
                }.help("下一集").buttonStyle(.borderless).disabled(current + 1 >= total || model.busy)
                // 连播：复用现有开关，持久化由 Model.autoNext 的 didSet 统一处理。
                Toggle("连播", isOn: $model.autoNext)
                Button { model.infoPanelOpen = false } label: {
                    Image(systemName: "xmark").font(.body)
                }.help("关闭").buttonStyle(.borderless)
            }
            // 选集网格：固定 8 列等宽、紧凑间距，当前集突出显示。
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(detail.episodes.indices, id: \.self) { index in
                        Button { model.play(index); model.infoPanelOpen = false } label: {
                            Text("\(index + 1)")
                                .font(.subheadline).fontWeight(model.episode == index ? .semibold : .regular)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(model.episode == index ? Color.white.opacity(0.85) : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .foregroundStyle(model.episode == index ? Color.black.opacity(0.85) : Color.white)
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }.padding(4)
            }.frame(maxHeight: 200)
            if !model.related.isEmpty {
                Text("相关作品").font(.subheadline).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(model.related) { work in
                            Button { model.infoPanelOpen = false; if work.upcoming { model.reserve(work) } else { model.open(work.series) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    AsyncImage(url: URL(string: work.series.cover)) { image in image.resizable().scaledToFill() }
                                        placeholder: { Rectangle().fill(.gray.opacity(0.18)).overlay(Image(systemName: "film")) }
                                        .frame(width: 110, height: 150).clipped().cornerRadius(10)
                                    Text(work.series.title).font(.caption).lineLimit(2).frame(height: 30, alignment: .topLeading)
                                }.frame(width: 110, alignment: .leading)
                            }.buttonStyle(.plain).padding(4)
                                .disabled(model.busy || (work.upcoming && model.account?.loggedIn != true))
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20).padding(.bottom, 16)
    }
}

// MARK: - 播放器覆盖层

/// 播放区悬浮覆盖层（右上角全屏入口 + 顶部栏 + 底部栏 + 信息面板）。
/// 全屏与非全屏共用一套布局，仅右上角按钮语义与底部栏传输控件（PiP/投屏）不同，
/// 消除 FullscreenSurface 与 EpisodeView 的重复实现。
struct PlayerOverlays: View {
    @ObservedObject var model: Model
    let library: LocalLibrary
    let detail: Detail?
    let showsTransport: Bool
    /// 右上角按钮语义：退出全屏 vs 进入全屏（各自图标/文案/动作不同）。
    let corner: Corner

    enum Corner {
        case enterFullscreen
        case exitFullscreen
    }

    var body: some View {
        // 右上角全屏入口——与上下控件一起随 playerControlsVisible 自动隐藏。
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
            VStack { Spacer(); PlayerBottomBar(model: model, library: library, detail: detail, showsTransport: showsTransport) }
                .transition(.opacity)
        }
        // 底部信息面板（选集/简介/相关作品）
        if let detail, model.infoPanelOpen {
            VStack { Spacer(); PlayerInfoPanel(model: model, library: library, detail: detail) }
                .transition(.opacity)
        }
    }

    private var cornerButton: some View {
        switch corner {
        case .exitFullscreen:
            return Button {
                model.fullscreenPlayback.close()
            } label: {
                cornerIcon("arrow.down.right.and.arrow.up.left")
            }.help("退出全屏 · Esc").buttonStyle(.plain).padding(12)
        case .enterFullscreen:
            return Button {
                model.fullscreenPlayback.show()
            } label: {
                cornerIcon("arrow.up.left.and.arrow.down.right")
            }.help("全屏").buttonStyle(.plain).padding(12)
        }
    }

    private func cornerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.5), in: Circle())
    }
}
