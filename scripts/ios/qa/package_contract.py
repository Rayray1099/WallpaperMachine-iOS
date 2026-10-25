#!/usr/bin/env python3
"""Synthetic unsigned IPA fixtures and the QA contract for the build validator.

Build Agent owns the validator (``scripts/ios/validate_ipa.py`` or equivalent).
QA owns the fixtures: an IPA must pass only when it is a structurally valid,
unsigned, arm64 iPhoneOS app at the iOS 18 deployment floor, and each malformed
fixture must make the validator fail for the intended reason. The fixtures are
built here from the ZIP and plist formats directly; no proprietary app content or
signing identity is involved.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import time
import zipfile

try:
    from . import qa_paths
except ImportError:  # pragma: no cover
    import qa_paths  # type: ignore[no-redef]

VALIDATOR_ENV = "WM_QA_IPA_VALIDATOR"
VALIDATOR_CANDIDATES = (
    "scripts/ios/validate_ipa.py",
    "scripts/ios/validate.py",
    "scripts/ios/validate_package.py",
    "scripts/ios/package.py",
)

APP_NAME = "WallpaperMachineIOS"
DEFAULT_BUNDLE_ID = qa_paths.BUNDLE_ID

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPE_X86_64 = 0x01000007
MH_EXECUTE = 0x2
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
PLATFORM_IOS_SIMULATOR = 7


def version_field(major: int, minor: int = 0, patch: int = 0) -> int:
    return (major << 16) | (minor << 8) | patch


def macho(
    *,
    cpu_type: int = CPU_TYPE_ARM64,
    platform: int = PLATFORM_IOS,
    minos: tuple[int, int] = (18, 0),
    sdk: tuple[int, int] = (18, 0),
    filetype: int = MH_EXECUTE,
    pie: bool = True,
) -> bytes:
    """A minimal 64-bit Mach-O carrying one LC_BUILD_VERSION command."""
    command = struct.pack(
        "<IIIIII", LC_BUILD_VERSION, 24, platform,
        version_field(*minos), version_field(*sdk), 0)
    header = struct.pack(
        "<IiiIIIII", MH_MAGIC_64, cpu_type, 0, filetype,
        1, len(command), 0x200000 if pie else 0, 0)
    return header + command


def info_plist(*, bundle_id: str = DEFAULT_BUNDLE_ID,
               executable: str = APP_NAME,
               min_os: str = "18.0",
               supported_platform: str = "iPhoneOS",
               family: list[int] | None = None,
               localizations: list[str] | None = None) -> bytes:
    payload = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": executable,
        "CFBundleName": "WallpaperMachine",
        "CFBundleDisplayName": "WallpaperMachine",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "1.0.0",
        "CFBundleVersion": "1",
        "MinimumOSVersion": min_os,
        "CFBundleSupportedPlatforms": [supported_platform],
        "UIDeviceFamily": family or [1, 2],
        "CFBundleLocalizations": localizations or ["en", "zh-Hant"],
        "DTPlatformName": "iphoneos",
        "DTSDKName": "iphoneos18.0",
        "LSRequiresIPhoneOS": True,
        "NSMicrophoneUsageDescription": "QA fixture for microphone-driven wallpapers.",
    }
    return plistlib.dumps(payload, fmt=plistlib.FMT_BINARY)


def build_app(directory: str | Path, *, bundle_id: str = DEFAULT_BUNDLE_ID,
              executable: str = APP_NAME, cpu_type: int = CPU_TYPE_ARM64,
              platform: int = PLATFORM_IOS, min_os: str = "18.0",
              include_localizations: bool = True, pie: bool = True) -> Path:
    """A synthetic ``.app`` directory good enough for structural validation."""
    app = Path(directory) / f"{APP_NAME}.app"
    app.mkdir(parents=True, exist_ok=True)
    (app / "Info.plist").write_bytes(info_plist(
        bundle_id=bundle_id, executable=executable, min_os=min_os))
    version = tuple(int(part) for part in min_os.split(".")[:2])
    (app / executable).write_bytes(macho(
        cpu_type=cpu_type, platform=platform, minos=version, sdk=version, pie=pie))
    if include_localizations:
        for language in ("en", "zh-Hant"):
            directory = app / f"{language}.lproj"
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "Localizable.strings").write_bytes(b"/* QA fixture */\n")
    return app


def build_ipa_from_app(app: str | Path, path: str | Path, *,
                       extra_entries: tuple[tuple[str, bytes], ...] = (),
                       include_info_plist: bool = True,
                       include_executable: bool = True) -> Path:
    """Package a synthetic app as an IPA, optionally breaking it for negative cases."""
    app_path = Path(app)
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload_root = f"Payload/{app_path.name}"
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for source in sorted(app_path.rglob("*")):
            if not source.is_file():
                continue
            if source.name == "Info.plist" and not include_info_plist:
                continue
            if source.name == app_path.stem and source.parent == app_path and not include_executable:
                continue
            archive.writestr(f"{payload_root}/{source.relative_to(app_path).as_posix()}",
                             source.read_bytes())
        for name, payload in extra_entries:
            archive.writestr(name, payload)
    return target


@dataclass
class IPAOptions:
    bundle_id: str = DEFAULT_BUNDLE_ID
    executable: str = APP_NAME
    app_name: str = f"{APP_NAME}.app"
    cpu_type: int = CPU_TYPE_ARM64
    platform: int = PLATFORM_IOS
    min_os: str = "18.0"
    supported_platform: str = "iPhoneOS"
    include_payload: bool = True
    include_info_plist: bool = True
    include_executable: bool = True
    include_swift_libraries: bool = False
    extra_entries: tuple[tuple[str, bytes], ...] = ()


def build_ipa(path: str | Path, options: IPAOptions | None = None) -> Path:
    """Write one synthetic IPA; every negative case is a flag on this builder."""
    options = options or IPAOptions()
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    root = "Payload/" + options.app_name + "/"
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        if options.include_payload:
            if options.include_info_plist:
                archive.writestr(root + "Info.plist", info_plist(
                    bundle_id=options.bundle_id, executable=options.executable,
                    min_os=options.min_os,
                    supported_platform=options.supported_platform))
            if options.include_executable:
                archive.writestr(root + options.executable, macho(
                    cpu_type=options.cpu_type, platform=options.platform))
        if options.include_swift_libraries:
            archive.writestr(root + "Frameworks/libswiftCore.dylib", macho(
                cpu_type=CPU_TYPE_ARM64, platform=PLATFORM_IOS, filetype=0x6))
        for name, payload in options.extra_entries:
            archive.writestr(name, payload)
    return target


def discover_validator(explicit: str | os.PathLike[str] | None = None,
                       root: str | Path | None = None) -> Path | None:
    """Locate Build Agent's validator, or None when it has not landed yet."""
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        return candidate if candidate.is_file() else None
    environment = os.environ.get(VALIDATOR_ENV, "").strip()
    if environment:
        candidate = Path(environment).expanduser().resolve()
        return candidate if candidate.is_file() else None
    base = Path(root) if root else qa_paths.ROOT
    for relative in VALIDATOR_CANDIDATES:
        candidate = base / relative
        if candidate.is_file():
            return candidate
    return None


