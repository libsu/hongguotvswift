// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine
import AVFoundation

@MainActor final class Model: ObservableObject {
    @Published var query = ""
    @Published var rows: [Series] = []
    @Published var detail: Detail?
    @Published var busy = true
    @Published var message = "正在启动…"
    @Published var episode: Int?
    @Published var hasMore = false
    let player = AVPlayer()
    @Published var showComments = false
    @Published var playerControlsVisible = true
    @Published var infoPanelOpen = false
    @Published var pipActive = false
    lazy var comments = MacComments { [weak self] series, episode in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("comments", ["series": series, "episode": episode])
    }
    lazy var commentThread = MacCommentThread { [weak self] series, episode, cursor in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("comment-page", ["series": series, "episode": episode, "cursor": cursor])
    }
    lazy var danmaku = MacDanmaku { [weak self] series, episode, start, duration in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("danmaku", ["series": series, "episode": episode, "start": String(start), "duration": String(duration)])
    }
    let library: LocalLibrary
    let catalogCache = CatalogCache()
    @Published var section = "搜索"
    @Published var navigation = "搜索"
    /// 上一次栏目，用于跨栏目切换时判断是否打断进行中的请求。
    var _previousSection = ""
    @Published var showDetail = false
    @Published var catalogRows: [Series] = []
    @Published var rankPositions: [String: MacRank] = [:]
    @Published var category = "COMIC"
    @Published var topic = ""
    @Published var topics: [Topic] = []
    @Published var board = "COMIC"
    @Published var catalogMore = false
    @Published var related: [RelatedEntry] = []
    @Published var relatedMessage = ""
    @Published var account: AccountResult?
    @Published var accountMessage = "登录后可查看账号片单和同步进度"
    @Published var accountBusy = false
    @Published var qrImageData: Data?
    @Published var cloudType = "账户历史"
    @Published var cloudRows: [CloudEntry] = []
    /// 已登录账户的收藏剧集 id 集合，用于收藏按钮的「已收藏」态判断。
    @Published var accountFavorites: Set<String> = []
    @Published var cloudLoading = false
    @Published var cloudError: String?
    @Published var cloudLoadedKey: String?
    var cloudTask: Task<Void, Never>?
    var cloudRequestID = UUID()
    var accountGeneration = 0
    var pendingLoginID: String?
    var loginTask: Task<Void, Never>?
    var uploadTask: Task<Void, Never>?
    var lastUpload = Date.distantPast
    var catalogPage = 1
    var catalogKind = ""
    var relatedTask: Task<Void, Never>?
    @Published var speed: Float = UserDefaults.standard.object(forKey: "playbackSpeed") as? Float ?? 1
    @Published var quality: Int = UserDefaults.standard.object(forKey: "playbackQuality") as? Int ?? 0
    @Published var autoNext = UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true
    @Published var actualQuality = ""
    private var activeSeries: Series?
    private var activeEpisodeID: String?
    private var activeEpisodeIndex: Int?
    private var progressObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var pendingNext = false
    private var warmNextTask: Task<Void, Never>?
    /// 已触发「靠近结尾预取」的集（episodeID），避免同一集重复预取。
    private var warmedNearEndKey: String?
    var stopping = false
    @Published var preview = false
    private var activeTrial = false
    private var pendingTrial = false
    private var pendingResume = false
    var pendingHomeSeries: Series?
    var homeWarmTask: Task<Void, Never>?
    var homeWarmDetail: Detail?
    var homeWarmQuality: Int?
    var homeGeneration = UUID()
    @Published var homeCategory = "ALL"
    /// 用户主动点「开始刷剧」后，加载完成即试播第一部；进入首页默认不自动试播。
    var autoTrialAfterLoad = false
    private var cloudResume: (Int, Double)?
    private var base: URL?
    private var page = 1
    private var searched = ""
    var action: Task<Void, Never>?
    /// perform 请求代次：跨栏目打断请求后，旧任务的 defer 依靠它避免误复位 busy/误处理 pending。
    private var performGeneration = UUID()
    private var playerObservation: NSKeyValueObservation?
    private let requestSession: URLSession
    /// 只读协议层的原生 Swift 实现（阶段 2）。为 nil 时全部走 HTTP 桥。
    let backend: HongguoBackend?
    /// 平台集成接口（键盘监听 / 全屏 / 画中画 / JVM 桥接等）。由 GUI 层注入；纯逻辑/测试场景为 nil。
    weak var platformInterface: (any ModelPlatformInterface)?
    /// 当前播放会话的资源加载委托（阶段 3），保持强引用避免被提前释放。
    private var activeLoader: ResourceLoader?
    /// 切集预热缓存（阶段 3），按 episodeID+quality 键存已解析的加密索引。
    private let preparedCache = PreparedCache()

