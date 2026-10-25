# 第三方声明

本仓库是红果短剧的纯 Swift 客户端（macOS / tvOS）。以下列出本项目参考或改写的第三方来源，以及随源码分发的第三方许可。

## 协议与签名

内容请求签名（gorgon / helios / medusa / x-argus）、Spade URL / key 处理、MP4 CENC 媒体解密，参考以下 GPL-3.0 源码的 Kotlin 实现移植为 Swift：

- drpys, `spider/js/红果果[短].js`
- https://github.com/woshishiq1/drpys/tree/22261adfa31435e3b3ef5a730b8a2a75bcaf1715
- 本仓库对照源：`../server/vendor/hongguo.cjs`，取回于 2026-09-21。

实现要点：签名只选择已验证的 hash branch 0；加密媒体通过媒体层自定义 scheme + `AVAssetResourceLoaderDelegate` 直接取流并样本级解密；增加样本边界检查、子样本处理和 AVC 原始编码恢复。对应源码位于 `Sources/Crypto/` 与 `Sources/Media/`。

## 播放兼容

本地播放兼容修改参考 FanchangWang 的 GPL-3.0 项目贡献：
https://github.com/N3urda/hongguoTV/pull/22 。

播放请求使用独立设备标识和无签名请求，复用本项目原有的响应大小限制、请求取消及媒体解析逻辑。

## 账号登录

账号登录功能参考 charlie901208/HGTV 的 `feat/phone-login` 分支（GPL-3.0-only）：
https://github.com/charlie901208/HGTV/tree/feat/phone-login 。

设备注册（`Sources/Account/DeviceRegister.swift`）与官网扫码登录会话（`Sources/Account/WebLogin.swift`）由该分支移植并改写；账号读写的路径和字段参照其 `Account.kt`、`ContentRepository.kt`。本地实现补充有界响应读取、登录态加密存储（钥匙串）、错误验证码停止重试与云端精确进度字段保留；账号界面和同步调度为本地实现。

## 评论

本集评论的协议字段参考 yangbin1322/hongguo-player 公开发行包中的接口线索（https://github.com/yangbin1322/hongguo-player/releases/tag/v1.2.11），以匿名请求核实数据来源和游标推进后独立实现；未纳入该客户端的代码、资源或二进制。

## 弹幕签名

弹幕评论签名的通用 Argus / Simon 结构参考并改写自 tr4cex/TikTok-Encryption（MIT）：
https://github.com/tr4cex/TikTok-Encryption

许可证全文见下文「MIT License」。

## 其他

- SM3 国密哈希为本仓库纯 Swift 实现（GM/T 0004-2012，`Sources/Crypto/SM3.swift`）；此前 Bouncy Castle SM3 参考：https://github.com/bcgit/bc-java — MIT
- 应用图标沿用本仓库素材。这里的应用不是内容平台官方客户端。

---

# MIT License

Copyright (c) 2024 TikTok Encryption Project

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

EDUCATIONAL USE DISCLAIMER:
This software is intended for educational and research purposes only.
Users are responsible for ensuring their use complies with applicable laws
and terms of service. The authors disclaim any responsibility for misuse
of this software.
