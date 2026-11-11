#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 探针：device_level 2/1/3 对返回档位的影响，每级可指定请求次数。
# 会发起真实网络请求。
#
# 用法：bash scripts/probe-device-level.sh [剧集id] [每级次数]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/device-level-probe"
mkdir -p "$OUT"

SOURCES=()
for source in "$ROOT/Sources/"*.swift "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift \
               "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift; do
    SOURCES+=("$source")
done

swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/DeviceLevelProbe.swift" -o "$OUT/probe"
exec "$OUT/probe" "$@"
