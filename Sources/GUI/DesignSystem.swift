// SPDX-License-Identifier: GPL-3.0-only
// 视觉设计系统：集中定义 macOS 前端的颜色、圆角、间距、卡片尺寸与通用可复用组件，
// 消除各视图中散落的魔法数字与重复特例代码
import SwiftUI

// MARK: - 视觉令牌

/// macOS 前端统一视觉令牌：命名按用途而非具体数值，便于将来统一换肤
///
/// 分组约定：色板（`capsuleUnselected` / `dark*`）供组件直接取用；
/// 间距只保留一套（`spacing*` 数值名），页面/卡片等尺寸按**用途**命名。
enum Theme {
    // MARK: 色板
    /// 浅色未选中底（浅色胶囊）
    static let capsuleUnselected = Color.gray.opacity(0.16)
    /// 侧栏选中项底色
    static let railSelected = Color.accentColor.opacity(0.22)

    // MARK: 圆角
    static let cornerSmall: CGFloat = 8
    static let cornerCard: CGFloat = 10
    static let cornerPanel: CGFloat = 12
    static let cornerLarge: CGFloat = 16

    // MARK: 间距（4pt 网格）
    static let spacingXS: CGFloat = 4
    static let spacingSM: CGFloat = 6
    static let spacingMD: CGFloat = 8
    static let spacingLG: CGFloat = 12
    static let spacingXL: CGFloat = 16
    static let spacingXXL: CGFloat = 18
    static let spacingHuge: CGFloat = 24
    static let spacingSection: CGFloat = 32

    // MARK: 页面与区块
    /// 页面外边距（片单页/首页/「我的」/窗口内容区）
    static let pagePadding: CGFloat = 24
    /// 区块之间的留白（片单头部→筛选→网格、「我的」各类片单之间）
    static let sectionGap: CGFloat = 18

    // MARK: 深色覆盖层（播放器）
    /// 深色覆盖层的内边距（状态栏、信息面板、角落按钮共用）
    static let overlayPadding: CGFloat = 20
    /// 深色未选中底（深色胶囊、信息面板集数格共用）
    static let darkUnselected = Color.white.opacity(0.12)
    /// 深色未选中前景
    static let darkUnselectedForeground = Color.white
    /// 深色选中底（信息面板当前集）
    static let darkSelected = Color.white.opacity(0.85)
    /// 深色选中前景
    static let darkSelectedForeground = Color.black.opacity(0.85)
    /// 底部控件栏的渐变影与内边距
    static let playerBarGradient = LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
    static let playerBarHPadding: CGFloat = 20
    static let playerBarVPadding: CGFloat = 14
    /// 播放控件显隐与覆盖层切换的动画
    static let overlayAnimation: Animation = .easeInOut(duration: 0.25)
    /// 底部信息面板（选集/相关作品）的高度区间：内容自适应，但不少于 min、不多于 max
    static let infoPanelMinHeight: CGFloat = 350
    static let infoPanelMaxHeight: CGFloat = 446

    // MARK: 片单布局
    /// 横向海报行的卡片间距
    static let rowCardGap: CGFloat = 12
    /// 片单网格（LazyVGrid）的列间距与行间距
    static let gridColumnSpacing: CGFloat = 20
    static let gridRowSpacing: CGFloat = 24
    /// 片单网格列宽区间：自适应列在 150～230 之间
    static let gridItemMinWidth: CGFloat = 150
    static let gridItemMaxWidth: CGFloat = 230

    // MARK: 胶囊控件
    static let capsuleFont: Font = .subheadline
    static let capsuleFontWeight: Font.Weight = .medium
    static let capsuleHPadding: CGFloat = 12
    static let capsuleVPadding: CGFloat = 5
    static let capsuleContentSpacing: CGFloat = 5
    /// 胶囊组之间的间距（筛选行、播放器选择器共用）
    static let capsuleGap: CGFloat = 6

