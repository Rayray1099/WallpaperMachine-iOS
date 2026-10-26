#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline, unsigned AirCard validation packaging and independent IPA inspection.

Build: --app AirCard-iOS.app --source checkout --patch-report patch.json
       --artifacts-dir out
Verify (no checkout or Apple tools required): --ipa validation.ipa --report out.json

Python API: package_app(app, source, patch_report, artifacts_dir) -> report dict;
verify_ipa(ipa, report=None) -> report dict. All paths accept str or Path.
Outputs are exclusive-create, never overwrite inputs. This is static validation,
not a release, signing, install, device, exploit-safety or runtime test.
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
import struct
import subprocess
import tempfile
import unicodedata
import zipfile
import zlib
from pathlib import Path

BASELINE_AIRCARD_SHA = "40640c4d827aeab8d798285b57d24fcf6be070d0"
BUNDLE_ID = "com.mak5er.aircard"
IPA_NAME = "AirCard-WM27-Validation.ipa"
REPORT_NAME = "AirCard-WM27-Validation-report.json"
STAMP_PATH = "WallpaperMachineValidation/WMPosterBoardValidation.json"
LICENSE_PATH = "WallpaperMachineValidation/MITLICENSE"
MAX_ARCHIVE_BYTES = 2 * 1024**3
MAX_TOTAL_BYTES = 4 * 1024**3
MAX_ENTRY_BYTES = 512 * 1024**2
MAX_ENTRIES = 50_000
MAX_METADATA_BYTES = 4 * 1024**2
MAX_LOAD_COMMAND_BYTES = 4 * 1024**2
CHUNK = 1024**2
PATCHED_PATHS = {
    "rust-core/src/exploit.rs", "ios-app/TendiesEngine.swift", "ios-app/AppViewModel.swift",
}


class ValidationError(ValueError):
    """An input is not a supported unsigned validation artifact."""


def _require(condition, message):
    if not condition:
        raise ValidationError(message)


def _sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            _require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValidationError(f"non-finite JSON constant: {value}")

    _require(len(data) <= MAX_METADATA_BYTES, "JSON exceeds metadata size limit")
    result = json.loads(data, object_pairs_hook=unique, parse_constant=invalid_constant)
    _require(isinstance(result, dict), "JSON must be an object")
    return result


def _write_json(path, value):
    with Path(path).open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, allow_nan=False)
        stream.write("\n")


