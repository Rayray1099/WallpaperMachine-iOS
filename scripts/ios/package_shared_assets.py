#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package an explicitly selected, user-owned assets root for the iOS shared mount.

Only the complete shaders/ tree and repeated --texture assets-relative file paths
are read. There is no Steam discovery, download, extraction, renderer or device I/O.
Texture paths must retain their real materials/... or textures/... prefix; nothing
is renamed or substituted. The output ZIP must not exist and its parent must exist.
Keep licensed ZIPs and the JSON preservation report private and out of source control.

Example: python scripts/ios/package_shared_assets.py --assets OWNED_ASSETS_ROOT
  --output NEW_PRIVATE.zip --texture materials/util/white.tex
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path
from typing import BinaryIO, NamedTuple, Sequence

MANIFEST_NAME = "wmassets-manifest.json"
SCHEMA = "wallpapermachine.shared-assets/v1"
CHUNK_BYTES = 65_536
ZIP_MODE = (stat.S_IFREG | 0o644) << 16
ROOTS = frozenset({"shaders", "materials", "textures"})
FORBIDDEN_EXTENSIONS = frozenset({
    "exe", "dll", "dylib", "so", "app", "com", "bat", "cmd", "ps1", "msi", "sh",
})
RESERVED_COMPONENTS = frozenset(
    {"con", "prn", "aux", "nul", "clock$", "conin$", "conout$"}
    | {f"{prefix}{number}" for prefix in ("com", "lpt") for number in "123456789¹²³"}
)


class Limits(NamedTuple):
    archive_bytes: int = 512 * 1024 * 1024
    extracted_bytes: int = 512 * 1024 * 1024
    file_bytes: int = 64 * 1024 * 1024
    file_count: int = 20_000
    manifest_bytes: int = 1024 * 1024


DEFAULT_LIMITS = Limits()


class SourceFile(NamedTuple):
    path: str
    source: Path
    size: int


def _validate_limits(limits: Limits) -> None:
    if any(not isinstance(value, int) or isinstance(value, bool) or value <= 0
           or value > ceiling for value, ceiling in zip(limits, DEFAULT_LIMITS)):
        raise ValueError("limits must be positive and cannot exceed the iOS installer limits")


def validate_path(path: str, *, directory: bool = False, manifest: bool = False) -> None:
    """Reject unsafe or ambiguous names; never normalize/rename owned resources."""
    if not isinstance(path, str) or not path or len(path.encode("utf-8")) > 1024:
        raise ValueError("unsupported asset path length")
    if unicodedata.normalize("NFC", path) != path:
        raise ValueError(f"asset path is not NFC: {path!r}")
    if any(char in path for char in '\\:<>"|?*') or any(
            unicodedata.category(char).startswith("C") for char in path):
        raise ValueError(f"unsupported asset path: {path!r}")
    parts = path.split("/")
    for part in parts:
        if (not part or part.startswith(".") or part.endswith((".", " "))
                or len(part.encode("utf-8")) > 255
                or part.split(".", 1)[0].casefold() in RESERVED_COMPONENTS):
            raise ValueError(f"unsupported asset path component: {path!r}")
    if manifest and path == MANIFEST_NAME and not directory:
        return
    if (parts[0] not in ROOTS or (not directory and len(parts) < 2)
            or parts[-1].rsplit(".", 1)[-1].casefold() in FORBIDDEN_EXTENSIONS):
        raise ValueError(f"unsupported asset root or executable path: {path!r}")


def _register_path(nodes: dict[str, tuple[str, bool]], path: str, *, directory: bool) -> None:
    parts = path.split("/")
    for depth in range(1, len(parts) + 1):
        prefix = "/".join(parts[:depth])
        key = unicodedata.normalize("NFC", prefix).casefold()
        value = (prefix, depth < len(parts) or directory)
        if key in nodes and nodes[key] != value:
            raise ValueError(f"case/Unicode or file/directory path collision: {path!r}")
        nodes[key] = value


