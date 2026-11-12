#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# tvOS TestFlight / App Store 归档与导出。
#
# 与 scripts/build-tv-swift.sh 的分工：
#   build-tv-swift.sh   swiftc 直编 + ad-hoc 签名，用于本地调试安装
#   本脚本              xcodebuild archive + exportArchive，产出可上传的 .ipa
#
# 前置（需手工完成，脚本无法代劳）：
#   1. Xcode 登录 Apple Developer 账号（Settings → Accounts）
#   2. App Store Connect 注册 Bundle ID：com.hongguotvswift.tv
#   3. 本机存在 Apple Distribution 证书与 tvOS App Store Provisioning Profile
#   验证：security find-identity -v -p codesigning
#
# 用法：
#   bash scripts/release-tvos.sh              # 归档并导出 .ipa
#   bash scripts/release-tvos.sh upload       # 归档、导出并上传 TestFlight
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/release"
ARCHIVE="$OUT/HongGuoTV.xcarchive"
EXPORT_DIR="$OUT/tvos-export"

UPLOAD=""
if [ "${1:-}" = "upload" ]; then UPLOAD=1; fi

# 签名前置检查：没有身份就提前报错，避免等到 archive 末尾才失败。
if ! security find-identity -v -p codesigning | grep -q "Apple Distribution\|Apple Development"; then
  echo "错误：本机没有可用的代码签名身份。" >&2
  echo "      请在 Xcode → Settings → Accounts 登录 Apple Developer 账号，并下载证书。" >&2
  echo "      如需先验证工程能否编译：bash scripts/build-tv-swift.sh" >&2
  exit 1
fi

mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$EXPORT_DIR"

echo "==> 归档 tvOS"
# 用 -target 而非 -scheme：本机未安装 tvOS 模拟器运行时时，-scheme + destination 会报找不到目标。
xcodebuild -project "$ROOT/HongGuoTV.xcodeproj" \
  -target HongGuoTV \
  -sdk appletvos \
  -configuration Release \
  -arch arm64 \
  ONLY_ACTIVE_ARCH=NO \
  -archivePath "$ARCHIVE" \
  archive

echo "==> 导出 ipa"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$ROOT/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR"

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)"
if [ -z "$IPA" ]; then
  echo "错误：导出未产出 .ipa，请检查 ExportOptions.plist 与签名配置。" >&2
  exit 1
fi
echo "已导出：$IPA"

if [ -n "$UPLOAD" ]; then
  KEY_ID="${ASC_API_KEY_ID:-}"
  ISSUER="${ASC_API_ISSUER_ID:-}"
  if [ -z "$KEY_ID" ] || [ -z "$ISSUER" ]; then
    echo "错误：上传需要 App Store Connect API Key。" >&2
    echo "      设置环境变量 ASC_API_KEY_ID 与 ASC_API_ISSUER_ID，" >&2
    echo "      并把 AuthKey_\${ASC_API_KEY_ID}.p8 放到 ~/.appstoreconnect/private_keys/。" >&2
    exit 1
  fi
  echo "==> 上传 TestFlight"
  xcrun altool --upload-app -f "$IPA" -t appletvos \
    --apiKey "$KEY_ID" --apiIssuer "$ISSUER"
fi

echo ""
echo "完成：$IPA"
