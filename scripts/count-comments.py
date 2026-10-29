#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Swift 注释量统计：按文件列出注释行数、占比，并可按阈值筛选。

注释定义：
- 纯注释行：去掉缩进后以 // 或 /// 开头
- 不含行尾 // 注释、不含块注释 /* */ 的跨行统计（本项目未使用块注释）
- 不计 SPDX 许可证首行

用法：
  ./scripts/count-comments.py                   # 全部文件，按注释行数降序
  ./scripts/count-comments.py --min 20          # 只看注释行 >= 20 的文件（找清理目标）
  ./scripts/count-comments.py --ratio 15        # 只看注释占比 >= 15% 的文件
  ./scripts/count-comments.py Sources/GUI       # 只统计指定目录
  ./scripts/count-comments.py --total           # 只输出汇总
"""
import argparse
import sys
from pathlib import Path


def is_comment(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("//")


def is_spdx(line: str) -> bool:
    return "SPDX-License-Identifier" in line


def measure(path: Path) -> tuple[int, int, int]:
    """返回 (总行数, 注释行数, 空行数)。"""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    total = len(lines)
    comments = 0
    blanks = 0
    for line in lines:
        if is_spdx(line):
            continue
        if not line.strip():
            blanks += 1
        elif is_comment(line):
            comments += 1
    return total, comments, blanks


def main() -> int:
    parser = argparse.ArgumentParser(description="统计 Swift 文件注释量")
    parser.add_argument("paths", nargs="*", default=["Sources"], help="目录或文件（默认 Sources）")
    parser.add_argument("--min", type=int, default=0, metavar="N", help="只显示注释行 >= N 的文件")
    parser.add_argument("--ratio", type=float, default=0.0, metavar="P", help="只显示注释占比 >= P%% 的文件")
    parser.add_argument("--total", action="store_true", help="只输出汇总，不列文件")
    parser.add_argument("--no-tests", action="store_true", help="同时统计 tests/")
    args = parser.parse_args()

    roots = [Path(p) for p in args.paths]
    files: list[Path] = []
    for root in roots:
        if root.is_file() and root.suffix == ".swift":
            files.append(root)
        elif root.is_dir():
            files.extend(root.rglob("*.swift"))
    if not args.no_tests:
        test_root = Path("tests")
        if test_root.is_dir() and not args.total:
            files.extend(test_root.rglob("*.swift"))

    rows = []
    for path in sorted(set(files)):
        total, comments, _ = measure(path)
        # 占比按「代码+注释行」（去掉空行）计算，避免空行稀释比例
        code_lines = total - measure(path)[2]
        ratio = (comments / code_lines * 100) if code_lines else 0.0
        rows.append((comments, ratio, total, path))

    if not args.total:
        filtered = [r for r in rows if r[0] >= args.min and r[1] >= args.ratio]
        filtered.sort(key=lambda r: (-r[0], str(r[3])))
        print(f"{'注释行':>6}  {'占比':>6}  {'总行':>6}  文件")
        print("-" * 60)
        for comments, ratio, total, path in filtered:
            print(f"{comments:>6}  {ratio:>5.1f}%  {total:>6}  {path}")
        print("-" * 60)

    all_comments = sum(r[0] for r in rows)
    all_total = sum(r[2] for r in rows)
    all_code = sum(r[2] - measure(r[3])[2] for r in rows)
    overall = (all_comments / all_code * 100) if all_code else 0.0
    print(f"合计：{len(rows)} 个文件，注释 {all_comments} 行 / 总 {all_total} 行，"
          f"占非空代码行 {overall:.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
