#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate an entirely self-authored packed quad scene; never claim GPU verification.

Usage: python scripts/ios/make_native_scene_fixture.py --output artifacts/new-fixture
The output directory must not exist. Point WM_NATIVE_SCENE_FIXTURE at the reported
project_directory for ios_scene_startup_render_test on a Metal-enabled build host.
Only Python's standard library is needed; no Workshop or shared assets are read.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import zipfile
import zlib
from pathlib import Path

PROJECT_NAME = "WM-QA-Native-Quadrants"
COLORS = ((255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 0, 255))
VERTEX = b"""attribute vec3 a_Position;
attribute vec2 a_TexCoord;
varying vec2 v_TexCoord;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
    gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    v_TexCoord = a_TexCoord;
}
"""
FRAGMENT = b"""varying vec2 v_TexCoord;
uniform sampler2D g_Texture0;
uniform vec4 g_Color4;
void main() {
    gl_FragColor = texSample2D(g_Texture0, v_TexCoord) * g_Color4;
}
"""


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2) + "\n").encode("utf-8")


def quadrant_pixels() -> bytes:
    return b"".join(bytes(COLORS[(2 if y >= 2 else 0) + (1 if x >= 2 else 0)])
                    for y in range(4) for x in range(4))


def make_texture(pixels: bytes) -> bytes:
    # Exact uncompressed RGBA8 format used by tests/support/scene_package.cpp.
    return (b"TEXV0005\0TEXI0001\0" + struct.pack("<7I", 0, 3, 4, 4, 4, 4, 0xff000000)
            + b"TEXB0002\0" + struct.pack("<7I", 1, 1, 4, 4, 0, len(pixels), len(pixels)) + pixels)


def make_preview(pixels: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data)))

    raw = b"".join(b"\0" + pixels[y * 16:(y + 1) * 16] for y in range(4))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 4, 4, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def package_entries() -> dict[str, bytes]:
    # Explicit bloom=false matters: otherwise the parser requests shared bloom materials.
    scene = {
        "camera": {"center": "0 0 0", "eye": "0 0 1", "up": "0 1 0"},
        "general": {
            "orthogonalprojection": {"width": 256, "height": 144},
            "clearcolor": "0 0 0", "clearenabled": True,
            "bloom": False, "hdr": False, "camerashake": False, "cameraparallax": False,
        },
        "objects": [{"id": 1, "name": "self-authored quadrants", "image": "models/qa_quad.json",
                     "origin": "128 72 0", "size": "256 144", "color": "1 1 1",
                     "alpha": 1.0, "visible": True}],
    }
    material = {"passes": [{"shader": "qa_quad", "textures": ["qa_quadrants"],
                            "blending": "disabled", "cullmode": "nocull",
                            "depthtest": "disabled", "depthwrite": "disabled"}]}
    return {
        "scene.json": json_bytes(scene),
        "models/qa_quad.json": json_bytes({"material": "materials/qa_quad.json", "autosize": False}),
        "materials/qa_quad.json": json_bytes(material),
        "shaders/qa_quad.vert": VERTEX,
        "shaders/qa_quad.frag": FRAGMENT,
        "materials/qa_quadrants.tex": make_texture(quadrant_pixels()),
    }


def make_package(entries: dict[str, bytes]) -> bytes:
    # WPPkgFs offsets are relative to the end of the complete entry table.
    table, payload, offset = [], [], 0
    for name, data in entries.items():
        encoded = name.encode("utf-8")
        table.append(struct.pack("<I", len(encoded)) + encoded + struct.pack("<II", offset, len(data)))
        payload.append(data)
        offset += len(data)
    return (struct.pack("<I", 8) + b"PKGV0001" + struct.pack("<I", len(entries))
            + b"".join(table) + b"".join(payload))


def build_fixture(output: Path) -> dict:
    # Never reuse, empty, delete or overwrite a caller-owned directory, including
    # dangling symlinks. mkdir(exist_ok=False) also protects against a creation race.
    output = Path(os.path.abspath(os.path.expanduser(str(output))))
    if os.path.lexists(output):
        raise FileExistsError(f"output must not exist: {output}")
    if output.resolve() == Path(output.anchor):
        raise ValueError("output must not be a filesystem root")
    output.mkdir(parents=True, exist_ok=False)
    project = output / PROJECT_NAME
    project.mkdir()
    manifest = {
        "type": "scene", "file": "scene.json", "title": "WM QA Native Quadrants",
        "description": "Self-authored one-pass native scene diagnostic; not a GPU verification result.",
        "preview": "preview.png", "general": {"properties": {}},
    }
    files = {
        "project.json": json_bytes(manifest),
        "scene.pkg": make_package(package_entries()),
        "preview.png": make_preview(quadrant_pixels()),
    }
    for name, data in files.items():
        with (project / name).open("xb") as stream:
            stream.write(data)
    archive = output / (PROJECT_NAME + ".zip")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED) as stream:
        for name, data in files.items():
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            # ZipInfo otherwise selects Windows/Unix metadata from sys.platform.
            # Pin the creator and regular-file mode; compressed bytes can still
            # vary with zlib versions, so publish uncompressed member hashes too.
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            stream.writestr(info, data)
    return {
        "project_directory": str(project), "archive": str(archive),
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "member_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()},
        "shared_asset_dependencies": [], "actual_gpu_frame_verified": False,
        "expected_quadrants": ["top-left red", "top-right green", "bottom-left blue", "bottom-right yellow"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new output directory; existing paths are refused")
    args = parser.parse_args(argv)
    try:
        report = build_fixture(args.output)
    except (OSError, ValueError) as exc:
        print(f"native scene fixture: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
