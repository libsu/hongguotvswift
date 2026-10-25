# 红果 tvOS（Apple TV）移植方案

> 目标：在当前纯 Swift 项目基础上，新增 Apple TV（tvOS）客户端。
> 结论先行：**可行**，但属于「抽出共享逻辑层 + 重写 UI / 播放器」的适配项目，而非一次开关式改动。

---

## 1. 现状与结论

- 当前是 **macOS 专用**客户端，SwiftUI + **AppKit** + AVKit，单二进制 `.app`，由 `scripts/build-mac-swift.sh` 用 `swiftc` 直接编译（**没有** `.xcodeproj`，也**没有** `Package.swift`）。
- 代码里 AppKit / macOS 专用 API 遍布 UI 与播放器层，且存在一条 `Process()` 启动 JVM 子进程的「桥接模式」分支（tvOS **禁止** `Process`）。

分层判断：

| 层                           | 模块                                                                                                | 可复用性                                                                              |
| ---------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| 纯逻辑（网络/签名/数据模型） | `Crypto/`、`Protocols/`、`Media/`、`Models.swift`、`LocalLibrary`、`Catalog`、`Danmaku`、`Comments` | ✅ 基本可复用（仅少量类型需条件编译）                                                 |
| 业务编排                     | `Model`（`HongguoMac.swift`）                                                                       | ⚠️ 半复用（含 AppKit 键盘监听、`NSImage`、`AVPictureInPictureController` 等，需抽离） |
| UI                           | `App.swift`、`ContentView`、`HomeView` 等所有 View                                                  | ❌ 重写（macOS 窗口/菜单/键盘模型 vs tvOS 遥控器焦点模型）                            |
| 播放器                       | `PlayerView.swift`                                                                                  | ❌ 重写（自定义 `NSWindow` vs `AVPlayerViewController`）                              |
| 登录                         | `Account.swift`、`Account/MacAccount.swift`                                                         | ⚠️ 适配（`NSImage`→`UIImage`、钥匙串可用属性差异、扫码 UX）                           |
| 更新                         | `MacUpdates.swift`                                                                                  | ❌ 删除（**已决策：tvOS 不做自更新**）                                                |

> **产品决策（已确认）**
>
> - tvOS **不更新**：删除自更新模块，仅走 App Store / TestFlight 分发。
> - tvOS **无需投屏**：删除投屏入口，不做 AirPlay「投出」。
> - 弹幕 / 评论 **只读**：不提供输入、评论编辑等交互。

---

## 2. 核心结论：为什么不能直接改

1. **入口不同**：`App.swift` 是全套 macOS 概念——`NSApplicationDelegate`、`Window`、`.commands`、`CommandMenu`、`defaultSize`、`willTerminate`。tvOS 只有单窗口全屏 `WindowGroup`，没有菜单栏 / 多窗口 / 窗口尺寸。
2. **输入模型不同**：`HongguoMac.swift` 的 `installKeyMonitor()`（`NSEvent.addLocalMonitorForEvents`）与 `PlayerView` 的鼠标/键盘监听，在 tvOS 上必须换成 **遥控器焦点系统**（`.focusable()`、`FocusState`、`onMoveCommand`、`onPlayPauseCommand` 等）。
3. **播放器渲染不同**：`PlayerView.swift` 用 `NSViewRepresentable` + 手动 `AVPlayerLayer`（`PlayerLayerView`）。tvOS **不允许应用层直接操作 `AVPlayerLayer`**，必须用 `AVPlayerViewController`（或 SwiftUI `VideoPlayer`）。
4. **画中画不可用**：`AVPictureInPictureController`（`pipController`、`togglePictureInPicture`）在 tvOS 上**不存在**。
5. **投屏（已决策：无需投屏）**：`AirPlayPicker` 是 `NSViewRepresentable` + `AVRoutePickerView`（AppKit 版），tvOS 端直接删除投屏入口，不做 AirPlay「投出」。
6. **剪贴板不存在**：`Comments.swift` 的 `NSPasteboard`「复制」相关逻辑 tvOS 上**无剪贴板**，需移除（与「评论只读」决策一致）。
7. **子进程被禁**：`Model.start()` 里有 `Process()` 启动 `runtime/bin/java` 的桥接分支。tvOS 沙盒**禁止 `Process`/`posix_spawn`**。原生模式（`backend != nil`）虽不走，但该分支必须整体裁剪或条件编译排除。
8. **自更新不存在（已决策：tvOS 不更新）**：`MacUpdates.swift` 的下载/校验/`NSWorkspace` 全部不可用于 tvOS，只能 App Store / TestFlight 分发。