def _absolute(path: Path) -> Path:
    # abspath is lexical: resolve() would follow a link before we could reject it.
    return Path(os.path.abspath(path))


def _is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def _directory_chain(path: Path) -> None:
    for ancestor in reversed((path, *path.parents)):
        info = ancestor.lstat()
        if _is_link(info) or not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"source/output directory is a link or non-directory: {ancestor}")


def _source_stat(source: Path) -> os.stat_result:
    _directory_chain(source.parent)
    info = source.lstat()
    if _is_link(info) or not stat.S_ISREG(info.st_mode):
        raise ValueError(f"asset is not an ordinary, non-linked file: {source}")
    return info


def _identity(info: os.stat_result) -> tuple[int, int, int, int]:
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def _read_source(file: SourceFile, sink: BinaryIO | None = None) -> dict:
    before = _source_stat(file.source)
    if before.st_size != file.size:
        raise ValueError(f"source size changed: {file.path}")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(file.source, flags)
    with os.fdopen(descriptor, "rb") as stream:
        if _identity(os.fstat(stream.fileno())) != _identity(before):
            raise ValueError(f"source changed while opening: {file.path}")
        digest, size = hashlib.sha256(), 0
        while chunk := stream.read(min(CHUNK_BYTES, file.size - size + 1)):
            size += len(chunk)
            if size > file.size:
                raise ValueError(f"source grew while reading: {file.path}")
            digest.update(chunk)
            if sink is not None:
                sink.write(chunk)
        if (size != file.size or _identity(os.fstat(stream.fileno())) != _identity(before)
                or _identity(_source_stat(file.source)) != _identity(before)):
            raise ValueError(f"source changed while reading: {file.path}")
    return {"path": file.path, "bytes": size, "sha256": digest.hexdigest()}


def _collect_sources(root: Path, textures: Sequence[str], limits: Limits) -> list[SourceFile]:
    _directory_chain(root)
    shaders = root / "shaders"
    _directory_chain(shaders)
    files: dict[str, SourceFile] = {}
    nodes: dict[str, tuple[str, bool]] = {}
    total = 0

    def add(path: str, source: Path) -> None:
        nonlocal total
        validate_path(path)
        _register_path(nodes, path, directory=False)
        if path in files:
            raise ValueError(f"duplicate selected asset: {path}")
        size = _source_stat(source).st_size
        if size > limits.file_bytes or len(files) >= limits.file_count:
            raise ValueError("asset file size/count exceeds installer limit")
        total += size
        if total > limits.extracted_bytes:
            raise ValueError("total asset bytes exceed installer limit")
        files[path] = SourceFile(path, source, size)

    # Do not follow links, recurse by extension, or silently skip any shader file.
    pending, directory_count = [shaders], 0
    while pending:
        directory = pending.pop()
        _directory_chain(directory)
        directory_count += 1
        if directory_count > limits.file_count:
            raise ValueError("shader directory count exceeds safe traversal limit")
        with os.scandir(directory) as children:
            for child in children:
                source = directory / child.name
                relative = source.relative_to(root).as_posix()
                info = child.stat(follow_symlinks=False)
                if _is_link(info):
                    raise ValueError(f"linked shader resource is not allowed: {relative}")
                if stat.S_ISDIR(info.st_mode):
                    validate_path(relative, directory=True)
                    _register_path(nodes, relative, directory=True)
                    pending.append(source)
                    if len(pending) + directory_count > limits.file_count:
                        raise ValueError("shader directory count exceeds safe traversal limit")
                else:
                    add(relative, source)
    if not files:
        raise ValueError("the explicitly selected shaders tree contains no files")
    for path in textures:
        validate_path(path)
        if path.split("/", 1)[0] not in {"materials", "textures"} or not path.endswith(".tex"):
            raise ValueError("--texture requires an exact materials/...tex or textures/...tex path")
        add(path, root.joinpath(*path.split("/")))
    return [files[path] for path in sorted(files)]


