#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# v04.10.03（v5）播放签名对齐回归：用上游固定向量校验 Swift 侧的 AesV3 / hashF13。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$ROOT/Sources/Crypto"/*.swift "$ROOT/tests/SignerV5Alignment.swift" -o "$TMP/signer-v5"
"$TMP/signer-v5" "$ROOT/tests/resources/signing-v5-f13.json" \
    "$ROOT/tests/resources/signing-v5-carrier.json" "$ROOT/tests/resources/signing-v5-medusa.json"
