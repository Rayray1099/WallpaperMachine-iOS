#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Isolated shared-assets packaging tests using only self-authored temporary bytes."""
from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import struct
import tempfile
import unittest
import unicodedata
import zipfile
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "ios" / "package_shared_assets.py"
SPEC = importlib.util.spec_from_file_location("ios_shared_assets_pack", SCRIPT)
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)


class SharedAssetsPackTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="wm-shared-assets-test-")
        self.addCleanup(self.temporary.cleanup)
        # macOS exposes tempfile paths through /var -> /private/var. Our owned
        # fixture is canonical; user-supplied source/output links remain refused.
        self.root = Path(self.temporary.name).resolve()
        self.assets = self.root / "owned-assets"
        self.payloads = {
            "shaders/qa.vert": b'#include "common.inc"\nvoid main() {}\n',
            "shaders/qa.frag": b"void main() {}\n",
            "shaders/common.inc": b"// Self-authored include\n",
            "shaders/HLSL/nested/qa.h": b"// Self-authored header\n",
            "shaders/declarations.json": b'{"selfAuthored":true}\n',
            "shaders/cache/qa.bin": bytes(range(256)),
            "materials/particle/qa.tex": b"self-authored particle texture\x00\xff",
            "textures/util/qa.tex": b"self-authored texture path\x00",
        }
        for name, data in self.payloads.items():
            target = self.assets / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        # These are intentionally not selected or read by the packager.
        (self.assets / "materials/unselected.tex").write_bytes(b"do not include")
        (self.assets / "private.json").write_bytes(b"not shared resources")
        self.output = self.root / "new.zip"
        self.textures = ["materials/particle/qa.tex", "textures/util/qa.tex"]

    def build(self, **kwargs):
        return pack.pack_assets(self.assets, self.output, self.textures, **kwargs)

    def snapshot(self):
        return {p.relative_to(self.assets).as_posix(): (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest())
                for p in self.assets.rglob("*") if p.is_file()}

    def rewrite_archive(self, mutate):
        """Construct deliberately invalid archives from authored test bytes only."""
        self.build()
        with zipfile.ZipFile(self.output) as archive:
            rows = [(entry, archive.read(entry)) for entry in archive.infolist()]
        other = self.root / "mutated.zip"
        with zipfile.ZipFile(other, "w") as archive:
            for entry, data in rows:
                result = mutate(entry, data)
                if result is not None:
                    archive.writestr(*result)
        return other

    def test_exact_recursive_shaders_and_only_explicit_texture_files(self):
        report = self.build()
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()), {*self.payloads, pack.MANIFEST_NAME})
            self.assertTrue(all(not entry.is_dir() for entry in archive.infolist()))
            self.assertIsNone(archive.testzip())
            for name, data in self.payloads.items():
                self.assertEqual(archive.read(name), data)
        self.assertEqual(report["selection"]["textures"], self.textures)
        self.assertEqual(report["file_count"], len(self.payloads))
        self.assertEqual(report["payload_bytes"], sum(map(len, self.payloads.values())))
        self.assertTrue(report["archive_verified"])
        self.assertFalse(report["device_or_gpu_verified"])

    def test_manifest_has_exact_schema_sizes_hashes_and_no_extra_root(self):
        report = self.build()
        with zipfile.ZipFile(self.output) as archive:
            data = archive.read(pack.MANIFEST_NAME)
            manifest = json.loads(data)
        self.assertEqual(set(manifest), {"schema", "files"})
        self.assertEqual(manifest["schema"], "wallpapermachine.shared-assets/v1")
        rows = [{"path": name, "bytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
                for name, payload in sorted(self.payloads.items())]
        self.assertEqual(manifest["files"], rows)
        self.assertEqual(report["manifest_sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(report["manifest_bytes"], len(data))

    def test_full_source_bytes_and_hashes_are_preserved_and_reported_before_after(self):
        before = self.snapshot()
        report = self.build()
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(report["source_preserved"])
        self.assertEqual(report["source_before"], report["source_after"])
        self.assertEqual({row["path"] for row in report["source_before"]}, set(self.payloads))
        for row in report["source_before"]:
            self.assertEqual((row["bytes"], row["sha256"]), before[row["path"]])
        self.assertEqual(report["archive_bytes"], self.output.stat().st_size)
        self.assertEqual(report["archive_sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())

    def test_strict_raw_central_directory_matches_ios_installer(self):
        self.build()
        blob = self.output.read_bytes()
        end = len(blob) - 22
        signature, disk, central_disk, disk_count, count, size, cursor, comment = struct.unpack_from("<I4H2IH", blob, end)
        self.assertEqual((signature, disk, central_disk, disk_count, count, comment),
                         (0x06054B50, 0, 0, len(self.payloads) + 1, len(self.payloads) + 1, 0))
        self.assertEqual(cursor + size, end)
        for _ in range(count):
            self.assertEqual(struct.unpack_from("<I", blob, cursor)[0], 0x02014B50)
            self.assertEqual(blob[cursor + 5], 3)
            flags, method = struct.unpack_from("<HH", blob, cursor + 8)
            self.assertEqual(flags & ~0x800, 0)
            self.assertEqual(method, 8)
            name_size, extra_size, comment_size, disk_start = struct.unpack_from("<4H", blob, cursor + 28)
            self.assertEqual((extra_size, comment_size, disk_start), (0, 0, 0))
            attributes, local_offset = struct.unpack_from("<II", blob, cursor + 38)
            self.assertEqual(attributes, (stat.S_IFREG | 0o644) << 16)
            self.assertEqual((attributes >> 16) & 0o111, 0)
            self.assertEqual(struct.unpack_from("<I", blob, local_offset)[0], 0x04034B50)
            self.assertEqual(struct.unpack_from("<H", blob, local_offset + 8)[0], 8)
            name = blob[cursor + 46:cursor + 46 + name_size].decode("utf-8")
            self.assertNotIn("\\", name)
            self.assertFalse(name.endswith("/"))
            cursor += 46 + name_size + extra_size + comment_size
        self.assertEqual(cursor, end)

    def test_posix_zip_metadata_does_not_depend_on_windows_defaults(self):
        original = zipfile.ZipInfo.__init__

        def windows_defaults(info, *args, **kwargs):
            original(info, *args, **kwargs)
            info.create_system = 0
            info.external_attr = 0

        with mock.patch.object(zipfile.ZipInfo, "__init__", windows_defaults):
            self.build()
        with zipfile.ZipFile(self.output) as archive:
            for entry in archive.infolist():
                self.assertEqual(entry.create_system, 3)
                self.assertEqual(entry.external_attr, (stat.S_IFREG | 0o644) << 16)
                self.assertEqual(entry.compress_type, 8)

    def test_archive_is_deterministic_for_same_owned_bytes(self):
        self.build()
        second = self.root / "other.zip"
        pack.pack_assets(self.assets, second, list(reversed(self.textures)))
        self.assertEqual(self.output.read_bytes(), second.read_bytes())

    def test_shader_only_selection_does_not_read_or_include_textures(self):
        original = pack._read_source
        observed = []

        def record(file, sink=None):
            observed.append(file.path)
            return original(file, sink)

        with mock.patch.object(pack, "_read_source", side_effect=record):
            report = pack.pack_assets(self.assets, self.output)
        self.assertTrue(observed)
        self.assertTrue(all(path.startswith("shaders/") for path in observed))
        self.assertEqual(report["selection"]["textures"], [])

    def test_missing_selected_texture_fails_without_output_or_fallback(self):
        with self.assertRaises(FileNotFoundError):
            pack.pack_assets(self.assets, self.output, ["textures/missing.tex"])
        self.assertFalse(self.output.exists())

    def test_texture_paths_are_explicit_root_relative_not_discovered_or_remapped(self):
        for path in ("qa.tex", "particle/qa.tex", "shaders/qa.vert", "materials/qa.json",
                     "materials/particle/qa.TEX", "textures/../materials/particle/qa.tex"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                pack.pack_assets(self.assets, self.output, [path])
            self.assertFalse(self.output.exists())

    def test_unsafe_paths_and_reserved_components_are_refused(self):
        names = ["/shaders/a.frag", "shaders//a.frag", "shaders/./a.frag", "shaders/../a.frag",
                 "shaders/.hidden/a.frag", "shaders/a./b.frag", "shaders/a /b.frag",
                 "shaders/a\\b.frag", "shaders/C:/a.frag", "shaders/a\x00.frag", "shaders/a\n.frag",
                 "shaders/CON.h", "shaders/COM1.inc", "shaders/lpt¹.h", "shaders/AUX/x.h",
                 "shaders/a?.frag", "shaders/a*.frag", "shaders/<a>.frag", "shaders/a|b.frag",
                 "shaders/test.exe", "shaders/test.CMD", "shaders/a/", "other/a.frag",
                 "shaders/" + "a" * 256, "shaders/" + "a/" * 600 + "a.h",
                 "shaders/" + unicodedata.normalize("NFD", "café.h"), "shaders/a\u202eb.frag"]
        for name in names:
            with self.subTest(name=name), self.assertRaises(ValueError):
                pack.validate_path(name)
        for name in ("shaders/common.inc", "shaders/HLSL/qa.h", "shaders/café.frag"):
            pack.validate_path(name)

    def test_casefold_unicode_and_parent_directory_collisions_are_refused(self):
        for names in (("shaders/A.h", "shaders/a.h"),
                      ("shaders/Dir/a.h", "shaders/dir/b.h"),
                      ("shaders/straße.h", "shaders/STRASSE.h"),
                      ("shaders/file", "shaders/file/sub.h")):
            with self.subTest(names=names):
                nodes = {}
                pack._register_path(nodes, names[0], directory=False)
                with self.assertRaises(ValueError):
                    pack._register_path(nodes, names[1], directory=False)

    def test_duplicate_explicit_texture_is_refused(self):
        with self.assertRaises(ValueError):
            pack.pack_assets(self.assets, self.output, self.textures * 2)
        self.assertFalse(self.output.exists())

    def test_existing_files_directories_and_output_inside_sources_are_not_modified(self):
        self.output.write_bytes(b"existing output sentinel")
        before = self.snapshot()
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertEqual(self.output.read_bytes(), b"existing output sentinel")
        occupied = self.root / "occupied"
        occupied.mkdir()
        with self.assertRaises(FileExistsError):
            pack.pack_assets(self.assets, occupied)
        self.assertEqual(list(occupied.iterdir()), [])
        with self.assertRaises(ValueError):
            pack.pack_assets(self.assets, self.assets / "new.zip")
        self.assertEqual(self.snapshot(), before)

    def test_linked_source_or_output_ancestor_is_still_refused(self):
        alias = self.root / "linked-parent"
        try:
            alias.symlink_to(self.root, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("directory symlinks unavailable")
        with self.assertRaisesRegex(ValueError, "link or non-directory"):
            pack.pack_assets(alias / "owned-assets", self.output, self.textures)
        self.assertFalse(self.output.exists())
        with self.assertRaisesRegex(ValueError, "link or non-directory"):
            pack.pack_assets(self.assets, alias / "new.zip", self.textures)
        self.assertFalse(self.output.exists())

    def test_output_parent_must_already_exist(self):
        output = self.root / "missing-parent/new.zip"
        with self.assertRaises(FileNotFoundError):
            pack.pack_assets(self.assets, output)
        self.assertFalse(output.parent.exists())

    def test_source_root_and_nonempty_shaders_are_required_without_discovery(self):
        empty = self.root / "empty-assets"
        empty.mkdir()
        with self.assertRaises(FileNotFoundError):
            pack.pack_assets(empty, self.output)
        (empty / "shaders").mkdir()
        with self.assertRaises(ValueError):
            pack.pack_assets(empty, self.output)
        self.assertFalse(self.output.exists())

    def test_file_count_file_bytes_total_bytes_and_manifest_caps_fail_closed(self):
        limits = [pack.Limits(file_count=2), pack.Limits(file_bytes=8),
                  pack.Limits(extracted_bytes=20), pack.Limits(manifest_bytes=20)]
        for cap in limits:
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                self.build(limits=cap)
            self.assertFalse(self.output.exists())

    def test_zip_byte_cap_removes_only_the_new_partial_zip(self):
        sentinel = self.root / "unrelated.zip"
        sentinel.write_bytes(b"unrelated")
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.build(limits=pack.Limits(archive_bytes=100))
        self.assertFalse(self.output.exists())
        self.assertEqual(sentinel.read_bytes(), b"unrelated")
        self.assertEqual(self.snapshot(), before)

    def test_shader_directory_traversal_is_bounded_even_with_empty_directories(self):
        empty = self.root / "many-empty"
        for number in range(8):
            (empty / "shaders" / str(number)).mkdir(parents=True)
        (empty / "shaders/qa.vert").write_bytes(b"authored")
        with self.assertRaises(ValueError):
            pack.pack_assets(empty, self.output, limits=pack.Limits(file_count=3))
        self.assertFalse(self.output.exists())

    def test_installer_caps_cannot_be_disabled_or_increased(self):
        for cap in (pack.Limits(file_count=20_001), pack.Limits(archive_bytes=0),
                    pack.Limits(manifest_bytes=-1), pack.Limits(file_bytes=True)):
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                self.build(limits=cap)
        self.assertFalse(self.output.exists())

    def test_executable_shader_tree_file_is_rejected_not_silently_skipped(self):
        (self.assets / "shaders/payload.exe").write_bytes(b"self-authored not an executable")
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_mid_copy_source_mutation_is_rejected_and_partial_zip_removed(self):
        original = pack._read_source
        target = self.assets / "shaders/qa.frag"

        def mutate_during_copy(file, sink=None):
            if sink is not None and file.path == "shaders/qa.frag":
                target.write_bytes(b"changed size during copy")
            return original(file, sink)

        with mock.patch.object(pack, "_read_source", side_effect=mutate_during_copy):
            with self.assertRaises(ValueError):
                self.build()
        self.assertFalse(self.output.exists())

    def test_same_size_source_mutation_after_copy_fails_preservation_check(self):
        original = pack._read_source
        changed = False

        def mutate_after_copy(file, sink=None):
            nonlocal changed
            result = original(file, sink)
            if sink is not None and not changed:
                file.source.write_bytes(b"X" * file.size)
                changed = True
            return result

        with mock.patch.object(pack, "_read_source", side_effect=mutate_after_copy):
            with self.assertRaises(ValueError):
                self.build()
        self.assertTrue(changed)
        self.assertFalse(self.output.exists())

    def symlink(self, link, target, *, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError) as exc:
            self.skipTest(f"symlink creation unavailable: {exc}")

    def test_dangling_output_link_is_never_followed_or_replaced(self):
        target = self.root / "missing.zip"
        self.symlink(self.output, target)
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(target.exists())

    def test_shader_file_and_directory_links_are_rejected(self):
        target = self.root / "external-self-authored.h"
        target.write_bytes(b"outside root")
        link = self.assets / "shaders/linked.h"
        self.symlink(link, target)
        with self.assertRaises(ValueError):
            self.build()
        self.assertFalse(self.output.exists())
        self.assertEqual(target.read_bytes(), b"outside root")

    def test_linked_texture_parent_is_rejected(self):
        external = self.root / "outside"
        external.mkdir()
        (external / "qa.tex").write_bytes(b"outside root")
        self.symlink(self.assets / "materials/linked", external, directory=True)
        with self.assertRaises(ValueError):
            pack.pack_assets(self.assets, self.output, ["materials/linked/qa.tex"])
        self.assertFalse(self.output.exists())

    def test_linked_source_root_is_rejected(self):
        link = self.root / "linked-assets"
        self.symlink(link, self.assets, directory=True)
        with self.assertRaises(ValueError):
            pack.pack_assets(link, self.output)
        self.assertFalse(self.output.exists())

    def test_verifier_refuses_payload_hash_mismatch(self):
        def mutate(entry, data):
            return entry, b"corrupt" if entry.filename == "shaders/qa.frag" else data

        invalid = self.rewrite_archive(mutate)
        with self.assertRaises(ValueError):
            pack.verify_archive(invalid)

    def test_verifier_refuses_executable_or_windows_metadata_and_stored_entries(self):
        for field, value in (("external_attr", (stat.S_IFREG | 0o755) << 16),
                             ("create_system", 0), ("compress_type", zipfile.ZIP_STORED)):
            def mutate(entry, data):
                if entry.filename == "shaders/qa.frag":
                    setattr(entry, field, value)
                return entry, data

            with self.subTest(field=field):
                if self.output.exists():
                    self.output.unlink()
                invalid = self.rewrite_archive(mutate)
                with self.assertRaises(ValueError):
                    pack.verify_archive(invalid)

    def test_verifier_refuses_undeclared_member_and_missing_manifest(self):
        def rename(entry, data):
            if entry.filename == "shaders/qa.frag":
                entry.filename = "shaders/other.frag"
            return entry, data

        invalid = self.rewrite_archive(rename)
        with self.assertRaises(ValueError):
            pack.verify_archive(invalid)
        self.output.unlink()
        invalid = self.rewrite_archive(lambda entry, data: None if entry.filename == pack.MANIFEST_NAME else (entry, data))
        with self.assertRaises(ValueError):
            pack.verify_archive(invalid)

    def test_verifier_rechecks_all_installer_quotas(self):
        self.build()
        for cap in (pack.Limits(archive_bytes=100), pack.Limits(file_count=2),
                    pack.Limits(file_bytes=8), pack.Limits(extracted_bytes=20),
                    pack.Limits(manifest_bytes=20)):
            with self.subTest(cap=cap), self.assertRaises(ValueError):
                pack.verify_archive(self.output, cap)

    def test_cli_requires_explicit_root_and_refuses_overwrite(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                pack.main(["--output", str(self.output)])
        self.assertEqual(error.exception.code, 2)
        stdout, stderr = io.StringIO(), io.StringIO()
        args = ["--assets", str(self.assets), "--output", str(self.output)]
        for path in self.textures:
            args.extend(["--texture", path])
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            self.assertEqual(pack.main(args), 0)
        report = json.loads(stdout.getvalue())
        self.assertEqual(report["archive"], str(self.output))
        self.assertTrue(report["source_preserved"])
        before = self.output.read_bytes()
        with contextlib.redirect_stderr(stderr):
            self.assertEqual(pack.main(args), 1)
        self.assertEqual(before, self.output.read_bytes())


if __name__ == "__main__":
    unittest.main()