class _BoundedOutput:
    """Limit writes including local headers, compressed bytes and central directory."""

    def __init__(self, stream: BinaryIO, limit: int):
        self.stream, self.limit = stream, limit

    def write(self, data: bytes) -> int:
        if self.stream.tell() + len(data) > self.limit:
            raise ValueError("compressed ZIP exceeds installer limit")
        return self.stream.write(data)

    def tell(self) -> int:
        return self.stream.tell()

    def seek(self, offset: int, whence: int = 0) -> int:
        return self.stream.seek(offset, whence)

    def flush(self) -> None:
        self.stream.flush()


def _zip_info(path: str, size: int) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = ZIP_MODE
    info.compress_type = zipfile.ZIP_DEFLATED
    info.file_size = size
    return info


def _read_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    if info.file_size > limit:
        raise ValueError("ZIP member exceeds byte limit")
    with archive.open(info) as stream:
        data = stream.read(limit + 1)
    if len(data) != info.file_size or len(data) > limit:
        raise ValueError("ZIP member size does not match metadata")
    return data


def verify_archive(path: Path, limits: Limits = DEFAULT_LIMITS) -> dict:
    """Independently read every payload/hash and enforce the installer ZIP contract."""
    _validate_limits(limits)
    size = path.stat().st_size
    if not 0 < size <= limits.archive_bytes:
        raise ValueError("ZIP archive exceeds byte limit")
    with zipfile.ZipFile(path, "r", allowZip64=False) as archive:
        infos = archive.infolist()
        if archive.comment or not 1 < len(infos) <= limits.file_count + 1:
            raise ValueError("ZIP entry count/comment is not supported")
        nodes: dict[str, tuple[str, bool]] = {}
        entries: dict[str, zipfile.ZipInfo] = {}
        for info in infos:
            validate_path(info.filename, manifest=True)
            _register_path(nodes, info.filename, directory=False)
            if (info.filename in entries or info.create_system != 3 or info.external_attr != ZIP_MODE
                    or info.compress_type != zipfile.ZIP_DEFLATED or info.is_dir()
                    or info.flag_bits & ~0x800 or info.extract_version >= 45
                    or info.extra or info.comment or info.volume != 0):
                raise ValueError("ZIP entry is duplicate, special, executable, encrypted or non-deflated")
            cap = limits.manifest_bytes if info.filename == MANIFEST_NAME else limits.file_bytes
            if info.file_size > cap:
                raise ValueError("ZIP member exceeds byte limit")
            entries[info.filename] = info
        if MANIFEST_NAME not in entries:
            raise ValueError("ZIP has no root manifest")
        data = _read_member(archive, entries.pop(MANIFEST_NAME), limits.manifest_bytes)
        manifest = json.loads(data)
        if (not isinstance(manifest, dict) or set(manifest) != {"schema", "files"}
                or manifest["schema"] != SCHEMA or not isinstance(manifest["files"], list)
                or len(manifest["files"]) != len(entries)):
            raise ValueError("invalid shared-assets manifest")
        declared, total = set(), 0
        for row in manifest["files"]:
            if not isinstance(row, dict) or set(row) != {"path", "bytes", "sha256"}:
                raise ValueError("invalid manifest file record")
            name, count, digest = row["path"], row["bytes"], row["sha256"]
            validate_path(name)
            if (name in declared or name not in entries or type(count) is not int
                    or not 0 <= count <= limits.file_bytes or count != entries[name].file_size
                    or not isinstance(digest, str) or len(digest) != 64
                    or any(char not in "0123456789abcdef" for char in digest)):
                raise ValueError("invalid manifest file size/path/hash")
            total += count
            if total > limits.extracted_bytes:
                raise ValueError("extracted ZIP exceeds installer limit")
            hasher, read = hashlib.sha256(), 0
            with archive.open(entries[name]) as stream:
                while chunk := stream.read(min(CHUNK_BYTES, count - read + 1)):
                    read += len(chunk)
                    if read > count:
                        raise ValueError("ZIP payload exceeds declared size")
                    hasher.update(chunk)
            if read != count or hasher.hexdigest() != digest:
                raise ValueError("ZIP payload hash mismatch")
            declared.add(name)
        if declared != entries.keys() or not any(name.startswith("shaders/") for name in declared):
            raise ValueError("ZIP manifest does not declare exactly the shared payload")
    return {"file_count": len(declared), "payload_bytes": total, "manifest_bytes": len(data),
            "manifest_sha256": hashlib.sha256(data).hexdigest()}


