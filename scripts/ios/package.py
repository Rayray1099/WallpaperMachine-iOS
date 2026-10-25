#!/usr/bin/env python3
"""Package the built .app as an unsigned IPA and write its provenance manifest.

Nothing here signs anything. The IPA is ``Payload/WallpaperMachineIOS.app`` in a
zip, the way a development IPA is laid out, for structural validation and for a
signing step outside CI. ``manifest.json`` records the source commit, the
toolchain, the renderer archive and the SHA-256 of every packaged input;
``checksums.sha256`` covers the IPA, the manifest and the native outputs.

Run after scripts/ios/build.py and before scripts/ios/validate.py.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(SCRIPT_DIR))

from lib.glyphs import markers  # noqa: E402

MARK = markers()

SCHEMA = "wallpapermachine.ios.build-manifest/v1"
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git(*args: str) -> str | None:
    result = subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def repository_slug() -> str:
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    remote = git("config", "--get", "remote.origin.url") or ""
    match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", remote)
    return match.group(1) if match else remote or "unknown"


def sdk_version() -> str | None:
    try:
        result = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def sanitize(text: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-") or "unknown"


def zip_app(stage: Path, ipa: Path) -> None:
    """Zip ``Payload/<app>`` with stable metadata and no host-specific timestamps."""
    ipa.parent.mkdir(parents=True, exist_ok=True)
    temporary = ipa.with_suffix(".ipa.tmp")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for current, directories, files in os.walk(stage):
            directories.sort()
            files.sort()
            current_path = Path(current)
            relative_dir = current_path.relative_to(stage).as_posix()
            if relative_dir != ".":
                info = zipfile.ZipInfo(relative_dir + "/", ZIP_TIMESTAMP)
                info.create_system = 3
                info.external_attr = (0o40755 << 16) | 0x10
                info.compress_type = zipfile.ZIP_STORED
                archive.writestr(info, b"")
            for name in files:
                source = current_path / name
                arcname = (Path(relative_dir) / name).as_posix() if relative_dir != "." else name
                if source.is_symlink():
                    info = zipfile.ZipInfo(arcname, ZIP_TIMESTAMP)
                    info.create_system = 3
                    info.external_attr = 0o120777 << 16
                    info.compress_type = zipfile.ZIP_STORED
                    archive.writestr(info, os.readlink(source))
                    continue
                mode = source.stat().st_mode & 0o7777
                info = zipfile.ZipInfo(arcname, ZIP_TIMESTAMP)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | mode) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with source.open("rb") as handle, archive.open(info, "w") as destination:
                    shutil.copyfileobj(handle, destination, 1024 * 1024)
    temporary.replace(ipa)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", type=Path, required=True, help="Built WallpaperMachineIOS.app.")
    parser.add_argument("--artifacts-dir", type=Path, required=True, help="Directory for IPA/manifest.")
    parser.add_argument("--renderer-dir", type=Path, default=ROOT / "iOS/Generated/Renderer")
    parser.add_argument("--configuration", default="Release", choices=["Debug", "Release"])
    parser.add_argument("--allow-dirty", action="store_true", help="Record a dirty tree instead of failing.")
    args = parser.parse_args()

    app = args.app.resolve()
    artifacts = args.artifacts_dir.resolve()
    renderer_dir = args.renderer_dir.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise SystemExit(f"--app must be a built .app bundle, got {app}")
    if not artifacts.is_relative_to(ROOT):
        raise SystemExit(f"--artifacts-dir must be inside the repository: {artifacts}")
    artifacts.mkdir(parents=True, exist_ok=True)

    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise SystemExit(f"{info_path} is missing; was the app built?")
    info = plistlib.loads(info_path.read_bytes())
    executable_name = info.get("CFBundleExecutable") or "WallpaperMachineIOS"
    executable = app / executable_name
    if not executable.is_file():
        raise SystemExit(f"{executable} is missing")
    version = str(info.get("CFBundleShortVersionString") or "").strip()
    build = str(info.get("CFBundleVersion") or "").strip()
    if not version or not build:
        raise SystemExit("the built Info.plist has no CFBundleShortVersionString/CFBundleVersion")

    commit = git("rev-parse", "HEAD")
    if not commit:
        raise SystemExit("cannot resolve git HEAD; packaging needs a source commit")
    short = commit[:8]
    status = git("status", "--porcelain", "--untracked-files=no") or ""
    dirty = bool(status.strip())
    if dirty and not args.allow_dirty:
        raise SystemExit("the working tree has tracked modifications; commit them before packaging")
    if dirty:
        print(f"{MARK.warn} packaging a dirty tree; the manifest records it and validate.py will reject it")

    archive = renderer_dir / "lib/libWallpaperSceneRenderer.a"
    if not archive.is_file():
        raise SystemExit(f"{archive} is missing; run scripts/ios/build_renderer.sh through build.py first")
    bindings_dir = renderer_dir / "include"
    binding_names = ("WallpaperSceneRenderer.h", "Platform/Apple/SceneWallpaperBindings.h", "Core/RendererCounters.h")
    for name in binding_names:
        if not (bindings_dir / name).is_file():
            raise SystemExit(f"{bindings_dir / name} is missing")

    stage_root = ROOT / "build/ios/ipa"
    if stage_root.exists():
        shutil.rmtree(stage_root)
    stage_app = stage_root / "Payload" / app.name
    stage_app.parent.mkdir(parents=True)
    shutil.copytree(app, stage_app, symlinks=True)

    ipa_name = f"WallpaperMachineIOS-unsigned-{sanitize(version)}-{sanitize(build)}-{short}.ipa"
    ipa = artifacts / ipa_name
    zip_app(stage_root, ipa)
    ipa_digest = sha256(ipa)

    renderer_manifest_path = renderer_dir / "manifest.json"
    renderer_manifest: dict = {}
    if renderer_manifest_path.is_file():
        try:
            renderer_manifest = json.loads(renderer_manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise SystemExit(f"cannot parse {renderer_manifest_path}: {error}") from error
    else:
        raise SystemExit(f"{renderer_manifest_path} is missing")

    toolchain: dict = {}
    toolchain_path = artifacts / "toolchain.json"
    if toolchain_path.is_file():
        try:
            toolchain = json.loads(toolchain_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            toolchain = {}

    def entry(path: Path, role: str, **extra) -> dict:
        return {
            "path": path.resolve().relative_to(ROOT).as_posix(),
            "role": role,
            "sha256": sha256(path),
            "size": path.stat().st_size,
            **extra,
        }

    artifacts_entries = [
        entry(executable, "app-executable", arch="arm64", platform="iphoneos"),
        entry(archive, "renderer-archive", arch="arm64", platform="iphoneos"),
        entry(info_path, "app-info"),
        entry(renderer_manifest_path, "renderer-manifest"),
    ]
    for name in binding_names:
        artifacts_entries.append(entry(bindings_dir / name, "renderer-bindings"))
    if toolchain_path.is_file():
        artifacts_entries.append(entry(toolchain_path, "toolchain"))

    document = {
        "schema": SCHEMA,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": {
            "repository": repository_slug(),
            "commit": commit,
            "commit_short": short,
            "ref": os.environ.get("GITHUB_REF") or git("symbolic-ref", "-q", "HEAD") or "",
            "ref_name": os.environ.get("GITHUB_REF_NAME") or "",
            "dirty": dirty,
            "workflow": {
                key: os.environ.get(env)
                for key, env in (
                    ("workflow", "GITHUB_WORKFLOW"),
                    ("job", "GITHUB_JOB"),
                    ("run_id", "GITHUB_RUN_ID"),
                    ("run_attempt", "GITHUB_RUN_ATTEMPT"),
                    ("server_url", "GITHUB_SERVER_URL"),
                )
                if os.environ.get(env)
            }
            or None,
        },
        "build": {
            "configuration": args.configuration,
            "sdk": "iphoneos",
            "sdk_version": sdk_version(),
            "deployment_target": str(info.get("MinimumOSVersion") or ""),
            "architectures": ["arm64"],
            "device_families": info.get("UIDeviceFamily") or [1, 2],
            "signing": "unsigned",
            "target_device": "iPadOS 27 (physical; not exercised in CI)",
            "command_line": "xcodebuild CODE_SIGNING_ALLOWED=NO",
        },
        "bundle": {
            "identifier": info.get("CFBundleIdentifier"),
            "executable": executable_name,
            "version": version,
            "build": build,
            "minimum_os": info.get("MinimumOSVersion"),
            "localizations": info.get("CFBundleLocalizations") or [],
            "supported_platforms": info.get("CFBundleSupportedPlatforms") or [],
        },
        "toolchain": toolchain,
        "renderer": {
            "manifest": renderer_manifest,
            "archive": {
                "path": archive.relative_to(ROOT).as_posix(),
                "sha256": sha256(archive),
                "size": archive.stat().st_size,
            },
            "bindings": {
                name: sha256(bindings_dir / name) for name in binding_names
            },
        },
        "ipa": {
            "path": ipa.relative_to(ROOT).as_posix(),
            "filename": ipa_name,
            "sha256": ipa_digest,
            "size": ipa.stat().st_size,
            "signed": False,
            "structure": "Payload/WallpaperMachineIOS.app",
        },
        "artifacts": artifacts_entries,
        "validation": {
            "report": (artifacts / "validation.json").relative_to(ROOT).as_posix(),
            "status": "pending",
        },
        "caveats": [
            "Unsigned: install requires signing outside CI; this is not an App Store build.",
            "iPadOS 27 is a physical target; CI proves structure, not on-device rendering.",
        ],
    }
    manifest = artifacts / "manifest.json"
    manifest.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    checksum_targets: list[Path] = [ipa, manifest, executable, info_path, archive, renderer_manifest_path]
    checksum_targets.extend(bindings_dir / name for name in binding_names)
    checksum_targets.extend(
        path for path in artifacts.iterdir() if path.is_file() and path.suffix in {".json", ".log"}
    )
    checksum_targets = sorted({path.resolve() for path in checksum_targets if path.is_file()})
    lines = []
    for path in checksum_targets:
        lines.append(f"{sha256(path)}  {path.relative_to(ROOT).as_posix()}")
    (artifacts / "checksums.sha256").write_text("\n".join(lines) + "\n", encoding="utf-8")

    print(f"{MARK.ok} Packaged {ipa.relative_to(ROOT)}")
    print(f"{MARK.ok} Manifest {manifest.relative_to(ROOT)} ({len(artifacts_entries)} native inputs)")
    print(f"{MARK.ok} Checksums cover {len(checksum_targets)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
