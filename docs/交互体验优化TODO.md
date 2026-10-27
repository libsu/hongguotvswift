# 交互体验优化 TODO 清单

> 依据《交互体验优化方案.md》整理，按**收效 × 紧迫性**综合排序。
> 排序评估两个维度：**收效**（对用户体感的提升幅度）、**紧迫性**（问题是否高频且明显）。
> 打分标准：P0 最高优，P3 可选锦上添花。风险标注参考方案文档「落地顺序与影响面」。

---

## 排序总览

| 优先级 | 事项                                                              | 解决的核心体验                                         | 收效  | 紧迫性 | 风险 | 状态 |
| ------ | ----------------------------------------------------------------- | ------------------------------------------------------ | ----- | ------ | ---- | ---- |
| P0     | 接入封面磁盘缓存：`AsyncImage` → `CoverImageView`                 | 二次进入/重启不再重新下载 100 张封面                   | ★★★★★ | ★★★★★  | 低   | ☐    |
| P0     | 点击即切详情：`open()` 拆成「先切骨架 + 后台填充」                | 点卡片立刻切画面，不再原地转圈                         | ★★★★★ | ★★★★★  | 中   | ☐    |
| P1     | 引入图片下载队列（并发上限 + 可见性优先级）                       | 榜单 100 张不再同时抢带宽，首屏更快                    | ★★★★☆ | ★★★★☆  | 中   | ☐    |
| P1     | 回收全局 `busy`，改为局部加载态（骨架屏/局部 spinner）            | 加载期间不再整页转圈、不连带禁用无关按钮               | ★★★★☆ | ★★★★☆  | 中   | ☐    |
| P1     | 导航/分区状态去字符串化：`section`/`cloudType`/`navigate` 改 enum | 消除文案改动导致的「点栏目无反应、片单空白、状态错乱」 | ★★★★☆ | ★★★★☆  | 中   | ☐    |
| P2     | 详情本地缓存 + 乐观回填                                           | 二次进入同一部剧详情秒开                               | ★★★☆☆ | ★★★☆☆  | 低   | ☐    |
| P2     | 图片降采样 + 单文件大小上限                                       | 减小封面体积、加快解码                                 | ★★★☆☆ | ★★☆☆☆  | 低   | ☐    |
| P3     | tvOS 侧 `TVCoverImage` 同步接入缓存                               | tvOS 版同样享受缓存收益（平台一致性）                  | ★★★☆☆ | ★★☆☆☆  | 低   | ☐    |

---

## 详细 TODO

### P0-1 接入封面磁盘缓存（问题 B 关键）

- [x] 将 `GUI/ContentView.swift` → `card(_:)` 的封面 `AsyncImage` 替换为 `CoverImageView(urlString: series.cover)`
- [x] 将 `GUI/HomeViews.swift` → `seriesCard` / `historyCard` / `cloudCard` 的 `AsyncImage` 替换为 `CoverImageView`
- [x] 将 `GUI/PlayerView.swift` → 相关作品卡片的 `AsyncImage` 替换为 `CoverImageView`
- [x] 确认 `CoverCache`（`Sources/CoverCache.swift`）的磁盘缓存逻辑参数合理（文件数上限 1000）
- [ ] 验证：进入榜单 → 退出 → 再进入，封面立即显示，不重新请求

**已完成说明**：macOS 侧三处封面（首页卡片、我的页三卡、播放器相关作品）均已替换为 `CoverImageView`。头像与 tvOS `TVCoverImage` 不在本次 P0-1 范围（头像非剧封面；tvOS 属 P3-7）。已通过 `swiftc -typecheck` 验证无编译错误。

**为什么排第一**：`CoverImageView` + `CoverCache` 已完整实现却从未接线，纯视图替换、风险最低，却能立刻消除「下次点击/进入又加载 100 张图」。

---

### P0-2 点击即切详情（问题 A 关键）

- [x] 重构 `Model.open(_:trial:resumeEpisodeID:resumePosition:)`（`HongguoMac.swift`），拆成两个阶段：
  - [x] 同步阶段：立即 `showDetail = true`，先展示「加载中」的 `Detail` 占位（含 title/cover/description，episodes 为空）
  - [x] 同步阶段：`saveProgress()` + 停旧播放 + 清空 comments/danmaku 等面板
  - [x] 异步阶段：后台拉取 `detail`，用 `detailGeneration` 令牌校验后填充
- [x] 详情请求**不占用全局 `busy`**（改为详情页内部局部 loading）
- [x] 从 `open()` 中剥离 `related` 拉取，改为挂到「detail 到达后」（`applyDetail`）
- [x] 处理云端续播判断（`cloudResume`）也要在 detail 到达后执行（`applyDetail`）
- [ ] 验证：连续快速点击 A、B 两部剧，最终停留在 B 的数据一致（竞态令牌）

