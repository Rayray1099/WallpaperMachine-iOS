# SPDX-License-Identifier: GPL-3.0-only
"""Offline format/closure tests; these do not constitute a GPU rendering pass."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "ios" / "make_native_scene_fixture.py"
SPEC = importlib.util.spec_from_file_location("ios_native_scene_fixture", SCRIPT)
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)


def read_package(blob: bytes) -> dict[str, bytes]:
    """Independent reader of the PKGV0001 header/table, with bounded payload slices."""
    version_size, = struct.unpack_from("<I", blob)
    if blob[4:4 + version_size] != b"PKGV0001":
        raise ValueError("wrong package version")
    count, = struct.unpack_from("<I", blob, 4 + version_size)
    cursor, rows = 8 + version_size, []
    for _ in range(count):
        name_size, = struct.unpack_from("<I", blob, cursor)
        cursor += 4
        name = blob[cursor:cursor + name_size].decode("utf-8")
        cursor += name_size
        offset, size = struct.unpack_from("<II", blob, cursor)
        cursor += 8
        rows.append((name, offset, size))
    if len({name for name, _, _ in rows}) != count:
        raise ValueError("duplicate package entry")
    result = {}
    for name, offset, size in rows:
        if cursor + offset + size > len(blob):
            raise ValueError("package payload exceeds file")
        result[name] = blob[cursor + offset:cursor + offset + size]
    return result


class NativeSceneFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wm-native-fixture-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.report = fixture.build_fixture(self.root / "new-output")
        self.project = Path(self.report["project_directory"])
        self.archive = Path(self.report["archive"])

    def test_package_only_virtual_scene_and_manifest(self):
        self.assertEqual({p.name for p in self.project.iterdir()}, {"project.json", "scene.pkg", "preview.png"})
        self.assertFalse((self.project / "scene.json").exists())
        manifest = json.loads((self.project / "project.json").read_bytes())
        self.assertEqual(manifest["type"], "scene")
        self.assertEqual(manifest["file"], "scene.json")
        self.assertEqual(manifest["general"]["properties"], {})
        with zipfile.ZipFile(self.archive) as archive:
            self.assertEqual(set(archive.namelist()), {"project.json", "scene.pkg", "preview.png"})
            self.assertIsNone(archive.testzip())
            for name in archive.namelist():
                self.assertEqual(archive.read(name), (self.project / name).read_bytes())

    def test_one_visible_quad_has_complete_local_dependency_closure(self):
        entries = read_package((self.project / "scene.pkg").read_bytes())
        scene = json.loads(entries["scene.json"])
        self.assertEqual(len(scene["objects"]), 1)
        layer = scene["objects"][0]
        self.assertEqual(layer["origin"], "128 72 0")
        self.assertEqual(layer["size"], "256 144")
        self.assertEqual(layer["color"], "1 1 1")
        self.assertEqual(layer["alpha"], 1)
        self.assertTrue(layer["visible"])
        self.assertFalse(layer.get("effects", []))
        self.assertEqual(scene["general"]["orthogonalprojection"], {"width": 256, "height": 144})
        for flag in ("bloom", "hdr", "camerashake", "cameraparallax"):
            self.assertFalse(scene["general"][flag])
        model = json.loads(entries[layer["image"]])
        material = json.loads(entries[model["material"]])
        self.assertEqual(len(material["passes"]), 1)
        required = {"scene.json", layer["image"], model["material"]}
        for render_pass in material["passes"]:
            for stage in ("vert", "frag"):
                key = "shaders/" + render_pass["shader"] + "." + stage
                self.assertNotIn(b"#include", entries[key])
                self.assertIn(b"void main()", entries[key])
                required.add(key)
            for texture in render_pass["textures"]:
                required.add("materials/" + texture + ".tex")
        self.assertEqual(set(entries), required)
        self.assertEqual(len(required), 6)

    def test_tex_header_and_authored_corner_pixels(self):
        entries = read_package((self.project / "scene.pkg").read_bytes())
        tex = entries["materials/qa_quadrants.tex"]
        self.assertEqual(tex[:18], b"TEXV0005\0TEXI0001\0")
        self.assertEqual(struct.unpack_from("<7I", tex, 18), (0, 3, 4, 4, 4, 4, 0xff000000))
        self.assertEqual(tex[46:55], b"TEXB0002\0")
        self.assertEqual(struct.unpack_from("<7I", tex, 55), (1, 1, 4, 4, 0, 64, 64))
        self.assertEqual(len(tex), 147)
        for x, y, color in ((0, 0, (255, 0, 0, 255)), (3, 0, (0, 255, 0, 255)),
                            (0, 3, (0, 0, 255, 255)), (3, 3, (255, 255, 0, 255))):
            start = 83 + (y * 4 + x) * 4
            self.assertEqual(tuple(tex[start:start + 4]), color)

    def test_deterministic_archive_does_not_claim_gpu_success(self):
        other = fixture.build_fixture(self.root / "other-output")
        self.assertEqual(self.archive.read_bytes(), Path(other["archive"]).read_bytes())
        self.assertEqual(self.report["archive_sha256"], other["archive_sha256"])
        self.assertEqual(self.report["shared_asset_dependencies"], [])
        self.assertFalse(self.report["actual_gpu_frame_verified"])

    def test_member_hashes_cover_exact_uncompressed_payloads(self):
        with zipfile.ZipFile(self.archive) as archive:
            self.assertEqual(set(self.report["member_sha256"]), set(archive.namelist()))
            for name in archive.namelist():
                expected = hashlib.sha256(archive.read(name)).hexdigest()
                self.assertEqual(self.report["member_sha256"][name], expected)
                self.assertEqual(expected, hashlib.sha256((self.project / name).read_bytes()).hexdigest())

    def test_zip_creator_metadata_does_not_depend_on_host_defaults(self):
        original_init = zipfile.ZipInfo.__init__

        def windows_defaults(info, *args, **kwargs):
            original_init(info, *args, **kwargs)
            info.create_system = 0
            info.external_attr = 0

        def unix_defaults(info, *args, **kwargs):
            original_init(info, *args, **kwargs)
            info.create_system = 3
            info.external_attr = 0o100600 << 16

        with mock.patch.object(zipfile.ZipInfo, "__init__", windows_defaults):
            windows = fixture.build_fixture(self.root / "windows-defaults")
        with mock.patch.object(zipfile.ZipInfo, "__init__", unix_defaults):
            unix = fixture.build_fixture(self.root / "unix-defaults")
        self.assertEqual(Path(windows["archive"]).read_bytes(), Path(unix["archive"]).read_bytes())
        self.assertEqual(windows["member_sha256"], unix["member_sha256"])
        with zipfile.ZipFile(self.archive) as archive:
            for info in archive.infolist():
                self.assertEqual(info.create_system, 3)
                self.assertEqual(info.external_attr, 0o100644 << 16)

    def test_existing_directory_and_file_are_never_overwritten(self):
        occupied = self.root / "occupied"
        occupied.mkdir()
        sentinel = occupied / "sentinel.txt"
        sentinel.write_text("untouched", encoding="utf-8")
        for path in (occupied, sentinel, Path(self.root.anchor)):
            with self.subTest(path=path), self.assertRaises((FileExistsError, ValueError)):
                fixture.build_fixture(path)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "untouched")
        self.assertEqual(list(occupied.iterdir()), [sentinel])
        empty = self.root / "existing-empty"
        empty.mkdir()
        with self.assertRaises(FileExistsError):
            fixture.build_fixture(empty)
        self.assertEqual(list(empty.iterdir()), [])

    def test_dangling_symlink_is_not_followed_or_replaced(self):
        link = self.root / "dangling"
        target = self.root / "absent-target"
        try:
            link.symlink_to(target, target_is_directory=True)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")
        with self.assertRaises(FileExistsError):
            fixture.build_fixture(link)
        self.assertTrue(link.is_symlink())
        self.assertFalse(target.exists())

    def test_cli_reports_paths_and_refuses_second_run(self):
        output = self.root / "cli-output"
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(fixture.main(["--output", str(output)]), 0)
        report = json.loads(stdout.getvalue())
        self.assertEqual(Path(report["project_directory"]), output / fixture.PROJECT_NAME)
        self.assertEqual(stderr.getvalue(), "")
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(fixture.main(["--output", str(output)]), 1)
        self.assertIn("output must not exist", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
