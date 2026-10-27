#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile actual Foundation-only request presets; no device or networking."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PCConverterOptionsTests(unittest.TestCase):
    def test_production_options_standalone(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        # Windows Swift runtime DLLs live beside swiftc in the installed toolchain.
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        with tempfile.TemporaryDirectory(prefix="wm-pc-options-test-") as temporary:
            executable = Path(temporary) / ("pc-options.exe" if os.name == "nt" else "pc-options")
            command = [compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                       str(ROOT / "iOS/Sources/Export/PCConverterOptions.swift"),
                       str(ROOT / "iOS/Sources/Export/PCConverterConnection.swift"),
                       str(ROOT / "scripts/ios/test_pc_converter_options.swift"),
                       "-o", str(executable)]
            compiled = subprocess.run(command, capture_output=True, text=True,
                                      encoding="utf-8", errors="replace", env=environment, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", env=environment, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("PASS: PCConverterOptions", result.stdout)


if __name__ == "__main__":
    unittest.main()
