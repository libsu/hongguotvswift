// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct HongGuo: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    var body: some Scene {
        Window("HongGuo", id: "main") { ContentView(model: model)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
            .defaultSize(width: 1200, height: 820)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandMenu("播放") {
                    Button("播放 / 暂停") { model.togglePlayback() }.disabled(!model.showDetail || model.busy)
                    Button("上一部") { model.moveRecommendation(-1) }.disabled(!model.preview || model.busy)
                    Button("下一部") { model.moveRecommendation(1) }.disabled(!model.preview || model.busy)
                    Button("快退 10 秒") { model.skipPlayback(-10) }.disabled(!model.showDetail)
                    Button("快进 10 秒") { model.skipPlayback(10) }.disabled(!model.showDetail)
                }
            }
    }
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }
}
