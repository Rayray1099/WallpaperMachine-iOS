#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the actual iOS Pixiv service without a device, account or network."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "ranking-loose-rows", "ranking-r18", "search-loose-rows", "search-alternate-envelope",
    "pages-multipage", "pages-invalid", "query-filters", "query-sanitization",
    "endpoint-encoding", "identity-validation", "cookie-hosts", "redirect-cookies",
    "http-responses", "service-requests", "service-account", "service-failures",
    "service-original-limit",
}


class IOSPixivServiceTests(unittest.TestCase):
    def test_production_pixiv_service_standalone(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        # On Windows the Swift runtime DLLs live beside swiftc.
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        with tempfile.TemporaryDirectory(prefix="wm-pixiv-service-test-") as temporary:
            executable = Path(temporary) / ("pixiv-service.exe" if os.name == "nt" else "pixiv-service")
            sources = ("PixivModels", "PixivService", "PixivTransport")
            command = [compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                       *(str(ROOT / "iOS/Sources/Pixiv" / (name + ".swift")) for name in sources),
                       str(ROOT / "scripts/ios/test_pixiv_service.swift"), "-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True, encoding="utf-8",
                                      errors="replace", env=environment, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, encoding="utf-8",
                                    errors="replace", env=environment, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            passed = {line.removeprefix("PASS ") for line in result.stdout.splitlines()
                      if line.startswith("PASS ")}
            self.assertEqual(passed, CASES, result.stdout + result.stderr)
            self.assertIn(f"PASS: PixivService {len(CASES)} cases", result.stdout)


if __name__ == "__main__":
    unittest.main()