@dataclass(frozen=True)
class ValidatorResult:
    command: list[str]
    returncode: int
    stdout: str
    stderr: str
    duration_ms: float
    ipa: Path

    @property
    def output(self) -> str:
        return (self.stdout + "\n" + self.stderr).strip()

    def as_dict(self) -> dict:
        return {
            "command": [Path(part).name if part.endswith(".py") else part
                        for part in self.command],
            "returncode": self.returncode,
            "stdout": self.stdout,
            "stderr": self.stderr,
            "duration_ms": round(self.duration_ms, 1),
        }


def run_validator(validator: str | Path, ipa: str | Path, *,
                  app: str | Path | None = None,
                  extra_args: tuple[str, ...] = (), timeout: float = 120.0,
                  python_executable: str | None = None) -> ValidatorResult:
    """Run the validator on one IPA (plus app bundle when its CLI requires one)."""
    script = Path(validator)
    target = Path(ipa)
    if not script.is_file():
        raise FileNotFoundError(script)
    if not target.is_file():
        raise FileNotFoundError(target)
    if script.suffix == ".py":
        command = [python_executable or sys.executable, str(script)]
    else:
        command = [str(script)]
    if app is not None:
        command.extend(["--app", str(Path(app)), "--ipa", str(target)])
    else:
        command.append(str(target))
    command.extend(extra_args)
    started = time.monotonic()
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                               cwd=str(qa_paths.ROOT), check=False)
    return ValidatorResult(
        command=command, returncode=completed.returncode,
        stdout=completed.stdout, stderr=completed.stderr,
        duration_ms=(time.monotonic() - started) * 1000.0, ipa=target)


