// SPDX-License-Identifier: GPL-3.0-only
// 视觉设计系统：集中定义 macOS 前端的颜色、圆角、间距、卡片尺寸与通用可复用组件，
// 消除各视图中散落的魔法数字与重复特例代码。
import SwiftUI

// MARK: - 视觉常量

/// macOS 前端统一视觉令牌。命名按用途而非具体数值，便于将来统一换肤。
enum Theme {
    // MARK: 颜色
    /// 非选中的胶囊/控件灰底。
    static let capsuleUnselected = Color.gray.opacity(0.16)
    /// 侧栏选中项底色。
    static let railSelected = Color.accentColor.opacity(0.22)

    // MARK: 圆角
    static let cornerSmall: CGFloat = 8
    static let cornerCard: CGFloat = 10
    static let cornerPanel: CGFloat = 12
    static let cornerLarge: CGFloat = 16

    // MARK: 间距
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 6
    static let spacingMD: CGFloat = 8
    static let spacingLG: CGFloat = 12
    static let spacingXL: CGFloat = 16
    static let spacingXXL: CGFloat = 18
    static let spacingHuge: CGFloat = 24
    static let spacingSection: CGFloat = 32

    // MARK: 卡片尺寸
    /// 小卡片（我的-收藏/历史、账户四类片单、相关作品）封面尺寸。
    static let posterSmallWidth: CGFloat = 110
    static let posterSmallHeight: CGFloat = 150
    static let posterLargeWidth: CGFloat = 158
    static let posterLargeHeight: CGFloat = 225

    // MARK: 胶囊控件（SelectableCapsule）
    static let capsuleFont: Font = .subheadline
    static let capsuleFontWeight: Font.Weight = .medium
    static let capsuleHPadding: CGFloat = 12
    static let capsuleVPadding: CGFloat = 5
    static let capsuleContentSpacing: CGFloat = 5
    static let capsuleGap: CGFloat = 6

    // MARK: 卡片文字行高
    /// 卡片徽章/副标题的单行固定高度（占位对齐用，避免有/无该行时卡片高度错位）。
    static let captionLineHeight: CGFloat = 15
}

// MARK: - 可复用组件

/// 平铺点选的「选中/未选中」胶囊按钮。
/// - Light 主题用于浅色界面（列表筛选、频道选择）：选中用 accent 底 + 白字，未选中用灰底。
/// - Dark 主题用于播放器深色覆盖层：选中用白底黑字，未选中用半透明白底白字。
/// 附带可选的图标（左侧）与尾部 chevron（下拉选择器风格）。
struct SelectableCapsule: View {
    enum Style {
        case light
        case dark

        var selectedBackground: Color {
            switch self {
            case .light: return Color.accentColor
            case .dark: return Color.white.opacity(0.85)
            }
        }
        var selectedForeground: Color {
            switch self {
            case .light: return Color.white
            case .dark: return Color.black.opacity(0.85)
            }
        }
        var unselectedBackground: Color {
            switch self {
            case .light: return Theme.capsuleUnselected
            case .dark: return Color.white.opacity(0.14)
            }
        }
        var unselectedForeground: Color {
            switch self {
            case .light: return Color.primary
            case .dark: return Color.white
            }
        }
    }

    let label: String
    let isSelected: Bool
    let style: Style
    var icon: String? = nil
    var showsChevron: Bool = false
    var horizontalPadding: CGFloat = Theme.capsuleHPadding
    var verticalPadding: CGFloat = Theme.capsuleVPadding
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.capsuleContentSpacing) {
                if let icon, !icon.isEmpty { Image(systemName: icon).font(.caption) }
                Text(label).font(Theme.capsuleFont).fontWeight(Theme.capsuleFontWeight).lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).opacity(0.6)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(isSelected ? style.selectedBackground : style.unselectedBackground, in: Capsule())
            .foregroundStyle(isSelected ? style.selectedForeground : style.unselectedForeground)
        }
        .buttonStyle(.plain)
    }
}

/// 胶囊筛选行：可选标题 + 一组「选中/未选中」胶囊。
/// 封装了「选项组 + 标题 + 布局 + 选中态」的整套筛选容器，避免各栏目各自手写标题与布局逻辑。
struct CapsuleFilterRow: View {
    struct Option: Identifiable {
        let label: String
        let value: String
        var id: String { value }
    }

