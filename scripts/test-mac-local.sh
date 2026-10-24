#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT
swiftc -parse-as-library "$ROOT/Sources/Models.swift" "$ROOT/Sources/LocalLibrary.swift" "$ROOT/tests/LibraryTests.swift" -o "$TESTDIR/library"
"$TESTDIR/library"
swiftc -parse-as-library "$ROOT/Sources/MacUpdates.swift" "$ROOT/tests/MacUpdateTests.swift" -o "$TESTDIR/updates"
"$TESTDIR/updates"
SOURCES=()
for source in "$ROOT/Sources/"*.swift "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift; do
    if [ "$(basename "$source")" != App.swift ]; then SOURCES+=("$source"); fi
done
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/CloudHistoryTests.swift" -o "$TESTDIR/cloud"
"$TESTDIR/cloud"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/PlayerControlsTests.swift" -o "$TESTDIR/controls"
"$TESTDIR/controls"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/HomeFeedTests.swift" -o "$TESTDIR/feed"
"$TESTDIR/feed"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/CommentsTests.swift" -o "$TESTDIR/comments"
"$TESTDIR/comments"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/DanmakuTests.swift" -o "$TESTDIR/danmaku"
"$TESTDIR/danmaku"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/CommentThreadTests.swift" -o "$TESTDIR/comment-thread"
"$TESTDIR/comment-thread"
swiftc -parse-as-library "${SOURCES[@]}" "$ROOT/tests/CodecSelectionTests.swift" -o "$TESTDIR/codec"
"$TESTDIR/codec"
