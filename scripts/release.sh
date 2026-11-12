#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 一键打 macOS 与 tvOS 的 release 包（忽略签名）。
#
# 产物（全部平铺在 outputs/release/）：
#   HongGuo-macOS-<版本>-build<N>.zip            通用包，macOS 自更新用
#   HongGuo-macOS-universal-<版本>-build<N>.dmg  通用包，手动安装用
#   mac-update.json                              自更新清单（不区分架构）
#   HongGuo-tvOS-<版本>-build<N>.zip             tvOS 归档
#
# .app 与单架构二进制都是打包中间态，放在临时目录，脚本结束自动清理。
#
# 版本号：build（CFBundleVersion）自动 +1；CFBundleShortVersionString 由 -v 指定，不指定则沿用。
#
# 用法：bash scripts/release.sh -v 0.2.0 [-n "本次更新说明"]
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
rm -rf "$OUT"/*

# ---------- 公共 ----------

SRC_COMMON=(
  "$ROOT/Sources/"*.swift
  "$ROOT/Sources/"Crypto/*.swift
  "$ROOT/Sources/"Protocols/*.swift
  "$ROOT/Sources/"Media/*.swift
  "$ROOT/Sources/"Account/*.swift
)

# 签名：有证书时用证书（稳定 keychain ACL），否则 ad-hoc。
sign_app() {
  local target="$1"
  if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
    codesign --force --deep --options runtime --sign "$CODE_SIGN_IDENTITY" \
      --entitlements "$ROOT/MacKeychain.entitlements" "$target"
  else
    codesign --force --deep --sign - "$target"
  fi
}

# 读取 plist 当前 build 并 +1 写回；$2 非空时同时更新版本号。结果写入全局 BUILD。
bump_build() {
  local plist="$1" version="$2"
  BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")
  BUILD=$((BUILD + 1))
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$plist"
  if [ -n "$version" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
  fi
}

# ---------- macOS ----------

bump_build "$ROOT/Info.plist" "$VERSION"
if [ -z "$VERSION" ]; then
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")
fi
MAC_BUILD="$BUILD"

echo "==> 构建 macOS 通用包（arm64 + x86_64）"
for ARCH in arm64 x86_64; do
  echo "  -> 编译 $ARCH"
  swiftc -parse-as-library -O -target "$ARCH-apple-macosx13.0" "${SRC_COMMON[@]}" \
    "$ROOT/Sources/"GUI/*.swift -o "$WORK/HongGuo-$ARCH"
done

APP="$WORK/HongGuo.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$WORK/HongGuo-arm64" "$WORK/HongGuo-x86_64" -output "$APP/Contents/MacOS/HongGuo"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/THIRD_PARTY.md" "$APP/Contents/Resources/THIRD_PARTY.md"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"
sign_app "$APP"

echo "==> 打包 zip 与更新清单"
MAC_ZIP="$OUT/HongGuo-macOS-$VERSION-build$MAC_BUILD.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$MAC_ZIP"
# macOS 自带 bash 3.2：空数组配 "${arr[@]}" 在 set -u 下会报未绑定，因此分两条命令。
if [ -n "$NOTES" ]; then
  python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$MAC_ZIP" --notes "$NOTES"
else
  python3 "$ROOT/scripts/prepare-mac-release.py" --app "$APP" --zip "$MAC_ZIP"
fi

echo "==> 打包 DMG"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/HongGuo.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/HongGuo-macOS-universal-$VERSION-build$MAC_BUILD.dmg"
hdiutil create -volname "HongGuo" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
sign_app "$DMG"

# ---------- tvOS ----------

bump_build "$ROOT/TVInfo.plist" "$VERSION"
TV_BUILD="$BUILD"

# 有签名身份时走 xcodebuild 归档导出 .ipa（可上传 TestFlight）；
# 没有时降级为 ad-hoc 直编，仅供本地调试安装，不可分发。
if security find-identity -v -p codesigning | grep -q "Apple Distribution"; then
  echo "==> tvOS：签名身份可用，xcodebuild 归档导出 ipa"
  xcodegen generate --spec "$ROOT/project.yml" --project "$WORK" >/dev/null
  ARCHIVE="$WORK/HongGuoTV.xcarchive"
  xcodebuild -project "$WORK/HongGuoTV.xcodeproj" \
    -target HongGuoTV -sdk appletvos -configuration Release -arch arm64 \
    ONLY_ACTIVE_ARCH=NO -archivePath "$ARCHIVE" archive >/dev/null
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/ExportOptions.plist" -exportPath "$OUT/tvos-export" >/dev/null
  TV_ARTIFACT="$(find "$OUT/tvos-export" -name '*.ipa' -maxdepth 1 | head -1)"
  if [ -z "$TV_ARTIFACT" ]; then
    echo "错误：未产出 .ipa，请检查签名与 ExportOptions.plist" >&2
    exit 1
  fi
  echo "  已导出 $(basename "$TV_ARTIFACT")（上传 TestFlight 请用 scripts/release-tvos.sh upload）"
else
  echo "==> tvOS：无签名身份，ad-hoc 直编（仅供本地调试，不可分发）"
  TV_APP="$WORK/HongGuoTV.app"
  mkdir -p "$TV_APP"
  xcrun --sdk appletvos swiftc -parse-as-library -O \
    -target "arm64-apple-tvos17.0" \
    -sdk "$(xcrun --sdk appletvos --show-sdk-path)" \
    "${SRC_COMMON[@]}" "$ROOT/Sources/"tvOS/*.swift \
    -o "$TV_APP/HongGuoTV"

  cp "$ROOT/Resources/AppIcon.icns" "$TV_APP/AppIcon.icns"
  cp "$ROOT/TVInfo.plist" "$TV_APP/Info.plist"
  cp "$ROOT/THIRD_PARTY.md" "$TV_APP/THIRD_PARTY.md"
  cp "$ROOT/LICENSE" "$TV_APP/LICENSE"
  cp "$ROOT/NOTICE.md" "$TV_APP/NOTICE.md"

  TV_ARTIFACT="$OUT/HongGuo-tvOS-$VERSION-build$TV_BUILD.zip"
  ditto -c -k --sequesterRsrc --keepParent "$TV_APP" "$TV_ARTIFACT"
fi

# ---------- 汇总 ----------

echo ""
echo "release 构建完成（$VERSION，mac build $MAC_BUILD，tv build $TV_BUILD）："
for f in "$MAC_ZIP" "$DMG" "$TV_ARTIFACT" "$OUT/mac-update.json"; do
  echo "  $(basename "$f")"
done
