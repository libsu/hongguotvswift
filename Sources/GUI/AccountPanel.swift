// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AppKit

struct AccountPanel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = model.account, account.loggedIn {
                HStack {
                    Text(account.nickname ?? "红果用户").font(.headline)
                    Spacer()
                    Button("退出") { model.logout() }.disabled(model.busy)
                }
            } else {
                if let data = model.qrImageData, let image = NSImage(data: data) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220).padding(10).background(.white)
                    Button("取消扫码") { model.cancelLogin() }
                } else {
                    Button("红果扫码登录") { model.beginLogin() }.disabled(model.busy || model.accountBusy)
                }
            }
            Text(model.accountMessage).font(.caption).foregroundStyle(.secondary)
        }
    }
}