---

## 3. 关键正资产：可复用核心必须保留

以下模块与 tvOS 平台无关，是移植的最大价值所在，**必须完整保留并设为共享**：

### 3.1 `Crypto/`

- `Signer.swift`（gorgon / helios / medusa / x-argus / md5）：纯 Foundation + CommonCrypto。
- `AesV3.swift`、`Bytes.swift`、`Gzip.swift`、`MediaCrypto.swift`、`SM3.swift`、`VendorConstants*.swift`。

### 3.2 `Protocols/`

原生协议层（`HongguoBackend`）与全部 `*Transport`/`*Models`/`*Repository`/`RecommendationFeed`/`Comments` 等。这是**推荐用原生模式（`backend != nil`）** 的原因之一——避免 `Process` 桥接。

### 3.3 `Media/`

- `CodecCapabilities.swift`：AV1 过滤逻辑 tvOS 同样成立（Apple TV 对 AV1 软解保守过滤是对的）。
- `MediaFetcher.swift`、`VideoTracks.swift`、`PreparedCache.swift`、`ResourceLoader.swift`。
  - **重点**：`AVAssetResourceLoaderDelegate` 自定义 scheme 解密方案在 tvOS 上**成立**——`AVPlayer` + `AVPlayerViewController` 同样支持 `resourceLoader.setDelegate`。这部分是播放器里**几乎不需要重写**的纯逻辑。

### 3.4 数据模型

`Models.swift`、`LocalLibrary.swift`（本机片单，注意下方存储位置差异）、`Catalog`、`Danmaku`（`MacDanmaku` 纯逻辑可复用，仅名字可保留）、`Comments`（除剪贴板部分）。

---

## 4. 分文件改造清单

### 4.1 必须重写 / 大改

| 文件                        | 问题                                                                                                               | 改造                                                                                                                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/App.swift`         | macOS `App`/`Scene`/`commands`                                                                                     | 重写为 `@main struct HongGuo: App { WindowGroup { TVRootView(model:) } }`，删除 `AppDelegate`、`CommandMenu`、`willTerminate`。生命周期改 `scenePhase`。                                                   |
| `Sources/PlayerView.swift`  | `NSWindow` 全屏 + 手动 `AVPlayerLayer` + `NSEvent` + `AVPictureInPictureController` + 自定义 `NSViewRepresentable` | 重写。核心：`AVPlayerViewController`（`player = model.player`）+ 自定义 SwiftUI 悬浮控件覆盖层；遥控器焦点处理 controls 显隐；删除 PiP（**决策：无需投屏 → `AirPlayPicker` 直接删除，不做 UIKit 承载**）。 |
| `Sources/ContentView.swift` | macOS 布局/侧栏/鼠标悬停                                                                                           | 重写为 tvOS 网格式首页 + 焦点导航（TabView + 焦点优先 layout）。                                                                                                                                           |
| `Sources/HomeView.swift`    | 同上                                                                                                               | 重写（推荐流 + 频道 TabView）。                                                                                                                                                                            |

### 4.2 适配（条件编译）

| 文件                         | 问题                                                                                                          | 改造                                                                                                                                                                                          |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Sources/HongguoMac.swift`   | `NSImage`、`installKeyMonitor`（`NSEvent`）、`AVPictureInPictureController`、`Process` 桥接分支、`MacUpdates` | 抽离非平台逻辑为共享 `ModelCore`；`#if os(tvOS)` 删除键盘监听 / PiP / `Process` 分支（tvOS 强制 `backend != nil` 原生模式）。                                                                 |
| `Sources/Account.swift`      | `NSImage(data:)`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`                                          | 二维码图片改用类型别名（`UIImage`/`NSImage`）；钥匙串 `kSecAttrAccessible` 用条件编译替代（tvOS 用 `kSecAttrAccessibleAfterFirstUnlock` 或改存 `NSUbiquitousKeyValueStore`/`UserDefaults`）。 |
| `Sources/Comments.swift`     | `NSPasteboard`                                                                                                | `#if os(macOS)` 包裹复制功能，tvOS 移除复制按钮。                                                                                                                                             |
| `Sources/LocalLibrary.swift` | 存储路径 `~/Library/Application Support/HongguoTVMac/`                                                        | tvOS 改 `NSPersistentContainer` / `UserDefaults` / 应用内 `Documents`（tvOS 沙盒无用户级 `Application Support` 可直接写）。                                                                   |

