// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine
import AVFoundation

/// UI 播放进度（秒），独立于 Model 发布
/// 播放时 AVPlayer 的回调频率很高，若写回 Model 的 @Published 属性，会让 ContentView/EpisodeView
/// 这类观察 Model 的大视图树每次都重算 body，是播放时 CPU/能耗偏高的主要原因
/// 只有真正显示进度的进度条/时间文本订阅本对象
@MainActor final class PlaybackClock: ObservableObject {
    @Published private(set) var time: Double = 0

    /// 同值更新不发布，暂停/静止时不再触发订阅方重绘
    func update(_ seconds: Double) {
        guard seconds.isFinite, seconds != time else { return }
        time = seconds
    }
}

@MainActor final class Model: ObservableObject {
    @Published var query = ""
    @Published var rows: [Series] = []
    @Published var detail: Detail?
    @Published var busy = true
    /// 列表首屏/全页加载中（区别于 busy 的操作互斥）：用于驱动列表页的转圈与「正在加载」空态
    /// 分页（more）与选集播放等局部操作不置此标志，避免局部操作导致整页转圈、置灰无关按钮
    @Published var loadingList = false
    @Published var message = "正在启动…"
    @Published var episode: Int?
    @Published var hasMore = false
    let player = AVPlayer()
    @Published var isPlaying = false
    /// 播放进度：由 AVPlayer 周期观察者按需更新，独立发布（见 PlaybackClock 注释）
    let playbackClock = PlaybackClock()

    // MARK: - 播放器交互状态

    @Published var playerControlsVisible = true
    /// 鼠标是否正悬停于播放区（非全屏） 自动隐藏需「超时且鼠标不在播放区」同时成立，
    /// 避免鼠标停在画面上时控件无故消失
    @Published var hoveringPlayer = false
        /// 清晰度/倍速 popover 是否展开：展开时锁定控件栏，避免自动隐藏移除弹窗锚点
        @Published var playerPopoverOpen = false
    @Published var infoPanelOpen = false
    @Published var pipActive = false
    /// 播放控件自动隐藏定时任务：显示控件后 2.5 秒无操作则淡出
    var controlsHideTask: Task<Void, Never>?
    lazy var comments = CommentsStore { [weak self] series, episode in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("comments", ["series": series, "episode": episode])
    }
    lazy var commentThread = CommentThreadStore { [weak self] series, episode, cursor in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("comment-page", ["series": series, "episode": episode, "cursor": cursor])
    }
    lazy var danmaku = DanmakuStore { [weak self] series, episode, start, duration in
        guard let self else { throw URLError(.cancelled) }
        return try await self.request("danmaku", ["series": series, "episode": episode, "start": String(start), "duration": String(duration)])
    }
    let library: LocalLibrary
    let catalogCache = CatalogCache()
    let detailCache = DetailCache()
    @Published var section = Section.search
    @Published var navigation = Destination.search
    /// 上一次栏目，用于跨栏目切换时判断是否打断进行中的请求
    var _previousSection: Section?
    @Published var showDetail = false
    @Published var catalogRows: [Series] = []
    @Published var rankPositions: [String: RankBadge] = [:]
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
    @Published var cloudType = CloudType.history
    @Published var cloudRows: [CloudEntry] = []
    /// 「我的-账户」页四类账号片单的独立缓存（登录后一次性加载，平铺展示）
    @Published var cloudFavorites: [CloudEntry] = []
    @Published var cloudHistory: [CloudEntry] = []
    @Published var cloudOnline: [CloudEntry] = []
    @Published var cloudUpcoming: [CloudEntry] = []
    /// 已登录账户的收藏剧集 id 集合，用于收藏按钮的「已收藏」态判断
    @Published var accountFavorites: Set<String> = []
    @Published var cloudLoading = false
    @Published var cloudError: String?
    @Published var cloudLoadedKey: String?
    var cloudTask: Task<Void, Never>?
    @Published var cloudAllLoading = false
    @Published var cloudAllError: String?
    var cloudAllTask: Task<Void, Never>?
    var cloudRequestID = UUID()
    var accountGeneration = 0
    var pendingLoginID: String?
    var loginTask: Task<Void, Never>?
    var uploadTask: Task<Void, Never>?
    var lastUpload = Date.distantPast
    var catalogPage = 1
    var catalogKind: Section?
    var relatedTask: Task<Void, Never>?
    var catalogRefreshTask: Task<Void, Never>?

