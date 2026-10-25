// SPDX-License-Identifier: GPL-3.0-only
// tvOS 统一设计系统：布局常量（1080p · 百分比 vh）、焦点视觉常量、控件三态模型。
// 所有按钮/卡片/胶囊共用，避免各栏目写各自的色值风格。
import SwiftUI

// MARK: - 布局常量（1080p · 百分比 vh）

/// tvOS 布局规范：单层、默认靠左，各区高度用屏幕高度百分比（vh）计算。
/// 1080p 屏幕 1920×1080 逻辑点（@1x）。
enum TVLayout {
    /// a 导航区（首页/找剧/榜单 + 搜索组件）
    static let navVH: CGFloat = 0.085
    /// b 筛选区（推荐/真人剧/漫剧、换一批/开始刷剧、类型/题材胶囊）
    static let filterVH: CGFloat = 0.065
    /// c 卡片区（单行横向滚动的剧集海报）
    static let cardVH: CGFloat = 0.70
    /// d 信息区（单行状态文本，不换行）
    static let statusVH: CGFloat = 0.045
    /// 区与区之间的垂直留白（vh）
    static let gapVH: CGFloat = 0.02

    static func h(_ vh: CGFloat, of height: CGFloat) -> CGFloat { max(0, height * vh) }
}

// MARK: - 统一 tvOS 焦点视觉（默认 / 聚焦 / 选中三态）

/// tvOS 深色主题下的统一视觉常量。所有按钮/卡片共用，避免各写各的色值风格。
enum TVFX {
    /// 默认态：低调半透明底 + 灰字。
    static let normalFill = Color.white.opacity(0.08)
    static let normalFg = Color.secondary
    /// 聚焦态：提亮底 + 白字 + 轻微放大 + 强调色描边。
    static let focusedFill = Color.white.opacity(0.20)
    static let focusedFg = Color.white
    /// 选中态：近白底 + 深色字（高对比，明确“当前项”）。
    static let selectedFill = Color.white.opacity(0.88)
    static let selectedFg = Color.black.opacity(0.85)

    static let focusScale: CGFloat = 1.05
    static let focusStrokeWidth: CGFloat = 2
    /// 聚焦态轻微阴影（tvOS 原生 focus 的「抬离」感）。
    static let focusShadowColor = Color.black.opacity(0.5)
    static let focusShadowRadius: CGFloat = 12
}

/// 控件三态（聚焦态优先于选中态展示放大/描边，选中态决定「底色语义」）。
enum TVControlState {
    case normal, focused, selected

    /// 由「是否选中」「是否聚焦」合成。
    init(selected: Bool, focused: Bool) {
        if focused { self = .focused }
        else if selected { self = .selected }
        else { self = .normal }
    }

    var fill: Color {
        switch self {
        case .normal: return TVFX.normalFill
        case .focused: return TVFX.focusedFill
        case .selected: return TVFX.selectedFill
        }
    }

    var fg: Color {
        switch self {
        case .normal: return TVFX.normalFg
        case .focused: return TVFX.focusedFg
        case .selected: return TVFX.selectedFg
        }
    }

    var scale: CGFloat {
        (self == .focused) ? TVFX.focusScale : 1.0
    }

    var stroke: Color {
        (self == .focused) ? Color.accentColor : Color.clear
    }

    /// 聚焦态的阴影半径（非聚焦为 0）与偏移。
    var shadowRadius: CGFloat {
        (self == .focused) ? TVFX.focusShadowRadius : 0
    }
}

/// 供按钮/胶囊复用的统一焦点视觉修饰符：
/// 由 selected/focused 合成三态，统一背景、描边、前景、放大与阴影。
struct TVControlStyle: ViewModifier {
    let selected: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        let state = TVControlState(selected: selected, focused: focused)
        return content
            .background(state.fill, in: Capsule())
            .overlay(Capsule().strokeBorder(state.stroke, lineWidth: TVFX.focusStrokeWidth))
            .foregroundStyle(state.fg)
            .scaleEffect(state.scale)
            .shadow(color: TVFX.focusShadowColor, radius: state.shadowRadius)
    }
}
