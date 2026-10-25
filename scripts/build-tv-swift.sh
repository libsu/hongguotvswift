#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# tvOS（Apple TV）客户端构建。需要完整 Xcode（含 AppleTVOS SDK）。
# 编译逻辑层（纯 Foundation/AVFoundation）+ Sources/tvOS 前端，排除 macOS 的 GUI/ 目录。
#
# 用法：
#   bash scripts/build-tv-swift.sh            # 真机（arm64-apple-tvos，App Store/TestFlight 分发）
#   bash scripts/build-tv-swift.sh simulator  # 模拟器（arm64-apple-tvsimulator，供 simctl 本地调试）
#
# 前置：安装完整 Xcode 并确保 tvOS SDK 可用：
#   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
#   xcodebuild -downloadPlatform tvOS   # 若 SDK 未随 Xcode 安装
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-device}"
MIN_TVOS="17.0"

case "$TARGET" in
  simulator|sim)
    SDK_NAME="appletvsimulator"
    TRIPLE="arm64-apple-tvos${MIN_TVOS}-simulator"
    DEST="$ROOT/outputs/tvos-sim/HongGuoTV.app"
    ;;
  device|dev|*)
    SDK_NAME="appletvos"
    TRIPLE="arm64-apple-tvos${MIN_TVOS}"
    DEST="$ROOT/outputs/tvos/HongGuoTV.app"
    ;;
esac

APP="$DEST"

# 解析对应 SDK 路径与版本。
SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk "$SDK_NAME" --show-sdk-version)"

rm -rf "$APP"
mkdir -p "$APP"

# 编译全部逻辑层源码（顶层 + Crypto/Protocols/Media/Account）与 tvOS 前端。
# 排除 macOS 专属的 Sources/GUI/。
# 用 `xcrun --sdk $SDK_NAME swiftc` 让 SDKROOT 环境正确传到链接阶段（避免误链到 macOS SDK）。
xcrun --sdk "$SDK_NAME" swiftc -parse-as-library -O \
    -target "$TRIPLE" \
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
# 注意：纯脚本 ad-hoc 签名（--sign -）在 tvOS 上无法可靠承载 Keychain entitlements，
# 强行加 keychain-access-groups 会导致启动时校验失败（launch-failed, 退出码 64）。
# 因此当前保持无 entitlements 签名；tvOS 真机/正式签名需通过 Xcode 工程注入 keychain-access-groups。
codesign --force --deep --sign - "$APP"

echo "Built ($TARGET): $APP"
if [ "$TARGET" = "device" ] || [ "$TARGET" = "dev" ]; then
    echo "Install/run requires a tvOS device via Xcode (App Store/TestFlight 分发)."
else
    echo "安装并运行到已启动的模拟器："
    echo "  xcrun simctl install booted '$APP'"
    echo "  xcrun simctl launch booted com.hongguotvswift.tv"
fi