    // MARK: 卡片文字行高
    /// 卡片徽章/副标题的单行固定高度（占位对齐用，避免有/无该行时卡片高度错位）
    static let captionLineHeight: CGFloat = 15
    /// 卡片标题固定两行高度（小卡 `.caption` / 大卡 15pt semibold）
    static let posterTitleHeight: CGFloat = 30
    static let posterTitleLargeHeight: CGFloat = 38

    // MARK: 卡片封面
    /// 小卡片（我的-收藏/历史、账户四类片单、相关作品）封面尺寸
    static let posterSmallWidth: CGFloat = 110
    static let posterSmallHeight: CGFloat = 150
    static let posterLargeWidth: CGFloat = 158
    static let posterLargeHeight: CGFloat = 225

    // MARK: 侧栏（NavigationSplitView rail）
    static let railHPadding: CGFloat = 12
    static let railVPadding: CGFloat = 8
    static let railIconWidth: CGFloat = 24
    static let railContentSpacing: CGFloat = 10
    static let railMaxWidth: CGFloat = 230

    // MARK: 窗口信息栏
    /// 底部状态栏高度（窗口最小尺寸计算依赖它）
    static let statusBarHeight: CGFloat = 40
}

// MARK: - 视图修饰符

extension View {
    /// 海报封面：固定尺寸 + 裁切 + 卡片圆角（小卡/大卡/相关作品共用）
    func posterCover(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
    }

    /// 播放器深色覆盖层里的系统开关（弹幕、连播）：small 尺寸 + 白色强调色
    /// 样式本身仍由系统 `.switch` 提供，这里只统一尺寸与着色，避免各处写法漂移
    func playerToggle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.darkUnselectedForeground)
    }

    /// 浅色界面（「我的」-设置）里的系统开关：small 尺寸，强调色跟随系统
    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
    }
}

// MARK: - 区块标颢

/// 区块标题的字号层级：页面级（「我的」中的收藏/历史/账户/设置）与子区块（账户四类片单）
/// 集中在此，避免各处手写 `.title2.bold()` / `.title3.bold()` 而逐渐漂移
enum SectionTitleLevel {
    case page
    case subsection

    var font: Font {
        switch self {
        case .page: return .title2.bold()
        case .subsection: return .title3.bold()
        }
    }
}

/// 区块标题：纯标题一行（与 `PosterSection` 共用同一份字号表）
/// 用于「账户」「设置」等后面还要接自定义内容的标题
struct SectionTitle: View {
    let title: String
    var level: SectionTitleLevel = .page

    init(_ title: String, level: SectionTitleLevel = .page) {
        self.title = title
        self.level = level
    }

    var body: some View {
        Text(title).font(level.font)
    }
}

// MARK: - 可复用组件

/// 平铺点选的「选中/未选中」胶囊按钮
/// - Light 主题用于浅色界面（列表筛选、频道选择）：选中用 accent 底 + 白字，未选中用灰底
/// - Dark 主题用于播放器深色覆盖层：选中用白底黑字，未选中用半透明白底白字
/// 附带可选的图标（左侧）与尾部 chevron（下拉选择器风格）
struct SelectableCapsule: View {
    /// 胶囊配色：把「选中/未选中 × 底色/前景」收成一份色板，避免每个使用点各写 4 个条件表达式
    struct Palette {
        let selectedBackground: Color
        let selectedForeground: Color
        let unselectedBackground: Color
        let unselectedForeground: Color

        static let light = Palette(
            selectedBackground: .accentColor,
            selectedForeground: .white,
            unselectedBackground: Theme.capsuleUnselected,
            unselectedForeground: .primary
        )
        static let dark = Palette(
            selectedBackground: Theme.darkSelected,
            selectedForeground: Theme.darkSelectedForeground,
            unselectedBackground: Theme.darkUnselected,
            unselectedForeground: Theme.darkUnselectedForeground
        )
    }

