#!/usr/bin/env python3
"""IPA validator fixtures: structural checks accept the valid app and refuse each defect."""
from __future__ import annotations

import importlib.util
import json
import plistlib
import sys
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

import package_contract  # noqa: E402

MINIMUM_OS = (18, 0)


def load_validator_module(path: Path):
    spec = importlib.util.spec_from_file_location("ios_validate", path)
    if spec is None or spec.loader is None:
        raise unittest.SkipTest(f"cannot import validator at {path}")
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves annotations through sys.modules[cls.__module__].
    sys.modules["ios_validate"] = module
    spec.loader.exec_module(module)
    return module


class FixtureBuilder(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def test_valid_fixture_has_expected_structure(self):
        ipa = package_contract.build_ipa(self.directory / "valid.ipa")
        with zipfile.ZipFile(ipa) as archive:
            names = archive.namelist()
            self.assertIn("Payload/WallpaperMachineIOS.app/Info.plist", names)
            self.assertIn("Payload/WallpaperMachineIOS.app/WallpaperMachineIOS", names)
            plist = plistlib.loads(archive.read("Payload/WallpaperMachineIOS.app/Info.plist"))
            self.assertEqual(plist["CFBundleIdentifier"],
                             "com.rayray1099.wallpapermachine.ios")
            self.assertEqual(plist["MinimumOSVersion"], "18.0")
            binary = archive.read("Payload/WallpaperMachineIOS.app/WallpaperMachineIOS")
            self.assertEqual(binary[:4], b"\xcf\xfa\xed\xfe")

    def test_arm64_build_version_is_ios_18(self):
        binary = package_contract.macho()
        import struct
        magic, cpu_type, _sub, filetype, ncmds = struct.unpack_from("<IiiII", binary, 0)
        self.assertEqual(magic, package_contract.MH_MAGIC_64)
        self.assertEqual(cpu_type, package_contract.CPU_TYPE_ARM64)
        self.assertEqual(filetype, package_contract.MH_EXECUTE)
        self.assertEqual(ncmds, 1)
        command, size, platform, minos, _sdk = struct.unpack_from("<IIIII", binary, 32)
        self.assertEqual((command, size, platform), (
            package_contract.LC_BUILD_VERSION, 24, package_contract.PLATFORM_IOS))
        self.assertEqual(minos >> 16, 18)

    def test_each_negative_fixture_differs_from_valid(self):
        cases = package_contract.positive_and_invalid_cases(self.directory / "cases")
        self.assertTrue(cases["valid"][1])
        self.assertEqual(sum(1 for _ipa, should_pass in cases.values() if not should_pass), 9)

    def test_traversal_entry_is_present_in_fixture(self):
        cases = package_contract.positive_and_invalid_cases(self.directory / "cases")
        ipa = cases["traversal_entry"][0]
        with zipfile.ZipFile(ipa) as archive:
            self.assertIn("Payload/../../escape.txt", archive.namelist())


class ValidatorDiscovery(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def test_missing_validator_is_reported_as_none(self):
        self.assertIsNone(package_contract.discover_validator(root=self.directory))

    def test_candidate_path_is_found(self):
        script = self.directory / "scripts/ios/validate_ipa.py"
        script.parent.mkdir(parents=True)
        script.write_text("raise SystemExit(0)\n", encoding="utf-8")
        self.assertEqual(package_contract.discover_validator(root=self.directory), script)

    def test_runner_reports_returncode_and_output(self):
        script = self.directory / "validator.py"
        script.write_text(
            "import sys\nprint('checked', sys.argv[1])\nraise SystemExit(3)\n",
            encoding="utf-8")
        ipa = package_contract.build_ipa(self.directory / "valid.ipa")
        result = package_contract.run_validator(script, ipa)
        self.assertEqual(result.returncode, 3)
        self.assertIn("checked", result.stdout)
        self.assertIn("valid.ipa", result.stdout)


class RealValidatorStructuralChecks(unittest.TestCase):
    """Drive Build Agent's validator checks on synthetic app/IPA fixtures."""

    @classmethod
    def setUpClass(cls):
        path = package_contract.discover_validator()
        if path is None or path.name != "validate.py":
            raise unittest.SkipTest("Build Agent's scripts/ios/validate.py is not present")
        cls.module = load_validator_module(path)

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def report(self):
        return self.module.Report()

    def failures(self, report):
        return [(check.name, check.detail) for check in report.failures]

    def app_and_ipa(self, *, app_options=None, ipa_options=None):
        app = package_contract.build_app(self.directory, **(app_options or {}))
        ipa = package_contract.build_ipa_from_app(
            app, self.directory / "app.ipa", **(ipa_options or {}))
        return app, app / "WallpaperMachineIOS", ipa

    def test_check_bundle_accepts_valid_app(self):
        app, executable, _ipa = self.app_and_ipa()
        report = self.report()
        self.module.check_bundle(report, app, executable,
                                 package_contract.DEFAULT_BUNDLE_ID, MINIMUM_OS)
        self.assertEqual(self.failures(report), [])

    def test_check_executable_accepts_thin_arm64_ios(self):
        app, executable, _ipa = self.app_and_ipa()
        report = self.report()
        self.module.check_executable(report, executable, MINIMUM_OS, None)
        self.assertEqual(self.failures(report), [])

    def test_check_ipa_accepts_ipa_matching_the_app(self):
        app, executable, ipa = self.app_and_ipa()
        report = self.report()
        self.module.check_ipa(report, ipa, app, executable, MINIMUM_OS)
        self.assertEqual(self.failures(report), [])
        names = [check.name for check in report.checks]
        self.assertIn("ipa.structure", names)

    def test_check_ipa_rejects_traversal_member(self):
        app, executable, ipa = self.app_and_ipa(ipa_options={"extra_entries": (
            ("Payload/../../escape.txt", b"escape"),)})
        report = self.report()
        self.module.check_ipa(report, ipa, app, executable, MINIMUM_OS)
        details = " ".join(detail for _name, detail in self.failures(report))
        self.assertIn("traversing", details)

    def test_check_ipa_rejects_x86_64_executable(self):
        app, executable, ipa = self.app_and_ipa(
            app_options={"cpu_type": package_contract.CPU_TYPE_X86_64})
        report = self.report()
        self.module.check_ipa(report, ipa, app, executable, MINIMUM_OS)
        details = " ".join(detail for _name, detail in self.failures(report))
        self.assertIn("x86_64", details)

    def test_check_ipa_rejects_missing_executable(self):
        app, executable, ipa = self.app_and_ipa(ipa_options={"include_executable": False})
        report = self.report()
        self.module.check_ipa(report, ipa, app, executable, MINIMUM_OS)
        details = " ".join(detail for _name, detail in self.failures(report))
        self.assertIn("no Payload", details)

    def test_check_ipa_rejects_missing_info_plist(self):
        app, executable, ipa = self.app_and_ipa(ipa_options={"include_info_plist": False})
        report = self.report()
        self.module.check_ipa(report, ipa, app, executable, MINIMUM_OS)
        details = " ".join(detail for _name, detail in self.failures(report))
        self.assertIn("no Info.plist", details)

    def test_check_ipa_rejects_ipa_plist_that_differs_from_app(self):
        app, executable, ipa = self.app_and_ipa()
        # Rewrite the IPA's plist while the app stays valid.
        rebuilt = self.directory / "mismatched.ipa"
        with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(rebuilt, "w") as target:
            for item in source.infolist():
                payload = source.read(item)
                if item.filename.endswith("Info.plist"):
                    payload = package_contract.info_plist(bundle_id="com.example.other")
                target.writestr(item, payload)
        report = self.report()
        self.module.check_ipa(report, rebuilt, app, executable, MINIMUM_OS)
        details = " ".join(detail for _name, detail in self.failures(report))
        self.assertIn("Info.plist differs", details)

    def test_check_executable_rejects_x86_64(self):
        app, executable, _ipa = self.app_and_ipa(
            app_options={"cpu_type": package_contract.CPU_TYPE_X86_64})
        report = self.report()
        self.module.check_executable(report, executable, MINIMUM_OS, None)
        self.assertTrue(any(name == "macho.arch" for name, _detail in self.failures(report)))

    def test_check_executable_rejects_old_deployment_target(self):
        app, executable, _ipa = self.app_and_ipa(app_options={"min_os": "16.0"})
        report = self.report()
        self.module.check_executable(report, executable, MINIMUM_OS, None)
        self.assertTrue(any(name == "macho.minimum_os" for name, _detail in self.failures(report)))

    def test_check_executable_rejects_non_pie(self):
        app, executable, _ipa = self.app_and_ipa(app_options={"pie": False})
        report = self.report()
        self.module.check_executable(report, executable, MINIMUM_OS, None)
        self.assertTrue(any(name == "macho.pie" for name, _detail in self.failures(report)))

    def test_check_bundle_rejects_broken_app(self):
        app = package_contract.build_app(self.directory, include_localizations=False)
        executable = app / "WallpaperMachineIOS"
        report = self.report()
        self.module.check_bundle(report, app, executable,
                                 package_contract.DEFAULT_BUNDLE_ID, MINIMUM_OS)
        names = {check.name for check in report.failures}
        self.assertIn("bundle.localization_resources", names)

    def test_cli_reports_ipa_pass_and_missing_renderer_failure(self):
        app, executable, ipa = self.app_and_ipa()
        artifacts = self.directory / "artifacts"
        artifacts.mkdir()
        report_path = self.directory / "validation.json"
        result = package_contract.run_validator(
            package_contract.discover_validator(), ipa, app=app,
            extra_args=("--artifacts-dir", str(artifacts),
                        "--renderer-dir", str(self.directory / "absent-renderer"),
                        "--sdk", str(self.directory / "absent-sdk"),
                        "--report", str(report_path)))
        self.assertEqual(result.returncode, 1)
        document = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertEqual(document["verdict"], "fail")
        checks = {check["name"]: check["status"] for check in document["checks"]}
        self.assertEqual(checks["ipa.structure"], "pass")
        self.assertEqual(checks["bundle.identifier"], "pass")
        self.assertEqual(checks["physical.ipados27"], "skip")
        self.assertEqual(checks["renderer.directory"], "fail")


if __name__ == "__main__":
    unittest.main()
