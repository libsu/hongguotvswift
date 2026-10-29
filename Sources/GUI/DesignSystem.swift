// SPDX-License-Identifier: GPL-3.0-only
// 视觉设计系统：macOS 前端的颜色/圆角/间距/尺寸令牌与通用组件，消除魔法数字与重复视图
import SwiftUI

// MARK: - 视觉令牌

/// macOS 前端视觉令牌：按用途命名而非数值，便于统一换肤。
enum Theme {
    // MARK: 色板
    static let capsuleUnselected = Color.gray.opacity(0.16)
    static let railSelected = Color.accentColor.opacity(0.22)

    // MARK: 圆角
    static let cornerSmall: CGFloat = 8
    static let cornerCard: CGFloat = 10
    // static let cornerPanel: CGFloat = 12
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
    /// 页面外边距
    static let pagePadding: CGFloat = 24
    /// 区块之间的留白
    static let sectionGap: CGFloat = 18

    // MARK: 深色覆盖层（播放器）
    /// 叠层内边距（状态栏、信息面板、角落按钮共用）
    static let overlayPadding: CGFloat = 20
    static let darkUnselected = Color.white.opacity(0.12)
    static let darkUnselectedForeground = Color.white
    static let darkSelected = Color.white.opacity(0.85)
    static let darkSelectedForeground = Color.black.opacity(0.85)
    /// 底部控件栏的渐变影与内边距
    static let playerBarGradient = LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
    static let playerBarHPadding: CGFloat = 20
    static let playerBarVPadding: CGFloat = 14
    static let overlayAnimation: Animation = .easeInOut(duration: 0.25)
    /// 底部控件栏占位高度：信息面板上限需扣掉它，避免遮住控件栏
    static let playerBarHeight: CGFloat = 60
    /// 信息面板内容距播放区底边的总距离（含面板自身内边距）
    static let infoPanelBottomInset: CGFloat = 50
    /// 信息面板距播放区左右边缘的外边距（不含面板自身内边距）
    static let infoPanelSideInset: CGFloat = 55

    // MARK: 弹幕
    /// 顶部偏移与行高：首行起始位置 + 每轨之间的间距（窄窗口下多轨道可能压到画面中线，调这里）
    static let danmakuTopOffset: CGFloat = 62
    static let danmakuLaneHeight: CGFloat = 36
    /// 字号与描边偏移：实心描边在亮画面上比模糊更清晰
    static let danmakuFontSize: CGFloat = 22
    static let danmakuOutlineOffset: CGFloat = 1.25

    // MARK: 片单布局
    static let rowCardGap: CGFloat = 12
    static let gridColumnSpacing: CGFloat = 20
    static let gridRowSpacing: CGFloat = 24
    /// 自适应列宽区间
    static let gridItemMinWidth: CGFloat = 150
    static let gridItemMaxWidth: CGFloat = 230

    // MARK: 胶囊控件
    static let capsuleFont: Font = .subheadline
    static let capsuleFontWeight: Font.Weight = .medium
    static let capsuleHPadding: CGFloat = 12
    static let capsuleVPadding: CGFloat = 5
    static let capsuleContentSpacing: CGFloat = 5
    /// 胶囊组之间的间距
    static let capsuleGap: CGFloat = 6

    // MARK: 卡片文字行高
    /// 副标题单行固定高度：占位对齐，避免有/无该行时卡片高度错位
    static let captionLineHeight: CGFloat = 15
    /// 标题固定两行高度（小卡 `.caption` / 大卡 15pt semibold）
    static let posterTitleHeight: CGFloat = 30
    static let posterTitleLargeHeight: CGFloat = 38

    // MARK: 卡片封面
    /// 小卡（我的/相关作品）与列表大卡的封面尺寸
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
    static let statusBarHeight: CGFloat = 35
}

// MARK: - 视图修饰符

extension View {
    /// 海报封面：固定尺寸 + 裁切 + 卡片圆角。
    func posterCover(width: CGFloat, height: CGFloat) -> some View {
        frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerCard, style: .continuous))
    }

    /// 播放器深色覆盖层里的系统开关（弹幕、连播）：small + 白色强调色。
    func playerToggle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.darkUnselectedForeground)
    }

    /// 浅色界面（「我的」-设置）里的系统开关：small 尺寸，强调色跟随系统。
    func settingsToggle() -> some View {
        toggleStyle(.switch)
            .controlSize(.small)
    }

    /// 设置项单行：占满宽度，文字左、开关右，开关右缘一致对齐（避免文字长度不同导致开关错位）。
    func settingsRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 浅色设置项：手动拆开「文字」与「开关」，文字左、开关右（右缘对齐），