def pack_assets(assets: Path, output: Path, textures: Sequence[str] = (),
                limits: Limits = DEFAULT_LIMITS) -> dict:
    _validate_limits(limits)
    root, output = _absolute(assets), _absolute(output)
    if os.path.lexists(output):
        raise FileExistsError(f"output must not exist: {output}")
    if output.is_relative_to(root):
        raise ValueError("output must be outside the read-only owned assets root")
    _directory_chain(output.parent)
    sources = _collect_sources(root, textures, limits)
    before = [_read_source(file) for file in sources]
    manifest = (json.dumps({"schema": SCHEMA, "files": before}, ensure_ascii=False,
                           separators=(",", ":")) + "\n").encode("utf-8")
    if len(manifest) > limits.manifest_bytes:
        raise ValueError("manifest exceeds installer limit")
    # Exclusive creation refuses files, directories and dangling links, including a
    # competing writer that publishes after preflight. Only our partial file is removed.
    with output.open("x+b") as raw:
        owned_identity = os.fstat(raw.fileno())
        try:
            bounded = _BoundedOutput(raw, limits.archive_bytes)
            with zipfile.ZipFile(bounded, "w", compression=zipfile.ZIP_DEFLATED,
                                 allowZip64=False) as archive:
                archive.writestr(_zip_info(MANIFEST_NAME, len(manifest)), manifest)
                for file, expected in zip(sources, before):
                    with archive.open(_zip_info(file.path, file.size), "w") as stream:
                        if _read_source(file, stream) != expected:
                            raise ValueError(f"source changed since initial hash: {file.path}")
            raw.flush()
            after = [_read_source(file) for file in sources]
            if after != before:
                raise ValueError("source preservation check failed")
            verification = verify_archive(output, limits)
            raw.seek(0)
            hasher = hashlib.sha256()
            while chunk := raw.read(CHUNK_BYTES):
                hasher.update(chunk)
            archive_bytes = os.fstat(raw.fileno()).st_size
        except BaseException:
            raw.close()
            current = output.lstat()
            if (not _is_link(current) and current.st_dev == owned_identity.st_dev
                    and current.st_ino == owned_identity.st_ino):
                output.unlink()  # Exact absolute path exclusively created above.
            raise
    return {
        "archive": str(output), "archive_bytes": archive_bytes,
        "archive_sha256": hasher.hexdigest(), "source_root": str(root),
        "selection": {"shaders": "complete recursive shaders/ tree", "textures": list(textures)},
        **verification, "source_preserved": True, "source_before": before, "source_after": after,
        "archive_verified": True, "device_or_gpu_verified": False,
        "distribution": "private user-owned resource transfer; do not commit licensed payloads",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, required=True, help="explicit user-owned assets root; no discovery")
    parser.add_argument("--output", type=Path, required=True, help="new ZIP path in an existing private directory")
    parser.add_argument("--texture", action="append", default=[], help="exact assets-relative .tex file; repeat as needed")
    args = parser.parse_args(argv)
    try:
        report = pack_assets(args.assets, args.output, args.texture)
    except (OSError, ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        print(f"shared assets pack: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=True, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
