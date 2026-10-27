#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# 死代码守护：校验一批标注为「暂未接入 / 无调用方 / 保留以备」的符号在仓库内确实零调用。
# 若日后有人意外引用或（更糟）删除了定义，本脚本会报错，提醒同步更新本清单或清理代码。
#
# 匹配策略：每个候选用一条「引用形态」正则（覆盖调用点写法），在 Sources/ 与 tests/ 中搜索，
# 排除定义所在文件后，若仍有命中则判定「存在真实引用」，视为非死代码 → 失败。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

# 每条记录： 名称 | 定义文件（相对 ROOT） | 引用形态正则（需能命中调用点、避开定义行）
# 用「:: 定义文件 :: 正则」三段表示，调用 bash 逐行解析。
CANDIDATES=(
  "AccountSession.snapshot()::Sources/Account/AccountSession.swift::\.snapshot\(\)"
  "Log.close()::Sources/Diagnostics.swift::Log\.shared\.close\(\)"
  "Log.logDebug/logInfo/logWarn/logError::Sources/Diagnostics.swift::\blog(Debug|Info|Warn|Error)\("
  "Bytes.rol/ror::Sources/Crypto/Bytes.swift::\b(rol|ror)\("
  "PreparedCache.invalidate(episodeID:)::Sources/Media/PreparedCache.swift::\.invalidate\(episodeID:"
  "Rendition.toStreamInfo()::Sources/Protocols/ContentModels.swift::\.toStreamInfo\(\)"
  "DramaCategory.init(fromRoute:)::Sources/Protocols/ContentModels.swift::fromRoute:"
  "RankBoard.loader::Sources/Protocols/ContentModels.swift::(board|boardEnum)\.loader\b"
  "RankBoard.key::Sources/Protocols/ContentModels.swift::(board|boardEnum)\.key\b"
  "Series.isValidId::Sources/Protocols/ContentModels.swift::\.isValidId\b"
)

echo "=== 死代码引用检查 ==="
for entry in "${CANDIDATES[@]}"; do
  name="${entry%%::*}"
  rest="${entry#*::}"
  def_file="${rest%%::*}"
  regex="${rest#*::}"

  # 在 Sources 与 tests 中搜索引用形态，排除定义文件自身。
  hits=$(grep -RIEn --include='*.swift' "$regex" Sources tests 2>/dev/null \
        | grep -v "^${def_file}:" \
        | grep -v '^\s*//' \
        || true)

  if [ -z "$hits" ]; then
    echo "[OK]   $name —— 零外部引用"
  else
    echo "[FAIL] $name —— 存在真实引用："
    echo "$hits" | sed 's/^/         /'
    FAIL=1
  fi
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "全部死代码候选均确认零引用"
else
  echo "存在被引用的候选符号，请复查（可能是死代码被重新启用，或清单过期）"
  exit 1
fi
