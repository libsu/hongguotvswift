#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 探针：按剧集 id 调生产入口 streamLadder，验证 v5 播放签名。会发起真实网络请求。
#
# 用法：bash scripts/probe-v5-playback.sh [剧集id...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/v5-probe"
mkdir -p "$OUT"

SOURCES=()
for dir in Crypto Protocols Media Account; do
    for source in "$ROOT/Sources/$dir"/*.swift; do SOURCES+=("$source"); done
done

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
    "${SOURCES[@]}" "$ROOT/Sources/Models.swift" "$ROOT/Sources/Diagnostics.swift" \
    "$ROOT/tests/V5PlaybackProbe.swift" -o "$OUT/probe" 2>&1 | grep -E "error:" || true

exec "$OUT/probe" "$@"
