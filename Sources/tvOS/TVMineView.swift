// SPDX-License-Identifier: GPL-3.0-only
// 「我的」栏目：收藏/历史/预约切换 + 扫码登录浮层 + 登录/登出控制
// tvOS 简化：已登录用账户数据，未登录用本地片单
import SwiftUI
import UIKit

/// 「我的」栏目：筛选区三个胶囊【收藏 / 历史 / 预约】切换下方卡片区，兼登录入口
struct TVMineView: View {
    @ObservedObject var model: Model
    let canvasHeight: CGFloat
    @FocusState private var focus: String?
    /// 扫码登录浮层内「取消登录」按钮的焦点：浮层显示时独占，避免焦点穿透到背景
    @FocusState private var cancelFocused: Bool
    @State private var category = "收藏"

    private var items: [Series] {
        switch category {
        case "历史": return model.mineHistory
        case "预约": return model.mineReservations
        default: return model.mineFavorites
        }
    }

    var body: some View {
        TVSectionContainer(canvasHeight: canvasHeight) {
            // b 筛选区：收藏/历史/预约 三胶囊 + （未登录时）扫码登录入口
            HStack(spacing: 16) {
                TVCapsuleButton(title: "收藏", value: "收藏", current: category, focusKey: "mine:fav", focus: $focus) {
                    category = "收藏"
                }
                TVCapsuleButton(title: "历史", value: "历史", current: category, focusKey: "mine:hist", focus: $focus) {
                    category = "历史"
                }
                TVCapsuleButton(title: "预约", value: "预约", current: category, focusKey: "mine:resv", focus: $focus) {
                    category = "预约"
                }
                accountControl
                Spacer()
            }
        } card: {
            // c 卡片区
            if items.isEmpty {
                TVEmptyView(title: emptyTitle, symbol: emptySymbol)
            } else {
                TVPosterGrid(
                    items: items,
                    section: .mine,
                    model: model,
                    focusedSeries: $focus,
                    hasMore: false,
                    loadMore: {},
                    onSelect: { model.open($0) },
                    cardHeight: TVLayout.h(TVLayout.cardVH, of: canvasHeight)
                )
            }
        } status: {
            model.account?.loggedIn == true ? model.accountMessage : "未登录，展示本机片单；登录后同步账号数据"
        }
        .overlay {
            if let qrData = model.qrImageData, let image = UIImage(data: qrData) {
                qrOverlay(image: image)
            }
        }
        // 浮层显隐时重排焦点：显示时独占给「取消登录」，隐藏时交还背景
        .onChange(of: model.qrImageData != nil) { _, showing in
            if showing {
                focus = nil
                cancelFocused = true
            }
        }
    }

    private var emptyTitle: String {
        switch category {
        case "历史": return "暂无观看记录"
        case "预约": return "暂无已上线预约"
        default: return "暂无收藏"
        }
    }

    private var emptySymbol: String {
        switch category {
        case "历史": return "clock.arrow.circlepath"
        case "预约": return "clock"
        default: return "star"
        }
    }

    /// 扫码登录：全屏不透明黑底 + 居中二维码 + 取消登录退出
    /// 「取消登录」按钮独占焦点（浮层显示时自动聚焦），避免焦点穿透到遮挡住的背景
    /// 注意：登录轮询期间 `accountBusy` 恒为 true，但「取消登录」始终可用，供用户随时打断
    private func qrOverlay(image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("扫码登录").font(.title2.bold()).foregroundStyle(.white)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 480, height: 480)
                Text(model.accountMessage)
                    .font(.body).foregroundStyle(.secondary)
                Button {
                    model.cancelLogin()
                } label: {
                    Label("取消登录", systemImage: "xmark")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .focused($cancelFocused)
            }
            .padding(48)
        }
        // 二维码显示期间，Menu/返回统一取消扫码
        .onExitCommand { model.cancelLogin() }
    }

    /// 登录/登出控制（未登录显示扫码登录，已登录显示昵称 + 登出）
    @ViewBuilder
    private var accountControl: some View {
        if model.account?.loggedIn == true {
            HStack(spacing: 16) {
                Text(model.account?.nickname ?? "红果用户").font(.body.weight(.semibold)).foregroundStyle(.white)
                logoutButton
            }
        } else {
            loginButton
        }
    }

    /// 扫码登录按钮：与「登出」按钮使用同一 TVCapsuleButton 渲染（自定义三态，含 qrcode 图标）
    private var loginButton: some View {
        TVCapsuleButton(
            title: "扫码登录",
            icon: "qrcode",
            selected: false,
            enabled: !model.accountBusy,
            focusKey: "mine:login",
            focus: $focus
        ) {
            model.beginLogin()
        }
    }

    /// 登出按钮：与首页「开始刷剧」按钮同等的自定义三态视觉，复用 TVCapsuleButton
    private var logoutButton: some View {
        TVCapsuleButton(
            title: "登出",
            selected: false,
            enabled: !model.accountBusy,
            focusKey: "mine:logout",
            focus: $focus
        ) {
            model.logout()
        }
    }
}
