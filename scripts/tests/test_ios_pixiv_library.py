#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the actual Pixiv library project and repository without a device or network."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "project-signatures-attribution",
    "project-rejects-and-cleans",
    "repository-idempotency-pages",
    "legacy-manifest-without-pixiv",
    "malformed-provenance-preserves-library",
    "provenance-save-load-validation",
}


class IOSPixivLibraryTests(unittest.TestCase):
    def test_production_pixiv_library_standalone(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        # Windows Swift runtime DLLs live beside swiftc in the installed toolchain.
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        with tempfile.TemporaryDirectory(prefix="wm-pixiv-library-test-") as temporary:
            executable = Path(temporary) / ("pixiv-library.exe" if os.name == "nt" else "pixiv-library")
            source_names = [
                "iOS/Sources/Models/WallpaperModels.swift",
                "iOS/Sources/Models/ScopedAssetAccess.swift",
                "iOS/Sources/Models/LibraryRepository.swift",
                "iOS/Sources/Pixiv/PixivModels.swift",
                "iOS/Sources/Pixiv/PixivTransport.swift",
                "iOS/Sources/Pixiv/PixivService.swift",
                "iOS/Sources/Pixiv/PixivLibraryProject.swift",
                "scripts/ios/test_pixiv_library.swift",
            ]
            command = [
                compiler,
                "-swift-version",
                "5",
                "-warnings-as-errors",
                "-parse-as-library",
                *(str(ROOT / source) for source in source_names),
                "-o",
                str(executable),
            ]
            compiled = subprocess.run(
                command,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=environment,
                timeout=120,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run(
                [str(executable)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                env=environment,
                timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            passed = {
                line.removeprefix("PASS ")
                for line in result.stdout.splitlines()
                if line.startswith("PASS ")
            }
            self.assertEqual(passed, CASES, result.stdout + result.stderr)
            self.assertIn(f"PASS: PixivLibrary {len(CASES)} cases", result.stdout)


if __name__ == "__main__":
    unittest.main()
