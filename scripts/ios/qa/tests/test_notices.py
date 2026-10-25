#!/usr/bin/env python3
"""Contract tests for accurate iOS notice source collection."""
from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "notices.py"
spec = importlib.util.spec_from_file_location("ios_notices", SCRIPT)
if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot import iOS notice generator at {SCRIPT}")
notices = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = notices
spec.loader.exec_module(notices)


class CargoClosureTests(unittest.TestCase):
    def test_uses_cargo_tree_normal_shader_closure_then_metadata_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "Renderer/Cargo.toml"
            manifest.parent.mkdir()
            manifest.write_text("[workspace]\n", encoding="utf-8")
            packages = []
            for name, version in (("wm-shader", "0.1.0"), ("naga", "29.0.3"),
                                  ("bitflags", "2.9.4"), ("wallpaper-core", "0.1.0")):
                crate = root / f"src/{name}-{version}"
                crate.mkdir(parents=True)
                (crate / "Cargo.toml").write_text("[package]\n", encoding="utf-8")
                packages.append({"name": name, "version": version,
                                 "manifest_path": str(crate / "Cargo.toml"), "source": None})
            outputs = [
                subprocess.CompletedProcess([], 0,
                    "wm-shader v0.1.0 (/repo/Renderer/Shader)|GPL-3.0-only\n"
                    "naga v29.0.3 (/repo/ThirdParty/naga)|MIT OR Apache-2.0\n"
                    "bitflags v2.9.4|MIT OR Apache-2.0\n", ""),
                subprocess.CompletedProcess([], 0, json.dumps({"packages": packages}), ""),
            ]
            commands = []
            def runner(command, **kwargs):
                commands.append(command)
                return outputs.pop(0)
            result = notices.run_metadata(manifest, "aarch64-apple-ios", "cargo", runner)
            self.assertEqual({(item["name"], item["version"]) for item in result},
                             {("wm-shader", "0.1.0"), ("naga", "29.0.3"), ("bitflags", "2.9.4")})
            self.assertIn("--edges", commands[0])
            self.assertIn("normal", commands[0])
            self.assertIn("--target", commands[0])
            self.assertEqual(commands[0][-2:], ["-f", "{p}|{l}"])

    def test_fails_if_cargo_tree_does_not_report_shader_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            manifest = Path(temporary) / "Cargo.toml"
            manifest.write_text("", encoding="utf-8")
            result = subprocess.CompletedProcess([], 0, "naga v29.0.3|MIT\n", "")
            with self.assertRaisesRegex(notices.NoticeError, "wm-shader"):
                notices.run_metadata(manifest, "aarch64-apple-ios", runner=lambda *_a, **_k: result)