    /// 布局模式：wrap = 单行横排（超出可滚动），row = 固定单行横排（首页频道切换）。
    enum Layout {
        case wrap
        case row
    }

    let title: String?
    let options: [Option]
    @Binding var selection: String
    var layout: Layout = .wrap
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            if let title {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            switch layout {
            case .wrap:
                // 单行：每个胶囊宽度由文本自适应、内部 padding 恒定、胶囊间距由 HStack spacing 恒等；
                // 超出可滚动。用系统 HStack/ScrollView 保证稳定，不借助会崩溃的自定义 Layout。
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.capsuleGap) {
                        ForEach(options) { option in
                            capsule(option)
                        }
                    }
                }
            case .row:
                HStack(spacing: Theme.capsuleGap) {
                    ForEach(options) { option in
                        capsule(option)
                    }
                }
            }
        }
    }

    private func capsule(_ option: Option) -> some View {
        let selected = selection == option.value
        return SelectableCapsule(label: option.label, isSelected: selected, style: .light) {
            guard !selected else { return }
            selection = option.value
            onChange()
        }
    }
}

/// 通用海报卡片：封面 + 标题 + 可选副标题，宽高固定（默认小卡尺寸）。
/// 封面加载/缓存由 CoverImageView 统一处理；圆角、标题行高遵循 Theme。
struct SeriesPosterCard: View {
    let cover: String
    let title: String
    var subtitle: String? = nil
    /// 副标题使用 accent 高亮色（如「账号看到第 N 集」「榜单名次」）还是次要色。
    var subtitleAccent: Bool = false
    var width: CGFloat = Theme.posterSmallWidth
    var height: CGFloat = Theme.posterSmallHeight
    /// 封面下载优先级：数值越小越优先，供列表按显示顺序传入索引。
    var priority: Int = .max
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                CoverImageView(urlString: cover, priority: priority)
                    .frame(width: width, height: height).clipped().cornerRadius(Theme.cornerCard)
                Text(title).font(.caption).lineLimit(2).frame(height: 30, alignment: .topLeading)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(subtitleAccent ? Color.accentColor : Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(Theme.spacingXS)
    }
}

/// 列表页大卡片：封面（高度可传入）+ 标题 + 可选徽章 + 多行副标题 + 可选右键菜单。
/// 由调用方组装数据，渲染与视觉样式集中在本组件。
struct SeriesCard: View {
    struct SubtitleLine {
        var text: String
        var accent: Bool = false
        var trailingText: String? = nil
        var trailingAccent: Bool = true
    }
    struct MenuItem: Identifiable {
        let id: String
        let title: String
        let action: () -> Void
    }

    let cover: String
    let title: String
    var coverWidth: CGFloat = Theme.posterLargeWidth
    var coverHeight: CGFloat = Theme.posterLargeHeight
    var subtitleLines: [SubtitleLine] = []
    var menuItems: [MenuItem] = []
    /// 封面下载优先级：数值越小越优先，供列表按显示顺序传入索引。
    var priority: Int = .max
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                CoverImageView(urlString: cover, priority: priority)
                    .frame(width: coverWidth, height: coverHeight).clipped().cornerRadius(Theme.cornerCard)
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2).frame(height: 38, alignment: .topLeading)
                ForEach(0..<2, id: \.self) { index in
                    let line = subtitleLines.indices.contains(index) ? subtitleLines[index] : SubtitleLine(text: "")
                    HStack(spacing: 6) {
                        Text(line.text).font(.caption).foregroundStyle(line.accent ? Color.accentColor : Color.secondary).lineLimit(1)
                        if let trailing = line.trailingText {
                            Spacer(minLength: 6)
                            Text(trailing).font(.caption).foregroundStyle(line.trailingAccent ? Color.accentColor : Color.secondary).lineLimit(1)
                        }
                    }
                    .frame(height: Theme.captionLineHeight, alignment: .leading)
                }
            }
            .frame(width: coverWidth, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .contextMenu {
            ForEach(menuItems) { item in
                Button(item.title, action: item.action)
            }
        }
    }
}
