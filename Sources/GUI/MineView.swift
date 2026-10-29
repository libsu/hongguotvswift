// SPDX-License-Identifier: GPL-3.0-only
// 「我的」栏目：账户登录态、收藏/历史/预约片单与设置项
import SwiftUI
import AppKit

struct MyAccountView: View {
    @ObservedObject var model: Model
    @ObservedObject var library: LocalLibrary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingSection) {
                mineSection(.account)
                mineSection(.favorites, emptyHint: "暂无收藏")
                mineSection(.history, emptyHint: "暂无观看记录")
                mineSection(.reservations, emptyHint: "暂无已上线预约")
                mineSection(.settings)
                Text("HongGuo · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "测试版")").font(.caption).foregroundStyle(.secondary)
            }.padding(Theme.spacingSection).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, minHeight: ContentView.detailMinHeight, maxHeight: .infinity, alignment: .top)
    }

    private enum MineBlock {
        case account, favorites, history, reservations, settings
        var title: String {
            switch self {
            case .account: return "账户"
            case .favorites: return "收藏"
            case .history: return "历史"
            case .reservations: return "预约"
            case .settings: return "设置"
            }
        }
    }

    @ViewBuilder
    private func mineSection(_ block: MineBlock, emptyHint: String = "") -> some View {
        switch block {
        case .account:
            VStack(alignment: .leading, spacing: Theme.spacingMD) {
                SectionTitle(block.title)
                if model.account?.loggedIn == true {
                    HStack(spacing: Theme.spacingLG) {
                        Text(model.account?.nickname ?? "用户").font(.headline).foregroundStyle(.secondary).lineLimit(1)
                        Button("登出") { model.logout() }.disabled(model.accountBusy)
                        Spacer(minLength: 0)
                    }
                    if let error = model.cloudAllError {
                        InlineHint(text: error, retry: { model.loadAllCloud() }, disabled: model.cloudAllLoading)
                    }
                } else {
                    AccountPanel(model: model)
                }
            }

        case .settings:
            VStack(alignment: .leading, spacing: Theme.spacingMD) {
                SectionTitle(block.title)
                settingsGrid
            }

        case .favorites, .reservations:
            let kind: MineSection = block == .favorites ? .favorites : .reservations
            PosterSection(block.title, items: kind.items(model: model), level: .page, emptyHint: emptyHint) { series in
                SeriesPosterCard(cover: series.cover, title: series.title) { model.open(series) }
            }

        case .history:
            if model.account?.loggedIn == true {
                PosterSection(block.title, items: model.cloudHistory, level: .page, emptyHint: emptyHint) { entry in
                    SeriesPosterCard(cover: entry.series.cover, title: entry.series.title, subtitle: historySubtitle(entry)) {
                        model.open(entry.series, resumeEpisodeID: entry.episodeID, resumePosition: entry.position)
                    }
                }
            } else {
                PosterSection(block.title, items: library.contents.history, level: .page, emptyHint: emptyHint) { record in
                    SeriesPosterCard(cover: record.series.cover, title: record.series.title, subtitle: record.label) { model.open(record.series) }
                }
            }
        }
    }

    // MARK: - 设置

    private var settingsGrid: some View {
        VStack(alignment: .leading, spacing: Theme.spacingXL) {
            SettingsRow(label: "连播", isOn: $model.autoNext)
            SettingsRow(label: "首页直接播放", isOn: $model.homeAutoPlay, help: "开启后进入首页加载完成即自动播放")
            SettingsRow(label: "自动清晰度", isOn: Binding(get: { model.quality == 0 }, set: { auto in model.setQualityPreference(auto ? 0 : 1080) }), help: "开启后自动选择源提供的最高可用清晰度")
            SettingsRow(label: "自动检查更新", isOn: Binding(get: { model.updates.autoCheck }, set: { model.updates.autoCheck = $0 }), help: "开启后启动时自动检查更新")
            updateHint
        }.frame(width: 200, alignment: .leading)
    }

    @ViewBuilder
    private var updateHint: some View {
        if let update = model.updates.available {
            HStack(spacing: Theme.spacingMD) {
                Text("发现新版本 \(update.version)").font(.caption).foregroundStyle(.secondary)
                Button("前往发布页下载") { NSWorkspace.shared.open(MacUpdates.releasePageURL) }
            }
        } else if model.updates.busy {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - 辅助

    private func historySubtitle(_ entry: CloudEntry) -> String {
        let ep = (entry.episodeIndex ?? 0) + 1
        let pos = max(0, Int(entry.position ?? 0))
        return "第 \(ep) 集 · \(String(format: "%02d:%02d", pos / 60, pos % 60))"
    }
}


struct AccountPanel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            if let data = model.qrImageData, let image = NSImage(data: data) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220).padding(10).background(.white)
                Button("取消扫码") { model.cancelLogin() }
            } else {
                Button("红果扫码登录") { model.beginLogin() }.disabled(model.busy || model.accountBusy)
            }
            Text(model.accountMessage).font(.caption).foregroundStyle(.secondary)
        }
    }
}