### 4.3 删除 / 排除

| 文件                                             | 原因                                                                                                  |
| ------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| `Sources/MacUpdates.swift`                       | **已决策：tvOS 不更新**。tvOS 构建直接排除此文件（不编译），macOS 端保留不变。                        |
| `Account/MacAccount.swift` 中 `Process` 相关内容 | 若存在 JVM 桥接残留（`HongguoMac.swift` 的 `helper`）需裁剪。实际 `MacAccount` 是纯编排，可复用核心。 |

### 4.4 工程 / 脚本

| 现状                                             | 目标                                                                                                                                                                                                                                       |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 无 `Package.swift`、无 `.xcodeproj`              | **新增**。推荐：抽出 `Package.swift` 定义 `HongguoCore`（逻辑层 library）+ 两个可执行/App target（`macOS`、`tvOS`），或用 `.xcodeproj` 双 target。tvOS 必须经 Xcode 或 `swiftc -target arm64-apple-tvos`（需正确 SDK + App bundle 结构）。 |
| `scripts/build-mac-swift.sh` 硬编码 `macosx13.0` | 新增 `scripts/build-tv-swift.sh`，target `arm64-apple-tvos17.0`（或匹配最低版），并生成 `.app` 结构 + `Info.plist`（`UILaunchScreen`、`UIRequiredDeviceCapabilities` 等 tvOS 必需键）。                                                    |

---

## 5. 播放器详细方案（最大工作量）

macOS 现在：`FullscreenPlayback` 用一个独立 `NSWindow` 全屏，`NSViewRepresentable` 包 `AVPlayerLayer`，`NSEvent` 监听控制显隐。

tvOS 目标结构：

```
TVPlayerView (SwiftUI)
├── AVPlayerViewController (UIViewControllerRepresentable, player = model.player)
│     // 复用 AVAssetResourceLoaderDelegate 解密（Media/ResourceLoader.swift 原样可搬）
└── 自定义悬浮控件覆盖层 (SwiftUI)
      ├── 进度条 (Slider / 自绘)
      ├── 播放/暂停、选集、清晰度、倍速
      ├── 焦点导航 (FocusState + .focusable + onMoveCommand)
      └── 自动隐藏（遥控器任意键唤醒 / 超时隐藏）
```

必须替换的点：

- `AVPlayerLayer` → `AVPlayerViewController`（系统负责渲染 + 手势/遥控器基础交互）。
- `NSEvent` → 遥控器 `onMoveCommand`（方向）、`onPlayPauseCommand`（播放暂停）、`.focusable()`（焦点环）。
- `AVPictureInPictureController` → 删除。
- `AirPlayPicker`（AppKit `NSViewRepresentable`）→ **删除**（**决策：tvOS 无需投屏**）。
- 弹幕/评论悬浮层需要重新设计焦点遍历（tvOS 焦点不能像鼠标悬浮）。
- **弹幕 / 评论只读（已决策）**：只展示内容，不提供输入 / 评论编辑 / 弹幕发送。因此弹幕层无需焦点交互，只需只读渲染 + 时间轴同步。

---

## 6. 登录 / 账户详细方案

- **二维码**：`beginLogin()` 的 `NSImage(data:)` → 类型别名 `#if os(tvOS) UIImage #else NSImage #endif`；`AccountPanel` 的 `Image(nsImage:)` → 条件编译 `Image(uiImage:)`。tvOS 上扫码 UX 建议：显示二维码 + 显著「在手机上扫码后确认」提示；超时/轮询逻辑**原样复用**。
- **钥匙串**：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 在 tvOS 不可用，改为：
  - 条件编译：tvOS 用 `kSecAttrAccessibleAfterFirstUnlock`（或 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）。
  - 或回避钥匙串，登录态存 `NSUbiquitousKeyValueStore`（跨设备 / 本机）。tvOS 设备通常绑定家庭账号，iCloud KV 更贴近使用场景，但需评估敏感凭据落 iCloud 的合规性——**建议 tvOS 端仍走钥匙串 + 后解锁可用**，或用 `UserDefaults`。
- `Account/MacAccount.swift` 的账号编排（扫码/轮询/云片单/收藏/预约/上传进度）**纯逻辑可复用**，仅注意「上传进度」在 tvOS 上可能因无后台执行时机而需要触发策略调整。

