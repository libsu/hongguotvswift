#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 独立 macOS Swift 客户端构建（脱离 JVM / Gradle / Kotlin）。
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

codesign --force --deep --sign - "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
ARCHIVE="$DEST/HongGuo-$(uname -m)-$VERSION-build$BUILD-test.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ARCHIVE"
echo "$APP"
echo "$ARCHIVE"
