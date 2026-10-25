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
    @Published var controlsVisible = true
    @Published var playing = false
    @Published var panelOpen = false
    @Published var commentsOpen = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    private var timer: Task<Void, Never>?
    private var observer: Any?
    private var monitor: Any?
    private var window: NSWindow?
    init(player: AVPlayer, model: Model? = nil) { self.player = player; self.model = model; super.init() }
    func show() {
        guard window == nil else { window?.makeKeyAndOrderFront(nil); return }
        let now = player.currentTime().seconds, length = player.currentItem?.duration.seconds ?? 0
        position = now.isFinite ? max(0, now) : 0
        duration = length.isFinite ? max(0, length) : 0
        playing = player.rate > 0
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
        window.contentView = NSHostingView(rootView: FullscreenSurface(playback: self))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        if !alreadyFullscreen { window.toggleFullScreen(nil) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .keyDown]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyDown && event.keyCode == 53 {
                if self.panelOpen || self.commentsOpen { self.panelOpen = false; self.commentsOpen = false; self.revealControls() } else { self.close() }; return nil
            }
            // 播放/暂停、方向键已由 Model 的全局键盘监听统一处理，此处不再重复，避免双重切换。
            self.revealControls()
            return event
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.playing = self.player.rate > 0
                self.position = time.seconds.isFinite ? time.seconds : 0
                let seconds = self.player.currentItem?.duration.seconds ?? 0
                self.duration = seconds.isFinite ? max(0, seconds) : 0
            }
        }
        revealControls()
    }
    func revealControls() {
        controlsVisible = true; timer?.cancel()
        timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.panelOpen || self.commentsOpen || NSEvent.pressedMouseButtons != 0 { self.revealControls() }
                else { self.controlsVisible = false }
        }
    }
    func togglePlayback() {
        if let model { model.togglePlayback() }
        else if player.rate > 0 { player.pause() } else { player.play() }
        playing = player.rate > 0
        revealControls()
    }
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideDock, .autoHideMenuBar]
    }
    func windowDidExitFullScreen(_ notification: Notification) { close() }
    func windowWillClose(_ notification: Notification) { cleanup(); window?.contentView = nil; window = nil }
    private func cleanup() {
        panelOpen = false; commentsOpen = false
        timer?.cancel(); timer = nil
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
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
    var model: Model? = nil
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
    @ObservedObject var playback: FullscreenPlayback
    var body: some View {
        ZStack {
            Color.black
            CleanVideo(player: playback.player)
            if let model = playback.model { DanmakuOverlay(model: model, danmaku: model.danmaku) }
            if playback.controlsVisible {
                VStack {
                    HStack {
                        if let model = playback.model { FullscreenTitle(model: model) }
                        Spacer()
                        Button { playback.close() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                            .help("退出全屏 · Esc")
                    }.padding(24).background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    Spacer()
                    VStack(spacing: 16) {
                        Slider(value: Binding(get: { min(playback.position, max(1, playback.duration)) }, set: { value in
                            playback.player.seek(to: CMTime(seconds: value, preferredTimescale: 600)); playback.revealControls()
                        }), in: 0...max(1, playback.duration))
                        HStack(spacing: 20) {
                            Button { playback.togglePlayback() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title2) }
                                .help(playback.playing ? "暂停" : "播放")
                            Text("\(clock(playback.position)) / \(clock(playback.duration))").monospacedDigit()
                            Spacer()
                            if let model = playback.model { FullscreenSettings(model: model, playback: playback) }
                        }
                    }.padding(24).background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                }
            }
            if playback.commentsOpen, let model = playback.model {
                HStack { Spacer()
                    VStack(spacing: 0) {
                        HStack { Spacer(); Button { playback.commentsOpen = false; playback.revealControls() } label: { Image(systemName: "xmark") } }.padding(16)
                        CommentsPanel(model: model, comments: model.comments, thread: model.commentThread)
                    }.frame(width: 420).background(.black.opacity(0.95)).padding(.vertical, 50)
                }
            }
            if playback.panelOpen, let model = playback.model {
                HStack { Spacer(); FullscreenEpisodes(model: model, playback: playback).frame(width: 340) }
            }
        }.buttonStyle(.borderless).ignoresSafeArea().preferredColorScheme(.dark).tint(.orange)
    }
    private func clock(_ value: Double) -> String { let seconds = Int(max(0, value)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}
private struct FullscreenTitle: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.detail?.series.title ?? "播放").font(.title2.bold()).lineLimit(1)
            Text("第 \((model.episode ?? 0) + 1) 集 · 共 \(model.detail?.episodes.count ?? 0) 集\(model.preview ? " · 首集试播" : "")").foregroundStyle(.secondary)
        }
    }
}
private struct FullscreenSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var playback: FullscreenPlayback
    var body: some View {
        Group {
            if model.preview { Button("观看全集") { model.watchFull(); playback.panelOpen = true } }
            DanmakuControl(danmaku: model.danmaku)
            Button("评论") { playback.commentsOpen.toggle(); playback.panelOpen = false; playback.revealControls() }
            Button("选集") { playback.panelOpen.toggle(); playback.commentsOpen = false; playback.revealControls() }
            Menu("\(String(model.quality))P") {
                ForEach([480,720,1080], id: \.self) { quality in Button("\(quality)P") { model.changeQuality(quality); playback.revealControls() } }
            }.disabled(model.busy)
            Menu("\(model.speed, specifier: "%g")×") {
                ForEach([Float(0.5),0.75,1,1.25,1.5,2], id: \.self) { speed in Button("\(speed, specifier: "%g")×") { model.changeSpeed(speed); playback.revealControls() } }
            }
        }
    }
}
private struct FullscreenEpisodes: View {
    @ObservedObject var model: Model
    @ObservedObject var playback: FullscreenPlayback
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("选集 · 共 \(model.detail?.episodes.count ?? 0) 集").font(.headline)
                Spacer()
                Button { playback.panelOpen = false; playback.revealControls() } label: { Image(systemName: "xmark") }
            }
            Text(model.detail?.series.title ?? "").font(.headline).lineLimit(2)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                    ForEach(model.detail?.episodes.indices ?? 0..<0, id: \.self) { index in
                        Button("\(index + 1)") { model.play(index); playback.panelOpen = false; playback.revealControls() }
                            .buttonStyle(.bordered).controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .tint(model.episode == index ? .orange : .gray).disabled(model.busy)
                    }
                }
            }
        }.padding(24).background(.black.opacity(0.94)).padding(.vertical, 60)
    }
}