    init(resourcesURL: URL? = Bundle.main.resourceURL, library: LocalLibrary? = nil, restoreSession: Bool = true, bridgeURL: URL? = nil, session: URLSession = .shared) {
        self.base = bridgeURL; self.requestSession = session
        // 仅当无桥接 URL（正式原生运行）时启用原生协议层；测试仍走注入的桥。
        self.backend = bridgeURL == nil ? HongguoBackend(session: session) : nil
        self.library = library ?? LocalLibrary()
        playerObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor [weak self] in self?.message = "此视频暂时无法播放，请尝试其他集数或剧集。" }
        }
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveProgress()
                self?.warmNextIfNearEnd()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.saveProgress(completed: true)
                if !self.activeTrial && self.autoNext, let index = self.episode, let detail = self.detail, index + 1 < detail.episodes.count {
                    self.playNextEpisode()
                } else { self.message = "本集播放结束" }
            }
        }
        Task { await start(resources: resourcesURL, restoreSession: restoreSession) }
    }
    private func start(resources: URL?, restoreSession: Bool) async {
        defer { busy = false }
        if base != nil { return }
        // 原生模式（无桥接 URL）：后端已是纯 Swift 实现，不再启动 JVM Helper。
        if backend != nil {
            Log.shared.info("启动：Swift 原生模式（无 JVM Helper）")
            message = "输入剧名，开始找剧"
            if restoreSession { Task { await restoreAccount() } }
            return
        }
        // 无原生后端、无桥接 URL、无资源：无法启动（理论不可达，防御性处理）。
        message = "客户端启动失败，请重新打开应用。"
    }
    func request<T: Decodable>(_ path: String, _ parameters: [String: String], body: [String: Any]? = nil) async throws -> T {
        let started = Date()
        let source: String
        do {
            let result: T
            if let backend, backend.supportedOperations.contains(path) {
                source = "native"
                result = try await self.requestNative(path, parameters, backend: backend)
            } else if let backend, path.hasPrefix("account/") {
                source = "account"
                result = try await self.requestAccount(path, parameters, body: body, backend: backend)
            } else {
                source = "bridge"
                result = try await self.requestBridge(path, parameters, body: body)
            }
            Log.shared.debug("request \(path) [\(source)] ok \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return result
        } catch {
            Log.shared.warn("request \(path) [\(source)] failed \(Int(Date().timeIntervalSince(started) * 1000))ms: \(error.localizedDescription)")
            throw error
        }
    }

    /// 原生协议层调度：返回 JSON 结构后，复用同一套 Decodable 解码。
    private func requestNative<T: Decodable>(_ path: String, _ parameters: [String: String], backend: HongguoBackend) async throws -> T {
        let result: [String: Any]
        switch path {
        case "search":
            result = try await backend.search(q: parameters["q"] ?? "", page: Int(parameters["page"] ?? "1") ?? 1)
        case "feed":
            result = try await backend.feed(category: parameters["category"] ?? "ALL", page: Int(parameters["page"] ?? "1") ?? 1, refresh: parameters["refresh"] == "true")
        case "catalog":
            result = try await backend.catalog(category: parameters["category"] ?? "COMIC", topic: parameters["topic"] ?? "", board: parameters["board"] ?? "COMIC", page: Int(parameters["page"] ?? "1") ?? 1, refresh: parameters["refresh"] == "true")
        case "rank":
            result = try await backend.rank(category: parameters["category"] ?? "COMIC", topic: parameters["topic"] ?? "", board: parameters["board"] ?? "COMIC", page: Int(parameters["page"] ?? "1") ?? 1, refresh: parameters["refresh"] == "true")
        case "related":
            result = try await backend.related(id: parameters["id"] ?? "")
        case "detail":
            result = try await backend.detail(id: parameters["id"] ?? "")
        case "comments":
            result = try await backend.comments(series: parameters["series"] ?? "", episode: parameters["episode"] ?? "")
        case "comment-page":
            result = try await backend.commentPage(series: parameters["series"] ?? "", episode: parameters["episode"] ?? "", cursor: parameters["cursor"] ?? "")
        case "danmaku":
            let start = Int64(parameters["start"] ?? "") ?? -1
            let duration = Int64(parameters["duration"] ?? "") ?? -1
            result = try await backend.danmaku(series: parameters["series"] ?? "", episode: parameters["episode"] ?? "", start: start, duration: duration)
        default:
            throw NSError(domain: "Hongguo", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的本地操作：\(path)"])
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try decodeNative(T.self, data: data)
    }

    private func decodeNative<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            // 原生层返回结构若与桥不一致，尽量给出可读错误而非解码崩溃。
            throw NSError(domain: "Hongguo", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据解析失败，请重试。"])
        }
    }

    /// 账号层原生调度（阶段 4）。path = "account/<action>"。
    private func requestAccount<T: Decodable>(_ path: String, _ parameters: [String: String], body: [String: Any]?, backend: HongguoBackend) async throws -> T {
        let action = String(path.dropFirst("account/".count))
        let result = try await backend.accountHandle(action: action, query: parameters, body: body ?? [:])
        let data = try JSONSerialization.data(withJSONObject: result)
        return try decodeNative(T.self, data: data)
    }

    private func requestBridge<T: Decodable>(_ path: String, _ parameters: [String: String], body: [String: Any]?) async throws -> T {
        guard let base else { throw URLError(.cannotConnectToHost) }
        var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        url.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 90
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await requestSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Hongguo", code: 1, userInfo: [NSLocalizedDescriptionKey: (try? JSONDecoder().decode(BridgeError.self, from: data).error) ?? "请求失败，请重试。"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let generation = UUID()
        performGeneration = generation
        action = Task {
            defer {
                // 仅当自己仍是当前代时才复位 busy 与处理 pending；被 interrupt 打断后由新任务接管。
                if self.performGeneration == generation {
                    busy = false
                    if let next = pendingHomeSeries, !stopping { pendingHomeSeries = nil; open(next, trial: true) }
                    else if pendingTrial && !stopping { pendingTrial = false; play(0, trial: true) }
                    else if pendingResume && !stopping { pendingResume = false; resume() }
                    else if pendingNext && !stopping {
                        pendingNext = false
                        if let episode { play(episode + 1) }
                    }
                }
            }
            do { try await body() }
            catch { if !Task.isCancelled && self.performGeneration == generation { message = error.localizedDescription } }
        }
    }
    func search(more: Bool = false) {
        let keyword = more ? searched : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, keyword.count <= 80 else { message = "请输入 1～80 字的剧名"; return }
        perform {
            let next = more ? self.page + 1 : 1
            self.message = "正在搜索…"
            let result: SearchResult = try await self.request("search", ["q": keyword, "page": String(next)])
            if more {
                let existing = Set(self.rows.map(\.id))
                self.rows += result.items.filter { !existing.contains($0.id) }
            } else { self.rows = result.items }
            if self.showDetail { self.saveProgress(); self.player.pause() }
            self.section = "搜索"
            self.navigation = "搜索"
            self.showDetail = false
            self.searched = keyword; self.page = next; self.hasMore = result.hasMore
            self.message = self.rows.isEmpty ? "没有找到相关剧集" : "已加载 \(self.rows.count) 部剧"
        }
    }
    func open(_ series: Series, trial: Bool = false) {
        perform {
            self.comments.clear(); self.commentThread.clear(); self.danmaku.clear()
            self.message = "正在读取剧集…"
            let detail: Detail
            if trial, let cached = self.homeWarmDetail, cached.series.id == series.id, self.homeWarmQuality == self.quality { detail = cached }
            else { detail = try await self.request("detail", ["id": series.id]) }
            self.saveProgress()
            self.player.pause(); self.player.replaceCurrentItem(with: nil)
            self.activeSeries = nil; self.activeEpisodeID = nil; self.activeEpisodeIndex = nil
            self.pendingNext = false
            self.warmedNearEndKey = nil
            self.detail = detail; self.showDetail = true; self.episode = nil; self.preview = trial; self.pendingTrial = trial; self.pendingResume = !trial
            if self.section == "账户" && self.cloudType == "账户历史", let cloud = self.cloudRows.first(where: { $0.id == series.id }), let id = cloud.episodeID, let index = detail.episodes.firstIndex(of: id) {
                self.cloudResume = (index, cloud.position ?? 0)
            } else { self.cloudResume = nil }
            self.related = []; self.relatedMessage = "正在读取相关作品…"
            self.relatedTask?.cancel()
            self.relatedTask = Task {
                do {
                    let result: RelatedResult = try await self.request("related", ["id": detail.series.id])
                    if !Task.isCancelled && self.detail?.series.id == detail.series.id { self.related = result.items; self.relatedMessage = result.items.isEmpty ? "暂无相关作品" : "" }
                } catch { if !Task.isCancelled { self.relatedMessage = "相关作品暂时无法加载" } }
            }
            self.message = "选择集数开始播放 · 共 \(detail.episodes.count) 集"
        }
    }
    func play(_ index: Int, position: Double = 0, autoplay: Bool = true, trial: Bool = false) {
        guard let detail, detail.episodes.indices.contains(index) else { return }
        let selectedQuality = quality
        perform {
            self.saveProgress()
            self.message = "正在准备第 \(index + 1) 集…"
            let episodeID = detail.episodes[index]
            if let backend = self.backend {
                // 阶段 3：原生取流（ResourceLoader 解密）。
                let info = try await backend.stream(episodeID: episodeID, quality: selectedQuality)
                guard !Task.isCancelled else { return }
                try await self.startNativeEpisode(episodeID: episodeID, info: info, index: index, position: position, autoplay: autoplay, trial: trial)
            } else {
                let result: PlayResult = try await self.request("play", ["id": episodeID, "quality": String(selectedQuality)])
                guard !Task.isCancelled else { return }
                guard let url = URL(string: result.url), url.host == "127.0.0.1" else { throw URLError(.badURL) }
                self.startEpisode(url: url, index: index, quality: result.quality, position: position, autoplay: autoplay, trial: trial)
            }
            if trial && self.section == "首页" { self.warmNextHome() }
        }
    }

    /// 阶段 3：用 AVAssetResourceLoaderDelegate 播放（自定义 scheme）。
    /// 命中预热缓存则复用已解析的加密索引，避免二次取流。
    private func startNativeEpisode(episodeID: String, info: ResourceLoader.StreamAndQuality, index: Int, position: Double, autoplay: Bool, trial: Bool) async throws {
        let stream = ResourceLoader.Stream(url: info.url, key: info.key)
        // 关键：当前集若未被预热，必须在创建 AVPlayerItem 之前先取头并解析加密索引，
        // 作为 seed 注入 ResourceLoader。否则 AVPlayer 首次 delegate 回调（往往只是 2 字节探测）
        // 会同步触发 256KB 取流 + 索引解析，期间若网络延迟/挂起，播放器与界面都会卡住。
        let seed: MediaFetcher.Prepared?
        if let cached = preparedCache.get(episodeID: episodeID, quality: quality) {
            seed = MediaFetcher.Prepared(prepared: cached.prepared, total: cached.total, mediaPrefixStart: cached.mediaPrefixStart > 0 ? cached.mediaPrefixStart : nil, mediaPrefix: cached.mediaPrefix)
        } else {
            seed = try await MediaFetcher.prepare(url: info.url, key: info.key, session: ResourceLoader.defaultSession())
        }
        let loader = ResourceLoader(stream: stream, episodeID: episodeID, seed: seed)
        let asset = AVURLAsset(url: MediaScheme.url(episodeID: episodeID), options: nil)
        asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
        activeLoader = loader
        let item = AVPlayerItem(asset: asset)
        startEpisode(item: item, index: index, quality: info.quality, position: position, autoplay: autoplay, trial: trial)
    }

    /// 拿到播放 URL 后，切换 AVPlayer 到指定集并开始播放。
    /// 自动下一集在预取命中时直接调用此方法，跳过网络等待，消除黑屏卡顿。
    private func startEpisode(url: URL, index: Int, quality: String, position: Double, autoplay: Bool, trial: Bool) {
        startEpisode(item: AVPlayerItem(url: url), index: index, quality: quality, position: position, autoplay: autoplay, trial: trial)
    }

    private func startEpisode(item: AVPlayerItem, index: Int, quality: String, position: Double, autoplay: Bool, trial: Bool) {
        guard let detail else { return }
        player.pause()
        danmaku.clear()
        player.replaceCurrentItem(with: item)
        activeSeries = detail.series; activeEpisodeID = detail.episodes[index]; activeEpisodeIndex = index
        activeTrial = trial; preview = trial
        episode = index; actualQuality = quality
        if position.isFinite && position > 0 {
            Task { await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        if autoplay { player.playImmediately(atRate: speed) }
        saveProgress()
        message = "第 \(index + 1) 集 · \(quality)"
        // 下一集预热改为「距本集结束不足 15 秒」时触发（见 warmNextIfNearEnd），
        // 不再于集开始时提前预热，避免无谓的取流请求与内存占用。
    }

    /// 预热下一集的流数据（阶段 3 改为原生取流 + 解析加密索引 + 预取开头媒体段；旧桥仍走 /warm）。
    /// 仅正式观看（非试播）且开启自动下一集时预热；切集时 play 命中 PreparedCache，
    /// 省去取流/解密/首包延迟，从而减少自动连播的卡顿。预热失败不影响当前播放。
    private func warmNextEpisode() {
        warmNextTask?.cancel()
        guard !activeTrial, autoNext, let detail, let index = episode, index + 1 < detail.episodes.count else { return }
        let seriesID = detail.series.id, nextID = detail.episodes[index + 1], selectedQuality = quality
        if warmedNearEndKey == nextID { return }
        warmedNearEndKey = nextID
        warmNextTask = Task { [weak self] in
            guard let self else { return }
            if let backend = self.backend {
                await self.prefetchEpisode(backend: backend, episodeID: nextID, quality: selectedQuality)
            } else {
                do {
                    let _: Detail = try await self.request("warm", ["id": seriesID, "episode": nextID, "quality": String(selectedQuality)])
                } catch { /* 可选预取失败，不应中断当前播放。 */ }
            }
        }
    }

    /// 距本集结束不足 15 秒时触发下一集预热（挂在 2 秒进度观测上，避免新增 Timer）。
    private func warmNextIfNearEnd() {
        guard !activeTrial, autoNext, !busy,
              let detail, let index = episode, index + 1 < detail.episodes.count,
              let item = player.currentItem, item.status == .readyToPlay else { return }
        let duration = item.duration.seconds
        let current = player.currentTime().seconds
        guard duration.isFinite, duration > 0, current.isFinite,
              duration - current <= 15, duration - current > 0 else { return }
        warmNextEpisode()
    }

    /// 原生预热某一集：解析流 -> 取头部 + 解析加密索引 -> 预取开头媒体段 -> 存入 PreparedCache。
    func prefetchEpisode(backend: HongguoBackend, episodeID: String, quality: Int) async {
        do {
            let info = try await backend.stream(episodeID: episodeID, quality: quality)
            Log.shared.info("prefetch \(episodeID) 取流完成，开始 prepare")
            let stream = ResourceLoader.Stream(url: info.url, key: info.key)
            let prepared = try await MediaFetcher.prepareWithMediaPrefix(url: info.url, key: info.key, session: ResourceLoader.defaultSession())
            Log.shared.info("prefetch \(episodeID) prepare 完成 samples=\(prepared.prepared.samples.count) total=\(prepared.total) prefix=\(prepared.mediaPrefix.count)B")
            preparedCache.put(PreparedEntry(episodeID: episodeID, quality: quality, stream: stream, prepared: prepared.prepared, total: prepared.total, mediaPrefixStart: prepared.mediaPrefixStart ?? 0, mediaPrefix: prepared.mediaPrefix))
        } catch { Log.shared.warn("prefetch \(episodeID) 失败：\(error.localizedDescription)") }
    }
    private func playNextEpisode() {
        guard let detail, let index = episode, index + 1 < detail.episodes.count else { return }
        if busy { pendingNext = true } else { play(index + 1) }
    }
    func watchFull() {
        preview = false; activeTrial = false; saveProgress()
        let current = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite && duration > 0 && current >= duration - 0.5 { play(episode ?? 0) }
        else if player.currentItem != nil { player.playImmediately(atRate: speed) }
        message = "已进入正式观看，可选择集数"
    }
    func moveRecommendation(_ delta: Int) {
        guard !busy, let id = detail?.series.id, let index = catalogRows.firstIndex(where: { $0.id == id }) else { return }
        if catalogRows.indices.contains(index + delta) { open(catalogRows[index + delta], trial: true) }
        else if delta > 0 && section == "首页" && catalogMore { loadHome(more: true) }
        else { message = "当前批次已到边界，可以换一批" }
    }
    var resumeLabel: String {
        if let cloudResume { return "继续账号第 \(cloudResume.0 + 1) 集" }
        guard let detail, let saved = library.history(detail.series.id) else { return "从第 1 集播放" }
        let index = saved.completed && saved.episodeIndex + 1 < detail.episodes.count ? saved.episodeIndex + 1 : saved.episodeIndex
        return "继续第 \(index + 1) 集"
    }
    func resume() {
        guard let detail else { return }
        if let cloudResume { play(cloudResume.0, position: cloudResume.1); self.cloudResume = nil; return }
        guard let saved = library.history(detail.series.id), let index = detail.episodes.firstIndex(of: saved.episodeID) else { play(0); return }
        if saved.completed && index + 1 < detail.episodes.count { play(index + 1) }
        else { play(index, position: saved.completed ? 0 : saved.position) }
    }
    func saveProgress(completed: Bool = false) {
        guard !activeTrial, let series = activeSeries, let id = activeEpisodeID, let index = activeEpisodeIndex, player.currentItem != nil else { return }
        let position = CMTimeGetSeconds(player.currentTime()), duration = CMTimeGetSeconds(player.currentItem!.duration)
        guard position.isFinite else { return }
        let record = WatchRecord(series: series, episodeID: id, episodeIndex: index, position: max(0, position), duration: duration.isFinite ? max(0, duration) : 0, completed: completed || (duration.isFinite && duration > 0 && position >= duration - 0.5), updatedAt: Date())
        library.record(record)
        uploadProgress(record, count: detail?.episodes.count ?? 0)
    }
    func changeSpeed(_ value: Float) {
        guard [0.5, 0.75, 1, 1.25, 1.5, 2].contains(value) else { return }
        speed = value; UserDefaults.standard.set(value, forKey: "playbackSpeed")
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
    }
    func changeQuality(_ value: Int) {
        guard [0, 480, 720, 1080].contains(value) else { return }
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
        if let episode { play(episode, position: CMTimeGetSeconds(player.currentTime()), autoplay: player.rate > 0, trial: activeTrial) }
    }

    /// 仅设置清晰度偏好（不触发重新播放），供「我的」页的自动清晰度开关使用。
    func setQualityPreference(_ value: Int) {
        quality = value; UserDefaults.standard.set(value, forKey: "playbackQuality")
    }


    func shutdown() {
        comments.clear(); commentThread.clear(); danmaku.clear(); platformInterface?.platformWillShutdown(); homeWarmTask?.cancel(); homeWarmDetail = nil; pendingHomeSeries = nil
        stopping = true; pendingNext = false; pendingTrial = false; pendingResume = false; relatedTask?.cancel(); loginTask?.cancel(); uploadTask?.cancel(); cloudTask?.cancel()
        warmNextTask?.cancel()
        saveProgress(); action?.cancel()
        if let progressObserver { player.removeTimeObserver(progressObserver); self.progressObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        platformInterface?.platformShutdown()
        player.pause(); player.replaceCurrentItem(with: nil)
        activeLoader?.close(); activeLoader = nil; preparedCache.clear()
        backend?.accountClose()
    }
}

/// 平台集成接口：由 GUI 层实现，逻辑层只依赖此抽象，不碰 AppKit/AVKit。
@MainActor
protocol ModelPlatformInterface: AnyObject {
    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool)
    func platformWillShutdown()
    func platformShutdown()
}