    let label: String
    let isSelected: Bool
    var palette: Palette = .light
    var icon: String? = nil
    var showsChevron: Bool = false
    var horizontalPadding: CGFloat = Theme.capsuleHPadding
    var verticalPadding: CGFloat = Theme.capsuleVPadding
    /// 最小宽度：文案长度会随选项变化的选择器（清晰度/倍速）用它固定按钮宽度，避免切换时整条控件栏跳动
    var minWidth: CGFloat? = nil
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
            .frame(minWidth: minWidth)
            .background(isSelected ? palette.selectedBackground : palette.unselectedBackground, in: Capsule())
            .foregroundStyle(isSelected ? palette.selectedForeground : palette.unselectedForeground)
        }
        .buttonStyle(.plain)
    }
}

/// 胶囊筛选行：可选标题 + 一组「选中/未选中」胶囊
/// 封装了「选项组 + 标题 + 布局 + 选中态」的整套筛选容器，避免各栏目各自手写标题与布局逻辑
struct CapsuleFilterRow: View {
    struct Option: Identifiable {
        let label: String
        let value: String
        var id: String { value }
    }

    /// 布局模式：scrolling = 单行横排（超出可滚动），fixed = 固定单行横排（首页频道切换）
    enum Layout {
        /// 单行：每个胶囊宽度由文本自适应、内部 padding 恒定、胶囊间距由 HStack spacing 恒等；
        /// 超出可滚动，用系统 ScrollView 保证稳定，不借助会崩溃的自定义 Layout
        case scrolling
        case fixed
    }

    let title: String?
    let options: [Option]
    @Binding var selection: String
    var layout: Layout = .scrolling
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            if let title {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            switch layout {
            case .scrolling:
                ScrollView(.horizontal, showsIndicators: false) { capsules }
            case .fixed:
                capsules
            }
        }
    }

    private var capsules: some View {
        HStack(spacing: Theme.capsuleGap) {
            ForEach(options) { option in
                capsule(option)
            }
        }
    }

    private func capsule(_ option: Option) -> some View {
        let selected = selection == option.value
        return SelectableCapsule(label: option.label, isSelected: selected) {
            guard !selected else { return }
            selection = option.value
            onChange()
        }
    }
}

/// 横向海报行（单行滚动）：「我的」收藏/历史、账户四类片单、播放器相关作品共用
/// 统一卡片间距与横向滚动行为，避免各栏目各写一套 ScrollView + LazyHStack
struct PosterRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let card: (Item) -> Card

    init(_ items: [Item], @ViewBuilder card: @escaping (Item) -> Card) {
        self.items = items
        self.card = card
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: Theme.rowCardGap) {
                ForEach(items) { item in card(item) }
            }
        }
    }
}

/// 带区块标题的横向海报行：标题 + 有内容则海报行、空则 `.caption` 次要色提示
/// 「我的」本机收藏/历史与账户四类片单结构相同，统一由它渲染
struct PosterSection<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    var level: SectionTitleLevel = .page
    let emptyHint: String
    let card: (Item) -> Card

    init(_ title: String,
         items: [Item],
         level: SectionTitleLevel = .page,
         emptyHint: String,
         @ViewBuilder card: @escaping (Item) -> Card) {
        self.title = title
        self.items = items
        self.level = level
        self.emptyHint = emptyHint
        self.card = card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingMD) {
            SectionTitle(title, level: level)
            if items.isEmpty {
                Text(emptyHint).font(.caption).foregroundStyle(.secondary)
            } else {
                PosterRow(items, card: card)
            }
        }
    }
}

/// 空态/占位视图：图标 + 标题 + 说明 + 可选操作
/// 用于片单无数据、登录引导、首页未开播、读取失败等场景，避免各处手写字号与间距
struct EmptyStateView<Actions: View>: View {
    /// 大空态占满整个内容区；紧凑态用于行内提示（更小的图标与字号）
    enum Size {
        case regular
        case compact

        fileprivate var spacing: CGFloat { self == .regular ? Theme.spacingXL : Theme.spacingMD }
        fileprivate var iconSize: CGFloat { self == .regular ? 42 : 22 }
        fileprivate var titleFont: Font { self == .regular ? .title2.bold() : .callout }
        fileprivate var detailFont: Font { self == .regular ? .body : .caption }
    }