struct NativePlayer: NSViewRepresentable {
    let player: AVPlayer
    var model: Model? = nil
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
        if AVPictureInPictureController.isPictureInPictureSupported(),
           let pip = AVPictureInPictureController(playerLayer: view.playerLayer) {
            pip.delegate = context.coordinator
            context.coordinator.pip = pip
            model?.pipController = pip
        }
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        context.coordinator.model = model
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.pip?.stopPictureInPicture()
        coordinator.pip?.delegate = nil
        coordinator.pip = nil
        coordinator.model?.pipController = nil
        view.playerLayer.player = nil
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        weak var view: PlayerLayerView?
        weak var model: Model?
        var pip: AVPictureInPictureController?

        func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in self.model?.pipActive = true }
        }
        func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
            Task { @MainActor in self.model?.pipActive = false }
        }
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

/// 透明点击层：点击画面切换控件显隐。
struct PlayerTapLayer: View {
    @ObservedObject var model: Model
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) {
                    model.playerControlsVisible.toggle()
                    if model.playerControlsVisible == false { model.infoPanelOpen = false }
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

/// 底部渐变栏：进度条、播放/暂停、时间、选集/下一集/弹幕/收藏/清晰度/倍速、PiP/投屏。
struct PlayerBottomBar: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    let detail: Detail

    private enum PickerKind { case quality, speed }
    @State private var expandedPicker: PickerKind? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            VStack(spacing: 12) {
                Slider(value: Binding(
                    get: { model.player.currentTime().seconds.isFinite ? model.player.currentTime().seconds : 0 },
                    set: { model.player.seek(to: CMTime(seconds: $0, preferredTimescale: 600)) }
                ), in: 0...max(1, duration))
                .tint(.orange)
                HStack(spacing: 18) {
                    Button { model.togglePlayback() } label: {
                        Image(systemName: model.player.rate > 0 ? "pause.fill" : "play.fill").font(.title2)
                    }.help(model.player.rate > 0 ? "暂停" : "播放").buttonStyle(.borderless)
                    Text("\(clock(model.player.currentTime().seconds)) / \(clock(duration))").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // 选集 + 下一集（正式观看）
                    Button { model.infoPanelOpen.toggle(); model.playerControlsVisible = true } label: {
                        Image(systemName: "list.bullet").font(.body)
                    }.help("选集").buttonStyle(.borderless)
                    if !model.preview, let episode = model.episode {
                        Button { model.play(episode + 1) } label: {
                            Image(systemName: "forward.end.fill").font(.body)
                        }.help("下一集").buttonStyle(.borderless)
                            .disabled(episode + 1 >= detail.episodes.count)
                    }
                    DanmakuControl(danmaku: model.danmaku)
                    // 评论入口暂时隐藏。
                    Button { model.toggleFavorite(detail.series) } label: {
                        Image(systemName: model.favoriteActive(detail.series) ? "star.fill" : "star")
                            .foregroundStyle(model.favoriteActive(detail.series) ? .orange : .white)
                    }.help(model.favoriteActive(detail.series) ? "取消收藏" : "收藏").buttonStyle(.borderless)
                    // 清晰度（自绘展开胶囊）
                    pickerCapsule(icon: "4k.tv", text: qualityLabel, kind: .quality)
                    // 倍速（自绘展开胶囊）
                    pickerCapsule(icon: "gauge.with.dots.needle.50percent", text: speedText(model.speed), kind: .speed)
                    // 画中画（PiP）
                    Button { model.togglePictureInPicture() } label: {
                        Image(systemName: model.pipActive ? "pip.exit" : "pip.enter").font(.body)
                    }.help("画中画").buttonStyle(.borderless)
                    // 投屏（系统路由选择器，一键唤起设备面板，等同 QuickTime 电视图标）
                    AirPlayPicker().frame(width: 32, height: 26)
                }
                // 自绘展开选项行（清晰度 / 倍速）
                if let picker = expandedPicker {
                    pickerOptions(picker)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
        }
    }

    // MARK: - 自绘选择器

    private func pickerCapsule(icon: String, text: String, kind: PickerKind) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expandedPicker = (expandedPicker == kind) ? nil : kind }
            model.playerControlsVisible = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption)
                Text(text).font(.caption).fontWeight(.medium)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).opacity(0.6)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(expandedPicker == kind ? .orange.opacity(0.9) : Color.white.opacity(0.14), in: Capsule())
            .foregroundStyle(expandedPicker == kind ? .black : .white)
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
                .background(selected ? Color.orange : Color.white.opacity(0.14), in: Capsule())
                .foregroundStyle(selected ? Color.black : Color.white)
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

