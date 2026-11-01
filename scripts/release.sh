#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 一键打 macOS 与 tvOS 的 release 包（忽略签名）。
#
# macOS：分别编译 arm64 与 x86_64 两套独立包（.app + .zip + 各自更新清单），
#        再用 lipo 合并为通用包，额外产出一个已签名的 DMG 供手动分发。
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
done

# 把资源与 Info.plist 拷进 .app（通用包与单架构包共用）。
copy_resources() {
  local app="$1"
  cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  cp "$ROOT/Info.plist" "$app/Contents/Info.plist"
  cp "$ROOT/THIRD_PARTY.md" "$app/Contents/Resources/THIRD_PARTY.md"
  cp "$ROOT/LICENSE" "$app/Contents/Resources/LICENSE"
  cp "$ROOT/NOTICE.md" "$app/Contents/Resources/NOTICE.md"
}

# 签名：与 build-mac-swift.sh 一致，有证书时用证书（稳定 keychain ACL），否则 ad-hoc。
sign_app() {
  local app="$1"
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" \
      --entitlements "$ROOT/MacKeychain.entitlements" "$app"
  else
    codesign --force --deep --sign - "$app"
  fi
}

# ---------- macOS 通用包（lipo 合并） ----------
# DMG 对外只发一个通用包；两套单架构包仍各自出 zip 与更新清单，供自更新按架构拉取。
echo "==> 合并通用包（arm64 + x86_64）"
UNIVERSAL_APP="$OUT/HongGuo.app"
rm -rf "$UNIVERSAL_APP"
mkdir -p "$UNIVERSAL_APP/Contents/MacOS" "$UNIVERSAL_APP/Contents/Resources"
lipo -create \
  "$OUT/HongGuo-arm64.app/Contents/MacOS/HongGuo" \
  "$OUT/HongGuo-x86_64.app/Contents/MacOS/HongGuo" \
  -output "$UNIVERSAL_APP/Contents/MacOS/HongGuo"
copy_resources "$UNIVERSAL_APP"
sign_app "$UNIVERSAL_APP"

for ARCH in arm64 x86_64; do
  APP="$OUT/HongGuo-$ARCH.app"
  copy_resources "$APP"
  sign_app "$APP"

  ZIP="$OUT/HongGuo-$ARCH-$VERSION-build$BUILD.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

  # 生成该架构的更新清单 mac-update-<arch>.json。
  if [ -n "$NOTES" ]; then
    python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ZIP" --arch "$ARCH" --notes "$NOTES"
  else
    python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$ZIP" --arch "$ARCH"
  fi
done

# ---------- macOS 通用 DMG ----------
# 暂存目录内放 .app 与 /Applications 软链，用户拖入即完成安装。
echo "==> 打包通用 DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$UNIVERSAL_APP" "$STAGE/HongGuo.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/HongGuo-universal-$VERSION-build$BUILD.dmg"
rm -f "$DMG"
hdiutil create -volname "HongGuo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
sign_app "$DMG"
rm -rf "$STAGE"

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

# tvOS 无自更新（App Store / TestFlight 分发），zip 仅用于归档/备份。
ditto -c -k --sequesterRsrc --keepParent "$TV_APP" "$OUT/HongGuoTV-$VERSION-build$TV_BUILD.zip"

echo ""
echo "release 构建完成："
echo "  macOS 通用 DMG: $DMG"
echo "  macOS 通用 app: $UNIVERSAL_APP"
echo "  macOS arm64:  $OUT/HongGuo-arm64.app  ($OUT/HongGuo-arm64-$VERSION-build$BUILD.zip)"
echo "  macOS x86_64: $OUT/HongGuo-x86_64.app ($OUT/HongGuo-x86_64-$VERSION-build$BUILD.zip)"
echo "  tvOS:         $TV_APP  ($OUT/HongGuoTV-$VERSION-build$TV_BUILD.zip)"
echo "  版本 $VERSION (mac build $BUILD, tv build $TV_BUILD)"
