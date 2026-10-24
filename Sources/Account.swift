// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import SwiftUI

struct AccountResult: Decodable {
    let loggedIn: Bool
    let id: String?
    let nickname: String?
    let credentials: String?
}
struct QRResult: Decodable { let image: String; let expiresIn: Int; let loginID: String }
struct OperationResult: Decodable { let ok: Bool; let confirmed: Bool? }
struct CloudEntry: Decodable, Identifiable {
    var id: String { series.id }
    let series: Series
    let episodeID: String?
    let episodeIndex: Int?
    let position: Double?
    let duration: Double?
    let online: Bool?
    let publishText: String?
}
struct CloudResult: Decodable { let items: [CloudEntry] }

enum SessionKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.hongguotvswift.app", kSecAttrAccount as String: "hongguo-session"] }
    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw failure() }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }
    private static func failure() -> Error { NSError(domain: "HongguoKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "登录态钥匙串操作失败，请检查系统授权。账号仍可在本次会话使用。"] ) }
}

extension Model {
    func restoreAccount() async {
        let generation = accountGeneration
        do {
            if let saved = try SessionKeychain.load() {
                let result: AccountResult = try await request("account/restore", [:], body: ["credentials": saved])
                guard generation == accountGeneration && account == nil && !accountBusy else { return }
                acceptAccount(result)
            }
        } catch { accountMessage = "上次账号暂时无法验证，可重新扫码或稍后重开应用。" }
    }
    func beginLogin() {
        guard !busy && !accountBusy else { return }
        accountGeneration += 1
        loginTask?.cancel(); accountBusy = true
        loginTask = Task {
            defer { accountBusy = false }
            do {
                let qr: QRResult = try await request("account/qr", [:], body: [:])
                guard let data = Data(base64Encoded: qr.image), let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                pendingLoginID = qr.loginID
                qrImage = image; accountMessage = "请用红果 App 扫一扫，扫码后在手机确认登录。"
                let expires = Date().addingTimeInterval(Double(min(300, max(1, qr.expiresIn))))
                while Date() < expires {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    let result: AccountResult = try await request("account/poll", ["loginID": qr.loginID])
                    try Task.checkCancellation()
                    if result.loggedIn {
                        acceptAccount(result); qrImage = nil; pendingLoginID = nil; lastUpload = .distantPast
                        accountMessage = "登录成功，播放进度会定期上传。"
                        if let credentials = result.credentials {
                            do { try SessionKeychain.save(credentials) }
                            catch { accountMessage = "已登录，但登录态未能保存到钥匙串；下次可能需要重新扫码。" }
                        }
                        return
                    }
                }
                qrImage = nil; accountMessage = "二维码已过期，请重新获取。"
            } catch {
                qrImage = nil
                if !Task.isCancelled { accountMessage = error.localizedDescription }
            }
        }
    }
    func cancelLogin() {
        let cancelled = pendingLoginID
        pendingLoginID = nil; loginTask?.cancel(); qrImage = nil
        if let cancelled {
            Task { let _: OperationResult? = try? await request("account/cancel", [:], body: ["loginID": cancelled]) }
        }
    }
    func logout() {
        guard !busy else { return }
        accountGeneration += 1
        cancelLogin(); uploadTask?.cancel()
        cloudTask?.cancel(); cloudRequestID = UUID(); cloudLoading = false; cloudError = nil; cloudLoadedKey = nil
        account = nil; cloudRows = []; accountFavorites = []; accountMessage = "已退出账号，本机记录保留。"
        accountBusy = true
        Task {
            _ = await loginTask?.result
            defer { accountBusy = false }
            let _: OperationResult? = try? await request("account/logout", [:], body: [:])
            do { try SessionKeychain.delete() } catch { accountMessage = error.localizedDescription }
        }
    }
    func acceptAccount(_ result: AccountResult) {
        account = result
        cloudRows = []; cloudError = nil; cloudLoadedKey = nil
        accountFavorites = []
        if section == "账户" { loadCloud() }
    }
    func loadCloud() {
        cloudTask?.cancel()
        let requestID = UUID(); cloudRequestID = requestID
        guard let identity = account?.id else {
            cloudRows = []; cloudLoading = false; cloudError = nil; cloudLoadedKey = nil
            return
        }
        let type = cloudType
        let path = type == "账户历史" ? "history" : type == "账户收藏" ? "favorites" : "reservations"
        cloudLoading = true; cloudError = nil; cloudLoadedKey = nil; cloudRows = []
        cloudTask = Task {
            defer { if cloudRequestID == requestID { cloudLoading = false } }
            do {
                let result: CloudResult = try await request("account/" + path, ["online": String(type != "待上线")])
                guard !Task.isCancelled, cloudRequestID == requestID, account?.id == identity, cloudType == type else { return }
                cloudRows = result.items; cloudLoadedKey = identity + ":" + type
                if type == "账户收藏" { accountFavorites = Set(result.items.map { $0.series.id }) }
                message = "已读取 \(result.items.count) 条\(type)"
            } catch {
                guard !Task.isCancelled, cloudRequestID == requestID, account?.id == identity else { return }
                cloudError = "\(type)读取失败：\(error.localizedDescription)"
            }
        }
    }
    func cloudFavorite(_ series: Series, add: Bool) {
        guard let identity = account?.id else { accountMessage = "请先扫码登录"; return }
        perform {
            let _: OperationResult = try await self.request("account/favorite", [:], body: ["id": series.id, "add": add, "accountID": identity])
            self.message = add ? "已加入账户收藏" : "已取消账户收藏"
            if add { self.accountFavorites.insert(series.id) } else { self.accountFavorites.remove(series.id) }
            if self.section == "账户" && self.cloudType == "账户收藏" {
                let result: CloudResult = try await self.request("account/favorites", [:])
                self.cloudRows = result.items
            }
        }
    }

    /// 当前是否已收藏：登录看账户收藏，未登录看本机收藏。
    func favoriteActive(_ series: Series) -> Bool {
        if account?.loggedIn == true { return accountFavorites.contains(series.id) }
        return library.favorite(series.id)
    }

    /// 切换收藏：登录走账户收藏，未登录走本机收藏。
    func toggleFavorite(_ series: Series) {
        if account?.loggedIn == true {
            cloudFavorite(series, add: !accountFavorites.contains(series.id))
        } else {
            library.toggleFavorite(series)
        }
    }
    func reserve(_ work: RelatedEntry) {
        guard work.upcoming, let identity = account?.id else { message = "请先登录红果账号后预约"; return }
        perform {
            let result: OperationResult = try await self.request("account/reserve", [:], body: ["id": work.id, "accountID": identity])
            self.message = result.confirmed == true ? "预约已确认" : "预约请求已提交，请在手机端核对"
        }
    }
    func uploadProgress(_ record: WatchRecord, count: Int) {
        guard !stopping, let identity = account?.id, uploadTask == nil, Date().timeIntervalSince(lastUpload) >= 30, record.position > 0 else { return }
        lastUpload = Date()
        uploadTask = Task {
            defer { uploadTask = nil }
            do {
                let series = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.series))
                let _: OperationResult = try await request("account/upload", [:], body: ["series": series, "episodeID": record.episodeID, "episodeIndex": record.episodeIndex, "position": Int64(record.position * 1000), "duration": Int64(record.duration * 1000), "episodeCount": count, "accountID": identity])
                if account?.id == identity { accountMessage = "播放进度已上传" }
            } catch { if account?.id == identity { accountMessage = "云端进度上传失败，本机记录已保留。" } }
        }
    }
}

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
                if let image = model.qrImage {
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
