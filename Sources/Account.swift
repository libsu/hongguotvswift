// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security

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
        guard status == errSecSuccess, let data = value as? Data else { throw failure(status) }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = data
            #if os(tvOS)
            // tvOS 无「设备解锁后可用」语义，使用 AfterFirstUnlock。
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            #else
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            let addStatus = SecItemAdd(entry as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw failure(addStatus) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus? = nil) -> Error {
        let code = status.map { "（OSStatus \($0)）" } ?? ""
        return NSError(domain: "HongguoKeychain", code: 1, userInfo: [NSLocalizedDescriptionKey: "登录态钥匙串操作失败\(code)，请检查系统授权。账号仍可在本次会话使用。"] )
    }
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
                guard let data = Data(base64Encoded: qr.image) else { throw URLError(.cannotDecodeContentData) }
                pendingLoginID = qr.loginID
                qrImageData = data; accountMessage = "请用红果 App 扫一扫，扫码后在手机确认登录。"
                let expires = Date().addingTimeInterval(Double(min(300, max(1, qr.expiresIn))))
                while Date() < expires {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    try Task.checkCancellation()
                    let result: AccountResult = try await request("account/poll", ["loginID": qr.loginID])
                    try Task.checkCancellation()
                    if result.loggedIn {
                        acceptAccount(result); qrImageData = nil; pendingLoginID = nil; lastUpload = .distantPast
                        accountMessage = "登录成功，播放进度会定期上传。"
                        if let credentials = result.credentials {
                            do { try SessionKeychain.save(credentials) }
                            catch {
                                Log.shared.warn("保存登录态到钥匙串失败：\(error.localizedDescription)")
                                accountMessage = "已登录，但登录态未能保存到钥匙串（\(error.localizedDescription)）；下次可能需要重新扫码。"
                            }
                        }
                        return
                    }
                }
                qrImageData = nil; accountMessage = "二维码已过期，请重新获取。"
            } catch {
                qrImageData = nil
                if !Task.isCancelled { accountMessage = error.localizedDescription }
            }
        }
    }
    func cancelLogin() {
        let cancelled = pendingLoginID
        pendingLoginID = nil; loginTask?.cancel(); qrImageData = nil
        if let cancelled {
            Task { let _: OperationResult? = try? await request("account/cancel", [:], body: ["loginID": cancelled]) }
        }
    }
    func logout() {
        guard !busy else { return }
        accountGeneration += 1
        cancelLogin(); uploadTask?.cancel()
        cloudTask?.cancel(); cloudRequestID = UUID(); cloudLoading = false; cloudError = nil; cloudLoadedKey = nil
        cloudAllTask?.cancel(); cloudAllLoading = false; cloudAllError = nil
        account = nil; cloudRows = []; accountFavorites = []; accountMessage = "已退出账号，本机记录保留。"
        cloudFavorites = []; cloudHistory = []; cloudOnline = []; cloudUpcoming = []
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
        if section == .account { loadCloud() }
        // 登录成功后预加载四类账号片单，供「我的-账户」页平铺展示。
        loadAllCloud()
    }
    func loadCloud() {
        cloudTask?.cancel()
        let requestID = UUID(); cloudRequestID = requestID
        guard let identity = account?.id else {
            cloudRows = []; cloudLoading = false; cloudError = nil; cloudLoadedKey = nil
            return
        }
        let type = cloudType
        cloudLoading = true; cloudError = nil; cloudLoadedKey = nil; cloudRows = []
        cloudTask = Task {
            defer { if cloudRequestID == requestID { cloudLoading = false } }
            do {
                let result: CloudResult = try await request("account/" + type.path, ["online": String(type.onlineOnly)])
                guard !Task.isCancelled, cloudRequestID == requestID, account?.id == identity, cloudType == type else { return }
                cloudRows = result.items; cloudLoadedKey = identity + ":" + type.rawValue
                if type == .favorites { accountFavorites = Set(result.items.map { $0.series.id }) }
                message = "已读取 \(result.items.count) 条\(type.title)"
            } catch {
                guard !Task.isCancelled, cloudRequestID == requestID, account?.id == identity else { return }
                cloudError = "\(type.title)读取失败：\(error.localizedDescription)"
            }
        }
    }

    /// 登录后一次性加载四类账号片单，供「我的-账户」页平铺展示。
    /// 独立于 loadCloud（单类型），两者可共存；加载失败的分类保持原数组不变。
    func loadAllCloud() {
        guard account?.loggedIn == true else {
            cloudFavorites = []; cloudHistory = []; cloudOnline = []; cloudUpcoming = []
            cloudAllLoading = false; cloudAllError = nil
            return
        }
        cloudAllTask?.cancel()
        let identity = account?.id
        cloudAllLoading = true; cloudAllError = nil
        cloudAllTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.account?.id == identity { self.cloudAllLoading = false } }
            var failures: [String] = []
            do {
                let favs: CloudResult = try await self.request("account/favorites", [:])
                if !Task.isCancelled, self.account?.id == identity { self.cloudFavorites = favs.items } else { return }
            } catch { if !Task.isCancelled { failures.append("账户收藏") } }
            do {
                let hist: CloudResult = try await self.request("account/history", [:])
                if !Task.isCancelled, self.account?.id == identity { self.cloudHistory = hist.items } else { return }
            } catch { if !Task.isCancelled { failures.append("账户历史") } }
            do {
                let online: CloudResult = try await self.request("account/reservations", ["online": "true"])
                if !Task.isCancelled, self.account?.id == identity { self.cloudOnline = online.items } else { return }
            } catch { if !Task.isCancelled { failures.append("已上线预约") } }
            do {
                let upcoming: CloudResult = try await self.request("account/reservations", ["online": "false"])
                if !Task.isCancelled, self.account?.id == identity { self.cloudUpcoming = upcoming.items } else { return }
            } catch { if !Task.isCancelled { failures.append("待上线预约") } }
            self.accountFavorites = Set(self.cloudFavorites.map { $0.series.id })
            self.cloudAllError = failures.isEmpty ? nil : "以下片单读取失败：\(failures.joined(separator: "、"))"
        }
    }
    /// 加入/取消账户收藏。成功返回 true；账号接口失败时不抛错，而是回退到本机收藏并返回 false。
    @discardableResult
    func cloudFavorite(_ series: Series, add: Bool) -> Bool {
        guard let identity = account?.id, account?.loggedIn == true else {
            // 未登录无账户收藏语义，交由本机收藏处理。
            return false
        }
        let target = add
        perform {
            do {
                let _: OperationResult = try await self.request("account/favorite", [:], body: ["id": series.id, "add": target, "accountID": identity])
            } catch {
                // 账号接口不可用（如错误码 101144 / 未登录态失效等）：按目标方向回退到本机收藏，避免「直接收藏失败」。
                guard !Task.isCancelled else { return }
                self.library.setFavorite(series, add: target)
                self.message = target ? "账号收藏暂不可用，已保存到本机收藏。" : "账号收藏暂不可用，已在本机移除收藏。"
                // favoriteActive 已合并账户/本机两套集合，图标仍能正确反映本机状态。
                return
            }
            self.message = target ? "已加入账户收藏" : "已取消账户收藏"
            if target { self.accountFavorites.insert(series.id) } else { self.accountFavorites.remove(series.id) }
            if self.section == .account && self.cloudType == .favorites {
                if let result: CloudResult = try? await self.request("account/favorites", [:]) {
                    self.cloudRows = result.items
                }
            }
        }
        return true
    }

    /// 当前是否已收藏：登录看账户收藏 ∪ 本机收藏，未登录看本机收藏。
    /// 合并视图保证「账号接口不可用回退到本机」后图标仍正确显示为已收藏。
    func favoriteActive(_ series: Series) -> Bool {
        let local = library.favorite(series.id)
        if account?.loggedIn == true { return accountFavorites.contains(series.id) || local }
        return local
    }

    /// 切换收藏：登录走账户收藏，未登录走本机收藏；账户收藏失败自动回退本机。
    func toggleFavorite(_ series: Series) {
        if account?.loggedIn == true {
            let active = favoriteActive(series)
            cloudFavorite(series, add: !active)
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
