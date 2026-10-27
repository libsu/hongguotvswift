#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 本地回归：逐个编译并运行 tests/ 下的测试。
# 单个套件失败不会中断其余套件——全部跑完后汇总，任一失败则整体以非 0 退出。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

FAILED=()
PASSED=()

# run_suite <名称> <源文件...>：编译并运行一个测试套件
run_suite() {
    local suite_name="$1"; shift
    local binary="$TESTDIR/$suite_name"
    if ! swiftc -parse-as-library "$@" -o "$binary"; then
        echo "FAIL  $suite_name（编译失败）" >&2
        FAILED+=("$suite_name")
        return
    fi
    if "$binary"; then
        PASSED+=("$suite_name")
    else
        echo "FAIL  $suite_name（运行失败）" >&2
        FAILED+=("$suite_name")
    fi
}

run_suite library "$ROOT/Sources/Models.swift" "$ROOT/Sources/LocalLibrary.swift" "$ROOT/tests/LibraryTests.swift"
run_suite updates "$ROOT/Sources/MacUpdates.swift" "$ROOT/tests/MacUpdateTests.swift"

# 需要完整 App 源码的套件：除入口 App.swift 外的全部源文件
SOURCES=()
for source in "$ROOT/Sources/"*.swift "$ROOT/Sources/"Crypto/*.swift "$ROOT/Sources/"Protocols/*.swift "$ROOT/Sources/"Media/*.swift "$ROOT/Sources/"Account/*.swift "$ROOT/Sources/"GUI/*.swift; do
    if [ "$(basename "$source")" != App.swift ]; then SOURCES+=("$source"); fi
done

for suite in CloudHistoryTests PlayerControlsTests HomeFeedTests CommentsTests DanmakuTests CommentThreadTests CodecSelectionTests; do
    run_suite "$suite" "${SOURCES[@]}" "$ROOT/tests/$suite.swift"
done

echo
echo "通过 ${#PASSED[@]} 个套件；失败 ${#FAILED[@]} 个。"
if [ "${#FAILED[@]}" -gt 0 ]; then
    printf '  失败：%s\n' "${FAILED[@]}"
    exit 1
fi
