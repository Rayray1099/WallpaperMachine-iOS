#!/usr/bin/env python3
"""Structurally validate the unsigned iOS app and IPA that CI produced.

This is the independent gate after xcodebuild and package.py. It does not trust
the build's exit status or the packaging script:

* the app executable is a thin arm64 device Mach-O (platform iOS, not macOS and
  not the simulator), with a minimum OS of at least 18.0, linked only against
  frameworks and system libraries that exist in the installed iPhoneOS SDK;
* the renderer archive contains real arm64 iOS objects and the Rust
  ``wm-shader`` plus C++ scene-engine C ABI symbols;
* the IPA has one ``Payload/*.app``, no absolute/traversing/symlink-escaping
  entries, and its executable is byte-identical to the built app;
* the build manifest's source commit is HEAD, its hashes cover the files, and
  every checksum matches;
* the bundle identifier, executable, device families and en/zh-Hant
  localizations are present.

The physical iPadOS 27 target is not exercised here and the report says so; a
successful CI run proves a structurally valid unsigned ARM64 build, not
on-device rendering. Run from the repository root after package.py.

Exit status: 0 only when every required check passes.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(SCRIPT_DIR))

from lib.glyphs import markers  # noqa: E402
import macho  # noqa: E402

MARK = markers()

DEFAULT_BUNDLE_ID = "com.rayray1099.wallpapermachine.ios"
DEFAULT_MINIMUM_OS = (18, 0)
EXPECTED_DEVICE_FAMILIES = {1, 2}
EXPECTED_LOCALIZATIONS = {"en", "zh-Hant"}

# Frameworks an iOS host for this renderer may link. Adding one is a deliberate
# review decision: a macOS-only framework here is exactly the failure mode this
# list exists to catch.
ALLOWED_FRAMEWORKS = frozenset(
    {
        "Accelerate",
        "AudioToolbox",
        "AudioUnit",
        "AVFAudio",
        "AVFoundation",
        "Combine",
        "CoreAudio",
        "CoreAudioTypes",
        "CoreFoundation",
        "CoreGraphics",
        "CoreHaptics",
        "CoreImage",
        "CoreLocation",
        "CoreMedia",
        "CoreML",
    "Foundation",
        "CoreMotion",
        "CoreServices",
        "CoreText",
        "CoreVideo",
        "GameController",
        "ImageIO",
        "IOSurface",
        "MediaToolbox",
        "Metal",
        "MetalKit",
        "Network",
        "OpenGLES",
        "Photos",
        "PhotosUI",
        "QuickLook",
        "QuartzCore",
        "Security",
        "StoreKit",
        "SwiftUI",
        "SystemConfiguration",
        "UIKit",
        "UniformTypeIdentifiers",
        "UserNotifications",
        "VideoToolbox",
        "WebKit",
    }
)
DENIED_FRAMEWORKS = frozenset(
    {
        "AppKit",
        "Carbon",
        "Cocoa",
        "CoreWLAN",
        "DiscRecording",
        "ExtensionKit",
        "GLUT",
        "ICADevices",
        "IOKit",
        "OpenGL",
        "PreferencePanes",
        "Quartz",
        "ScreenSaver",
        "ScriptingBridge",
        "ServiceManagement",
        "WebKitLegacy",
    }
)
SYSTEM_LIBRARIES = frozenset(
    {
        "/usr/lib/libSystem.B.dylib",
        "/usr/lib/libc++.1.dylib",
        "/usr/lib/libc++abi.dylib",
        "/usr/lib/libobjc.A.dylib",
        "/usr/lib/libz.1.dylib",
        "/usr/lib/libiconv.2.dylib",
        "/usr/lib/libbz2.1.0.dylib",
        "/usr/lib/libresolv.9.dylib",
        "/usr/lib/libsqlite3.dylib",
        "/usr/lib/libxml2.2.dylib",
        "/usr/lib/libcompression.dylib",
        "/usr/lib/libm.dylib",
        "/usr/lib/libdl.dylib",
        "/usr/lib/libpthread.dylib",
    }
)
SWIFT_RUNTIME = re.compile(r"^/usr/lib/swift/libswift[A-Za-z0-9_]+\.dylib$")
FRAMEWORK_PATH = re.compile(r"^/System/Library/Frameworks/([A-Za-z0-9_]+)\.framework/\1$")


@dataclass
class Check:
    name: str
    status: str
    detail: str


@dataclass
class Report:
    checks: list[Check] = field(default_factory=list)

    def add(self, name: str, status: str, detail: str) -> None:
        self.checks.append(Check(name, status, detail))

    def passed(self, name: str, detail: str) -> None:
        self.add(name, "pass", detail)

    def failed(self, name: str, detail: str) -> None:
        self.add(name, "fail", detail)

    def skipped(self, name: str, detail: str) -> None:
        self.add(name, "skip", detail)

    @property
    def failures(self) -> list[Check]:
        return [check for check in self.checks if check.status == "fail"]

    @property
    def verdict(self) -> str:
        return "fail" if self.failures else "pass"


def version_tuple(text: str | None) -> tuple[int, ...]:
    if not text:
        return ()
    return tuple(int(part) for part in re.findall(r"\d+", text)[:3])


def version_at_least(text: str | None, minimum: tuple[int, int]) -> bool:
    parts = version_tuple(text)
    if len(parts) < 2:
        return False
    return parts[:2] >= minimum


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def sha256(path: Path) -> str:
    return macho.sha256_file(path)


def git_output(*args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def detect_sdk(explicit: Path | None) -> Path | None:
    if explicit:
        return explicit if explicit.is_dir() else None
    try:
        result = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "--show-sdk-path"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    path = Path(result.stdout.strip())
    return path if path.is_dir() else None


def sdk_has_framework(sdk: Path, name: str) -> bool:
    framework = sdk / "System/Library/Frameworks" / f"{name}.framework"
    binary = framework / name
    return framework.is_dir() and (binary.exists() or (framework / f"{name}.tbd").exists())


def load_command_problems(info: macho.MachOInfo, sdk: Path | None) -> tuple[list[str], int, int]:
    """Framework-rule violations, plus framework and system-library counts."""
    problems: list[str] = []
    frameworks: list[str] = []
    libraries: list[str] = []
    for path in info.dylibs:
        if SWIFT_RUNTIME.match(path):
            libraries.append(path)
            continue
        if path in SYSTEM_LIBRARIES:
            libraries.append(path)
            continue
        match = FRAMEWORK_PATH.match(path)
        if match:
            name = match.group(1)
            frameworks.append(name)
            if name in DENIED_FRAMEWORKS:
                problems.append(f"macOS-only framework {name}")
            elif name not in ALLOWED_FRAMEWORKS:
                problems.append(f"framework {name} is not in the iOS allowlist")
            elif sdk is not None and not sdk_has_framework(sdk, name):
                problems.append(f"{name}.framework is not in the iPhoneOS SDK")
            continue
        problems.append(f"unexpected load path {path}")
    return problems, len(frameworks), len(libraries)


def check_load_commands(report: Report, info: macho.MachOInfo, sdk: Path | None) -> None:
    problems, framework_count, library_count = load_command_problems(info, sdk)
    if problems:
        report.failed("macho.load_commands", "; ".join(problems))
    else:
        report.passed(
            "macho.load_commands",
            f"{framework_count} frameworks, {library_count} system libraries, "
            "all allowed and present in the SDK"
            if sdk is not None
            else f"{framework_count} frameworks, {library_count} system libraries, allowlist only",
        )
    if sdk is None:
        report.skipped(
            "macho.sdk_frameworks",
            "no iPhoneOS SDK available on this machine; framework allowlist checked, "
            "existence in the SDK not checked",
        )


def check_executable(
    report: Report, executable: Path, minimum_os: tuple[int, int], sdk: Path | None
) -> macho.MachOInfo | None:
    if not executable.is_file():
        report.failed("executable.present", f"{rel(executable)} is missing")
        return None
    report.passed("executable.present", rel(executable))
    try:
        slices = macho.parse_macho(executable)
    except macho.MachOError as error:
        report.failed("macho.format", str(error))
        return None
    report.passed("macho.format", f"{len(slices)} slice(s), {', '.join(s.arch for s in slices)}")

    device_slices = [s for s in slices if s.platform == 2 and s.arch == "arm64"]
    if len(device_slices) != 1 or len(slices) != 1:
        detail = ", ".join(f"{s.arch}/{s.platform_name or 'no platform'}" for s in slices)
        report.failed(
            "macho.arch",
            f"expected exactly one thin arm64 device slice, found: {detail}",
        )
        info = slices[0]
    else:
        info = device_slices[0]
        report.passed("macho.arch", "thin arm64")

    if info.filetype != macho.MH_EXECUTE:
        report.failed("macho.filetype", f"expected execute (2), found {info.filetype_name}")
    else:
        report.passed("macho.filetype", "execute")

    if info.platform != 2:
        report.failed(
            "macho.platform",
            f"expected iOS device (2), found {info.platform_name or info.platform}",
        )
    else:
        report.passed("macho.platform", "iOS device (2)")

    if not version_at_least(info.minos, minimum_os):
        report.failed("macho.minimum_os", f"expected >= {minimum_os[0]}.{minimum_os[1]}, found {info.minos}")
    else:
        report.passed("macho.minimum_os", info.minos or "")

    if info.sdk and not version_at_least(info.sdk, minimum_os):
        report.failed("macho.sdk", f"linked against SDK {info.sdk}, older than the deployment floor")
    else:
        report.passed("macho.sdk", info.sdk or "not recorded")

    if not info.pie:
        report.failed("macho.pie", "MH_PIE is not set")
    else:
        report.passed("macho.pie", "position independent")

    report.passed(
        "macho.signature",
        "no code-signature load command (unsigned)" if not info.has_code_signature else
        "ad-hoc/signature blob present; the app is still not distribution-signed "
        "(CI builds with CODE_SIGNING_ALLOWED=NO)",
    )
    check_load_commands(report, info, sdk)
    return info


def check_bundle(
    report: Report,
    app: Path,
    executable: Path,
    expected_bundle: str,
    minimum_os: tuple[int, int],
) -> dict | None:
    info_path = app / "Info.plist"
    if not info_path.is_file():
        report.failed("bundle.info", f"{rel(info_path)} is missing")
        return None
    try:
        info = plistlib.loads(info_path.read_bytes())
    except Exception as error:  # plistlib raises several types for malformed input
        report.failed("bundle.info", f"cannot parse Info.plist: {error}")
        return None
    report.passed("bundle.info", rel(info_path))

    identifier = info.get("CFBundleIdentifier")
    if identifier != expected_bundle:
        report.failed("bundle.identifier", f"expected {expected_bundle}, found {identifier!r}")
    else:
        report.passed("bundle.identifier", identifier)

    if info.get("CFBundleExecutable") != executable.name:
        report.failed(
            "bundle.executable",
            f"Info.plist names {info.get('CFBundleExecutable')!r}, executable is {executable.name!r}",
        )
    else:
        report.passed("bundle.executable", executable.name)

    if info.get("CFBundlePackageType") != "APPL":
        report.failed("bundle.package_type", f"expected APPL, found {info.get('CFBundlePackageType')!r}")
    else:
        report.passed("bundle.package_type", "APPL")

    minimum = info.get("MinimumOSVersion")
    if not version_at_least(minimum, minimum_os):
        report.failed(
            "bundle.minimum_os",
            f"MinimumOSVersion {minimum!r} is below the iOS {minimum_os[0]}.{minimum_os[1]} floor",
        )
    else:
        report.passed("bundle.minimum_os", str(minimum))

    platform = info.get("DTPlatformName")
    supported = info.get("CFBundleSupportedPlatforms") or []
    if platform != "iphoneos" or "iPhoneOS" not in supported:
        report.failed(
            "bundle.platform",
            f"DTPlatformName={platform!r}, CFBundleSupportedPlatforms={supported!r}",
        )
    else:
        report.passed("bundle.platform", "iPhoneOS")

    families = set(info.get("UIDeviceFamily") or [])
    if not EXPECTED_DEVICE_FAMILIES.issubset(families):
        report.failed(
            "bundle.device_family",
            f"UIDeviceFamily {sorted(families)} does not include iPhone and iPad (1,2)",
        )
    else:
        report.passed("bundle.device_family", "1,2 (iPhone and iPad)")

    localizations = set(info.get("CFBundleLocalizations") or [])
    missing = EXPECTED_LOCALIZATIONS - localizations
    if missing:
        report.failed("bundle.localizations", f"CFBundleLocalizations lacks {sorted(missing)}")
    else:
        report.passed("bundle.localizations", ", ".join(sorted(localizations)))

    for language in sorted(EXPECTED_LOCALIZATIONS):
        directory = app / f"{language}.lproj"
        if not directory.is_dir():
            report.failed("bundle.localization_resources", f"{language}.lproj is missing")
        else:
            report.passed("bundle.localization_resources", f"{language}.lproj present")

    microphone = (info.get("NSMicrophoneUsageDescription") or "").strip()
    if not microphone:
        report.failed("bundle.microphone_usage", "NSMicrophoneUsageDescription is empty or missing")
    else:
        report.passed("bundle.microphone_usage", "present")

    if (app / "Contents").exists():
        report.failed("bundle.layout", "app contains a macOS Contents directory")
    else:
        report.passed("bundle.layout", "flat iOS bundle")

    embedded: list[str] = []
    frameworks_dir = app / "Frameworks"
    if frameworks_dir.exists():
        embedded.extend(rel(path) for path in frameworks_dir.rglob("*") if path.is_file())
    embedded.extend(rel(path) for path in app.rglob("*.dylib"))
    if embedded:
        report.failed(
            "bundle.embedded_dylibs",
            "dynamic libraries are embedded instead of statically linked: " + ", ".join(embedded[:5]),
        )
    else:
        report.passed("bundle.embedded_dylibs", "none (renderer is static)")

    if list(app.rglob("*.dSYM")):
        report.failed("bundle.dsym", "a dSYM bundle is inside the app")
    else:
        report.passed("bundle.dsym", "no dSYM inside the app")
    return info


def load_manifest(report: Report, artifacts: Path) -> dict | None:
    path = artifacts / "manifest.json"
    if not path.is_file():
        report.failed("manifest.present", f"{rel(path)} is missing")
        return None
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report.failed("manifest.present", f"cannot read manifest: {error}")
        return None
    report.passed("manifest.present", rel(path))
    schema = manifest.get("schema", "")
    if not str(schema).startswith("wallpapermachine.ios.build-manifest/v1"):
        report.failed("manifest.schema", f"unexpected schema {schema!r}")
    else:
        report.passed("manifest.schema", str(schema))
    return manifest


def check_manifest(
    report: Report,
    manifest: dict | None,
    ipa: Path,
    executable: Path,
    renderer_archive: Path,
    expected_bundle: str,
    artifacts: Path,
) -> None:
    if manifest is None:
        return
    source = manifest.get("source") or {}
    expected_commit = git_output("rev-parse", "HEAD")
    if not expected_commit:
        report.skipped("manifest.source", "git is unavailable; source commit cannot be compared")
    elif source.get("commit") != expected_commit:
        report.failed(
            "manifest.source",
            f"manifest commit {source.get('commit')!r} is not HEAD {expected_commit!r}",
        )
    else:
        report.passed("manifest.source", expected_commit)

    if source.get("dirty") is not False:
        report.failed("manifest.source_clean", "manifest records a dirty working tree")
    else:
        report.passed("manifest.source_clean", "clean")

    build = manifest.get("build") or {}
    if build.get("signing") != "unsigned":
        report.failed("manifest.signing", f"expected unsigned, found {build.get('signing')!r}")
    else:
        report.passed("manifest.signing", "unsigned")
    architectures = build.get("architectures") or []
    if architectures != ["arm64"]:
        report.failed("manifest.architecture", f"expected ['arm64'], found {architectures!r}")
    else:
        report.passed("manifest.architecture", "arm64")

    bundle = manifest.get("bundle") or {}
    if bundle.get("identifier") != expected_bundle:
        report.failed(
            "manifest.bundle",
            f"expected {expected_bundle}, found {bundle.get('identifier')!r}",
        )
    else:
        report.passed("manifest.bundle", expected_bundle)

    if ipa.is_file():
        recorded = (manifest.get("ipa") or {}).get("sha256")
        actual = sha256(ipa)
        if recorded != actual:
            report.failed("manifest.ipa_hash", f"manifest {recorded!r} != actual {actual!r}")
        else:
            report.passed("manifest.ipa_hash", actual)
        if (manifest.get("ipa") or {}).get("size") != ipa.stat().st_size:
            report.failed("manifest.ipa_size", "manifest IPA size does not match the file")
        else:
            report.passed("manifest.ipa_size", str(ipa.stat().st_size))

    artifact_entries = manifest.get("artifacts") or []
    if not artifact_entries:
        report.failed("manifest.artifacts", "manifest has no artifact checksums")
    problems: list[str] = []
    roles: set[str] = set()
    for entry in artifact_entries:
        path_text = entry.get("path")
        digest = entry.get("sha256")
        roles.add(str(entry.get("role")))
        if not path_text or not digest:
            problems.append(f"incomplete artifact entry {entry!r}")
            continue
        candidate = Path(path_text)
        if candidate.is_absolute() or ".." in candidate.parts:
            problems.append(f"artifact path is not repository-relative: {path_text!r}")
            continue
        target = ROOT / candidate
        if not target.is_file():
            problems.append(f"artifact missing: {path_text}")
        elif sha256(target) != digest:
            problems.append(f"hash mismatch: {path_text}")
    if problems:
        report.failed("manifest.artifacts", "; ".join(problems))
    else:
        report.passed("manifest.artifacts", f"{len(artifact_entries)} files, all hashes match")

    required_roles = {"app-executable", "renderer-archive", "renderer-bindings"}
    missing_roles = required_roles - roles
    if missing_roles:
        report.failed("manifest.artifact_roles", f"missing roles {sorted(missing_roles)}")
    else:
        report.passed("manifest.artifact_roles", ", ".join(sorted(required_roles)))

    if renderer_archive.is_file():
        renderer = manifest.get("renderer") or {}
        recorded = None
        archive_entry = renderer.get("archive")
        if isinstance(archive_entry, dict):
            recorded = archive_entry.get("sha256")
        if not recorded and isinstance(renderer.get("manifest"), dict):
            recorded = find_renderer_hash(renderer["manifest"])
        if not recorded:
            recorded = find_renderer_hash(renderer)
        actual = sha256(renderer_archive)
        if recorded and recorded != actual:
            report.failed("manifest.renderer_hash", f"manifest {recorded!r} != actual {actual!r}")
        elif recorded:
            report.passed("manifest.renderer_hash", actual)
        else:
            report.skipped("manifest.renderer_hash", "build manifest has no renderer archive hash")
    check_checksums(report, manifest, ipa, executable, artifacts)


def check_checksums(report: Report, manifest: dict, ipa: Path, executable: Path, artifacts: Path) -> None:
    checksums = artifacts / "checksums.sha256"
    if not checksums.is_file():
        report.failed("checksums.present", f"{rel(checksums)} is missing")
        return
    problems: list[str] = []
    seen: set[Path] = set()
    for line in checksums.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            problems.append(f"malformed checksum line: {line!r}")
            continue
        digest, path_text = parts
        path_text = path_text.lstrip("*")
        candidate = Path(path_text)
        if candidate.is_absolute() or ".." in candidate.parts:
            problems.append(f"checksum path is not repository-relative: {path_text!r}")
            continue
        target = (ROOT / candidate).resolve()
        seen.add(target)
        if not target.is_file():
            problems.append(f"checksummed file missing: {path_text}")
        elif sha256(target) != digest:
            problems.append(f"checksum mismatch: {path_text}")
    for required in (ipa.resolve(), executable.resolve(), (artifacts / "manifest.json").resolve()):
        if required not in seen:
            problems.append(f"{rel(required)} is not covered by checksums.sha256")
    if problems:
        report.failed("checksums.verify", "; ".join(problems))
    else:
        report.passed("checksums.verify", f"{len(seen)} files")


def check_renderer(
    report: Report, renderer_dir: Path, configuration: str
) -> macho.ArchiveInfo | None:
    if not renderer_dir.is_dir():
        report.failed("renderer.directory", f"{rel(renderer_dir)} is missing")
        return None
    archive = renderer_dir / "lib/libWallpaperSceneRenderer.a"
    bindings = renderer_dir / "include"
    for name in ("WallpaperSceneRenderer.h", "Platform/Apple/SceneWallpaperBindings.h", "Core/RendererCounters.h"):
        path = bindings / name
        if not path.is_file():
            report.failed("renderer.bindings", f"{rel(path)} is missing")
            return None
    header = (bindings / "Platform/Apple/SceneWallpaperBindings.h").read_text(encoding="utf-8")
    if "owe_scene_wallpaper_new" not in header:
        report.failed("renderer.bindings", "C ABI header does not expose the real scene renderer")
    else:
        report.passed("renderer.bindings", "Existing engine C ABI and renderer umbrella headers")

    if not archive.is_file():
        report.failed("renderer.archive", f"{rel(archive)} is missing")
        return None
    try:
        info = macho.inspect_archive(
            archive,
            {
                "engine": ["owe_scene_wallpaper_new", "scenewallpaper", "wescene"],
                "shader": ["rs_shader"],
            },
        )
    except macho.MachOError as error:
        report.failed("renderer.archive", f"cannot parse {rel(archive)}: {error}")
        return None
    if info.objects == 0:
        report.failed("renderer.archive", "archive contains no Mach-O objects")
        return info
    if set(info.archs) != {"arm64"}:
        report.failed("renderer.arch", f"expected only arm64 objects, found {info.archs}")
    else:
        report.passed("renderer.arch", f"arm64 across {info.objects} objects")
    if info.macos_objects or info.simulator_objects:
        report.failed(
            "renderer.platform",
            f"{info.macos_objects} macOS and {info.simulator_objects} simulator objects "
            "are in the device archive",
        )
    elif info.ios_objects == 0:
        report.failed("renderer.platform", "no object records the iOS platform")
    else:
        report.passed(
            "renderer.platform",
            f"{info.ios_objects} iOS objects"
            + (f", {info.unknown_platform_objects} without a build-version command"
               if info.unknown_platform_objects else ""),
        )
    missing = [name for name, values in info.symbols.items() if not values]
    if missing:
        report.failed(
            "renderer.symbols",
            "archive lacks " + ", ".join(missing) + " symbols (Rust wm-shader, C++ engine)",
        )
    else:
        report.passed(
            "renderer.symbols",
            "; ".join(f"{name}: {values[0]}" for name, values in info.symbols.items()),
        )
    if info.size < 1_000_000:
        report.failed("renderer.size", f"archive is only {info.size} bytes")
    else:
        report.passed("renderer.size", f"{info.size // (1024 * 1024)} MiB")
    if info.has_code_signature:
        report.failed("renderer.signature", "static archive object has a code-signature command")
    else:
        report.passed("renderer.signature", "unsigned objects")

    manifest_path = renderer_dir / "manifest.json"
    if not manifest_path.is_file():
        report.failed("renderer.manifest", f"{rel(manifest_path)} is missing")
    else:
        try:
            renderer_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            report.failed("renderer.manifest", f"cannot parse: {error}")
            renderer_manifest = {}
        recorded = find_renderer_hash(renderer_manifest)
        if recorded and recorded != info.sha256:
            report.failed("renderer.manifest", f"recorded archive hash {recorded!r} != {info.sha256!r}")
        elif recorded:
            report.passed("renderer.manifest", f"archive hash {recorded}")
        else:
            report.skipped("renderer.manifest", "manifest present but no archive hash recorded")
    return info


def find_renderer_hash(manifest: dict) -> str | None:
    for key in ("archiveSHA256", "archive_sha256", "sha256"):
        value = manifest.get(key)
        if isinstance(value, str) and len(value) == 64:
            return value
    archive = manifest.get("archive")
    if isinstance(archive, dict):
        for key in ("sha256", "archive_sha256"):
            value = archive.get(key)
            if isinstance(value, str) and len(value) == 64:
                return value
    artifacts = manifest.get("artifacts")
    if isinstance(artifacts, list):
        for entry in artifacts:
            if isinstance(entry, dict) and entry.get("role") in ("archive", "renderer-archive"):
                value = entry.get("sha256")
                if isinstance(value, str) and len(value) == 64:
                    return value
    return None


def check_ipa(
    report: Report,
    ipa: Path,
    app: Path | None,
    executable: Path | None,
    minimum_os: tuple[int, int],
    sdk: Path | None = None,
    expected_bundle: str = DEFAULT_BUNDLE_ID,
) -> None:
    if not ipa.is_file():
        report.failed("ipa.present", f"{rel(ipa)} is missing")
        return
    report.passed("ipa.present", f"{rel(ipa)} ({ipa.stat().st_size} bytes)")
    try:
        archive = zipfile.ZipFile(ipa)
    except (OSError, zipfile.BadZipFile) as error:
        report.failed("ipa.format", f"not a readable zip: {error}")
        return
    problems: list[str] = []
    names: list[str] = []
    apps: set[str] = set()
    with archive:
        for entry in archive.infolist():
            name = entry.filename
            names.append(name)
            if "\\" in name:
                problems.append(f"backslash in member name: {name!r}")
            if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
                problems.append(f"absolute member name: {name!r}")
            parts = [part for part in name.split("/") if part not in ("", ".")]
            if ".." in parts:
                problems.append(f"traversing member name: {name!r}")
            if entry.flag_bits & 0x1:
                problems.append(f"encrypted member: {name!r}")
            if name == "__MACOSX" or name.startswith("__MACOSX/"):
                problems.append(f"__MACOSX member: {name!r}")
            if name.startswith("Payload/") and len(parts) >= 2:
                apps.add(parts[1])
            is_symlink = (entry.external_attr >> 16) & 0o170000 == 0o120000
            if is_symlink:
                target = archive.read(entry).decode("utf-8", "replace")
                target_parts = [part for part in target.split("/") if part not in ("", ".")]
                if target.startswith("/") or ".." in target_parts:
                    problems.append(f"symlink escapes the app: {name!r} -> {target!r}")
        if len(apps) != 1:
            problems.append(f"expected one Payload/*.app, found {sorted(apps)}")
            app_name = None
        else:
            app_name = next(iter(apps))
            if not app_name.endswith(".app"):
                problems.append(f"Payload entry {app_name!r} is not an .app")
        prefix = f"Payload/{app_name}/" if app_name else "Payload/"
        allowed_container_entries = {"Payload/", f"Payload/{app_name}", f"Payload/{app_name}/"}
        for name in names:
            if name in allowed_container_entries:
                continue
            if not name.startswith(prefix):
                problems.append(f"member outside {prefix}: {name!r}")
        if app_name:
            ipa_plist = b""
            try:
                ipa_plist = archive.read(f"{prefix}Info.plist")
            except KeyError:
                problems.append("IPA has no Info.plist")
            inner_info: dict = {}
            if ipa_plist:
                try:
                    inner_info = plistlib.loads(ipa_plist)
                except Exception as error:
                    problems.append(f"IPA Info.plist does not parse: {error}")
                else:
                    identifier = inner_info.get("CFBundleIdentifier")
                    if identifier != expected_bundle:
                        report.failed(
                            "ipa.bundle_identifier",
                            f"expected {expected_bundle}, found {identifier!r}",
                        )
                    else:
                        report.passed("ipa.bundle_identifier", identifier)
                    declared = inner_info.get("CFBundlePackageType")
                    if declared != "APPL":
                        report.failed("ipa.package_type", f"expected APPL, found {declared!r}")
                    else:
                        report.passed("ipa.package_type", "APPL")
                    if inner_info.get("DTPlatformName") != "iphoneos" or "iPhoneOS" not in (
                        inner_info.get("CFBundleSupportedPlatforms") or []
                    ):
                        report.failed(
                            "ipa.platform",
                            f"DTPlatformName={inner_info.get('DTPlatformName')!r}, "
                            f"CFBundleSupportedPlatforms={inner_info.get('CFBundleSupportedPlatforms')!r}",
                        )
                    else:
                        report.passed("ipa.platform", "iPhoneOS")
                    if not version_at_least(inner_info.get("MinimumOSVersion"), minimum_os):
                        report.failed(
                            "ipa.minimum_os",
                            f"MinimumOSVersion {inner_info.get('MinimumOSVersion')!r} is below the "
                            f"iOS {minimum_os[0]}.{minimum_os[1]} floor",
                        )
                    else:
                        report.passed("ipa.minimum_os", str(inner_info.get("MinimumOSVersion")))
                    families = set(inner_info.get("UIDeviceFamily") or [])
                    if not EXPECTED_DEVICE_FAMILIES.issubset(families):
                        report.failed(
                            "ipa.device_family",
                            f"UIDeviceFamily {sorted(families)} does not include iPhone and iPad",
                        )
                    else:
                        report.passed("ipa.device_family", "1,2")
            declared_executable = inner_info.get("CFBundleExecutable")
            expected_executable = executable.name if executable is not None else (
                app_name.removesuffix(".app") if app_name else None
            )
            if app is not None:
                expected_executable = executable.name if executable is not None else declared_executable
            if expected_executable and declared_executable != expected_executable:
                report.failed(
                    "ipa.bundle_executable",
                    f"expected {expected_executable!r}, Info.plist names {declared_executable!r}",
                )
            elif declared_executable:
                report.passed("ipa.bundle_executable", declared_executable)
            elif app is not None:
                report.failed("ipa.bundle_executable", "Info.plist names no executable")
            executable_member = f"{prefix}{declared_executable}" if declared_executable else ""
            payload = b""
            if executable_member:
                try:
                    payload = archive.read(executable_member)
                except KeyError:
                    problems.append(f"IPA has no {executable_member}")
            if payload:
                try:
                    slices = macho.parse_macho_bytes(payload)
                except macho.MachOError as error:
                    report.failed("ipa.executable_format", f"not a Mach-O: {error}")
                else:
                    inner = slices[0] if len(slices) == 1 else None
                    if inner is None:
                        report.failed(
                            "ipa.executable_arch",
                            f"expected one slice, found {[slice.arch for slice in slices]}",
                        )
                    else:
                        if inner.arch != "arm64" or inner.platform != 2:
                            report.failed(
                                "ipa.executable_arch",
                                f"{inner.arch}/{inner.platform_name}, expected arm64 iOS device",
                            )
                        else:
                            report.passed("ipa.executable_arch", "arm64 iOS device")
                        if inner.filetype != macho.MH_EXECUTE:
                            report.failed(
                                "ipa.executable_type",
                                f"expected execute, found {inner.filetype_name}",
                            )
                        else:
                            report.passed("ipa.executable_type", "execute")
                        if not version_at_least(inner.minos, minimum_os):
                            report.failed(
                                "ipa.executable_minimum_os",
                                f"Mach-O minimum OS {inner.minos} is below the floor",
                            )
                        else:
                            report.passed("ipa.executable_minimum_os", inner.minos or "")
                        load_problems, _, _ = load_command_problems(inner, sdk)
                        if load_problems:
                            report.failed("ipa.load_commands", "; ".join(load_problems))
                        else:
                            report.passed("ipa.load_commands", "allowed frameworks and system libraries")
                        if app is not None and executable is not None:
                            if sha256_bytes(payload) != sha256(executable):
                                problems.append("IPA executable differs from the built app executable")
                            else:
                                report.passed("ipa.executable_matches_app", "byte-identical")
            if app is not None:
                if ipa_plist and ipa_plist != (app / "Info.plist").read_bytes():
                    problems.append("IPA Info.plist differs from the built app Info.plist")
                else:
                    report.passed("ipa.info_matches_app", "byte-identical")
                for language in sorted(EXPECTED_LOCALIZATIONS):
                    if not any(name.startswith(f"{prefix}{language}.lproj/") for name in names):
                        problems.append(f"IPA lacks {language}.lproj resources")
                    else:
                        report.passed("ipa.localization_resources", f"{language}.lproj")
            else:
                report.skipped(
                    "ipa.matches_app",
                    "IPA-only validation: no built .app was supplied to compare against",
                )
        if problems:
            report.failed("ipa.structure", "; ".join(problems[:10]))
        elif app_name:
            report.passed(
                "ipa.structure",
                f"Payload/{app_name}/, {len(names)} members"
                + (", matches the built app" if app is not None else ""),
            )
    if not names:
        report.failed("ipa.empty", "IPA contains no files")


def sha256_bytes(data: bytes) -> str:
    import hashlib

    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "ipa_path",
        nargs="?",
        type=Path,
        help="Packaged unsigned IPA (also accepted as --ipa; an IPA-only run needs no --app).",
    )
    parser.add_argument("--ipa", dest="ipa_option", type=Path, help="Packaged unsigned IPA.")
    parser.add_argument("--app", type=Path, help="Built .app bundle; enables the full app/manifest checks.")
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        help="Directory with manifest.json/checksums.sha256 (default: the IPA's directory).",
    )
    parser.add_argument(
        "--renderer-dir", type=Path, default=ROOT / "iOS/Generated/Renderer", help="Renderer output root."
    )
    parser.add_argument("--configuration", default="Release", choices=["Debug", "Release"])
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_ID)
    parser.add_argument("--sdk", type=Path, help="iPhoneOS SDK path (default: xcrun detects it).")
    parser.add_argument("--report", type=Path, help="JSON report path (default: ARTIFACTS/validation.json).")
    args = parser.parse_args()

    ipa = (args.ipa_option or args.ipa_path)
    if ipa is None:
        parser.error("supply the IPA as a positional argument or with --ipa")
    ipa = ipa.resolve()
    app = args.app.resolve() if args.app else None
    artifacts = args.artifacts_dir.resolve() if args.artifacts_dir else (
        ipa.parent if app is not None else None
    )
    renderer_dir = args.renderer_dir.resolve()
    minimum_os = DEFAULT_MINIMUM_OS
    sdk = detect_sdk(args.sdk.resolve() if args.sdk else None)

    report = Report()
    executable: Path | None = None
    renderer_info: macho.ArchiveInfo | None = None
    if app is None:
        report.skipped(
            "app.bundle",
            "IPA-only validation: pass --app for the built-app, manifest and renderer checks",
        )
    else:
        info_path = app / "Info.plist"
        bundle: dict = {}
        if info_path.is_file():
            try:
                bundle = plistlib.loads(info_path.read_bytes())
            except Exception:
                bundle = {}
        executable = app / str(bundle.get("CFBundleExecutable") or "WallpaperMachineIOS")
        check_bundle(report, app, executable, args.bundle_id, minimum_os)
        check_executable(report, executable, minimum_os, sdk)
        renderer_info = check_renderer(report, renderer_dir, args.configuration)
        assert artifacts is not None
        manifest = load_manifest(report, artifacts)
        check_manifest(
            report,
            manifest,
            ipa,
            executable,
            renderer_dir / "lib/libWallpaperSceneRenderer.a",
            args.bundle_id,
            artifacts,
        )
    check_ipa(report, ipa, app, executable, minimum_os, sdk, args.bundle_id)
    report.skipped(
        "physical.ipados27",
        "CI cannot exercise the physical iPadOS 27 target; success is a structural build result only",
    )

    now = datetime.now(timezone.utc).isoformat()
    document = {
        "schema": "wallpapermachine.ios.validation/v1",
        "generated_at": now,
        "mode": "app+ipa" if app is not None else "ipa-only",
        "app": rel(app) if app is not None else None,
        "ipa": rel(ipa),
        "sdk": str(sdk) if sdk else None,
        "minimum_os": f"{minimum_os[0]}.{minimum_os[1]}",
        "verdict": report.verdict,
        "checks": [check.__dict__ for check in report.checks],
        "renderer": {
            "archive": rel(renderer_info.path) if renderer_info else None,
            "objects": renderer_info.objects if renderer_info else None,
            "sha256": renderer_info.sha256 if renderer_info else None,
        },
    }
    report_path = args.report or (artifacts / "validation.json" if artifacts is not None else None)
    if report_path is not None:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    for check in report.checks:
        prefix = {"pass": MARK.ok, "fail": MARK.missing, "skip": MARK.warn}[check.status]
        print(f"{prefix} {check.name}: {check.detail}")
    if report.failures:
        print(
            f"{MARK.missing} validation failed: {len(report.failures)} check(s)"
            + (f"; report: {rel(report_path)}" if report_path is not None else ""),
            flush=True,
        )
        return 1
    print(
        f"{MARK.ok} structurally valid unsigned arm64 iOS build"
        + (f"; report: {rel(report_path)}" if report_path is not None else ""),
        flush=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
