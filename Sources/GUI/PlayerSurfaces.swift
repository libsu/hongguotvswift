// SPDX-License-Identifier: GPL-3.0-only
// Sources/GUI/PlayerSurfaces.swift
import SwiftUI
import AVKit

// MARK: - Shared Helpers

@MainActor
private func makeBareAVPlayerView(videoGravity: AVLayerVideoGravity = .resizeAspect) -> AVPlayerView {
    let view = AVPlayerView()
    view.videoGravity = videoGravity
    return view
}

private extension AVPlayerView {
    /// Preset playback speeds offered by the trial player's floating controls.
    /// 取值来自 `PlaybackOptions.speeds`，与自绘底部控件栏共用同一份真源。
    static let trialSpeeds: [AVPlaybackSpeed] = PlaybackOptions.speeds.map {
        AVPlaybackSpeed(rate: $0, localizedName: "\($0)×")
    }
}

// MARK: - Preview Surface (System AVPlayerView)

/// System player view with floating controls and system Picture-in-Picture.
/// Used for trial playback on the home screen.
@MainActor
struct PlayerSurfacePreview: NSViewRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = makeBareAVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false // Custom fullscreen (danmaku/comments/episodes) replaces the system one.
        view.allowsPictureInPicturePlayback = true
        view.pictureInPictureDelegate = context.coordinator
        view.speeds = AVPlayerView.trialSpeeds
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        // Stop PiP before teardown to avoid crashes from a stale session outliving the view.
        view.allowsPictureInPicturePlayback = false
        view.pictureInPictureDelegate = nil
        view.player = nil
    }

    /// Keeps PiP interface restoration under app control instead of the default dismiss behavior.
    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool {
            false
        }

        func playerView(
            _ playerView: AVPlayerView,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            completionHandler(true)
        }
    }
}

// MARK: - Window Surface (AVPlayerLayer + Custom Controls)

/// Primary in-window playback surface, backed by `AVPlayerLayer` with custom-drawn controls.
/// Danmaku and interactive overlays are composited by the caller (see `EpisodeView`).
@MainActor
struct PlayerSurfaceWindow: NSViewRepresentable {
    let player: AVPlayer
    weak var model: Model?

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect

        // PiP lifecycle (creation, delegate ownership, deferred teardown while active)
        // is fully owned by `model.pipSession`; this view only hands over the layer.
        model?.pipSession.activate(for: view.playerLayer)
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleNSView(_ view: PlayerLayerHostView, coordinator: Coordinator) {
        // `pipSession` decides whether to release the view immediately or defer
        // until an active PiP session actually stops (releasing it early crashes).
        coordinator.model?.pipSession.retire(view)
    }

    /// 仅用于在 `dismantleNSView`（static，拿不到 self）时访问 Model
    @MainActor
    final class Coordinator {
        weak var model: Model?
        init(model: Model?) { self.model = model }
    }
}

/// `NSView` hosting an `AVPlayerLayer`.
final class PlayerLayerHostView: NSView {
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }
}

// MARK: - Fullscreen Surface (Bare Video)

/// Bare video surface (controls disabled) for the fullscreen window.
/// Danmaku and custom controls are composited on top by `FullscreenSurface`.
@MainActor
struct PlayerSurfaceFullscreen: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = makeBareAVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