---

## 7. 妥协与遗留风险（需产品决策）

1. **自更新（已决策：不做）**：tvOS 只能 App Store / TestFlight 分发；`MacUpdates` 整体移除。
2. **投屏（已决策：不做）**：tvOS 本身是「目标设备」，不做 AirPlay「投出」，删除投屏入口。
3. **弹幕 / 评论（已决策：只读）**：只展示弹幕与评论，不提供输入、编辑、发送等交互。
4. **视频编码**：Apple TV 无 AV1 硬解（同 macOS 策略），`CodecCapabilities` 过滤 AV1 是对的，但需实测 HEVC/AVC 在 tvOS `AVPlayerViewController` 下的播放与解密兼容性（`ResourceLoader` 解密需回归验证）。
5. **遥控器焦点遍历顺序**：tvOS 焦点系统与 macOS 鼠标布局完全不同，所有 View 的焦点优先级都要重配，这是隐蔽但耗时的部分。

---

## 8. 建议实施顺序（里程碑）

1. **M0 工程基建**：建 `Package.swift`，抽出 `HongGuoCore`（Crypto + Protocols + Media + 数据模型）为共享 library；搭建 tvOS target，先空壳 `WindowGroup` 编译通过。
2. **M1 播放验证**：tvOS `AVPlayerViewController` + 复用 `ResourceLoader` 解密，跑通「取流 → 解密 → 播放」最小闭环（这是技术上最大风险点，优先验证）。
3. **M2 首页/搜索/榜单**：tvOS 焦点式网格 UI，接 `HongGuoCore` 的网络层。
4. **M3 播放器完整替换**：悬浮控件、选集、清晰度、倍速、弹幕（只读）、遥控器焦点。
5. **M4 登录**：二维码扫码 + 钥匙串适配。
6. **M5 清理**：删 `MacUpdates`、`Process` 桥接、剪贴板；跑 `test-*` 回归 + 真机 Apple TV 验收。

---

## 9. 一句话总结

**这是「保留 60% 纯逻辑、重写 40% UI 与播放器」的 tvOS 移植**：网络签名/协议/解密/数据模型几乎原样可搬，但入口、窗口/焦点模型、播放器（`AVPlayerLayer`→`AVPlayerViewController`）、画中画、剪贴板、子进程桥接、自更新都要重写或裁剪。**最大技术风险点在 `AVAssetResourceLoaderDelegate` 解密方案在 tvOS `AVPlayerViewController` 下是否兼容**，应作为第一个验证里程碑。

---

## 10. 实施进展（已落地）

> 截止当前提交，已完成的实际代码改动如下。

### 10.1 GUI 收容（路径 B）

- 新建 `Sources/GUI/`，收容全部 macOS 前端：`App.swift`、`ContentView.swift`、`PlayerView.swift`、`MacUpdates.swift`、`HomeViews.swift`、`AccountPanel.swift`、`CommentsPanel.swift`、`DanmakuViews.swift`。
- 新增 `Sources/GUI/ModelPlatform.swift`：用 `extension Model` + 关联对象承载 GUI 专属存储属性（`fullscreenPlayback`/`pipController`/`updates`），实现 `ModelPlatformInterface`。
- 逻辑层（`Sources/*.swift` + `Crypto/` `Protocols/` `Media/` `Account/`）已做到**零 AppKit/SwiftUI/AVKit**，只 import `Foundation`/`Combine`/`Security`/`CommonCrypto`/`zlib`/`AVFoundation`。
- `Model.shutdown()` 改调 `platformInterface` 协议钩子；`start()` 移除了 JVM `Process` 桥接死代码。
- `qrImage: NSImage?` → `qrImageData: Data?`（跨平台）。

### 10.2 跨平台隔离（逻辑层）

- `Account.swift` 的 `SessionKeychain.save()`：`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 用 `#if os(tvOS)` 切换为 `kSecAttrAccessibleAfterFirstUnlock`。
- `MediaFetcher.swift` 的 `saveDecryptedSampleForInspection`（调试用）与 `Log`/`CatalogCache`/`LocalLibrary` 的 `HongguoTVMac` 路径名仅为字符串，不影响 tvOS 编译（暂不改名，后续统一为平台无关名）。

### 10.3 tvOS 骨架（方案 A）

