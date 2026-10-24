#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Swift 加密/签名对齐回归：用 signing.json 金标准验证 Swift 侧 Signer。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRYPTO="$ROOT/Sources/Crypto"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$CRYPTO"/*.swift "$ROOT/tests/CryptoSanity.swift" -o "$TMP/crypto"
"$TMP/crypto"

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$CRYPTO"/*.swift "$ROOT/tests/SignerAlignment.swift" -o "$TMP/signer"
"$TMP/signer" "$ROOT/tests/resources/signing.json"

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$CRYPTO"/*.swift "$ROOT/tests/MediaCryptoAlignment.swift" -o "$TMP/media"
"$TMP/media"

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$CRYPTO"/*.swift "$ROOT/Sources/Protocols/CommentSignature.swift" "$ROOT/tests/CommentSignatureAlignment.swift" -o "$TMP/social"
"$TMP/social"

swiftc -parse-as-library -target "$(uname -m)-apple-macosx13.0" -O \
    "$ROOT/Sources/Models.swift" "$CRYPTO"/*.swift "$ROOT/Sources/Account/AccountModels.swift" "$ROOT/Sources/Account/DeviceRegister.swift" "$ROOT/tests/AccountCryptoSanity.swift" -o "$TMP/account"
"$TMP/account"

echo "Swift 加密/签名对齐回归全部通过"
