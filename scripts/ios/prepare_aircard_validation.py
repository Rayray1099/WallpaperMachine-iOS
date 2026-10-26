#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Apply three source-pinned AirCard validation changes in a separate checkout.

No download, commit, build, install, device operation or preferences mutation.
The caller obtains the MIT upstream source and retains its license in artifacts.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

PINNED_COMMIT = "40640c4d827aeab8d798285b57d24fcf6be070d0"
ORIGINAL_BLOBS = {
    "rust-core/src/exploit.rs": "a759c80b44112708c8c377c46123c1d1b0f46873",
    "ios-app/TendiesEngine.swift": "ae7afdc343489df9fc8fdf495f50c77fa693aeea",
    "ios-app/AppViewModel.swift": "7cb0eefacb0eb5986bca4d0d232185e387f4fbf1",
}
CONFIG_BASENAME = ".com.apple.posterkit.provider.contents.configurableOptions.plist"
RUST_TEST_FILTER = "wm_posterboard_validation"

# These bounded before-contexts identify the precise upstream statements, not a
# vendored implementation. Whole-file Git blob IDs guard every other byte.
RUST_OLD_BLOCK = """            if file_name == "__MACOSX" || file_name.starts_with('.') {
                continue;
            }
            let rel = path.strip_prefix(base)?.to_string_lossy().to_string();
            if path.is_dir() {
                let dir_entry = format!("payload/{rel}/");
                zip.add_directory(&dir_entry, zip_opts(0o040755))?;
                walk_dir(&path, base, zip)?;
            } else if path.is_file() {"""

RUST_NEW_BLOCK = """            let file_type = entry.file_type()?;
            let components: Vec<String> = path.strip_prefix(base)?.components()
                .map(|part| part.as_os_str().to_string_lossy().into_owned())
                .collect();
            // A descriptor's one legitimate hidden options file is not Finder junk.
            // Never follow symlinks or descend through hidden/junk directories.
            let is_poster_options = file_type.is_file()
                && components.len() == 4
                && components[0] == "versions"
                && !components[1].is_empty()
                && components[2] == "contents"
                && components[3] == ".com.apple.posterkit.provider.contents.configurableOptions.plist"
                && components[..3].iter().all(|part| !part.starts_with('.') && part != "__MACOSX");
            if file_name == "__MACOSX" || (file_name.starts_with('.') && !is_poster_options) {
                continue;
            }
            // ZIP member paths are POSIX on every host, including Windows.
            let rel = components.join("/");
            if file_type.is_dir() {
                let dir_entry = format!("payload/{rel}/");
                zip.add_directory(&dir_entry, zip_opts(0o040755))?;
                walk_dir(&path, base, zip)?;
            } else if file_type.is_file() {"""

SWIFT_OLD_LINE = '                    plist["wallpaperRepresentingIdentifier"] = randomizedID'
SWIFT_NEW_LINE = '                    plist["wallpaperRepresentingIdentifier"] = String(randomizedID)'
RESPRING_OLD_BLOCK = """            tendiesFlashLog.append("⚡ Triggering NeoSpring respring...")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.isNeoSpringing = true
                RespringHelper.triggerNeoSpring()
            }"""
RESPRING_NEW_BLOCK = """            tendiesFlashLog.append("Validation: injection complete; automatic NeoSpring is disabled. Inspect terminal logs and the picker before any separately authorized manual respring.")"""


class PreparationError(RuntimeError):
    """A failed guard; no speculative source replacement is permitted."""


def git(source, *args):
    result = subprocess.run(["git", "-C", str(source), *args], capture_output=True, timeout=60)
    if result.returncode:
        raise PreparationError("Git inspection failed: " + result.stderr.decode("utf-8", "replace"))
    return result.stdout


def normalize(data):
    return data.replace(b"\r\n", b"\n")


