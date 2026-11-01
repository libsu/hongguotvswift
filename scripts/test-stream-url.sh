#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 取流解析回归测试：直接调用 ContentRepository 的真实解析函数。
# 不依赖 GUI，也不发起网络请求（只构造响应字典喂给解析函数）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/stream-url-test"
mkdir -p "$OUT"

SOURCES=()
for source in "$ROOT/Sources/"*.swift "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift "$ROOT/Sources/"GUI/*.swift; do
    if [ "$(basename "$source")" != App.swift ]; then SOURCES+=("$source"); fi
done

swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/StreamUrlDetectionTests.swift" -o "$OUT/stream-url"

"$OUT/stream-url"
echo "取流解析回归全部通过"

# 崩溃探测：非 http 且长度 % 4 == 1 的 main_url 会走 lenientBase64 → decode64，
# 后者对非法长度直接 precondition（终止进程），try? 捕不住。
# 该场景必须独立进程运行，据此区分「已修复」与「仍会闪退」。
if "$OUT/stream-url" --crash-probe; then
    echo "崩溃探测：已具备长度保护"
else
    echo "崩溃探测：仍会崩溃（decode64 precondition），见 docs/取流解析TODO.md 第 2 节"
    exit 1
fi
