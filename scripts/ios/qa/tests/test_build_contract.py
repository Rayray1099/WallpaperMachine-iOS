#!/usr/bin/env python3
"""Portable tests for iOS Xcode build-product discovery."""
from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "build.py"
spec = importlib.util.spec_from_file_location("ios_build", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot import build script at {SCRIPT}")
build = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = build
spec.loader.exec_module(build)


class BuildProductDiscovery(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.derived = self.root / "DerivedData"
        self.product_dir = self.derived / "Build/Products/Release-iphoneos"
        self.product_dir.mkdir(parents=True)
        self.app = self.product_dir / "WallpaperMachineIOS.app"
        self.app.mkdir()

    def test_build_settings_match_named_app_target(self):
        wrong_target = self.root / "Tests.app"
        wrong_target.mkdir()
        named_app = self.root / "NamedProduct.app"
        named_app.mkdir()
        settings = {
            "returncode": 0,
            "stdout": json.dumps([
                {"target": "WallpaperMachineIOSTests", "buildSettings": {
                    "TARGET_BUILD_DIR": str(self.root), "FULL_PRODUCT_NAME": "Tests.app"}},
                {"target": "WallpaperMachineIOS", "buildSettings": {
                    "TARGET_BUILD_DIR": str(self.root), "FULL_PRODUCT_NAME": "NamedProduct.app"}},
            ]),
        }
        self.assertEqual(build.app_product_candidates(settings, self.derived), [named_app])

    def test_missing_named_target_or_nonexistent_product_falls_back(self):
        settings = {
            "returncode": 0,
            "stdout": json.dumps([{"target": "WallpaperMachineIOSTests", "buildSettings": {}}]),
        }
        self.assertEqual(build.app_product_candidates(settings, self.derived), [self.app])
        settings["stdout"] = json.dumps([{"target": "WallpaperMachineIOS", "buildSettings": {
            "TARGET_BUILD_DIR": str(self.root), "FULL_PRODUCT_NAME": "missing.app"}}])
        self.assertEqual(build.app_product_candidates(settings, self.derived), [self.app])

    def test_settings_command_uses_same_derived_data_path(self):
        command = build.build_settings_command(self.derived)
        self.assertIn("-derivedDataPath", command)
        self.assertEqual(command[command.index("-derivedDataPath") + 1], str(self.derived))
        self.assertEqual(command[command.index("-showBuildSettings") - 1], str(self.derived))


if __name__ == "__main__":
    unittest.main()
