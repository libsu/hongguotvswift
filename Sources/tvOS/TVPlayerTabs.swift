// SPDX-License-Identifier: GPL-3.0-only
// 播放器 info tab 的 SwiftUI 内容（供 UIHostingController 承载，挂在 AVPlayerViewController 的 customInfoViewControllers）
// 含「选集 / 相关作品 / 倍速 / 清晰度」四个 tab，与 UIKit 桥接层（TVPlayerView.swift）分离
import SwiftUI
import UIKit

// MARK: - Info Tab 内容（SwiftUI，供 UIHostingController 承载）

/// 「选集」tab：短剧数百上千集不适合平铺网格，改用「集数步进选择器」——
/// 选集：步进（±1 / ±10）调整目标集，点「播放该集」才切换播放 内容高度固定，避免 info tab 抬升忽高忽低
struct TVEpisodeList: View {
    @ObservedObject var model: Model
    @State private var target: Int = 0

    /// 本 tab 内五个可聚焦元素的统一焦点 scope
    /// 关键：不绑定同一 scope 时，系统在 `customInfoViewControllers` 里做几何推断，
    /// 会导致「下一/后十」按「下」找不到下方按钮（焦点界层级乱）
    enum Focus: Hashable { case prev10, prev, next, next10, play }
    @FocusState private var focus: Focus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = model.detail {
                let total = detail.episodes.count
                let current = model.episode ?? 0

                Text("第 \(target + 1) 集 / 共 \(total) 集")
                    .font(.title2.bold())
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    stepButton(icon: "backward.frame.fill", focusKey: .prev10) {
                        target = max(0, target - 10)
                    }
                    stepButton(icon: "backward.fill", focusKey: .prev) {
                        target = max(0, target - 1)
                    }

                    Text("\(target + 1)")
                        .font(.system(size: 40, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(minWidth: 100)

                    stepButton(icon: "forward.fill", focusKey: .next) {
                        target = min(total - 1, target + 1)
                    }
                    stepButton(icon: "forward.frame.fill", focusKey: .next10) {
                        target = min(total - 1, target + 10)
                    }
                }

                Button {
                    model.play(target)
                } label: {
                    Label(target == current ? "正在播放" : "播放该集", systemImage: "play.fill")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 4).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                // 视觉上仍靠左显示，但可聚焦命中区铺满整行
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .focused($focus, equals: .play)
                .disabled(target == current)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: infoTabHeight)
        .onAppear {
            target = model.episode ?? 0
        }
    }

    private func stepButton(icon: String, focusKey: Focus, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .frame(width: 28, height: 28)
                .padding(2)
        }
        .buttonStyle(.bordered)
        .focused($focus, equals: focusKey)
        // 步进行（含下一/后十）按「下」显式到「播放该集」，绕过系统在嵌套 info tab 里的不可靠几何推断
        .onMoveCommand { direction in
            if direction == .down { focus = .play }
        }
    }
}

/// 「相关作品」tab：横向海报列表，点选打开（待上线则预约）
struct TVRelatedList: View {
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.related.isEmpty {
                Text(model.relatedMessage.isEmpty ? "暂无相关作品" : model.relatedMessage)
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(model.related) { entry in
                            Button {
                                if entry.upcoming { model.reserve(entry) }
                                else { model.open(entry.series) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    TVCoverImage(url: entry.series.cover, width: 120, height: 180, cornerRadius: 10)
                                    Text(entry.series.title)
                                        .font(.caption).foregroundStyle(.white).lineLimit(1)
                                        .frame(width: 120, alignment: .leading)
                                }
                                .frame(width: 120, alignment: .leading)
                            }
                            .buttonStyle(.borderless)
                            .disabled(entry.upcoming && model.account?.loggedIn != true)
                        }
                    }
                    .padding(4)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: infoTabHeight)
    }
}

// MARK: - 倍速 / 清晰度 info tab（原在 transport bar 菜单，改为本身自定义 tab）

/// 「倍速」tab：横向胶囊列表，点选切换播放倍速（当前值高亮为选中态）
struct TVSpeedView: View {
    @ObservedObject var model: Model
    @FocusState private var focus: String?

    private let values = PlaybackOptions.speeds

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(values, id: \.self) { value in
                    optionCapsule(title: speedText(value), value: "\(value)", current: "\(model.speed)") {
                        model.changeSpeed(value)
                    }
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: infoTabHeight)
    }

    private func speedText(_ value: Float) -> String { String(format: "%g×", value) }

    private func optionCapsule(title: String, value: String, current: String, action: @escaping () -> Void) -> some View {
        TVCapsuleButton(optionTitle: title, selected: current == value, focusKey: value, focus: $focus, action: action)
    }
}

/// 「清晰度」tab：横向胶囊列表，点选切换清晰度（当前值高亮为选中态）
struct TVQualityView: View {
    @ObservedObject var model: Model
    @FocusState private var focus: String?

    private let values = PlaybackOptions.qualities

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ForEach(values, id: \.self) { value in
                    optionCapsule(title: value == 0 ? "自动" : "\(value)P", value: "\(value)", current: "\(model.quality)") {
                        model.changeQuality(value)
                    }
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: infoTabHeight)
    }

    private func optionCapsule(title: String, value: String, current: String, action: @escaping () -> Void) -> some View {
        TVCapsuleButton(optionTitle: title, selected: current == value, focusKey: value, focus: $focus, action: action)
    }
}

/// 播放器 info tab 里通用的单选胶囊已收敛为 TVCapsuleButton 的 option 工厂（见 TVComponents.swift），此处不再单独声明