def blob_id(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def replace_scoped(text, start, end, before, after):
    if text.count(start) != 1:
        raise PreparationError("Unexpected or ambiguous function signature: " + start)
    first = text.index(start)
    last = text.find(end, first + len(start))
    if last < 0:
        raise PreparationError("Missing exact function boundary: " + end)
    body = text[first:last]
    if body.count(before) != 1:
        raise PreparationError("Pinned function body does not contain one exact expected mutation")
    return text[:first] + body.replace(before, after, 1) + text[last:]


def patch_rust(data):
    text = normalize(data).decode("utf-8")
    text = replace_scoped(text, "fn build_folder_archive(\n", "\n/// Build the Books.plist sync manifest.",
                          RUST_OLD_BLOCK, RUST_NEW_BLOCK)
    if "mod wm_posterboard_validation" in text:
        raise PreparationError("Unexpected pre-existing validation test module")
    tests = Path(__file__).with_name("test_aircard_payload.rs").read_text(encoding="utf-8")
    return (text.rstrip("\n") + "\n\n" + tests.rstrip("\n") + "\n").encode()


def patch_tendies(data):
    text = normalize(data).decode("utf-8")
    return replace_scoped(text,
        "    func updatePlistIdentifiers(in folderURL: URL, randomizedID: Int) {\n",
        "\n    // MARK: - Folder Injector Helper", SWIFT_OLD_LINE, SWIFT_NEW_LINE).encode()


def patch_viewmodel(data):
    text = normalize(data).decode("utf-8")
    return replace_scoped(text, "    func flashSelectedTendies() async {\n",
        "\n    func respringDevice() {", RESPRING_OLD_BLOCK, RESPRING_NEW_BLOCK).encode()


def original_sources(source):
    head = git(source, "rev-parse", "HEAD").decode().strip()
    if head != PINNED_COMMIT:
        raise PreparationError(f"Expected pinned AirCard HEAD {PINNED_COMMIT}, received {head}")
    originals = {}
    for relative, expected_blob in ORIGINAL_BLOBS.items():
        data = git(source, "show", f"HEAD:{relative}")
        if blob_id(data) != expected_blob:
            raise PreparationError("Unexpected pinned source blob: " + relative)
        originals[relative] = data
    return originals


def plan(source):
    source = Path(source).absolute()
    if source.is_symlink():
        raise PreparationError("Use a real separate checkout, not a source-root symlink")
    source = source.resolve(strict=True)
    parts = [part.casefold() for part in source.parts]
    if any(parts[i:i + 2] == [".local", "references"] for i in range(len(parts) - 1)):
        raise PreparationError("The read-only .local/references baseline must never be patched")
    top = Path(git(source, "rev-parse", "--show-toplevel").decode("utf-8").strip()).resolve()
    if top != source:
        raise PreparationError("--source must name the separate checkout root")
    originals = original_sources(source)
    patchers = (patch_rust, patch_tendies, patch_viewmodel)
    records = []
    for (relative, original), patcher in zip(originals.items(), patchers):
        target = source / relative
        if any(path.is_symlink() for path in (target, *target.parents) if path != source.parent):
            raise PreparationError("Source paths must not contain symlinks: " + relative)
        current = target.read_bytes()
        # Respect checkout CRLF while comparing Git's canonical original bytes.
        newline = b"\r\n" if b"\r\n" in current else b"\n"
        patched = patcher(original).replace(b"\n", newline)
        clean_original = normalize(original).replace(b"\n", newline)
        if current not in (clean_original, patched):
            raise PreparationError("Unexpected worktree edits; refusing all writes: " + relative)
        records.append({"path": relative, "target": target, "original": current,
                        "baseline": clean_original, "patched": patched,
                        "already_patched": current == patched})
    already = [record["already_patched"] for record in records]
    if any(already) and not all(already):
        raise PreparationError("Partially applied patch; refusing all writes")
    status = git(source, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    expected_status = {b" M " + record["path"].encode() for record in records} if all(already) else set()
    if set(status.rstrip(b"\0").split(b"\0")) - {b""} != expected_status:
        raise PreparationError("Checkout must be clean, or contain only this exact complete unstaged patch")
    return source, records


def staged_file(target, data, mode):
    descriptor, name = tempfile.mkstemp(prefix=".wm-aircard-stage-", dir=target.parent)
    staged = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        staged.chmod(mode)
        return staged
    except BaseException:
        staged.unlink(missing_ok=True)
        raise


def apply_records(records):
    """Stage everything first; replace atomically per file and roll back on error."""
    staged = []
    replaced = []
    try:
        for record in records:
            target = record["target"]
            mode = stat.S_IMODE(target.stat().st_mode)
            staged.append((record, staged_file(target, record["patched"], mode), mode))
        # Catch ordinary concurrent edits before replacing any source file.
        for record in records:
            if record["target"].read_bytes() != record["original"]:
                raise PreparationError("Source changed during staging; refusing replacement")
        for record, temporary, mode in staged:
            os.replace(temporary, record["target"])
            replaced.append((record, mode))
    except BaseException as error:
        failures = []
        for record, mode in reversed(replaced):
            try:
                rollback = staged_file(record["target"], record["original"], mode)
                try:
                    os.replace(rollback, record["target"])
                finally:
                    rollback.unlink(missing_ok=True)
            except OSError:
                failures.append(record["path"])
        if failures:
            raise PreparationError("Replacement failed and rollback requires inspection: " + ", ".join(failures)) from error
        raise
    finally:
        for _, temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def prepare(source, report):
    source, records = plan(source)
    report = Path(report).absolute()
    if source == report.resolve() or source in report.resolve().parents:
        raise PreparationError("Write the JSON report outside the upstream checkout")
    result = {
        "source": str(source), "upstream_commit": PINNED_COMMIT,
        "status": "already_prepared" if all(row["already_patched"] for row in records) else "prepared",
        "automatic_neospring": False, "asset_identifiers_or_names_renamed": False,
        "rust_test_filter": RUST_TEST_FILTER,
        "cargo_locked": (source / "rust-core/Cargo.lock").is_file(),
        "changes": [{"path": row["path"], "upstream_blob": ORIGINAL_BLOBS[row["path"]],
                     "original_sha256": hashlib.sha256(row["baseline"]).hexdigest(),
                     "patched_sha256": hashlib.sha256(row["patched"]).hexdigest()}
                    for row in records],
    }
    if result["status"] == "prepared":
        apply_records(records)
    # Re-check all guards before emitting a successful mutation fingerprint.
    plan(source)
    report.parent.mkdir(parents=True, exist_ok=True)
    temporary = staged_file(report, (json.dumps(result, indent=2, sort_keys=True) + "\n").encode(), 0o600)
    try:
        os.replace(temporary, report)
    finally:
        temporary.unlink(missing_ok=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = prepare(args.source, args.report)
    except (PreparationError, OSError, UnicodeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"AirCard validation preparation refused: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
