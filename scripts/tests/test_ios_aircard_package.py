# SPDX-License-Identifier: GPL-3.0-only
"""Self-authored synthetic format tests only: no real app build or hardware access."""
from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "ios" / "package_aircard_validation.py"
SPEC = importlib.util.spec_from_file_location("ios_aircard_package", SCRIPT)
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)


def macho(platform=2, cpu=0x0100000C, kind=2, commands=None):
    if commands is None:
        commands = [struct.pack("<6I", 0x32, 24, platform, 0x00120000, 0x00120000, 0)]
    data = b"".join(commands)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, kind, len(commands), len(data), 0, 0) + data


def sha(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(root):
    return {p.relative_to(root).as_posix(): (p.read_bytes(), p.stat().st_mtime_ns)
            for p in root.rglob("*") if p.is_file()}


class MachOTests(unittest.TestCase):
    def inspect(self, blob):
        return package.inspect_macho(io.BytesIO(blob), len(blob))

    def test_valid_thin_arm64_ios_execute(self):
        self.assertEqual(self.inspect(macho())["platform"], 2)

    def test_simulator_macos_and_other_platforms_rejected(self):
        for platform in (1, 7, 0, 6):
            with self.subTest(platform=platform), self.assertRaises(package.ValidationError):
                self.inspect(macho(platform=platform))

    def test_non_arm64_and_non_execute_rejected(self):
        for blob in (macho(cpu=0x01000007), macho(cpu=12), macho(kind=6)):
            with self.assertRaises(package.ValidationError):
                self.inspect(blob)

    def test_fat_swapped_and_truncated_headers_rejected(self):
        for blob in (b"", macho()[:31], b"\xca\xfe\xba\xbe" + macho()[4:],
                     struct.pack(">8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)):
            with self.assertRaises(package.ValidationError):
                self.inspect(blob)

    def test_malformed_command_tables_rejected(self):
        valid = macho()
        variants = [valid[:-1], macho(commands=[])]
        for offset, value in ((16, 3), (20, 23), (36, 0), (36, 16), (36, 32), (52, 1)):
            data = bytearray(valid)
            struct.pack_into("<I", data, offset, value)
            variants.append(bytes(data))
        variants.append(macho(commands=[struct.pack("<II", 0x24, 8)]))
        variants.append(macho(commands=[valid[32:], valid[32:]]))
        for blob in variants:
            with self.subTest(blob=blob.hex()), self.assertRaises(package.ValidationError):
                self.inspect(blob)

    def test_load_command_size_guard(self):
        with mock.patch.object(package, "MAX_LOAD_COMMAND_BYTES", 16):
            with self.assertRaisesRegex(package.ValidationError, "size limit"):
                self.inspect(macho())

    def test_code_signature_rejected(self):
        signed = macho(commands=[macho()[32:], struct.pack("<4I", 0x1D, 16, 72, 0)])
        with self.assertRaisesRegex(package.ValidationError, "LC_CODE_SIGNATURE"):
            self.inspect(signed)


class AirCardPackageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wm-aircard-unit-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "AirCard-iOS.app"
        self.app.mkdir()
        self.info = {
            "CFBundleIdentifier": "com.mak5er.aircard", "CFBundleExecutable": "AirCard-iOS",
            "CFBundleVersion": "42", "CFBundleShortVersionString": "1.3.2",
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.app / "AirCard-iOS").write_bytes(macho())
        (self.app / "AirCard-iOS").chmod(0o755)
        (self.app / "resource.txt").write_bytes(b"CRC check me, too")
        self.source = self.root / "source"
        self.source.mkdir()
        # Deliberately a synthetic fixture, never advertised as an upstream/app build.
        (self.source / "LICENSE").write_text(
            "MIT License\nSynthetic test notice\nPermission is hereby granted\n", encoding="utf-8")
        changes = []
        for name in sorted(package.PATCHED_PATHS):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"self-authored synthetic patched source\n" + name.encode())
            changes.append({"path": name, "upstream_blob": "a" * 40,
                            "original_sha256": "b" * 64, "patched_sha256": sha(path.read_bytes())})
        self.patch = {
            "source": str(self.source), "upstream_commit": package.BASELINE_AIRCARD_SHA,
            "status": "prepared", "automatic_neospring": False,
            "asset_identifiers_or_names_renamed": False, "cargo_locked": True,
            "rust_test_filter": "wm_posterboard_validation", "changes": changes,
        }
        self.patch_file = self.root / "patch.json"
        self.patch_file.write_text(json.dumps(self.patch), encoding="utf-8")
        self.out = self.root / "out"
        self.ipa = self.out / package.IPA_NAME
        self.prefix = "Payload/AirCard-iOS.app/"
        self.stamp_name = self.prefix + package.STAMP_PATH

    def build(self):
        with mock.patch.object(package, "_source_pin", return_value=package.BASELINE_AIRCARD_SHA):
            return package.package_app(self.app, self.source, self.patch_file, self.out)

    def entries(self):
        with zipfile.ZipFile(self.ipa) as archive:
            return [(row.filename, archive.read(row)) for row in archive.infolist()]

    def rewrite(self, rows, compression=zipfile.ZIP_STORED):
        path = self.root / "mutated.ipa"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", compression=compression) as archive:
                for name, blob in rows:
                    archive.writestr(name, blob)
        return path

    def mutate_stamp(self, change):
        rows = self.entries()
        result = []
        for name, blob in rows:
            if name == self.stamp_name:
                stamp = json.loads(blob)
                change(stamp)
                blob = json.dumps(stamp).encode()
            result.append((name, blob))
        return self.rewrite(result)

    def test_roundtrip_preserves_inputs_and_original_bundle_identity(self):
        before_app, before_source = snapshot(self.app), snapshot(self.source)
        patch_bytes = self.patch_file.read_bytes()
        result = self.build()
        self.assertEqual(snapshot(self.app), before_app)
        self.assertEqual(snapshot(self.source), before_source)
        self.assertEqual(self.patch_file.read_bytes(), patch_bytes)
        self.assertEqual(result["bundleID"], "com.mak5er.aircard")
        self.assertEqual(result["CFBundleVersion"], "42")
        self.assertEqual(result["CFBundleShortVersionString"], "1.3.2")
        self.assertEqual(result["archiveSHA256"], sha(self.ipa.read_bytes()))
        self.assertEqual(result["binarySHA256"], sha(macho()))
        self.assertEqual(result["sourcePin"], package.BASELINE_AIRCARD_SHA)
        self.assertTrue(result["unsigned"] and result["testsNotDevice"])
        self.assertTrue(result["allZipCRCsVerified"])
        self.assertFalse(result["release"] or result["unsafeAutomaticNeoSpring"])
        self.assertEqual(result, json.loads((self.out / package.REPORT_NAME).read_bytes()))
        with zipfile.ZipFile(self.ipa) as archive:
            self.assertEqual(archive.read(self.prefix + "Info.plist"), before_app["Info.plist"][0])
            self.assertEqual(archive.read(self.prefix + package.LICENSE_PATH),
                             (self.source / "LICENSE").read_bytes())
            self.assertTrue(archive.getinfo(self.prefix + "AirCard-iOS").external_attr >> 16 & 0o111)
            self.assertEqual(set(archive.namelist()) - {self.prefix + name for name in before_app},
                             {self.stamp_name, self.prefix + package.LICENSE_PATH})

    def test_independent_verify_without_source_or_git_and_cli(self):
        self.build()
        report = self.root / "independent.json"
        with mock.patch.object(package.subprocess, "run", side_effect=AssertionError("no Git needed")):
            result = package.verify_ipa(self.ipa, report)
        self.assertEqual(json.loads(report.read_bytes()), result)
        cli_report = self.root / "cli.json"
        completed = subprocess.run([sys.executable, "-B", str(SCRIPT), "--ipa", str(self.ipa),
                                    "--report", str(cli_report)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout), result)

    def test_static_library_fingerprint_if_available(self):
        library = self.source / "rust-core/target/aarch64-apple-ios/release/libairlift_ffi.a"
        library.parent.mkdir(parents=True)
        library.write_bytes(b"!<arch>\nself-authored static-library fixture")
        result = self.build()
        self.assertEqual(result["instrumentation"]["staticLibrariesSHA256"],
                         {library.relative_to(self.source).as_posix(): sha(library.read_bytes())})

    def test_stored_and_deflated_archives_supported(self):
        self.build()
        rows = self.entries()
        for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            with self.subTest(compression=compression):
                self.assertTrue(package.verify_ipa(self.rewrite(rows, compression))["allZipCRCsVerified"])

    def test_zip_malicious_paths(self):
        self.build()
        rows = self.entries()
        for path in ("../escape", "/absolute", "C:/absolute", "Payload/../escape",
                     "Payload\\escape", "Payload//escape", "Payload/./escape",
                     self.prefix + "bad\nname",
                     self.prefix + "trailing. ", self.prefix + "dir//"):
            with self.subTest(path=path), self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite(rows + [(path, b"")]))

    def test_nul_zip_filename_is_not_silently_truncated(self):
        self.build()
        path = self.rewrite(self.entries() + [(self.prefix + "badXsuffix", b"")])
        path.write_bytes(path.read_bytes().replace(b"badXsuffix", b"bad\x00suffix"))
        with self.assertRaises(package.ValidationError):
            package.verify_ipa(path)

    def test_duplicate_zip_entries_case_aliases_and_parent_collisions(self):
        self.build()
        rows = self.entries()
        for extra in ([(rows[0][0], b"duplicate")], [(rows[0][0].upper(), b"alias")],
                      [(self.prefix + "RESOURCE.TXT/child", b"collision")],
                      [(self.prefix + "\u00e9", b"a"), (self.prefix + "e\u0301", b"b")]):
            with self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite(rows + extra))

    def test_every_zip_crc_is_checked_including_unreferenced_resource(self):
        self.build()
        archive_path = self.rewrite(self.entries())
        data = bytearray(archive_path.read_bytes())
        index = data.index(b"CRC check me, too")
        data[index] ^= 1
        archive_path.write_bytes(data)
        with self.assertRaises(zipfile.BadZipFile):
            package.verify_ipa(archive_path)

    def test_metadata_absence_and_source_stamp_absence(self):
        self.build()
        rows = self.entries()
        for missing in (self.stamp_name, self.prefix + package.LICENSE_PATH,
                        self.prefix + "Info.plist", self.prefix + "AirCard-iOS"):
            with self.subTest(missing=missing), self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite([(n, b) for n, b in rows if n != missing]))
        for field in ("sourcePin", "baselineAirCardSHA", "script", "patchReport", "binarySHA256"):
            with self.subTest(field=field), self.assertRaises(package.ValidationError):
                package.verify_ipa(self.mutate_stamp(lambda stamp: stamp.pop(field)))

    def test_false_claims_and_wrong_hashes_rejected(self):
        self.build()
        for field, value in (("sourcePin", "a" * 40), ("binarySHA256", "0" * 64),
                             ("unsafeAutomaticNeoSpring", True), ("unsafeAutomaticNeoSpring", 0),
                             ("testsNotDevice", False), ("release", True),
                             ("upstreamLicenseSHA256", "0" * 64)):
            with self.subTest(field=field), self.assertRaises(package.ValidationError):
                package.verify_ipa(self.mutate_stamp(lambda stamp: stamp.update({field: value})))

    def test_wrong_platform_and_identity_in_actual_archive_rejected(self):
        self.build()
        rows = self.entries()
        for replacement in (macho(platform=7), macho(platform=1), macho(cpu=0x01000007), b"placeholder"):
            with self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite([(n, replacement if n == self.prefix + "AirCard-iOS" else b)
                                                 for n, b in rows]))
        for key, value in (("CFBundleIdentifier", "org.invalid"),
                           ("CFBundleSupportedPlatforms", ["iPhoneSimulator"]),
                           ("CFBundleExecutable", "../escape"), ("CFBundleVersion", "")):
            info = dict(self.info, **{key: value})
            with self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite([(n, plistlib.dumps(info) if n.endswith("Info.plist") else b)
                                                 for n, b in rows]))

    def test_signed_or_provisioned_archive_rejected(self):
        self.build()
        rows = self.entries()
        for extra in ("_CodeSignature/CodeResources", "embedded.mobileprovision"):
            with self.assertRaisesRegex(package.ValidationError, "unsigned"):
                package.verify_ipa(self.rewrite(rows + [(self.prefix + extra, b"synthetic-not-a-credential")]))

    def test_symlink_zip_rejected(self):
        self.build()
        path = self.rewrite(self.entries())
        with zipfile.ZipFile(path, "a") as archive:
            entry = zipfile.ZipInfo(self.prefix + "link")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "../../escape")
        with self.assertRaisesRegex(package.ValidationError, "symlink"):
            package.verify_ipa(path)

    def test_extra_payload_or_second_app_rejected(self):
        self.build()
        for extra in ("outside", "Payload/Other.app/Info.plist"):
            with self.assertRaises(package.ValidationError):
                package.verify_ipa(self.rewrite(self.entries() + [(extra, plistlib.dumps(self.info))]))

    def test_archive_expansion_entry_count_and_metadata_size_guards(self):
        self.build()
        for constant, limit in (("MAX_ARCHIVE_BYTES", 1), ("MAX_ENTRY_BYTES", 1),
                                ("MAX_TOTAL_BYTES", 1), ("MAX_ENTRIES", 1),
                                ("MAX_METADATA_BYTES", 1)):
            with self.subTest(constant=constant), mock.patch.object(package, constant, limit):
                with self.assertRaisesRegex(package.ValidationError, "limit"):
                    package.verify_ipa(self.ipa)

    def test_build_guards_preserve_inputs_and_create_no_ipa(self):
        before = snapshot(self.app)
        with mock.patch.object(package, "MAX_ENTRY_BYTES", 1):
            with self.assertRaises(package.ValidationError):
                self.build()
        self.assertFalse(self.ipa.exists())
        self.assertEqual(before, snapshot(self.app))

    def test_patch_report_actual_source_fingerprints_checked(self):
        changed = self.source / "ios-app/TendiesEngine.swift"
        changed.write_bytes(b"unreported edits")
        with self.assertRaisesRegex(package.ValidationError, "source does not match"):
            self.build()
        self.assertFalse(self.ipa.exists())

    def test_patch_report_schema_and_fingerprints_validated(self):
        for field, value in (("upstream_commit", "a" * 40), ("automatic_neospring", True),
                             ("asset_identifiers_or_names_renamed", True), ("status", "failed"),
                             ("source", str(self.root)), ("cargo_locked", False), ("changes", [])):
            patch = dict(self.patch, **{field: value})
            self.patch_file.write_text(json.dumps(patch), encoding="utf-8")
            with self.subTest(field=field), self.assertRaises(package.ValidationError):
                self.build()

    def test_missing_or_invalid_source_pin_rejected(self):
        completed = subprocess.CompletedProcess([], 0, "a" * 40 + "\n", "")
        with mock.patch.object(package.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(package.ValidationError, "pinned"):
                package.package_app(self.app, self.source, self.patch_file, self.out)

    def test_outputs_never_overwrite_existing_files(self):
        self.out.mkdir()
        self.ipa.write_bytes(b"existing output")
        with self.assertRaisesRegex(package.ValidationError, "already exists"):
            self.build()
        self.assertEqual(self.ipa.read_bytes(), b"existing output")
        self.ipa.unlink()
        self.build()
        with self.assertRaises(FileExistsError):
            package.verify_ipa(self.ipa, self.ipa)
        self.assertTrue(package.verify_ipa(self.ipa)["unsigned"])

    def test_output_inside_input_rejected(self):
        for root in (self.app, self.source):
            with self.assertRaisesRegex(package.ValidationError, "inside app/source"):
                package.package_app(self.app, self.source, self.patch_file, root / "out")

    def test_existing_metadata_is_not_overwritten(self):
        folder = self.app / "WallpaperMachineValidation"
        folder.mkdir()
        (folder / "keep").write_bytes(b"keep")
        with self.assertRaisesRegex(package.ValidationError, "already contains"):
            self.build()
        self.assertEqual((folder / "keep").read_bytes(), b"keep")

    def test_duplicate_json_keys_and_nonfinite_values_rejected(self):
        for data in (b'{"key": 1, "key": 2}', b'{"key": NaN}', b'[]'):
            with self.assertRaises(package.ValidationError):
                package._json(data)

    def test_cli_rejects_incomplete_or_mixed_modes(self):
        for args in ([], ["--app", str(self.app)], ["--ipa", "missing.ipa"],
                     ["--ipa", "missing.ipa", "--report", "out.json", "--source", str(self.source)]):
            with mock.patch("sys.stderr", new_callable=io.StringIO), self.assertRaises(SystemExit) as error:
                package.main(args)
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
