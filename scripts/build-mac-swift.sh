#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 独立 macOS Swift 客户端构建。
# 只编译 Sources 下的全部 Swift 源码 + 资源，打成一个单 Swift 二进制 .app。
set -euo pipefail
# 兼容 Apple Silicon (arm64) 与 Intel (x86_64)，目标三元组根据本机架构动态确定。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/outputs/mac"
APP="$DEST/HongGuo.app"

# 清掉旧的输出 bundle，避免旧产物混入。
rm -rf "$APP"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 编译全部 Swift 源码（顶层 + Crypto/Protocols/Media/Account 子目录）。
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" \
    "$ROOT/Sources/"*.swift \
    "$ROOT/Sources/"Crypto/*.swift \
    "$ROOT/Sources/"Protocols/*.swift \
    "$ROOT/Sources/"Media/*.swift \
    "$ROOT/Sources/"Account/*.swift \
    "$ROOT/Sources/"GUI/*.swift \
    -o "$APP/Contents/MacOS/HongGuo"

cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"

# 签名身份：优先使用开发者证书（提供稳定的 keychain ACL 身份，避免每次启动弹钥匙串授权）。
# 未配置证书时回退到 ad-hoc 签名（代价是每次重建 CDHash 变化，见 docs/钥匙串逻辑.md）。
# 注意：ad-hoc 签名无 TeamID，不能携带 keychain-access-groups 等受限 entitlement，
# 否则 AMFI 会拒绝加载（Restricted entitlements not validated → launchd spawn failed，App 打不开）。
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" \
        --entitlements "$ROOT/MacKeychain.entitlements" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ARCHIVE="$DEST/HongGuo-$(uname -m)-$VERSION-build$BUILD-test.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ARCHIVE" --arch "$(uname -m)"
echo "$APP"
echo "$ARCHIVE"
