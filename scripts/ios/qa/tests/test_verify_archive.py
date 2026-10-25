#!/usr/bin/env python3
"""Archive validation checks real object members, not the ar symbol-table index."""
from pathlib import Path
import sys
import tempfile
import unittest

IOS_SCRIPTS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IOS_SCRIPTS))
sys.path.insert(0, str(IOS_SCRIPTS / "qa"))
import package_contract
import verify_archive


def ar_member(name, payload):
    header = (f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(payload):<10}`\n").encode("ascii")
    return header + payload + (b"\n" if len(payload) % 2 else b"")


def object_bytes(*, arch="arm64", platform=2):
    cpu = package_contract.CPU_TYPE_ARM64 if arch == "arm64" else package_contract.CPU_TYPE_X86_64
    return package_contract.macho(cpu_type=cpu, platform=platform, filetype=1)


class VerifyArchive(unittest.TestCase):
    def verify(self, objects, *, sdk="iphoneos", arch="arm64"):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "libtest.a"
            data = b"!<arch>\n" + ar_member("__.SYMDEF", b"not a Mach-O object")
            for index, obj in enumerate(objects):
                data += ar_member(f"object{index}.o/", obj)
            archive.write_bytes(data)
            return verify_archive.verify(archive, sdk, arch)

    def test_index_is_ignored_and_all_device_objects_are_counted(self):
        info = self.verify([object_bytes(), object_bytes()])
        self.assertEqual(info.objects, 2)
        self.assertEqual(info.ios_objects, 2)

    def test_later_macos_object_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "platforms"):
            self.verify([object_bytes(), object_bytes(platform=1)])

    def test_simulator_is_not_a_device_archive(self):
        with self.assertRaisesRegex(ValueError, "platforms"):
            self.verify([object_bytes(platform=7)])

    def test_simulator_archive_accepts_only_simulator_objects(self):
        self.assertEqual(self.verify([object_bytes(platform=7)], sdk="iphonesimulator").objects, 1)

    def test_foreign_cpu_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.verify([object_bytes(arch="x86_64")])

    def test_index_without_objects_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "no Mach-O"):
            self.verify([])


if __name__ == "__main__":
    unittest.main()
