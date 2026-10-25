#!/usr/bin/env python3
"""Verify every Mach-O member of a thin iOS renderer dependency archive."""
from __future__ import annotations

import argparse
from pathlib import Path

import macho


def verify(path: Path, sdk: str, arch: str) -> macho.ArchiveInfo:
    """Ignore ar symbol tables, reject foreign CPU/platform objects, fail closed."""
    info = macho.inspect_archive(path)
    platform = 2 if sdk == "iphoneos" else 7
    if info.objects == 0:
        raise ValueError("archive contains no Mach-O objects")
    if set(info.archs) != {arch}:
        raise ValueError(f"expected only {arch} objects, found {info.archs}")
    foreign = {key: count for key, count in info.object_platforms.items() if key not in (0, platform)}
    if foreign or not info.object_platforms.get(platform):
        raise ValueError(f"expected {sdk} objects, found platforms {info.object_platforms}")
    if info.has_code_signature:
        raise ValueError("static archive contains a signed object")
    return info


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), required=True)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    args = parser.parse_args()
    try:
        info = verify(args.archive, args.sdk, args.arch)
    except (OSError, ValueError) as error:
        print(f"error: {args.archive}: {error}")
        return 1
    print(f"Verified {args.archive.name}: {info.objects} {args.arch} objects for {args.sdk}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