def validator_report(validator: Path | None, results: list[ValidatorResult]) -> dict:
    return {
        "validator": str(validator) if validator else None,
        "cases": [result.as_dict() for result in results],
        "case_count": len(results),
    }


def positive_and_invalid_cases(directory: str | Path) -> dict[str, tuple[Path, bool]]:
    """Build each contract fixture; maps case name to (IPA path, should_pass)."""
    base = Path(directory)
    base.mkdir(parents=True, exist_ok=True)
    cases: dict[str, tuple[Path, bool]] = {}

    cases["valid"] = (build_ipa(base / "valid.ipa"), True)
    cases["missing_payload"] = (
        build_ipa(base / "missing_payload.ipa", IPAOptions(include_payload=False)), False)
    cases["missing_info_plist"] = (
        build_ipa(base / "missing_info_plist.ipa",
                  IPAOptions(include_info_plist=False)), False)
    cases["missing_executable"] = (
        build_ipa(base / "missing_executable.ipa",
                  IPAOptions(include_executable=False)), False)
    cases["wrong_bundle_id"] = (
        build_ipa(base / "wrong_bundle_id.ipa",
                  IPAOptions(bundle_id="com.example.notwallpapermachine")), False)
    cases["wrong_executable"] = (
        build_ipa(base / "wrong_executable.ipa",
                  IPAOptions(executable="SomeOtherApp")), False)
    cases["x86_64_slice"] = (
        build_ipa(base / "x86_64_slice.ipa",
                  IPAOptions(cpu_type=CPU_TYPE_X86_64)), False)
    cases["simulator_platform"] = (
        build_ipa(base / "simulator_platform.ipa",
                  IPAOptions(platform=PLATFORM_IOS_SIMULATOR)), False)
    cases["old_deployment_target"] = (
        build_ipa(base / "old_deployment_target.ipa",
                  IPAOptions(min_os="16.0")), False)
    cases["traversal_entry"] = (
        build_ipa(base / "traversal_entry.ipa", IPAOptions(extra_entries=(
            ("Payload/../../escape.txt", b"escape"),))), False)
    return cases


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", default=str(qa_paths.QA_ARTIFACTS / "ipa-fixtures"))
    parser.add_argument("--validator", default=None)
    args = parser.parse_args()
    validator = discover_validator(args.validator)
    print(f"validator: {validator or 'not found'}")
    if not validator:
        raise SystemExit(2)
    for name, (ipa, should_pass) in positive_and_invalid_cases(args.directory).items():
        result = run_validator(validator, ipa)
        verdict = "PASS" if (result.returncode == 0) == should_pass else "FAIL"
        print(json.dumps({"case": name, "expected_pass": should_pass,
                          "returncode": result.returncode, "verdict": verdict}))
