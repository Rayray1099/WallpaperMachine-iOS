#!/usr/bin/env python3
"""Assemble real source license texts for the iOS renderer and app dependencies.

Run on the macOS build host after the renderer dependency sources and Cargo crates
are available. Output is a deterministic directory that the app target can bundle.
No license text is synthesized: a required missing text is a hard error.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "Renderer"
DEFAULT_OUTPUT = ROOT / "iOS/Generated/Renderer/notices"


class NoticeError(RuntimeError):
    pass


def read_text(path: Path) -> str:
    try:
        value = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise NoticeError(f"cannot read required notice source {path}: {exc}") from exc
    value = value.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not value:
        raise NoticeError(f"required notice source is empty: {path}")
    return value


def find_licenses(directory: Path, labels: tuple[str, ...] = ("LICENSE", "COPYING", "NOTICE")) -> list[Path]:
    if not directory.is_dir():
        raise NoticeError(f"dependency source directory is missing: {directory}")
    # Retain every upstream alternative (e.g. MIT OR Apache), not an alphabetical winner.
    candidates = sorted(p for p in directory.iterdir() if p.is_file() and
                        any(p.name.upper() == label or p.name.upper().startswith(label + ".")
                            or p.name.upper().startswith(label + "-") for label in labels))
    if not candidates:
        raise NoticeError(f"no license/notice file found in dependency source: {directory}")
    return candidates


def run_metadata(manifest: Path, target: str, cargo: str = "cargo", runner=subprocess.run, package: str = "wm-shader") -> list[dict]:
    """Use cargo tree for the compiled normal closure; metadata only locates source paths."""
    tree_command = [cargo, "tree", "--locked", "--manifest-path", str(manifest), "-p", package]
    if package == "wm-shader":
        tree_command += ["--features", "ffi"]
    tree_command += ["--target", target, "--edges", "normal", "--prefix", "none", "-f", "{p}|{l}"]
    tree_result = runner(tree_command, cwd=manifest.parent, text=True, capture_output=True, check=False)
    if tree_result.returncode:
        raise NoticeError(f"cargo tree failed ({tree_result.returncode}): {(tree_result.stderr or tree_result.stdout)[-2000:]}")
    selected: set[tuple[str, str]] = set()
    for line in tree_result.stdout.splitlines():
        match = re.match(r"^([^ |]+) v([^ |]+)(?: \([^)]*\))?\|", line.strip())
        if match:
            selected.add((match.group(1), match.group(2)))
    if not selected or not any(name == package for name, _ in selected):
        raise NoticeError(f"cargo tree did not report the {package} normal dependency closure")

    metadata_command = [cargo, "metadata", "--format-version", "1", "--locked", "--manifest-path", str(manifest)]
    result = runner(metadata_command, cwd=manifest.parent, text=True, capture_output=True, check=False)
    if result.returncode:
        raise NoticeError(f"cargo metadata failed ({result.returncode}): {(result.stderr or result.stdout)[-2000:]}")
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise NoticeError(f"cargo metadata returned invalid JSON: {exc}") from exc
    available = {(package["name"], package["version"]): package for package in document.get("packages", [])}
    missing = sorted(selected - available.keys())
    if missing:
        raise NoticeError("cargo metadata cannot locate cargo-tree packages: " + ", ".join(f"{n} {v}" for n, v in missing))
    return [available[key] for key in sorted(selected)]


def crate_licenses(package: dict, cargo_home: Path) -> list[Path]:
    # Cargo metadata resolves the exact source manifest for registry and path crates.
    # Do not guess a registry directory from the package name/version.
    manifest = Path(package.get("manifest_path", ""))
    if not manifest.is_file():
        raise NoticeError(f"Cargo manifest for {package.get('name')} {package.get('version')} is missing: {manifest}")
    license_file = package.get("license_file")
    if license_file:
        candidate = Path(license_file)
        if not candidate.is_absolute():
            candidate = manifest.parent / candidate
        if candidate.is_file():
            return [candidate]
    try:
        return find_licenses(manifest.parent, ("LICENSE", "COPYING", "UNLICENSE", "COPYRIGHT"))
    except NoticeError:
        # openssl-src vendors upstream OpenSSL beneath its crate root.
        nested = manifest.parent / "openssl/LICENSE.txt"
        if package.get("name") == "openssl-src" and nested.is_file():
            return [nested]
        # Steam-Vent publishes an MIT declaration but omits a separate text.
        # This explicit notice preserves the actual declaration/author and the
        # SPDX standard terms without pretending to be an upstream license file.
        name = package.get("name", "")
        if (name == "steam-vent" or name.startswith("steam-vent-")) and package.get("license") == "MIT":
            declared_notice = ROOT / "Packaging/notices/steam-vent/NOTICE.txt"
            if declared_notice.is_file():
                return [declared_notice]
        fallback = ROOT / "Packaging/notices" / name
        if fallback.is_dir():
            return find_licenses(fallback, ("LICENSE", "COPYING", "UNLICENSE", "COPYRIGHT"))
        raise


def add_copy(output: Path, source: Path, destination: str, index: list[str]) -> None:
    text = read_text(source)
    target = output / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text + "\n", encoding="utf-8", newline="\n")
    index.append(f"{destination}: {source.relative_to(ROOT).as_posix() if source.is_relative_to(ROOT) else source.name}")


def generate(output: Path, deps_sources: Path, cargo_home: Path, zipfoundation: Path,
             cargo: str = "cargo", target: str = "aarch64-apple-ios",
             cargo_tree_runner=subprocess.run, deps_downloads: Path | None = None,
             steam_manifest: Path | None = None) -> list[str]:
    if output.exists() and any(output.iterdir()):
        raise NoticeError(f"refusing to overwrite non-empty notice output directory: {output}")
    output.mkdir(parents=True, exist_ok=True)
    index: list[str] = []

    fixed = [
        (ROOT / "LICENSE", "WallpaperMachine-LICENSE.txt"),
        (ROOT / "LICENSING.md", "LICENSING.md"),
        (ROOT / "ThirdParty/provenance.json", "provenance.json"),
        (ROOT / "ThirdParty/received-licenses/open-wallpaper-engine.GPL-2.0.txt",
         "received-licenses/open-wallpaper-engine.GPL-2.0.txt"),
        (ROOT / "ThirdParty/received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt",
         "received-licenses/wallpaper-engine-for-macos.GPL-2.0.txt"),
        (ROOT / "ThirdParty/miniaudio/LICENSE", "renderer/miniaudio/LICENSE"),
        (ROOT / "ThirdParty/stb_vorbis/LICENSE", "renderer/stb_vorbis/LICENSE"),
        (ROOT / "ThirdParty/naga/LICENSE.MIT", "renderer/naga/LICENSE.MIT"),
    ]
    for source, dest in fixed:
        add_copy(output, source, dest, index)

    # stb_image carries its actual permissive license at the end of its upstream header.
    stb_header = ROOT / "ThirdParty/stb_image/stb_image.h"
    header = read_text(stb_header)
    marker = "This software is available under 2 licenses"
    at = header.rfind(marker)
    if at < 0:
        raise NoticeError(f"license marker not found in {stb_header}")
    add_text(output, "renderer/stb_image/LICENSE.txt", header[at:], "ThirdParty/stb_image/stb_image.h (embedded license)", index)

    dep_map = {
        "quickjs-ng": "quickjs-0.17.0",
        "freetype": "freetype-VER-2-13-3",
        "lz4": "lz4-1.10.0",
        "argparse": "argparse-3.2",
    }
    for name, dirname in dep_map.items():
        source_dir = deps_sources / dirname
        for source in find_licenses(source_dir):
            add_copy(output, source, f"renderer/{name}/{source.name}", index)
        if name == "lz4":
            # The project root LICENSE is a selector; the linked library's BSD-2 text is here.
            add_copy(output, source_dir / "lib/LICENSE", "renderer/lz4/lib-LICENSE", index)
        if name == "freetype":
            for extra in ("docs/GPLv2.TXT", "docs/FTL.TXT"):
                candidate = source_dir / extra
                if not candidate.is_file():
                    raise NoticeError(f"FreeType licensing alternative is missing: {candidate}")
                add_copy(output, candidate, f"renderer/freetype/{extra.replace('/', '-')}", index)
    # nlohmann/json's single-header release is not a full license document.
    # Use the exact upstream MIT license file from the pinned release tag.
    downloads_dir = deps_downloads or (deps_sources.parent / "downloads")
    license_source = downloads_dir / "nlohmann-json-LICENSE.MIT"
    add_copy(output, license_source, "renderer/nlohmann-json/LICENSE.MIT", index)

    packages = run_metadata(RENDERER / "Cargo.toml", target, cargo, cargo_tree_runner)
    crate_entries = []
    if steam_manifest is not None:
        packages.extend(run_metadata(steam_manifest, target, cargo, cargo_tree_runner, package="wm-steam-transport"))
    # Merge the two target closures by exact crate identity before writing files.
    packages = list({(package["name"], package["version"]): package for package in packages}.values())
    for package in packages:
        # Workspace-owned packages are not third-party dependencies.
        if package.get("name") in {"wm-shader", "wallpaper-core", "wallpaper-bridge", "wm-steam-transport"}:
            continue
        sources = crate_licenses(package, cargo_home)
        declared = package.get("license") or "(license not declared)"
        for source in sources:
            dest = f"rust/{package['name']}-{package['version']}/{source.name}"
            add_copy(output, source, dest, index)
        crate_entries.append(f"{package['name']} {package['version']} [{declared}] authors={package.get('authors', [])!r} repository={package.get('repository')!r}")

    for zip_license in find_licenses(zipfoundation, ("LICENSE", "COPYING")):
        add_copy(output, zip_license, f"zipfoundation/{zip_license.name}", index)
    index_text = "iOS third-party license texts\n\n" + "\n".join(index) + "\n\n"
    closures = ["Rust wm-shader target dependency closure (Cargo metadata):"]
    if steam_manifest is not None:
        closures.append("Rust wm-steam-transport target dependency closure (Cargo metadata):")
    index_text += "\n".join(closures) + "\n" + "\n".join(crate_entries) + "\n"
    (output / "INDEX.txt").write_text(index_text, encoding="utf-8", newline="\n")
    return index


def add_text(output: Path, destination: str, text: str, origin: str, index: list[str]) -> None:
    value = text.strip()
    if not value:
        raise NoticeError(f"empty embedded license text from {origin}")
    target = output / destination
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(value + "\n", encoding="utf-8", newline="\n")
    index.append(f"{destination}: {origin}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--deps-sources", type=Path, required=True,
                        help="Extracted pinned dependency sources under the iOS deps cache.")
    parser.add_argument("--deps-downloads", type=Path,
                        help="Downloaded pinned license/source files (default: sibling downloads directory).")
    parser.add_argument("--cargo-home", type=Path, default=Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo")))
    parser.add_argument("--zipfoundation", type=Path, required=True, help="Resolved ZIPFoundation source checkout.")
    parser.add_argument("--target", default="aarch64-apple-ios")
    parser.add_argument("--cargo", default="cargo")
    parser.add_argument("--steam-manifest", type=Path, default=None,
                        help="Optional SteamTransport Cargo.toml whose native dependency closure is included.")
    args = parser.parse_args(argv)
    try:
        entries = generate(args.output.resolve(), args.deps_sources.resolve(), args.cargo_home.resolve(),
                           args.zipfoundation.resolve(), args.cargo, args.target,
                           deps_downloads=args.deps_downloads.resolve() if args.deps_downloads else None,
                            steam_manifest=args.steam_manifest.resolve() if args.steam_manifest else None)
    except NoticeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"generated {len(entries)} license/attribution files under {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
