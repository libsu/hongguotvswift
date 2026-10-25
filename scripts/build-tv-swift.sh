#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# tvOS（Apple TV）客户端构建。需要完整 Xcode（含 AppleTVOS SDK）。
# 编译逻辑层（纯 Foundation/AVFoundation）+ Sources/tvOS 前端，排除 macOS 的 GUI/ 目录。
#
# 前置：安装完整 Xcode 并确保 tvOS SDK 可用：
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#   xcodebuild -downloadPlatform tvOS   # 若 SDK 未随 Xcode 安装
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/outputs/tvos"
APP="$DEST/HongGuoTV.app"

# 解析 AppleTVOS SDK 路径与版本。
SDK_PATH="$(xcrun --sdk appletvos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk appletvos --show-sdk-version)"
MIN_TVOS="17.0"

rm -rf "$APP"
mkdir -p "$APP"

# 编译全部逻辑层源码（顶层 + Crypto/Protocols/Media/Account）与 tvOS 前端。
# 排除 macOS 专属的 Sources/GUI/。
# 用 `xcrun --sdk appletvos swiftc` 让 SDKROOT 环境正确传到链接阶段（避免误链到 macOS SDK）。
xcrun --sdk appletvos swiftc -parse-as-library -O \
    -target "arm64-apple-tvos${MIN_TVOS}" \
    -sdk "$SDK_PATH" \
    "$ROOT/Sources/"*.swift \
    "$ROOT/Sources/"Crypto/*.swift \
    "$ROOT/Sources/"Protocols/*.swift \
    "$ROOT/Sources/"Media/*.swift \
    "$ROOT/Sources/"Account/*.swift \
    "$ROOT/Sources/"tvOS/*.swift \
    -o "$APP/HongGuoTV"

# 复制资源与 tvOS Info.plist。
cp "$ROOT/Resources/AppIcon.icns" "$APP/AppIcon.icns" 2>/dev/null || true
cp "$ROOT/TVInfo.plist" "$APP/Info.plist"
cp "$ROOT/THIRD_PARTY.md" "$APP/THIRD_PARTY.md" 2>/dev/null || true
cp "$ROOT/LICENSE" "$APP/LICENSE" 2>/dev/null || true
cp "$ROOT/NOTICE.md" "$APP/NOTICE.md" 2>/dev/null || true

# 临时签名（同 macOS 策略：本机/个人分发，未公证）。
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
echo "Install/run requires a tvOS device or tvOS Simulator via Xcode."
