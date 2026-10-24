#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate the independent Mac update manifest from a built bundle and its ZIP."""
import argparse
import hashlib
import json
import plistlib
import platform
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--zip", type=Path, required=True)
args = parser.parse_args()
with (args.app / "Contents/Info.plist").open("rb") as source:
    metadata = plistlib.load(source)
digest = hashlib.sha256()
with args.zip.open("rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
manifest = dict(schema=1, bundleID=metadata["CFBundleIdentifier"], build=int(metadata["CFBundleVersion"]),
                version=metadata["CFBundleShortVersionString"], architecture=platform.machine(),
                minMacOS=int(metadata["LSMinimumSystemVersion"].split(".")[0]), fileName=args.zip.name,
                size=args.zip.stat().st_size, sha256=digest.hexdigest(),
                notes="新增本集评论下滑连续加载、筛选排序与复制；新增真实时间轴弹幕，支持开关、重试和播放同步。改善弹幕清晰度与移动连续性，修复主窗口全屏时的视频全屏入口。整剧剧评仍为官网节选，发送和回复尚未接入。")
(args.zip.parent / "mac-update.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
