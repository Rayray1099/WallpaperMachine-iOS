#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Execute production Pixiv state/async races with isolated transport and library fixtures."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "cache-and-filters", "stale-listing", "late-sign-in", "mature-sanitization",
    "expired-restore", "failed-import-retry", "cancelled-retry", "reject-unverified-page",
}


class IOSPixivStoreTests(unittest.TestCase):
    def test_production_pixiv_store_standalone(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        with tempfile.TemporaryDirectory(prefix="wm-pixiv-store-test-") as temporary:
            executable = Path(temporary) / ("pixiv-store.exe" if os.name == "nt" else "pixiv-store")
            sources = ("PixivModels", "PixivService", "PixivTransport", "PixivSessionStore",
                       "PixivResumableTransfer", "PixivLibraryProject", "PixivStore")
            command = [compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                       str(ROOT / "iOS/Sources/Models/WallpaperModels.swift"),
                       *(str(ROOT / "iOS/Sources/Pixiv" / (name + ".swift")) for name in sources),
                       str(ROOT / "scripts/ios/test_pixiv_store.swift"), "-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                      errors="replace", env=environment, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", env=environment, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            passed = {line.removeprefix("PASS ") for line in result.stdout.splitlines() if line.startswith("PASS ")}
            self.assertEqual(passed, CASES, result.stdout + result.stderr)
            self.assertIn(f"PASS: PixivStore {len(CASES)} cases", result.stdout)


if __name__ == "__main__":
    unittest.main()
