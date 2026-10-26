#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline preparation guards plus opt-in actual pinned-source Swift execution.

Set AIRCARD_VALIDATION_SOURCE to the separately fetched pinned AirCard checkout.
The Rust tests appended by preparation run against its real ZIP builder in CI:
cargo test --locked --manifest-path rust-core/Cargo.toml --lib wm_posterboard_validation -- --nocapture
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ios/prepare_aircard_validation.py"
spec = importlib.util.spec_from_file_location("prepare_aircard_validation", SCRIPT)
assert spec and spec.loader
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wm-aircard-prep-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "checkout"
        self.report = self.root / "reports/preparation.json"
        # Minimal authored before-context fixtures, NOT a vendored upstream file.
        # Git responses are injected so default tests need no network or commits.
        self.originals = {
            "rust-core/src/exploit.rs": (
                "// authored wrapper fixture\nfn build_folder_archive(\n" + prepare.RUST_OLD_BLOCK +
                "\n}\n\n/// Build the Books.plist sync manifest.\nfn untouched() {}\n").encode(),
            "ios-app/TendiesEngine.swift": (
                "// authored wrapper fixture\n"
                "    func updatePlistIdentifiers(in folderURL: URL, randomizedID: Int) {\n" +
                prepare.SWIFT_OLD_LINE + "\n    }\n\n    // MARK: - Folder Injector Helper\n// unchanged tail\n").encode(),
            "ios-app/AppViewModel.swift": (
                "// authored wrapper fixture\n    func flashSelectedTendies() async {\n" +
                prepare.RESPRING_OLD_BLOCK + "\n    }\n\n    func respringDevice() {\n" +
                '        RespringHelper.triggerNeoSpring()\n    }\n// unchanged tail\n').encode(),
        }
        for relative, data in self.originals.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.extra_status = b""
        self.head = prepare.PINNED_COMMIT
        self.git_mock = mock.patch.object(prepare, "git", side_effect=self.fake_git).start()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(prepare, "ORIGINAL_BLOBS", {
            name: prepare.blob_id(data) for name, data in self.originals.items()}).start()

    def fake_git(self, source, *args):
        if args == ("rev-parse", "HEAD"):
            return self.head.encode() + b"\n"
        if args == ("rev-parse", "--show-toplevel"):
            return str(self.source).encode() + b"\n"
        if args[0] == "show":
            return self.originals[args[1].removeprefix("HEAD:")]
        if args[:2] == ("status", "--porcelain=v1"):
            rows = [b" M " + relative.encode() for relative, data in self.originals.items()
                    if prepare.normalize((self.source / relative).read_bytes()) != prepare.normalize(data)]
            return b"\0".join(rows) + (b"\0" if rows else b"") + self.extra_status
        raise AssertionError("Unexpected Git command: " + repr(args))

    def snapshot(self):
        return {name: (self.source / name).read_bytes() for name in self.originals}

    def test_preparation_is_exactly_scoped_and_idempotent_with_fingerprints(self):
        original = self.snapshot()
        result = prepare.prepare(self.source, self.report)
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(set(row["path"] for row in result["changes"]), set(original))
        self.assertEqual(json.loads(self.report.read_text()), result)
        patched = self.snapshot()
        self.assertEqual(patched["ios-app/TendiesEngine.swift"],
                         original["ios-app/TendiesEngine.swift"].replace(
                             prepare.SWIFT_OLD_LINE.encode(), prepare.SWIFT_NEW_LINE.encode()))
        self.assertEqual(patched["ios-app/AppViewModel.swift"],
                         original["ios-app/AppViewModel.swift"].replace(
                             prepare.RESPRING_OLD_BLOCK.encode(), prepare.RESPRING_NEW_BLOCK.encode()))
        self.assertFalse(result["automatic_neospring"])
        self.assertFalse(result["asset_identifiers_or_names_renamed"])
        for row in result["changes"]:
            self.assertEqual(row["original_sha256"], hashlib.sha256(original[row["path"]]).hexdigest())
            self.assertEqual(row["patched_sha256"], hashlib.sha256(patched[row["path"]]).hexdigest())
        again = prepare.prepare(self.source, self.report)
        self.assertEqual(again["status"], "already_prepared")
        self.assertEqual(again["changes"], result["changes"])
        self.assertEqual(self.snapshot(), patched)
        self.assertEqual(list(self.source.rglob(".wm-aircard-stage-*")), [])

    def test_wrong_head_refuses_every_write(self):
        self.head = "0" * 40
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "Expected pinned"):
            prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.report.exists())

    def test_unrelated_dirty_untracked_or_staged_status_refuses_every_write(self):
        for status in (b"?? unrelated.txt\0", b"M  ios-app/TendiesEngine.swift\0", b" M README.md\0"):
            with self.subTest(status=status):
                before = self.snapshot()
                self.extra_status = status
                with self.assertRaisesRegex(prepare.PreparationError, "Checkout must be clean"):
                    prepare.prepare(self.source, self.report)
                self.assertEqual(self.snapshot(), before)

    def test_modified_target_and_partial_application_refuse_every_write(self):
        target = self.source / "ios-app/AppViewModel.swift"
        target.write_bytes(target.read_bytes() + b"// unexpected edit\n")
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "Unexpected worktree edits"):
            prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)
        target.write_bytes(prepare.patch_viewmodel(self.originals["ios-app/AppViewModel.swift"]))
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "Partially applied"):
            prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)

    def test_unexpected_last_function_body_is_detected_before_first_write(self):
        key = "ios-app/AppViewModel.swift"
        changed = self.originals[key].replace(b".now() + 0.6", b".now() + 0.7")
        self.originals[key] = changed
        prepare.ORIGINAL_BLOBS[key] = prepare.blob_id(changed)
        (self.source / key).write_bytes(changed)
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "one exact expected mutation"):
            prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse(self.report.exists())

    def test_unexpected_git_blob_is_rejected_even_at_pinned_head(self):
        prepare.ORIGINAL_BLOBS["ios-app/TendiesEngine.swift"] = "0" * 40
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "Unexpected pinned source blob"):
            prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)

    def test_ambiguous_function_anchor_refuses_plan(self):
        original = self.originals["ios-app/TendiesEngine.swift"]
        with self.assertRaisesRegex(prepare.PreparationError, "ambiguous function signature"):
            prepare.patch_tendies(original + original)

    def test_crlf_checkout_keeps_line_endings_and_remains_idempotent(self):
        for name, data in self.originals.items():
            (self.source / name).write_bytes(data.replace(b"\n", b"\r\n"))
        prepare.prepare(self.source, self.report)
        for data in self.snapshot().values():
            self.assertNotIn(b"\n", data.replace(b"\r\n", b""))
        self.assertEqual(prepare.prepare(self.source, self.report)["status"], "already_prepared")

    def test_failed_second_atomic_replace_rolls_back_all_source_bytes(self):
        before = self.snapshot()
        replace = os.replace
        count = 0

        def fail_once(source, destination):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("simulated replacement failure")
            return replace(source, destination)

        with mock.patch.object(prepare.os, "replace", side_effect=fail_once):
            with self.assertRaisesRegex(OSError, "simulated replacement failure"):
                prepare.prepare(self.source, self.report)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(list(self.source.rglob(".wm-aircard-stage-*")), [])
        self.assertFalse(self.report.exists())

    def test_reference_baseline_and_report_inside_source_are_refused(self):
        baseline = self.root / ".local/references/AirCard-iOS"
        baseline.mkdir(parents=True)
        with self.assertRaisesRegex(prepare.PreparationError, "baseline must never be patched"):
            prepare.prepare(baseline, self.report)
        before = self.snapshot()
        with self.assertRaisesRegex(prepare.PreparationError, "outside the upstream checkout"):
            prepare.prepare(self.source, self.source / "report.json")
        self.assertEqual(self.snapshot(), before)

class ActualPinnedSourceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = os.environ.get("AIRCARD_VALIDATION_SOURCE")
        if not source:
            raise unittest.SkipTest("Set AIRCARD_VALIDATION_SOURCE to the pinned external checkout; no automatic fetch")
        cls.source = Path(source).resolve()
        # Reads only the pinned Git blobs; never patches the reference baseline.
        cls.originals = prepare.original_sources(cls.source)

    def test_real_pinned_sources_accept_only_the_three_guarded_changes(self):
        rust = prepare.patch_rust(self.originals["rust-core/src/exploit.rs"])
        self.assertIn(prepare.RUST_NEW_BLOCK.encode(), rust)
        for path, before, after, patcher in (
            ("ios-app/TendiesEngine.swift", prepare.SWIFT_OLD_LINE, prepare.SWIFT_NEW_LINE, prepare.patch_tendies),
            ("ios-app/AppViewModel.swift", prepare.RESPRING_OLD_BLOCK, prepare.RESPRING_NEW_BLOCK, prepare.patch_viewmodel),
        ):
            original = prepare.normalize(self.originals[path])
            self.assertEqual(patcher(original), original.replace(before.encode(), after.encode(), 1))
            current = prepare.normalize((self.source / path).read_bytes())
            self.assertIn(current, (original, patcher(original)), "Unexpected source working-copy mutation")
        original = prepare.normalize(self.originals["ios-app/AppViewModel.swift"])
        patched = prepare.patch_viewmodel(original)
        manual = b"\n    func respringDevice() {"
        self.assertEqual(patched[patched.index(manual):], original[original.index(manual):])

    def test_actual_patched_foundation_method_preserves_asset_identity_and_hidden_options(self):
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is not installed")
        compiler = str(Path(compiler).resolve())
        environment = os.environ.copy()
        environment["PATH"] = str(Path(compiler).parent) + os.pathsep + environment.get("PATH", "")
        original = prepare.normalize(self.originals["ios-app/TendiesEngine.swift"])
        expected = prepare.patch_tendies(original)
        current = prepare.normalize((self.source / "ios-app/TendiesEngine.swift").read_bytes())
        self.assertIn(current, (original, expected), "Unexpected source working-copy mutation")
        # On CI use the actual prepared file. A read-only pinned baseline can
        # also exercise precisely the same bounded change entirely in memory.
        patched = (current if current == expected else prepare.patch_tendies(current)).decode()
        first = patched.index("    func updatePlistIdentifiers(in folderURL: URL, randomizedID: Int) {")
        last = patched.index("\n    // MARK: - Folder Injector Helper", first)
        method = patched[first:last]
        with tempfile.TemporaryDirectory(prefix="wm-aircard-id-scalar-") as temporary:
            root = Path(temporary)
            swift = root / "Method.swift"
            executable = root / ("method.exe" if os.name == "nt" else "method")
            swift.write_text("import Foundation\nfinal class ActualEngineMethod {\n" + method + "\n}\n" + r'''
@main struct VerifyIdentifiers {
    static func main() {
        ActualEngineMethod().updatePlistIdentifiers(
            in: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true), randomizedID: 77777)
    }
}
''', encoding="utf-8")
            result = subprocess.run([compiler, "-swift-version", "5", "-warnings-as-errors", "-parse-as-library",
                                     str(swift), "-o", str(executable)], capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", env=environment, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for suggestion in (False, True):
                with self.subTest(suggestion_metadata=suggestion):
                    descriptor = root / ("suggestion" if suggestion else "descriptor")
                    contents = descriptor / "versions/1/contents"
                    wallpaper = contents / "44556.Clownfish-834w-1210h@2x~ipad.wallpaper"
                    wallpaper.mkdir(parents=True)
                    sidecar = descriptor / "com.apple.posterkit.provider.descriptor.identifier"
                    user_info = contents / "com.apple.posterkit.provider.contents.userInfo"
                    top = wallpaper / "Wallpaper.plist"
                    config = contents / prepare.CONFIG_BASENAME
                    sidecar.write_bytes(b"12345")
                    names = {"backgroundAnimationFileName": "44556.Clownfish_Background-834w-1210h@2x~ipad.ca",
                             "floatingAnimationFileNameKey": "44556.Clownfish_Floating-834w-1210h@2x~ipad.ca",
                             "foregroundAnimationFileName": "44556.Clownfish_Foreground-834w-1210h@2x~ipad.ca"}
                    original_user = {"wallpaperRepresentingIdentifier": "12345",
                                     "wallpaperRepresentingFileName": wallpaper.name,
                                     "posterEnvironmentOverrides": b"{}"}
                    asset = {"identifier": 44556, "name": "Original Human Title", **names}
                    original_top = {"identifier": 12345, "name": "Original Human Title",
                                    "family": "Clownfish", "assets": {"lockAndHome": {"default": asset}}}
                    user_info.write_bytes(plistlib.dumps(original_user, fmt=plistlib.FMT_BINARY))
                    top.write_bytes(plistlib.dumps(original_top, fmt=plistlib.FMT_BINARY))
                    config.write_bytes(b"unchanged-hidden-options\0\xff")
                    for role, filename in names.items():
                        plane = wallpaper / filename
                        plane.mkdir()
                        (plane / "main.caml").write_bytes(("unchanged-" + role).encode())
                    if suggestion:
                        (descriptor / "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist").write_bytes(b"present")
                    before = {path.relative_to(descriptor).as_posix(): path.read_bytes()
                              for path in descriptor.rglob("*") if path.is_file()}
                    run = subprocess.run([str(executable), str(descriptor)], capture_output=True, text=True,
                                         encoding="utf-8", errors="replace", env=environment, timeout=30)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    after = {path.relative_to(descriptor).as_posix(): path.read_bytes()
                             for path in descriptor.rglob("*") if path.is_file()}
                    self.assertEqual(set(before), set(after), "No files or asset bundles may be renamed")
                    if suggestion:
                        self.assertEqual(after, before, "Upstream suggestion-metadata early return must remain unchanged")
                        continue
                    self.assertEqual(sidecar.read_bytes(), b"77777")
                    user = plistlib.loads(user_info.read_bytes())
                    self.assertEqual(user, {**original_user, "wallpaperRepresentingIdentifier": "77777"})
                    self.assertIs(type(user["wallpaperRepresentingIdentifier"]), str)
                    self.assertEqual(plistlib.loads(top.read_bytes()), {**original_top, "identifier": 77777})
                    modified = {sidecar.relative_to(descriptor).as_posix(), user_info.relative_to(descriptor).as_posix(),
                                top.relative_to(descriptor).as_posix()}
                    for path in set(before) - modified:
                        self.assertEqual(before[path], after[path], path)


if __name__ == "__main__":
    unittest.main()