/// 避免直接用 `Toggle` 导致 label 与 switch 之间出现大片空白。
struct SettingsRow: View {
    let label: String
    @Binding var isOn: Bool
    var help: String? = nil

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(help ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 区块标颢

/// 区块标题字号层级：集中定义，避免各处手写 `.title2.bold()` 而逐渐漂移。
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

/// 区块标题一行，用于后面还要接自定义内容的标题（账户/设置）。
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

/// 平铺点选的「选中/未选中」胶囊按钮，带可选左图标与尾部 chevron。
struct SelectableCapsule: View {
    /// 把「选中/未选中 × 底色/前景」收成一份色板，避免每个使用点各写 4 个条件表达式。
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
    /// 最小宽度：文案长度随选项变化的选择器（清晰度/倍速）用它固定宽度，避免切换时控件栏跳动。
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

/// 胶囊筛选行：可选标题 + 一组胶囊，统一「选项组 + 标题 + 布局 + 选中态」。
struct CapsuleFilterRow: View {
    struct Option: Identifiable {
        let label: String
        let value: String
        var id: String { value }
    }

    /// 布局模式：scrolling = 单行可横向滚动，fixed = 固定单行。
    enum Layout {
        /// 用系统 ScrollView 而非自定义 Layout（后者在内容变化时会崩溃）。
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

/// 横向海报行（单行滚动）：统一卡片间距与横向滚动行为。
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

/// 带区块标题的横向海报行：有内容则展示行，空则显示次要色提示。
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

/// 空态/占位视图：图标 + 标题 + 说明 + 可选操作，用于无数据/登录引导/读取失败。
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
        // 大空态占满内容区，紧凑态只占自身高度。
        .frame(maxWidth: .infinity, maxHeight: size == .regular ? .infinity : nil)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, symbol: String, detail: String? = nil, size: Size = .regular) {
        self.init(title: title, symbol: symbol, detail: detail, size: size) { EmptyView() }
    }
}

/// 行内加载/错误/空态提示：小进度圈 + 次要色小字 + 可选重试。
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

/// 通用小海报卡：封面 + 标题 + 可选副标题，尺寸固定。
struct SeriesPosterCard: View {
    let cover: String
    let title: String
    var subtitle: String? = nil
    /// 副标题用 accent 高亮色（账号看到第 N 集、榜单名次）还是次要色。
    var subtitleAccent: Bool = false
    var width: CGFloat = Theme.posterSmallWidth
    var height: CGFloat = Theme.posterSmallHeight
    /// 封面下载优先级：越小越优先，由列表按显示顺序传入索引。
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

/// 列表页大卡片：封面 + 标题 + 两行副标题（各带可选尾部）+ 可选右键菜单。
struct SeriesCard: View {
    /// 副标题的一行：前半段与可选的尾部（右对齐）
    struct SubtitleLine {
        var text: String
        var accent: Bool = false
        var trailingText: String? = nil
        var trailingAccent: Bool = true

        /// 占位空行：保证有无副标题的卡片等高。
        static let blank = SubtitleLine(text: "")
    }

    struct MenuItem: Identifiable {
        let id: String
        let title: String
        let action: () -> Void
    }

    /// 卡片装配结果：副标题 / 右键菜单 / 点击动作。
    struct ViewModel {
        var subtitleLines: [SubtitleLine]
        var menuItems: [MenuItem]
        var onTap: () -> Void
    }

    let cover: String
    let title: String
    var coverWidth: CGFloat = Theme.posterLargeWidth
    var coverHeight: CGFloat = Theme.posterLargeHeight
    var subtitleLines: [SubtitleLine] = []
    var menuItems: [MenuItem] = []
    /// 封面下载优先级：越小越优先，由列表按显示顺序传入索引。
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
                // 固定两行：不足时用空行补齐。
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

/// `SeriesCard` 的默认装配规则：纯静态函数，不依赖 `Model`，可脱离 View 单测。
/// 输入 `Series` + 跨域上下文，输出 `ViewModel`（副标题 / 菜单 / 点击动作）。
/// 其它列表页（HomeViews / tvOS）应复用这里，避免各写一套副标题/菜单。
@MainActor
enum SeriesCardBuilder {
    struct Context {
        var section: Section
        var cloudType: CloudType?
        var rankPosition: RankBadge?
        var cloudEntry: CloudEntry?
        var accountLoggedIn: Bool
        var isLocalFavorite: Bool
        var historyRecord: WatchRecord?
    }

    /// 纯函数：组装副标题。
    static func subtitleLines(for series: Series, context: Context) -> [SeriesCard.SubtitleLine] {
        let progressText = context.cloudEntry?.episodeIndex.map { "账号看到第 \($0 + 1) 集" }
            ?? context.historyRecord?.label

        var first = SeriesCard.SubtitleLine(text: series.badge.isEmpty ? "" : series.badge)
        first.trailingText = progressText
        first.trailingAccent = false

        var lines = [first]
        if context.section == .rank, let rank = context.rankPosition {
            let text = [rank.rank.map { "第 \($0) 名" } ?? "", rank.heat].filter { !$0.isEmpty }.joined(separator: " · ")
            lines.append(.init(text: text, accent: true))
        } else if let publish = context.cloudEntry?.publishText {
            lines.append(.init(text: publish))
        }
        return lines
    }

    /// 纯函数：组装右键菜单项（按展示顺序）。
    static func menuItems(for context: Context, actions: Actions) -> [SeriesCard.MenuItem] {
        var menu: [SeriesCard.MenuItem] = [
            .init(id: "fav", title: context.isLocalFavorite ? "取消本机收藏" : "加入本机收藏") {
                actions.toggleLocalFavorite()
            }
        ]
        if context.accountLoggedIn {
            menu.append(.init(id: "cloud-fav", title: "加入账户收藏") {
                actions.addCloudFavorite()
            })
            if context.section == .account && context.cloudType == .favorites {
                menu.append(.init(id: "cloud-unfav", title: "取消账户收藏") {
                    actions.removeCloudFavorite()
                })
            }
        }
        if context.section == .history {
            menu.append(.init(id: "remove-history", title: "删除本机观看记录") {
                actions.removeLocalHistory()
            })
        }
        return menu
    }

    struct Actions {
        var toggleLocalFavorite: () -> Void
        var addCloudFavorite: () -> Void
        var removeCloudFavorite: () -> Void
        var removeLocalHistory: () -> Void
    }
}

private extension Text {
    /// 单行截断的 accent / 次要色着色。
    func secondaryOrAccent(_ accent: Bool) -> some View {
        font(.caption)
            .foregroundStyle(accent ? Color.accentColor : Color.secondary)
            .lineLimit(1)
    }
}