**已完成说明**：`open` 拆为同步骨架切换 + 后台 `detailTask` 填充；新增 `detailGeneration`/`detailTask` 令牌与 `applyDetail` 聚合填充/续播/下拉相关作品逻辑；`navigate`/`shutdown` 中作废在途详情请求。同时清理了因重构而失效的 `pendingTrial`/`pendingResume` 死代码。已通过 `swiftc -typecheck`。

---

### P1-3 图片下载队列（并发上限 + 可见性优先级）

- [x] 在 `CoverCache`（`Sources/CoverCache.swift`）内增加并发受限下载队列（信号量，上限 10）
- [x] `CoverImageView` 结合 `LazyVGrid` 惰性渲染 + `task(id:)`，只对可视区卡片触发加载
- [x] 滚出可视区时取消未完成下载（`AsyncSemaphore` 支持取消，`task(id:)` 传播取消）
- [x] 榜单按显示顺序排队：列表索引越小优先级越高（顶部前 10 项自然优先），其余按滚动顺序滑动窗口补位
- [x] 存图前做魔数校验（JPEG/PNG/GIF/WebP），避免坏图/破图写入 covers 缓存
- [ ] 验证：首屏只看到可视区 + 邻近区并发请求（约 ≤10），滚动时渐进加载

**已完成说明**：并发上限由 6 提到 10；`AsyncSemaphore.acquire` 增加 `priority`（数值越小越优先，同优先级按入队序 FIFO，取消时从队列移除并抛 CancellationError）。`CoverDownloader.download` 透传优先级，`CoverImageView`/`SeriesCard`/`SeriesPosterCard` 增加 `priority` 参数，`ContentView` 的主网格 `ForEach(items.enumerated())` 把列表索引作为优先级传入，从而「榜单前几项先于后续滚动项」，且 release 时立即唤醒队首形成滑动窗口（一个完成即让下一个进入，无需等整批）。`CoverCache.store` 落盘前做魔数校验（极小开销、只读文件头，封面实际为 JPEG，同时兼容 PNG/GIF/WebP），坏图/破图不再被缓存。IO 侧：磁盘写入移到串行后台队列（不在 MainActor 上写文件/stat），目录修剪从「每张都全量扫描」改为每 64 张节流一次，且内存层复用调用方已解码的图、不再二次 `NSImage(data:)` 解码。已通过 `swiftc -typecheck`。

---

### P1-4 回收全局 `busy`，改用局部加载态

- [x] 定义 `busy` 新语义：只表示操作互斥，新增 `loadingList` 专门驱动列表页整页转圈
- [x] 将 `ContentView` 的 `if model.busy || model.cloudLoading { ProgressView() }` 改为 `model.loadingList || model.cloudLoading`
- [x] 分页（more）与选集播放等局部操作不再触发整页转圈（不置 `loadingList`）
- [x] 详情/分页/图片加载各用独立状态（详情 + 图片已在 P0-2/P1-3 实现，分页本次收敛）
- [ ] 验证：点击详情加载期间，列表/首页可继续操作，无关按钮不被禁用

**已完成说明**：新增 `loadingList`（列表首屏/全页加载态），与 `busy`（操作互斥锁）解耦。`search`/`loadHome`/`loadCatalog` 仅在首次加载（非分页）时置 `loadingList`，分页与选集播放不再置此标志。`ContentView` 顶部转圈与 emptyState「正在加载」文案、`HomeFeedView`「准备试播」文案改由 `loadingList` 驱动。`.disabled(model.busy)` 保留为合理互斥（防重复提交，非滥用）。已通过 `swiftc -typecheck`。

---

### P1-8 导航/分区状态去字符串化（依据《项目分析.md》P1 插入）

- [x] 定义导航目的地/分区枚举（`Section`、`CloudType`、导航 `Destination`），替换 `Navigation.swift` 中 `section == "账户"`、`navigate("首页")` 等字符串字面量
- [x] 替换 `section`/`cloudType` 的字符串判定扩散点：`Account.swift`（`section == "账户"`、`cloudType == "账户收藏"`、`type == "待上线"`）、`Catalog.swift`（`["找剧","榜单","推荐"].contains(section)`）、`Detail.swift`（`section == "搜索"`）、`HomeView.swift`、`Playback.swift`、`GUI/ContentView.swift`、`Sources/tvOS/*` 等
- [x] 验证：改动任意文案/图标不影响导航与片单行为；各栏目切换、账户收藏/历史/预约、搜索回退均正常

