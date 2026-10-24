# 红果（macOS Swift 客户端）

红果短剧的 macOS 原生客户端，Swift + SwiftUI + AVKit 实现，单二进制打包成 `.app`，不依赖 JVM 或 Gradle。

支持 Apple Silicon（arm64）与 macOS 13+，使用本机临时签名（未做 Apple 公证），供本机或个人分发使用。

## 功能

- 首页刷剧：官方综合推荐，支持「推荐 / 真人剧 / 漫剧」频道切换、换一批、上一部 / 下一部，首集试播（点「开始刷剧」才播放，不进入即自动播放）。
- 搜索：全部剧集搜索、分页。
- 找剧：真人剧、漫剧、AI 剧，题材筛选（平铺点选，自动换行）。
- 榜单：综合 / 漫剧 / 真人剧 / AI 热播榜，含排名与热度，多页并发加载。
- 播放器：沉浸式全屏播放，顶部/底部悬浮控件自动隐藏，进度条按帧顺滑刷新，支持 0.5～2 倍速、480/720/1080P 上限（默认自动选最高清晰度）、画中画、投屏、选集面板、评论、弹幕。
- 收藏与历史：本机片单（收藏、历史）与红果账号片单（账户收藏 / 历史 / 已上线预约 / 待上线预约）分离；收藏按钮按登录态路由到本机或账户。
- 账户：红果官方扫码登录，登录态存于 macOS 钥匙串。
- 评论与弹幕：本集评论（下滑连续加载）、整剧剧评、时间轴弹幕（暂停/拖动/倍速同步）。
- 更新：检查、下载、校验 Mac 更新包（`mac-stable` 独立发布，不设 Latest）。

## 目录结构

```
hongguotvswift/
├── Sources/          # 纯 Swift 源码（Crypto / Protocols / Media / Account 子目录）
├── Resources/        # AppIcon.icns
├── tests/            # 回归测试 + signing.json 金标准
├── scripts/          # 构建与测试脚本
├── Info.plist
├── LICENSE / NOTICE.md / THIRD_PARTY.md
└── README.md
```

## 构建与运行

需 Xcode Command Line Tools（`swiftc`），仅支持 Apple Silicon（arm64）。

```sh
# 构建（产出 outputs/mac/HongGuo.app 与测试 zip）
bash scripts/build-mac-swift.sh
```

打开 `outputs/mac/HongGuo.app` 或拖入「应用程序」。

## 测试

```sh
# 加密 / 签名对齐回归（含 signing.json 金标准）
bash scripts/test-mac-crypto.sh

# 编码择优 / AV1 过滤 / 降级顺序 / VideoTracks 回归
bash scripts/test-mac-codec.sh

# 本机记录、云历史、播放控件、评论、弹幕等隔离回归（不联网）
bash scripts/test-mac-local.sh
```

## 数据和账号

- 本机记录存于 `~/Library/Application Support/HongguoTVMac/library.json`；找剧/榜单的缓存存于同目录 `catalog/`（限量缓存，进入栏目先上缓存「架子」，后台刷新）。
- 登录态只存于 macOS 钥匙串，不写盘、不出现在日志或文档里。
- 手机号、验证码、密码、会话 Cookie 等凭据不会落日志或文档。

## 更新发布

构建脚本自动生成 `.zip` 与 `mac-update.json`。客户端固定读取 GitCode Release `mac-stable` 的 `mac-update.json`（`Info.plist` 的 `CFBundleIdentifier` 为 `com.hongguotv.mac`，正式发布递增 `CFBundleVersion`；调试期间保持版本号不变、以文件名区分 debug 包）。

- 不要把 `mac-update.json` 改名为 `update.json`，也不要用 Mac 包覆盖其它平台附件。
- 更新只允许 GitCode 及其官方文件 CDN 的 HTTPS 跳转，校验大小与 SHA256 后保存到下载目录，不自动执行或替换应用。

## 许可

GPL-3.0-only。构建产物包含 LICENSE / NOTICE；分发时需提供对应源码提交。