/// 投屏路由选择器：直接展示系统路由按钮（一键唤起设备面板），调整着色以融入深色 UI。
struct AirPlayPicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        return view
    }
    func updateNSView(_ view: AVRoutePickerView, context: Context) {}
}

/// 底部弹出的选集面板（精简：标题 + 关闭 + 选集网格 + 自动下一集 + 相关作品）。
struct PlayerInfoPanel: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary
    let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("选集", systemImage: "list.bullet").font(.headline)
                Text("共 \(detail.episodes.count) 集").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { model.infoPanelOpen = false } label: {
                    Image(systemName: "xmark").font(.body)
                }.help("关闭").buttonStyle(.borderless)
            }
            HStack {
                Button(model.resumeLabel) { model.resume(); model.infoPanelOpen = false }.disabled(model.busy)
                Spacer()
                Toggle("自动下一集", isOn: $model.autoNext).onChange(of: model.autoNext) { UserDefaults.standard.set($0, forKey: "autoNext") }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], spacing: 10) {
                    ForEach(detail.episodes.indices, id: \.self) { index in
                        Button("\(index + 1)") { model.play(index); model.infoPanelOpen = false }
                            .buttonStyle(.bordered).controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .tint(model.episode == index ? .orange : .gray).disabled(model.busy)
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