def inspect_macho(stream, size):
    """Read bounded load commands, requiring thin little-endian ARM64 iOS execute."""
    header = stream.read(32)
    _require(len(header) == 32, "truncated Mach-O header")
    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack(
        "<8I", header
    )
    _require(magic == 0xFEEDFACF, "executable must be thin little-endian Mach-O 64")
    _require(cpu == 0x0100000C, "executable must be ARM64")
    _require(kind == 2, "Mach-O must be MH_EXECUTE")
    _require(0 < count <= command_bytes // 8, "invalid Mach-O command count")
    _require(command_bytes <= MAX_LOAD_COMMAND_BYTES, "Mach-O commands exceed size limit")
    _require(32 + command_bytes <= size, "truncated Mach-O load commands")
    commands = stream.read(command_bytes)
    _require(len(commands) == command_bytes, "truncated Mach-O load commands")
    cursor, platforms = 0, []
    for _ in range(count):
        _require(cursor + 8 <= len(commands), "truncated Mach-O command")
        command, length = struct.unpack_from("<II", commands, cursor)
        _require(length >= 8 and length % 8 == 0, "invalid Mach-O command size/alignment")
        _require(cursor + length <= len(commands), "Mach-O command overrun")
        _require(command != 0x1D, "signed Mach-O (LC_CODE_SIGNATURE) is not unsigned")
        if command == 0x32:  # LC_BUILD_VERSION, not legacy minimum-version inference
            _require(length >= 24, "truncated LC_BUILD_VERSION")
            platform, minimum, sdk, tools = struct.unpack_from("<4I", commands, cursor + 8)
            _require(length == 24 + tools * 8, "invalid LC_BUILD_VERSION tool table")
            platforms.append(platform)
        cursor += length
    _require(cursor == len(commands), "Mach-O load command size mismatch")
    _require(platforms == [2], "requires exactly one LC_BUILD_VERSION platform iOS (2)")
    return {"architecture": "arm64", "fileType": "MH_EXECUTE", "platform": 2}


def _safe_name(name):
    _require(isinstance(name, str) and bool(name), "empty ZIP path")
    _require(not any(ord(c) < 32 or ord(c) == 127 for c in name), "control byte in ZIP path")
    _require("\\" not in name and ":" not in name and not name.startswith("/"),
             f"unsafe ZIP path: {name!r}")
    parts = (name[:-1] if name.endswith("/") else name).split("/")
    _require(all(part not in ("", ".", "..") and not part.endswith((".", " "))
                 for part in parts), f"unsafe ZIP path: {name!r}")
    return unicodedata.normalize("NFC", "/".join(parts)).casefold()


def _bundle_info(data):
    _require(len(data) <= MAX_METADATA_BYTES, "Info.plist exceeds metadata size limit")
    info = plistlib.loads(data)
    _require(isinstance(info, dict), "Info.plist must be a dictionary")
    _require(info.get("CFBundleIdentifier") == BUNDLE_ID, "unexpected AirCard bundle ID")
    platforms = info.get("CFBundleSupportedPlatforms")
    _require(isinstance(platforms, list) and "iPhoneOS" in platforms,
             "CFBundleSupportedPlatforms must contain iPhoneOS")
    executable = info.get("CFBundleExecutable")
    _require(isinstance(executable, str) and bool(executable), "missing CFBundleExecutable")
    _safe_name(executable)
    _require("/" not in executable, "CFBundleExecutable must be a filename")
    _require(isinstance(info.get("CFBundleVersion"), str) and bool(info["CFBundleVersion"]),
             "missing CFBundleVersion")
    return info


def _check_stamp(stamp, binary_sha, license_sha):
    _require(stamp.get("schemaVersion") == 1, "unsupported validation stamp schema")
    _require(stamp.get("sourcePin") == BASELINE_AIRCARD_SHA, "missing/wrong explicit source pin")
    _require(stamp.get("baselineAirCardSHA") == BASELINE_AIRCARD_SHA, "wrong AirCard baseline")
    _require(stamp.get("unsafeAutomaticNeoSpring") is False, "unsafeAutomaticNeoSpring must be false")
    _require(stamp.get("testsNotDevice") is True and stamp.get("release") is False,
             "validation stamp must explicitly disclaim device/release validation")
    _require(stamp.get("binarySHA256") == binary_sha, "validation binary SHA256 mismatch")
    _require(stamp.get("upstreamLicenseSHA256") == license_sha, "upstream license SHA256 mismatch")
    _require(isinstance(stamp.get("patchReport"), dict) and bool(stamp["patchReport"]),
             "missing source patch report")
    _check_patch(stamp["patchReport"])
    _require(isinstance(stamp.get("script"), dict), "missing packager script metadata")
    _require(bool(re.fullmatch(r"[0-9a-f]{64}", str(stamp["script"].get("sha256", "")))),
             "missing packager script SHA256")
    static = stamp.get("staticLibrariesSHA256")
    _require(isinstance(static, dict), "missing static library inventory")
    for name, digest in static.items():
        _safe_name(name)
        _require(bool(re.fullmatch(r"[0-9a-f]{64}", str(digest))), "invalid static library SHA256")


def _check_patch(patch, source=None):
    """Match prepare_aircard_validation.py's report; never infer a patch from a label."""
    _require(patch.get("upstream_commit") == BASELINE_AIRCARD_SHA, "patch report source pin mismatch")
    _require(patch.get("automatic_neospring") is False, "patch report must disable automatic NeoSpring")
    _require(patch.get("asset_identifiers_or_names_renamed") is False,
             "patch report must preserve asset identifiers/names")
    _require(patch.get("cargo_locked") is True, "patch report must record a Cargo lockfile")
    _require(patch.get("rust_test_filter") == "wm_posterboard_validation", "unexpected Rust test filter")
    _require(patch.get("status") in ("prepared", "already_prepared"), "patch report is not prepared")
    _require(isinstance(patch.get("source"), str) and bool(patch["source"]), "missing patch source path")
    if source is not None:
        _require(Path(patch["source"]).resolve() == source, "patch report names a different checkout")
    changes = patch.get("changes")
    _require(isinstance(changes, list) and len(changes) == len(PATCHED_PATHS),
             "patch report must inventory all three source changes")
    _require(all(isinstance(row, dict) and isinstance(row.get("path"), str) for row in changes),
             "invalid patch report changes")
    _require({row["path"] for row in changes} == PATCHED_PATHS, "unexpected source patch paths")
    for row in changes:
        _require(bool(re.fullmatch(r"[0-9a-f]{40}", str(row.get("upstream_blob", "")))),
                 "invalid upstream Git blob SHA1")
        _require(bool(re.fullmatch(r"[0-9a-f]{64}", str(row.get("original_sha256", "")))),
                 "invalid original source SHA256")
        digest = row.get("patched_sha256")
        _require(bool(re.fullmatch(r"[0-9a-f]{64}", str(digest))), "invalid patched source SHA256")
        if source is not None:
            target = source / row["path"]
            _require(not any(p.is_symlink() for p in (target, *target.parents)),
                     "patched source cannot use symlinks")
            _require(target.resolve().is_relative_to(source), "patched source escapes checkout")
            _require(_sha256(target) == digest, "source does not match patch report: " + row["path"])


def verify_ipa(ipa, report=None):
    """Independently inspect archive bytes. Never extract, sign or use the source checkout."""
    ipa = Path(ipa)
    _require(0 < ipa.stat().st_size <= MAX_ARCHIVE_BYTES, "IPA exceeds archive size limit or is empty")
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        _require(0 < len(entries) <= MAX_ENTRIES, "ZIP entry count exceeds limit or is empty")
        names, folded, total = {}, set(), 0
        for entry in entries:
            # zipfile truncates filename at NUL; examine the original as well.
            key = _safe_name(entry.orig_filename)
            _require(entry.filename == entry.orig_filename, "ZIP path was truncated")
            _require(key not in folded, "duplicate ZIP path (including case/Unicode aliases)")
            folded.add(key)
            mode = entry.external_attr >> 16
            _require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR),
                     "ZIP symlinks/special files are not supported")
            _require(not entry.flag_bits & 1, "encrypted ZIP entry")
            _require(entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                     "unsupported ZIP compression")
            _require(entry.file_size <= MAX_ENTRY_BYTES, "ZIP entry exceeds size limit")
            _require(not entry.is_dir() or entry.file_size == 0, "nonempty ZIP directory")
            total += entry.file_size
            _require(total <= MAX_TOTAL_BYTES, "ZIP expanded total exceeds size limit")
            names[entry.filename] = entry
        # Reject file/directory collisions and files used as parent directories.
        file_keys = {_safe_name(name) for name, entry in names.items() if not entry.is_dir()}
        for name in names:
            parts = name.rstrip("/").split("/")
            for end in range(1, len(parts)):
                parent = "/".join(parts[:end])
                _require(_safe_name(parent) not in file_keys, "ZIP file used as parent directory")
        infos = [name for name in names if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        _require(len(infos) == 1, "requires exactly one Payload/*.app/Info.plist")
        prefix = infos[0].rsplit("/", 1)[0] + "/"
        _require(all(name in ("Payload/", prefix) or name.startswith(prefix) for name in names),
                 "unexpected entry outside the single app payload")
        _require(not any("_CodeSignature" in name.split("/") or
                         name.rsplit("/", 1)[-1] == "embedded.mobileprovision" for name in names),
                 "signed/provisioned app is not an unsigned validation IPA")

        def small(name):
            _require(name in names and not names[name].is_dir(), f"missing {name}")
            _require(names[name].file_size <= MAX_METADATA_BYTES, "metadata exceeds size limit")
            return archive.read(names[name])

        info = _bundle_info(small(infos[0]))
        executable_name = prefix + info["CFBundleExecutable"]
        _require(executable_name in names, "missing main executable")
        with archive.open(names[executable_name]) as stream:
            macho = inspect_macho(stream, names[executable_name].file_size)
        stamp = _json(small(prefix + STAMP_PATH))
        license_data = small(prefix + LICENSE_PATH)
        _require(b"Permission is hereby granted" in license_data, "missing upstream MIT license text")
        binary_sha = None
        # Read every member to EOF: verifies every CRC, including unreferenced resources.
        for entry in entries:
            digest, actual = hashlib.sha256(), 0
            with archive.open(entry) as stream:
                for chunk in iter(lambda: stream.read(CHUNK), b""):
                    actual += len(chunk)
                    _require(actual <= entry.file_size and actual <= MAX_ENTRY_BYTES,
                             "ZIP actual expanded size exceeds limit")
                    digest.update(chunk)
            _require(actual == entry.file_size, "ZIP actual size mismatch")
            if entry.filename == executable_name:
                binary_sha = digest.hexdigest()
        _check_stamp(stamp, binary_sha, hashlib.sha256(license_data).hexdigest())
    result = {
        "schemaVersion": 1, "archiveSHA256": _sha256(ipa), "bytes": ipa.stat().st_size,
        "binarySHA256": binary_sha, "sourcePin": stamp["sourcePin"],
        "baselineAirCardSHA": stamp["baselineAirCardSHA"], "bundleID": info["CFBundleIdentifier"],
        "CFBundleVersion": info["CFBundleVersion"],
        "CFBundleShortVersionString": info.get("CFBundleShortVersionString"),
        "macho": macho, "zipEntries": len(entries), "expandedBytes": total,
        "allZipCRCsVerified": True, "unsigned": True, "testsNotDevice": True,
        "release": False, "unsafeAutomaticNeoSpring": False,
        "limitations": "Static package tests only; no device, runtime, install or exploit-safety validation. "
                        "Embedded provenance is self-described, not a signed source-to-binary attestation.",
        "instrumentation": stamp,
    }
    if report is not None:
        _write_json(report, result)
    return result


def _source_pin(source):
    result = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                            check=True, capture_output=True, text=True, timeout=30)
    pin = result.stdout.strip()
    _require(pin == BASELINE_AIRCARD_SHA, "source HEAD is not the pinned AirCard baseline")
    return pin