class LicenseSourceTests(unittest.TestCase):
    def test_license_lookup_accepts_path_crate_manifest_location(self):
        with tempfile.TemporaryDirectory() as temporary:
            crate = Path(temporary) / "naga"
            crate.mkdir()
            manifest = crate / "Cargo.toml"
            manifest.write_text("[package]\n", encoding="utf-8")
            license_file = crate / "LICENSE.MIT"
            license_file.write_text("actual upstream license text\n", encoding="utf-8")
            found = notices.crate_licenses({"name": "naga", "version": "29.0.3",
                                            "manifest_path": str(manifest), "source": None}, Path(temporary))
            self.assertEqual(found, [license_file])

    def test_all_crate_alternative_license_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            crate = Path(temporary) / "both"
            crate.mkdir()
            manifest = crate / "Cargo.toml"
            manifest.write_text("[package]\n", encoding="utf-8")
            mit = crate / "LICENSE-MIT"
            apache = crate / "LICENSE-APACHE"
            mit.write_text("MIT text", encoding="utf-8")
            apache.write_text("Apache text", encoding="utf-8")
            found = notices.crate_licenses({"name": "both", "version": "1.0",
                                            "manifest_path": str(manifest)}, Path(temporary))
            self.assertEqual(found, [apache, mit])

    def test_license_lookup_fails_closed_when_no_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            crate = Path(temporary) / "missing"
            crate.mkdir()
            manifest = crate / "Cargo.toml"
            manifest.write_text("[package]\n", encoding="utf-8")
            with self.assertRaisesRegex(notices.NoticeError, "no license/notice"):
                notices.crate_licenses({"name": "missing", "version": "1.0",
                                        "manifest_path": str(manifest)}, Path(temporary))

    def test_generate_stages_real_repository_and_pinned_input_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = Path(__file__).resolve().parents[4] / "artifacts/ios-continuation/notice-inputs"
            if not inputs.is_dir():
                self.skipTest("local pinned source archives are unavailable")
            deps_sources = root / "src"
            deps_sources.mkdir()
            for name in ("quickjs-0.17.0", "freetype-VER-2-13-3", "lz4-1.10.0", "argparse-3.2"):
                shutil.copytree(inputs / name, deps_sources / name)
            downloads = root / "downloads"
            downloads.mkdir()
            nlohmann_license = Path(__file__).resolve().parents[4] / "artifacts/ios-continuation/nlohmann-json-LICENSE.MIT"
            if not nlohmann_license.is_file():
                self.skipTest("local pinned nlohmann license is unavailable")
            shutil.copy(nlohmann_license, downloads / "nlohmann-json-LICENSE.MIT")
            zipfoundation = inputs / "ZIPFoundation-0.9.19"
            cargo_home = root / "cargo"
            naga = cargo_home / "registry/src/fixture/naga-29.0.3"
            naga.mkdir(parents=True)
            naga_manifest = naga / "Cargo.toml"
            naga_manifest.write_text("[package]\n", encoding="utf-8")
            (naga / "LICENSE.MIT").write_text("MIT grant", encoding="utf-8")
            shader = root / "shader"
            shader.mkdir()
            shader_manifest = shader / "Cargo.toml"
            shader_manifest.write_text("[package]\n", encoding="utf-8")
            packages = [
                {"name": "wm-shader", "version": "0.1.0", "manifest_path": str(shader_manifest),
                 "license": "GPL-3.0-only", "source": None},
                {"name": "naga", "version": "29.0.3", "manifest_path": str(naga_manifest),
                 "license": "MIT OR Apache-2.0", "source": None},
            ]
            cargo_outputs = [
                subprocess.CompletedProcess([], 0,
                    "wm-shader v0.1.0 (/repo/Renderer/Shader)|GPL-3.0-only\n"
                    "naga v29.0.3 (/repo/ThirdParty/naga)|MIT OR Apache-2.0\n", ""),
                subprocess.CompletedProcess([], 0, json.dumps({"packages": packages}), ""),
            ]
            def runner(*_args, **_kwargs):
                return cargo_outputs.pop(0)
            output = root / "out"
            entries = notices.generate(output, deps_sources, cargo_home, zipfoundation,
                                       cargo_tree_runner=runner, deps_downloads=downloads)
            self.assertTrue(entries)
            self.assertIn("GNU GENERAL PUBLIC LICENSE", (output / "WallpaperMachine-LICENSE.txt").read_text(encoding="utf-8"))
            self.assertTrue((output / "received-licenses/open-wallpaper-engine.GPL-2.0.txt").is_file())
            self.assertTrue((output / "rust/naga-29.0.3/LICENSE.MIT").is_file())
            self.assertTrue((output / "renderer/freetype/docs-GPLv2.TXT").is_file())
            self.assertTrue((output / "renderer/freetype/docs-FTL.TXT").is_file())
            self.assertIn("MIT OR Apache-2.0", (output / "INDEX.txt").read_text(encoding="utf-8"))
            self.assertIn("MIT License", (output / "renderer/nlohmann-json/LICENSE.MIT").read_text(encoding="utf-8"))

    def test_real_source_generation_completes_with_zipfoundation_and_cargo_closure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = Path(__file__).resolve().parents[4] / "artifacts/ios-continuation/notice-inputs"
            if not inputs.is_dir():
                self.skipTest("local pinned source archives are unavailable")
            deps_sources = root / "src"
            deps_sources.mkdir()
            for name in ("quickjs-0.17.0", "freetype-VER-2-13-3", "lz4-1.10.0", "argparse-3.2"):
                shutil.copytree(inputs / name, deps_sources / name)
            downloads = root / "downloads"
            downloads.mkdir()
            nlohmann_license = Path(__file__).resolve().parents[4] / "artifacts/ios-continuation/nlohmann-json-LICENSE.MIT"
            if not nlohmann_license.is_file():
                self.skipTest("local pinned nlohmann license is unavailable")
            shutil.copy(nlohmann_license, downloads / "nlohmann-json-LICENSE.MIT")
            cargo_home = root / "cargo"
            naga = cargo_home / "registry/src/fixture/naga-29.0.3"
            naga.mkdir(parents=True)
            naga_manifest = naga / "Cargo.toml"
            naga_manifest.write_text("[package]\n", encoding="utf-8")
            (naga / "LICENSE.MIT").write_text("MIT grant", encoding="utf-8")
            shader = root / "shader"
            shader.mkdir()
            shader_manifest = shader / "Cargo.toml"
            shader_manifest.write_text("[package]\n", encoding="utf-8")
            packages = [
                {"name": "wm-shader", "version": "0.1.0", "manifest_path": str(shader_manifest),
                 "license": "GPL-3.0-only", "source": None},
                {"name": "naga", "version": "29.0.3", "manifest_path": str(naga_manifest),
                 "license": "MIT OR Apache-2.0", "source": None},
            ]
            cargo_outputs = [
                subprocess.CompletedProcess([], 0,
                    "wm-shader v0.1.0 (/repo/Renderer/Shader)|GPL-3.0-only\n"
                    "naga v29.0.3 (/repo/ThirdParty/naga)|MIT OR Apache-2.0\n", ""),
                subprocess.CompletedProcess([], 0, json.dumps({"packages": packages}), ""),
            ]
            output = root / "out"
            notices.generate(output, deps_sources, cargo_home, inputs / "ZIPFoundation-0.9.19",
                             cargo_tree_runner=lambda *_a, **_k: cargo_outputs.pop(0), deps_downloads=downloads)
            self.assertTrue((output / "zipfoundation/LICENSE").is_file())
            self.assertTrue((output / "rust/naga-29.0.3/LICENSE.MIT").is_file())
            self.assertTrue((output / "renderer/quickjs-ng/LICENSE").is_file())
            self.assertTrue((output / "renderer/lz4/lib-LICENSE").is_file())
            self.assertTrue((output / "renderer/nlohmann-json/LICENSE.MIT").is_file())

    def test_generation_fails_closed_if_required_pinned_text_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            inputs = Path(__file__).resolve().parents[4] / "artifacts/ios-continuation/notice-inputs"
            if not inputs.is_dir():
                self.skipTest("local pinned source archives are unavailable")
            deps_sources = root / "src"
            deps_sources.mkdir()
            for name in ("quickjs-0.17.0", "freetype-VER-2-13-3", "lz4-1.10.0", "argparse-3.2"):
                shutil.copytree(inputs / name, deps_sources / name)
            (deps_sources / "argparse-3.2/LICENSE").unlink()
            output = root / "out"
            with self.assertRaisesRegex(notices.NoticeError, "no license/notice"):
                notices.generate(output, deps_sources, root / "cargo", inputs / "ZIPFoundation-0.9.19",
                                 deps_downloads=root / "downloads")
            self.assertFalse((output / "renderer/argparse/LICENSE").exists())

    def test_output_refuses_to_delete_or_replace_existing_contents(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "notices"
            output.mkdir()
            sentinel = output / "keep.txt"
            sentinel.write_text("retain", encoding="utf-8")
            with self.assertRaisesRegex(notices.NoticeError, "refusing to overwrite"):
                notices.generate(output, output, Path(temporary), output)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "retain")


if __name__ == "__main__":
    unittest.main()
