#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 编码择优 / AV1 过滤 / 降级顺序 / VideoTracks 回归测试。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/codec-test"
mkdir -p "$OUT"

SOURCES=()
for source in "$ROOT/Sources/"*.swift "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift "$ROOT/Sources/"GUI/*.swift; do
    if [ "$(basename "$source")" != App.swift ]; then SOURCES+=("$source"); fi
done

swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/CodecSelectionTests.swift" -o "$OUT/codec"
"$OUT/codec"
echo "编码选择回归全部通过"