def _files(root):
    """Inventory without following any symlink, even a directory link/junction."""
    result = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            _require(not path.is_symlink() and not getattr(path, "is_junction", lambda: False)(),
                     f"symlink/junction input not supported: {path}")
            _require(path.is_dir() or path.is_file(), f"special input file: {path}")
        result.extend(Path(directory) / name for name in files)
    return sorted(result)


def package_app(app, source, patch_report, artifacts_dir):
    """Copy a real built app to a private system temp dir; preserve app/source bytes."""
    app, source, patch_report, out = map(Path, (app, source, patch_report, artifacts_dir))
    _require(not app.is_symlink() and not source.is_symlink(), "input root cannot be a symlink")
    app, source, patch_report, out = (p.resolve() for p in (app, source, patch_report, out))
    _require(app.is_dir() and app.name.endswith(".app"), "--app must be an existing .app directory")
    _require(source.is_dir(), "--source must be an existing pinned checkout")
    _require(not out.is_relative_to(app) and not out.is_relative_to(source),
             "artifacts directory cannot be inside app/source")
    _require(patch_report.stat().st_size <= MAX_METADATA_BYTES, "patch report exceeds size limit")
    patch = _json(patch_report.read_bytes())
    _require(bool(patch), "patch report cannot be empty")
    source_pin = _source_pin(source)
    _check_patch(patch, source)
    files = _files(app)
    total, seen = 0, set()
    for path in files:
        key = _safe_name(path.relative_to(app).as_posix())
        _require(key not in seen, "duplicate app path")
        seen.add(key)
        size = path.stat().st_size
        _require(size <= MAX_ENTRY_BYTES, "app file exceeds size limit")
        total += size
    _require(total <= MAX_TOTAL_BYTES and len(files) + 2 <= MAX_ENTRIES, "app exceeds size limits")
    _require(not (app / "WallpaperMachineValidation").exists(), "app already contains validation metadata")
    _require((app / "Info.plist").stat().st_size <= MAX_METADATA_BYTES, "Info.plist exceeds size limit")
    info = _bundle_info((app / "Info.plist").read_bytes())
    binary = app / info["CFBundleExecutable"]
    with binary.open("rb") as stream:
        inspect_macho(stream, binary.stat().st_size)
    license_file = source / "LICENSE"
    _require(not license_file.is_symlink(), "MITLICENSE cannot be a symlink")
    _require(0 < license_file.stat().st_size <= MAX_METADATA_BYTES, "invalid MITLICENSE size")
    license_data = license_file.read_bytes()
    _require(b"Permission is hereby granted" in license_data, "source MITLICENSE is not MIT text")
    libraries = {p.relative_to(source).as_posix(): _sha256(p)
                 for p in source.rglob("*.a") if p.is_file() and not p.is_symlink()}
    stamp = {
        "schemaVersion": 1, "baselineAirCardSHA": BASELINE_AIRCARD_SHA,
        "sourcePin": source_pin, "patchReport": patch,
        "script": {"name": Path(__file__).name, "sha256": _sha256(__file__)},
        "binarySHA256": _sha256(binary), "staticLibrariesSHA256": libraries,
        "upstreamLicenseSHA256": hashlib.sha256(license_data).hexdigest(),
        "unsafeAutomaticNeoSpring": False, "testsNotDevice": True, "release": False,
    }
    out.mkdir(parents=True, exist_ok=True)
    ipa, report_path = out / IPA_NAME, out / REPORT_NAME
    _require(not ipa.exists() and not report_path.exists(), "output already exists; choose another directory")
    # Only TemporaryDirectory's own newly-created directory is ever recursively removed.
    with tempfile.TemporaryDirectory(prefix="wm-aircard-validation-") as temp:
        temp = Path(temp)
        copied = temp / "Payload" / app.name
        shutil.copytree(app, copied)
        (copied / "WallpaperMachineValidation").mkdir()
        _write_json(copied / STAMP_PATH, stamp)
        (copied / LICENSE_PATH).write_bytes(license_data)
        temporary_ipa = temp / IPA_NAME
        with zipfile.ZipFile(temporary_ipa, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in _files(copied):
                entry = zipfile.ZipInfo.from_file(path, path.relative_to(temp).as_posix())
                # Windows cannot represent POSIX executable bits. Restore the main
                # executable's mode in the ZIP without chmod/mutating the input app.
                mode = stat.S_IFREG | (path.stat().st_mode & 0o777)
                if path == copied / info["CFBundleExecutable"]:
                    mode |= 0o111
                entry.create_system = 3
                entry.external_attr = mode << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                with path.open("rb") as input_stream, archive.open(entry, "w") as output:
                    shutil.copyfileobj(input_stream, output, CHUNK)
        result = verify_ipa(temporary_ipa)
        with ipa.open("xb") as output, temporary_ipa.open("rb") as input_stream:
            shutil.copyfileobj(input_stream, output, CHUNK)
        _write_json(report_path, result)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    for option in ("app", "source", "patch-report", "artifacts-dir", "ipa", "report"):
        parser.add_argument("--" + option, type=Path)
    args = parser.parse_args(argv)
    build = (args.app, args.source, args.patch_report, args.artifacts_dir)
    if args.ipa:
        if any(value is not None for value in build) or args.report is None:
            parser.error("verify requires --ipa --report only")
    elif not all(value is not None for value in build) or args.report is not None:
        parser.error("build requires --app --source --patch-report --artifacts-dir only")
    try:
        result = verify_ipa(args.ipa, args.report) if args.ipa else package_app(*build)
    except (OSError, ValueError, RuntimeError, EOFError, zipfile.BadZipFile,
            plistlib.InvalidFileException, subprocess.SubprocessError, zlib.error,
            RecursionError, OverflowError) as error:
        parser.exit(1, f"AirCard validation failed: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