    let title: String
    let symbol: String
    var detail: String? = nil
    var size: Size = .regular
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: size.spacing) {
            Image(systemName: symbol)
                .font(.system(size: size.iconSize))
                .foregroundStyle(Color.accentColor)
            Text(title).font(size.titleFont)
            if let detail {
                Text(detail)
                    .font(size.detailFont)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions()
        }
        // 大空态占满整个内容区；紧凑态只占自身高度
        .frame(maxWidth: .infinity, maxHeight: size == .regular ? .infinity : nil)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, symbol: String, detail: String? = nil, size: Size = .regular) {
        self.init(title: title, symbol: symbol, detail: detail, size: size) { EmptyView() }
    }
}

/// 行内的加载/错误/空态提示：小号进度圈 + 次要色小字 + 可选重试按钮
/// 统一片单头部、评论区、账户读取的提示样式
struct InlineHint: View {
    let text: String
    var isLoading: Bool = false
    var retry: (() -> Void)? = nil
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: Theme.spacingMD) {
            if isLoading { ProgressView().controlSize(.small) }
            Text(text).font(.caption).foregroundStyle(.secondary)
            if let retry { Button("重试", action: retry).disabled(disabled) }
        }
    }
}

/// 通用海报卡片：封面 + 标题 + 可选副标题，宽高固定（默认小卡尺寸）
/// 封面加载/缓存由 CoverImageView 统一处理；圆角、标题行高遵循 Theme
struct SeriesPosterCard: View {
    let cover: String
    let title: String
    var subtitle: String? = nil
    /// 副标题使用 accent 高亮色（如「账号看到第 N 集」「榜单名次」）还是次要色
    var subtitleAccent: Bool = false
    var width: CGFloat = Theme.posterSmallWidth
    var height: CGFloat = Theme.posterSmallHeight
    /// 封面下载优先级：数值越小越优先，供列表按显示顺序传入索引
    var priority: Int = .max
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                CoverImageView(urlString: cover, priority: priority)
                    .posterCover(width: width, height: height)
                Text(title)
                    .font(.caption).lineLimit(2)
                    .frame(height: Theme.posterTitleHeight, alignment: .topLeading)
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

/// 列表页大卡片：封面 + 标题 + 两行副标题（各带可选尾部文本）+ 可选右键菜单
/// 由调用方组装数据，渲染与视觉样式集中在本组件
struct SeriesCard: View {
    /// 副标题的一行：前半段与可选的尾部（右对齐）
    struct SubtitleLine {
        var text: String
        var accent: Bool = false
        var trailingText: String? = nil
        var trailingAccent: Bool = true

        /// 占位空行：保证没有副标题的卡片与有副标题的卡片等高
        static let blank = SubtitleLine(text: "")
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
    /// 封面下载优先级：数值越小越优先，供列表按显示顺序传入索引
    var priority: Int = .max
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.spacingSM) {
                CoverImageView(urlString: cover, priority: priority)
                    .posterCover(width: coverWidth, height: coverHeight)
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    .frame(height: Theme.posterTitleLargeHeight, alignment: .topLeading)
                // 固定两行：用取行函数代替 ForEach(0..<2)，不足时取空行
                subtitleLine(at: 0)
                subtitleLine(at: 1)
            }
            .frame(width: coverWidth, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .contextMenu {
            ForEach(menuItems) { item in
                Button(item.title, action: item.action)
            }
        }
    }

    private func subtitleLine(at index: Int) -> some View {
        let line = subtitleLines.indices.contains(index) ? subtitleLines[index] : .blank
        return HStack(spacing: Theme.spacingSM) {
            Text(line.text).secondaryOrAccent(line.accent)
            if let trailing = line.trailingText {
                Spacer(minLength: Theme.spacingSM)
                Text(trailing).secondaryOrAccent(line.trailingAccent)
            }
        }
        .frame(height: Theme.captionLineHeight, alignment: .leading)
    }
}

private extension Text {
    /// 卡片副标题的两种着色：强调色或次要色（单行截断）
    func secondaryOrAccent(_ accent: Bool) -> some View {
        font(.caption)
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            .lineLimit(1)
    }
}