- 新建 `Sources/tvOS/`：
  - `TVApp.swift` — tvOS `@main` 入口（`WindowGroup`）+ `TVPlatformIntegration`（占位实现 `ModelPlatformInterface`）。
  - `TVShelfViews.swift`（含 `TVRootView`/`TVLibraryView`/`TVNavBar` 及各栏目视图）、`TVDesignSystem.swift`（`TVLayout`/`TVFX`/`TVControlState`/`TVControlStyle`）、`TVComponents.swift`（`TVCapsuleButton` 通用胶囊按钮、筛选/页签胶囊、空态/加载态/状态栏）、`TVPosterGrid.swift`（海报网格/卡片）、`TVSections.swift`（栏目三段式容器 + 「我的」数据扩展）——根视图由 `showDetail` 切换首页/播放器，各栏目含焦点导航与搜索。
  - `TVPlayerView.swift` — `AVPlayerViewController` 封装（`TVPlayerViewController: UIViewControllerRepresentable`），复用逻辑层 `ResourceLoader` 取流/解密。
- 新建 `scripts/build-tv-swift.sh`：编译逻辑层 + `Sources/tvOS/`，排除 `Sources/GUI/`，target `arm64-apple-tvos17.0`。
- 新建 `TVInfo.plist`：tvOS 必需的 `UILaunchScreen`、`UIRequiredDeviceCapabilities` 等键。

### 10.4 环境限制与下一步

- **当前开发机只有 Command Line Tools，无完整 Xcode / tvOS SDK**，因此无法在本机编译验证 tvOS 产物。
- 逻辑层已跨平台就绪、tvOS 骨架代码已就位；在安装完整 Xcode（`xcodebuild -downloadPlatform tvOS`）后，运行 `bash scripts/build-tv-swift.sh` 即可首次编译 tvOS。
- 尚未完成（后续里程碑）：M2 完整首页/搜索/榜单焦点导航、M3 播放器悬浮控件、M4 登录扫码 UI。

---

## 11. tvOS 布局规范（1080p · 百分比）

> tvOS 只跑 1920×1080 全屏，布局极简、单层、默认靠左。所有尺寸用**百分比相对屏幕高度（vh）**计算，避免硬编码 pt。

### 11.1 主界面（上→下四区，默认靠左）

| 区       | 内容                                                                 | 占高（vh） | 说明                                |
| -------- | -------------------------------------------------------------------- | ---------- | ----------------------------------- |
| a 导航区 | 首页 / 找剧 / 榜单 + 搜索输入组件                                    | ~8.5vh     | 靠左排页签，右侧搜索输入框          |
| b 筛选区 | 推荐/真人剧/漫剧（首页）、换一批、开始刷剧；找剧/榜单的类型+题材胶囊 | ~6.5vh     | 胶囊平铺靠左，自动换行              |
| c 卡片区 | 剧集卡片（单行横向滚动，海报竖版 2:3）                               | ~70vh      | 卡片占满本区高度，宽度按 2:3 自适应 |
| d 信息区 | 状态/提示文本（单行、不换行、靠左）                                  | ~4.5vh     | `TVStatusBar`                       |

- 剩余高度作为区与区之间的留白（spacing ≈ 2vh）。
- 所有内容 `.frame(maxWidth: .infinity, alignment: .leading)`（默认靠左「start」）。
- 卡片封面高度 = 卡片区高度 − 文字区固定高度，宽度 = 封面高 × 2/3。

### 11.2 播放器（自绘控件）

- **顶部**：返回 + 剧名 + 小字「当前集 / 总集」，靠左。
- **底部**：播放/暂停 → 上一集/下一集 → 选集 → 收藏 → 清晰度 → 倍速 → 相关作品（按使用频率从左到右）；上方一行时间 + 自绘进度条。
- **默认显示**：进入播放页时底部控件即显示可激活；**无任何操作（Remote 无焦点移动/按键）一段时间后自动隐藏**；任一操作（方向键/Play/Pause）重新显示。
- 系统 `AVPlayerViewController.showsPlaybackControls = false`，完全自绘（tvOS 无投屏/画中画/全屏入口）。
- 清晰度默认 1080P。

### 11.3 焦点（tvOS 焦点系统）

- 每个可聚焦元素用 `.focused(_:equals:)` 绑定到**同一 `@FocusState`**（同一 scope），确保遥控器上下左右可在各区之间导航。
- 焦点视觉：聚焦时白底黑字（`white 0.88` + `black 0.88`），未聚焦半透明白字；不使用 `scaleEffect`（避免挤压相邻元素）。
