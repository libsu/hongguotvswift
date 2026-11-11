#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Argus/Ladon 签名回归：与上游固定向量逐字节对齐，不发起网络请求。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/outputs/mac/argus-test"
mkdir -p "$OUT"

SOURCES=()
for source in "$ROOT/Sources/"Crypto/*.swift; do
    SOURCES+=("$source")
done

swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/ArgusTests.swift" -o "$OUT/argus-test"

"$OUT/argus-test"