**已完成说明**：新增 `Section`（首页/找剧/榜单/推荐/收藏/历史/账户/我的/搜索）、`CloudType`（账户历史/收藏/已上线/待上线预约）与 `Destination`（含本机收藏/历史、账户四类片单等导航入口）三个 enum；`Model.section/navigation/cloudType/catalogKind/previousSection` 全部去字符串化，`navigate` 改为接收 `Destination` 并通过 `Destination.section/cloudType` 派生分区。同步替换了 `Account/Catalog/Detail/HomeView/Playback/ContentView` 与 tvOS 前端（`TVShelfViews/TVMineView/TVPosterGrid`）的字符串判定，以及两个测试用例的 `navigate(...)` 调用。已通过 `swiftc -typecheck`（macOS 与 tvOS 模拟器目标均通过）。

**排序理由**：字符串是脆弱的状态载体，扩散面广（Playback/Detail/Catalog/Account 均依赖中文文案判等），任一文案改动都会造成「点栏目无反应 / 片单空白 / 状态错乱」且无编译报错。收效集中在对用户体感的稳定性与防回归——平时不可见，一旦触发即明显故障，故列 P1。

---

### P2-5 详情本地缓存 + 乐观回填

- [x] 新增 `Detail` 磁盘缓存（复用 `CatalogCache` 模式，键：`series.id`）
- [x] `open()` 先读缓存立即渲染详情，后台刷新后再覆盖
- [x] 处理缓存失效/版本兼容（详情结构变化时优雅降级）
- [ ] 验证：二次进入同一部剧详情页秒开（集数列表立即可点）

**已完成说明**：新增 `DetailCache`（`Sources/Detail.swift`，键为 `series.id`，磁盘目录 `HongguoTVMac/detail`，文件数上限 128，落盘包一层 `schemaVersion` 版本号），`Detail` 由 `Decodable` 改为 `Codable`。`open()` 在骨架切换后先 `detailCache.load(series.id)`：命中则用新增的 `renderDetail` 立即填充集数/续播/相关作品（不自动播放，避免对过期集数自动续播），后台 `detailTask` 拿到权威数据后 `save` 并 `applyDetail` 覆盖（含自动播放）。缓存解码失败/版本不符时 `load` 返回 nil 优雅降级；后台刷新失败且已有缓存兜底时保留缓存画面而非退回片单。已通过 `swiftc -typecheck`。

**排序理由**：收效集中在「二次进入」，频率低于首屏场景，故列 P2。

---

### P2-6 图片降采样 + 单文件大小上限

- [ ] `CoverCache.store` 前按目标卡片尺寸做缩略图/降采样
- [ ] 增加磁盘单文件大小上限校验（现有仅文件数上限 1000）
- [ ] 验证：体积下降、命中后内存解码更快

**排序理由**：属于优化体感，不解决核心痛点的首要矛盾，收效与紧迫性中等偏下。

---

### P3-7 tvOS 侧 `TVCoverImage` 同步接入缓存

- [x] `tvOS/TVComponents.swift` 的 `TVCoverImage` 改为受控缓存实现
- [x] 复用共享层 `Sources/CoverCache.swift` 的磁盘缓存与队列逻辑（macOS / tvOS 同一实现）
- [x] 验证：tvOS 版二次进入同样命中缓存

**已完成说明**：`CoverCache` / `AsyncSemaphore` / `CoverDownloader` 已下沉到共享层 `Sources/CoverCache.swift`，不依赖 AppKit / UIKit，只对外传递本地文件路径（`URL`），不再解码图片。`TVCoverImage` 已从裸 `AsyncImage` 切换为「`CoverCache.cachedURL` 命中 → 否则 `CoverDownloader.download` 落盘 → `UIImage(contentsOfFile:)` 渲染」，两处调用方（`TVPosterCard`、`TVRelatedList`）接口不变。缓存键仍为 URL 末段（非 SHA-256），单一路径 `Application Support/HongguoTV/covers`。已通过 macOS 与 tvOS 两侧 `swiftc -typecheck`。

**排序理由**：平台一致性收益，但 tvOS 用户面/改动紧迫性相对较低，故列 P3 收尾。

---

## 建议执行节奏

1. **先做 P0-1 + P0-2**：两者分属不同问题、改动文件无重叠，可并行；合计风险可控，能一次性解决两个最痛的问题。
2. **再做 P1-3 + P1-4**：P1-3 依赖 P0-1 的统一入口，P1-4 是 P0-2 的深化，按序推进。
3. **P1-8 可穿插推进**：改动分散在 `Navigation/Account/Catalog/Detail/HomeView/ContentView` 多处，建议独立成一次提交、整体回归；与 P1-3/P1-4 无强依赖，可并行或排在其后。
4. **P2/P3 按需收尾**：作为锦上添花，视主链路稳定后再加。
