#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 一键打 macOS 与 tvOS 的 release 包（忽略签名）。
#
# macOS：分别编译 arm64 与 x86_64 两套独立包（.app + .zip + 各自更新清单）。
# tvOS：编译真机 arm64，打包 .app（App Store / TestFlight 使用）。
#
# 版本号：build（CFBundleVersion）自动 +1，CFBundleShortVersionString 由调用者通过 -v 指定（不指定则沿用当前值）。
#
# 用法：
#   bash scripts/release.sh -v 0.2.0 [-n "本次更新说明"]
#
# 产物统一平铺输出到 outputs/release/。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/release"

VERSION=""
NOTES=""
while getopts "v:n:" opt; do
  case "$opt" in
    v) VERSION="$OPTARG" ;;
    n) NOTES="$OPTARG" ;;
    *) echo "用法: $0 -v <版本号> [-n <更新说明>]" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
rm -rf "$OUT"/*

# ---------- macOS 双架构双包 ----------
echo "==> 构建 macOS（arm64 + x86_64）"

# 递增 build（两包共用同一个 build 号）。
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ROOT/Info.plist")
BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$ROOT/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/Info.plist"
else
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
fi

SRC_COMMON=(
  "$ROOT/Sources/"*.swift
  "$ROOT/Sources/"Crypto/*.swift
  "$ROOT/Sources/"Protocols/*.swift
  "$ROOT/Sources/"Media/*.swift
  "$ROOT/Sources/"Account/*.swift
  "$ROOT/Sources/"GUI/*.swift
)

for ARCH in arm64 x86_64; do
  echo "  -> 编译 $ARCH"
  APP="$OUT/HongGuo-$ARCH.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

  swiftc -parse-as-library -O -target "$ARCH-apple-macosx13.0" "${SRC_COMMON[@]}" -o "$APP/Contents/MacOS/HongGuo"

  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
  cp "$ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
  cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
  cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"

  ZIP="$OUT/HongGuo-$ARCH-$VERSION-build$BUILD.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  # 生成该架构的更新清单 mac-update-<arch>.json。
  if [ -n "$NOTES" ]; then
    python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ZIP" --arch "$ARCH" --notes "$NOTES"
  else
    python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ZIP" --arch "$ARCH"
  fi
done

# ---------- tvOS 真机 ----------
echo "==> 构建 tvOS 真机"
TV_BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$ROOT/TVInfo.plist")
TV_BUILD=$((TV_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $TV_BUILD" "$ROOT/TVInfo.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$ROOT/TVInfo.plist"
fi

MIN_TVOS="17.0"
SDK_PATH="$(xcrun --sdk appletvos --show-sdk-path)"
TV_APP="$OUT/HongGuoTV.app"
rm -rf "$TV_APP"
mkdir -p "$TV_APP"

xcrun --sdk appletvos swiftc -parse-as-library -O \
  -target "arm64-apple-tvos${MIN_TVOS}" \
  -sdk "$SDK_PATH" \
  "$ROOT/Sources/"*.swift \
  "$ROOT/Sources/"Crypto/*.swift \
  "$ROOT/Sources/"Protocols/*.swift \
  "$ROOT/Sources/"Media/*.swift \
  "$ROOT/Sources/"Account/*.swift \
  "$ROOT/Sources/"tvOS/*.swift \
  -o "$TV_APP/HongGuoTV"

cp "$ROOT/Resources/AppIcon.icns" "$TV_APP/AppIcon.icns" 2>/dev/null || true
cp "$ROOT/TVInfo.plist" "$TV_APP/Info.plist"
cp "$ROOT/THIRD_PARTY.md" "$TV_APP/THIRD_PARTY.md" 2>/dev/null || true
cp "$ROOT/LICENSE" "$TV_APP/LICENSE" 2>/dev/null || true
cp "$ROOT/NOTICE.md" "$TV_APP/NOTICE.md" 2>/dev/null || true

echo ""
echo "release 构建完成："
echo "  macOS arm64:  $OUT/HongGuo-arm64.app  ($OUT/HongGuo-arm64-$VERSION-build$BUILD.zip)"
echo "  macOS x86_64: $OUT/HongGuo-x86_64.app ($OUT/HongGuo-x86_64-$VERSION-build$BUILD.zip)"
echo "  tvOS:         $TV_APP"
echo "  版本 $VERSION (mac build $BUILD, tv build $TV_BUILD)"