    // MARK: - 播放参数与预热门闩

    @Published var speed: Float = UserDefaults.standard.object(forKey: "playbackSpeed") as? Float ?? 1
    @Published var quality: Int = UserDefaults.standard.object(forKey: "playbackQuality") as? Int ?? 0
    @Published var autoNext = UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoNext, forKey: "autoNext") }
    }
    /// 首页直接播放：开启后进入首页加载完成即自动试播第一部，不再等待「开始刷剧」确认
    @Published var homeAutoPlay = UserDefaults.standard.object(forKey: "homeAutoPlay") as? Bool ?? false {
        didSet { UserDefaults.standard.set(homeAutoPlay, forKey: "homeAutoPlay") }
    }
    @Published var actualQuality = ""
    var activeSeries: Series?
    var activeEpisodeID: String?
    var activeEpisodeIndex: Int?
    private var progressObserver: Any?
    private var playbackTimeObserver: Any?
    private var playStateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    var pendingNext = false
    var warmNextTask: Task<Void, Never>?
    /// 自动连播切集失败后的幂等量试标记：同一集只允许兜底重试一次，避免软失败（如「播放接口返回空响应」）时无限重试
    var autoRetrying = false
    /// 已触发「靠近结尾预取」的集（episodeID），避免同一集重复预取
    var warmedNearEndKey: String?
    var stopping = false
    @Published var preview = false
    var activeTrial = false
    var pendingHomeSeries: Series?
    var homeWarmTask: Task<Void, Never>?
    var homeWarmDetail: Detail?
    var homeWarmQuality: Int?
    var homeGeneration = UUID()
    @Published var homeCategory = "COMIC"
    /// 用户主动点「开始刷剧」后，加载完成即试播第一部；进入首页默认不自动试播
    var autoTrialAfterLoad = false
    var cloudResume: (Int, Double)?
    private var base: URL?
    var page = 1
    var searched = ""
    var action: Task<Void, Never>?
    /// perform 请求代次：跨栏目打断请求后，旧任务的 defer 依靠它避免误复位 busy/误处理 pending
    private var performGeneration = UUID()
    /// 详情加载代次：open 拆成「先切骨架 + 后台填充」后，
    var detailGeneration = UUID()
    var detailTask: Task<Void, Never>?
    private var playerObservation: NSKeyValueObservation?
    private let requestSession: URLSession
    let backend: HongguoBackend?
    /// 平台集成接口（键盘监听 / 全屏 / 画中画等） 由 GUI 层注入；纯逻辑/测试场景为 nil
    weak var platformInterface: (any ModelPlatformInterface)?
    /// 当前播放会话的资源加载委托（阶段 3），保持强引用避免被提前释放
    var activeLoader: ResourceLoader?
    /// 切集预热缓存（阶段 3），按 episodeID+quality 键存已解析的加密索引
    let preparedCache = PreparedCache()
    /// 预加载好的「下一集/下一部剧首集」播放项，到时直接切换实现无缝/秒开
    struct PrewarmedEpisode {
        let item: AVPlayerItem
        let episodeID: String
        let seriesID: String?
        let index: Int
        let quality: String
    }
    var prewarmedEpisode: PrewarmedEpisode?
    var prewarmLoader: ResourceLoader?

    init(resourcesURL: URL? = Bundle.main.resourceURL, library: LocalLibrary? = nil, restoreSession: Bool = true, bridgeURL: URL? = nil, session: URLSession = .shared) {
        self.base = bridgeURL; self.requestSession = session
        // 仅当无桥接 URL（正式运行）时启用原生协议层；测试仍走注入的本地 HTTP 桥
        self.backend = bridgeURL == nil ? HongguoBackend(session: session) : nil
        self.library = library ?? LocalLibrary()
        installPlayerObservations()
        Task { await start(resources: resourcesURL, restoreSession: restoreSession) }
    }

    // MARK: - 播放器状态观测

    /// 装配播放器观察者：失败提示 / 播放状态 / 5s 存进度与预热 / 0.1s 进度时钟 / 播放结束
    /// 观察者随 Model 生命周期存在；`shutdown()` 负责移除定时与通知观察者
    private func installPlayerObservations() {
        playerObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
            guard player.currentItem?.status == .failed else { return }
            Task { @MainActor [weak self] in self?.message = "此视频暂时无法播放，请尝试其他集数或剧集 " }
        }
        playStateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in self?.isPlaying = player.rate > 0 }
        }
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveProgress()
                self?.warmNextIfNearEnd()
            }
        }
        // UI 进度：控件隐藏时无人显示进度，直接跳过更新；可见时 10Hz 足够（时间文本只到秒）
        // 进度写进独立的 playbackClock，避免高频率刷新带动整棵视图树重绘
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playerControlsVisible else { return }
                self.playbackClock.update(seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            Task { @MainActor [weak self] in
                guard let self, item === self.player.currentItem else { return }
                self.saveProgress(completed: true)
                if !self.activeTrial && self.autoNext, let index = self.episode, let detail = self.detail, index + 1 < detail.episodes.count {
                    self.autoRetrying = false
                    self.playNextEpisode()
                } else { self.message = "本集播放结束" }
            }
        }
    }

    private func start(resources: URL?, restoreSession: Bool) async {
        defer { busy = false }
        if base != nil { return }
        if backend != nil {
            Log.shared.info("启动：Swift 原生模式")
            message = "输入剧名，开始找剧"
            if restoreSession { Task { await restoreAccount() } }
            return
        }
        message = "客户端启动失败，请重新打开应用"
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

    /// 原生协议层调度：返回 JSON 结构后，复用同一套 Decodable 解码
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
            // 原生层返回结构若与桥不一致，尽量给出可读错误而非解码崩溃
            throw NSError(domain: "Hongguo", code: 1, userInfo: [NSLocalizedDescriptionKey: "数据解析失败，请重试 "])
        }
    }

    /// 账号层原生调度（阶段 4） path = "account/<action>"
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
            throw NSError(domain: "Hongguo", code: 1, userInfo: [NSLocalizedDescriptionKey: (try? JSONDecoder().decode(BridgeError.self, from: data).error) ?? "请求失败，请重试 "])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func perform(_ body: @escaping @MainActor () async throws -> Void, onRetryable: ((Error) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        let generation = UUID()
        performGeneration = generation
        action = Task {
            defer {
                // 仅当自己仍是当前代时才复位 busy 与处理 pending；被 interrupt 打断后由新任务接管
                if self.performGeneration == generation {
                    busy = false
                    if let next = pendingHomeSeries, !stopping { pendingHomeSeries = nil; open(next, trial: true) }
                    else if pendingNext && !stopping {
                        pendingNext = false
                        if let episode { play(episode + 1, auto: true) }
                    }
                }
            }
            do { try await body() }
            catch {
                if !Task.isCancelled && self.performGeneration == generation {
                    message = error.localizedDescription
                    onRetryable?(error)
                }
            }
        }
    }


    func shutdown() {
        comments.clear(); commentThread.clear(); danmaku.clear(); platformInterface?.platformWillShutdown(); homeWarmTask?.cancel(); homeWarmDetail = nil; pendingHomeSeries = nil
        stopping = true; pendingNext = false; relatedTask?.cancel(); loginTask?.cancel(); uploadTask?.cancel(); cloudTask?.cancel()
        detailTask?.cancel()
        warmNextTask?.cancel()
        saveProgress(); action?.cancel()
        if let progressObserver { player.removeTimeObserver(progressObserver); self.progressObserver = nil }
        if let playbackTimeObserver { player.removeTimeObserver(playbackTimeObserver); self.playbackTimeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        platformInterface?.platformShutdown()
        player.pause(); player.replaceCurrentItem(with: nil)
        activeLoader?.close(); activeLoader = nil; preparedCache.clear()
        prewarmLoader?.close(); prewarmLoader = nil; prewarmedEpisode = nil
        backend?.accountClose()
    }
}

/// 平台集成接口：由 GUI 层实现，逻辑层只依赖此抽象，不碰 AppKit/AVKit
@MainActor
protocol ModelPlatformInterface: AnyObject {
    func installPlatformIntegrations(resourcesURL: URL?, restoreSession: Bool)
    func platformWillShutdown()
    func platformShutdown()
}
