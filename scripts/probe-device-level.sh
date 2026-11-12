#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 探针：device_level 3 与 1 对不同剧集的档位影响。会发起真实网络请求。
#
# 用法：bash scripts/probe-device-level.sh [剧集id...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/device-level-probe"
mkdir -p "$OUT"

SOURCES=()
for source in "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift \
               "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift; do
    SOURCES+=("$source")
done

swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/Sources/Models.swift" "$ROOT/Sources/Diagnostics.swift" \
    "$ROOT/tests/DeviceLevelProbe.swift" -o "$OUT/probe"

exec "$OUT/probe" "$@"
