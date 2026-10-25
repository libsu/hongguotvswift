// SPDX-License-Identifier: GPL-3.0-only
// tvOS 播放器骨架：用系统 AVPlayerViewController 承载 Model.player。
// 关键：取流/解密（ResourceLoader + AVAssetResourceLoaderDelegate）完全复用逻辑层，
// 本文件只负责「把 AVPlayer 交给系统控制器渲染」，不含任何 AppKit 依赖。
import SwiftUI
import AVKit

/// 把 AVPlayerViewController 桥接进 SwiftUI。
struct TVPlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // tvOS 上 AVPlayerViewController 本身就是全屏，无「进入/退出全屏」属性；
        // 也无画中画，故不设置 PiP 相关属性。
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

/// 播放页面：整页展示系统播放器 + 悬浮返回 / 标题。
struct TVPlayerView: View {
    @ObservedObject var model: Model

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVPlayerViewController(player: model.player)
                .ignoresSafeArea()

            // 顶部悬浮标题 + 返回（仅占位，完整遥控器焦点控件后续阶段做）。
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        model.backToLibrary()
                    } label: {
                        Label("返回", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                if let detail = model.detail {
                    Text(detail.series.title).font(.title3.bold()).foregroundStyle(.white)
                    Text("第 \((model.episode ?? 0) + 1) 集").font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }
}
