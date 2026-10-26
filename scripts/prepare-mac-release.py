#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate the independent Mac update manifest from a built bundle and its ZIP."""

import argparse
import hashlib
import json
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--zip", type=Path, required=True)
parser.add_argument("--arch", type=str, required=True, help="arm64 或 x86_64")
parser.add_argument("--notes", type=str, default="")
args = parser.parse_args()
with (args.app / "Contents/Info.plist").open("rb") as source:
    metadata = plistlib.load(source)
digest = hashlib.sha256()
with args.zip.open("rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
manifest = dict(
    schema=1,
    bundleID=metadata["CFBundleIdentifier"],
    build=int(metadata["CFBundleVersion"]),
    version=metadata["CFBundleShortVersionString"],
    architecture=args.arch,
    minMacOS=int(metadata["LSMinimumSystemVersion"].split(".")[0]),
    fileName=args.zip.name,
    size=args.zip.stat().st_size,
    sha256=digest.hexdigest(),
    notes=args.notes,
)
(args.zip.parent / f"mac-update-{args.arch}.json").write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
