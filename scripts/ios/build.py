#!/usr/bin/env python3
"""Build the unsigned ARM64 iOS app from the Rust/C++ renderer and XcodeGen spec.

Stages, in order:

1. select the installed Xcode and detect the iPhoneOS SDK (the SDK version is
   read from the machine; nothing here assumes an iOS 27 SDK);
2. clean ``iOS/Generated/Renderer`` and run
   ``scripts/ios/build_renderer.sh --sdk iphoneos``, which builds the Rust
   ``wm-shader`` static library and C++ scene engine C ABI for arm64 device;
3. regenerate ``iOS/WallpaperMachineIOS.xcodeproj`` with XcodeGen;
4. build scheme ``WallpaperMachineIOS`` for a generic iOS device with signing
   disabled, and refuse to continue unless the product is an arm64 iOS Mach-O
   with a deployment target of at least iOS 18.

``package.py`` then writes the IPA/manifest and ``validate.py`` performs the
independent structural and framework-rule checks. Full logs go to the artifacts
directory; the terminal only shows stage failures and the verdict.

``--check`` runs static configuration checks without Xcode, so the spec and
scripts can be reviewed on a non-macOS machine. It never claims a build pass.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(SCRIPT_DIR))

from lib.glyphs import markers  # noqa: E402
import macho  # noqa: E402

MARK = markers()

IOS = ROOT / "iOS"
PROJECT_YML = IOS / "project.yml"
INFO_PLIST = IOS / "Resources/Info.plist"
XCODEPROJ = IOS / "WallpaperMachineIOS.xcodeproj"
DERIVED_DATA = ROOT / "build/ios/DerivedData"
RENDERER_DIR = IOS / "Generated/Renderer"
RENDERER_SCRIPT = ROOT / "scripts/ios/build_renderer.sh"
DEPLOYMENT_TARGET = "18.0"
DEPLOYMENT_TARGET_PARTS = (18, 0)
SDK_NAME = "iphoneos"
ARCH = "arm64"
RUST_TARGET = "aarch64-apple-ios"

BINDINGS = (
    "WallpaperSceneRenderer.h",
    "Platform/Apple/SceneWallpaperBindings.h",
    "Core/RendererCounters.h",
)


class BuildError(RuntimeError):
    pass


def rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def run_capture(args: list[str], env: dict[str, str], cwd: Path = ROOT) -> dict:
    try:
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, check=False)
    except OSError as error:
        return {"command": args, "returncode": None, "stdout": "", "stderr": str(error)}
    return {
        "command": args,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def require(command: dict, label: str) -> str:
    if command["returncode"] != 0:
        raise BuildError(
            f"{label} failed (exit {command['returncode']}): "
            f"{(command['stderr'] or command['stdout']).strip()[:400]}"
        )
    return command["stdout"].strip()


def run_logged(args: list[str], log_path: Path, env: dict[str, str], label: str, verbose: bool) -> None:
    print(f"{MARK.step} {label}: {' '.join(map(str, args))}", flush=True)
    start = time.monotonic()
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        log.write("$ " + " ".join(map(str, args)) + "\n\n")
        try:
            process = subprocess.Popen(
                args,
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
            )
        except OSError as error:
            raise BuildError(f"{label} could not start: {error}") from error
        assert process.stdout is not None
        for line in process.stdout:
            log.write(line)
            if verbose:
                print(line, end="", flush=True)
        returncode = process.wait()
    elapsed = time.monotonic() - start
    if returncode != 0:
        tail = "\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
        raise BuildError(
            f"{label} failed (exit {returncode}) after {elapsed:.1f}s; full log: {rel(log_path)}\n{tail}"
        )
    log_path.write_text(
        log_path.read_text(encoding="utf-8", errors="replace") + f"\n\n[exit 0 in {elapsed:.1f}s]\n",
        encoding="utf-8",
    )
    print(f"{MARK.ok} {label} ({elapsed:.1f}s)", flush=True)


def developer_dir(path: Path) -> Path | None:
    """Normalize an Xcode.app path, or a DEVELOPER_DIR, to .../Contents/Developer."""
    if (path / "usr/bin/xcodebuild").is_file():
        return path.resolve()
    if (path / "Contents/Developer/usr/bin/xcodebuild").is_file():
        return (path / "Contents/Developer").resolve()
    return None


def select_xcode() -> Path:
    override = os.environ.get("DEVELOPER_DIR")
    if override:
        normalized = developer_dir(Path(override))
        if normalized:
            return normalized
    candidates = []
    for path in Path("/Applications").glob("Xcode*.app"):
        if "beta" in path.name.lower() or "rc" in path.name.lower():
            continue
        version_match = re.search(r"Xcode_([0-9][0-9A-Za-z_.-]*)\.app$", path.name)
        if not version_match:
            continue
        numbers = tuple(int(part) for part in re.findall(r"\d+", version_match.group(1)))
        candidates.append((numbers, path))
    if candidates:
        candidates.sort(key=lambda item: item[0], reverse=True)
        normalized = developer_dir(candidates[0][1])
        if normalized:
            return normalized
    try:
        selected = subprocess.run(
            ["xcode-select", "-p"], capture_output=True, text=True, check=False
        ).stdout.strip()
    except OSError as error:
        raise BuildError(f"no Xcode found and xcode-select failed: {error}") from error
    if selected:
        normalized = developer_dir(Path(selected))
        if normalized:
            return normalized
    raise BuildError("no Xcode installation found in /Applications or via xcode-select")


def version_at_least(text: str, minimum: tuple[int, int]) -> bool:
    parts = tuple(int(part) for part in re.findall(r"\d+", text)[:3])
    return len(parts) >= 2 and parts[:2] >= minimum


def detect_toolchain(artifacts: Path) -> dict:
    xcode = select_xcode()
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = str(xcode)
    env.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")

    xcode_version = require(run_capture(["xcodebuild", "-version"], env), "xcodebuild -version")
    sdk_version = require(
        run_capture(["xcrun", "--sdk", SDK_NAME, "--show-sdk-version"], env),
        "iPhoneOS SDK detection",
    )
    sdk_path = require(
        run_capture(["xcrun", "--sdk", SDK_NAME, "--show-sdk-path"], env),
        "iPhoneOS SDK path detection",
    )
    if not version_at_least(sdk_version, DEPLOYMENT_TARGET_PARTS):
        raise BuildError(
            f"installed iPhoneOS SDK {sdk_version} is older than the iOS "
            f"{DEPLOYMENT_TARGET} deployment floor"
        )
    if not Path(sdk_path).is_dir():
        raise BuildError(f"the iPhoneOS SDK path does not exist: {sdk_path}")

    def tool(args: list[str]) -> dict:
        return run_capture(args, env)

    rustup_targets = tool(["rustup", "target", "list", "--installed"])
    stable_targets = tool(["rustup", "target", "list", "--installed", "--toolchain", "stable"])
    swift_version = tool(["swift", "--version"])
    toolchain = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "host": {
            "machine": platform.machine(),
            "platform": platform.platform(),
            "macos": tool(["sw_vers"]).get("stdout"),
        },
        "selected_xcode": str(xcode),
        "xcode": {"version": xcode_version, "build": None},
        "sdk": {"name": SDK_NAME, "version": sdk_version, "path": sdk_path},
        "swift": swift_version.get("stdout") or swift_version.get("stderr"),
        "rust": {
            "rustc": tool(["rustc", "--version"]).get("stdout"),
            "cargo": tool(["cargo", "--version"]).get("stdout"),
            "active_toolchain": tool(["rustup", "show", "active-toolchain"]).get("stdout"),
            "targets_active": rustup_targets.get("stdout"),
            "targets_stable": stable_targets.get("stdout"),
            "required_target": RUST_TARGET,
        },
        "cmake": tool(["cmake", "--version"]).get("stdout"),
        "ninja": tool(["ninja", "--version"]).get("stdout"),
        "xcodegen": tool(["xcodegen", "--version"]).get("stdout"),
        "pkg_config": tool(["pkg-config", "--version"]).get("stdout"),
        "python": sys.version.split()[0],
        "commands": {
            "xcodebuild": {"version": tool(["xcodebuild", "-version"])},
            "sdks": {"list": tool(["xcodebuild", "-showsdks"])},
        },
    }
    version_line = xcode_version.splitlines()
    if len(version_line) > 1 and "Build" in version_line[1]:
        toolchain["xcode"]["build"] = version_line[1].split("Build", 1)[1].strip()
    return toolchain


def verify_sources() -> int:
    sources = IOS / "Sources"
    swift_files = sorted(sources.rglob("*.swift")) if sources.is_dir() else []
    if not swift_files:
        raise BuildError(
            f"{rel(sources)} has no Swift sources; the iOS agents' app module is not present yet"
        )
    if not (IOS / "Resources/en.lproj").is_dir():
        print(f"{MARK.warn} iOS/Resources/en.lproj is missing; validate.py will reject the app", flush=True)
    if not (IOS / "Resources/zh-Hant.lproj").is_dir():
        print(f"{MARK.warn} iOS/Resources/zh-Hant.lproj is missing; validate.py will reject the app", flush=True)
    return len(swift_files)


def renderer_environment(toolchain: dict) -> dict:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = toolchain["selected_xcode"]
    sdk_path = toolchain["sdk"]["path"]
    env.update(
        {
            "CONFIGURATION": "Release",
            "IOS_SDK": SDK_NAME,
            "IOS_SDK_VERSION": toolchain["sdk"]["version"],
            "SDKROOT": sdk_path,
            "IOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "IPHONEOS_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "IOS_ARCH": ARCH,
            "RUST_TARGET": RUST_TARGET,
            "RENDERER_BUILD_DIR": str(RENDERER_DIR),
            "CMAKE_OSX_SYSROOT": sdk_path,
            "CMAKE_OSX_ARCHITECTURES": ARCH,
            "CMAKE_OSX_DEPLOYMENT_TARGET": DEPLOYMENT_TARGET,
            "CMAKE_BUILD_TYPE": "Release",
            "GIT_SHORT_COMMIT": (subprocess.run(
                ["git", "-C", str(ROOT), "rev-parse", "--short=8", "HEAD"],
                capture_output=True, text=True, check=False,
            ).stdout.strip() or "unknown"),
        }
    )
    for variable, tool in (("CC", "clang"), ("CXX", "clang++")):
        found = run_capture(["xcrun", "--sdk", SDK_NAME, "--find", tool], env)
        if found["returncode"] == 0 and found["stdout"]:
            env[variable] = found["stdout"].strip()
    return env


def build_renderer(toolchain: dict, artifacts: Path, skip: bool, verbose: bool) -> None:
    if skip:
        print(f"{MARK.warn} --skip-renderer: using existing renderer outputs in {rel(RENDERER_DIR)}", flush=True)
    else:
        if not RENDERER_SCRIPT.is_file():
            raise BuildError(
                f"{rel(RENDERER_SCRIPT)} is missing; the renderer agent owns it and must provide "
                "the iOS Rust/C++ build before CI can succeed"
            )
        if RENDERER_DIR.exists():
            if RENDERER_DIR.resolve() != (ROOT / "iOS/Generated/Renderer").resolve():
                raise BuildError("refusing to clean unexpected renderer path")
            shutil.rmtree(RENDERER_DIR)
        env = renderer_environment(toolchain)
        run_logged(
            ["bash", str(RENDERER_SCRIPT), "--sdk", "iphoneos", "--out", str(RENDERER_DIR)],
            artifacts / "renderer-build.log",
            env,
            "Build Rust wm-shader and C++ scene engine C ABI",
            verbose,
        )
    archive = RENDERER_DIR / "lib/libWallpaperSceneRenderer.a"
    missing = [rel(path) for path in (archive, *(RENDERER_DIR / "include" / name for name in BINDINGS)) if not path.is_file()]
    if missing:
        raise BuildError("renderer build did not produce: " + ", ".join(missing))
    renderer_manifest = RENDERER_DIR / "manifest.json"
    if not renderer_manifest.is_file():
        raise BuildError(f"{rel(renderer_manifest)} is missing; renderer must record its build")
    try:
        json.loads(renderer_manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise BuildError(f"renderer manifest is not JSON: {error}") from error
    if archive.stat().st_size < 1_000_000:
        raise BuildError(f"{rel(archive)} is only {archive.stat().st_size} bytes; not a real renderer archive")


def run_xcodegen(toolchain: dict, artifacts: Path, verbose: bool) -> None:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = toolchain["selected_xcode"]
    run_logged(
        ["xcodegen", "generate", "--spec", str(PROJECT_YML), "--project", str(IOS)],
        artifacts / "xcodegen.log",
        env,
        "Generate the Xcode project",
        verbose,
    )
    if not XCODEPROJ.is_dir():
        raise BuildError(f"XcodeGen produced no {rel(XCODEPROJ)}")


def xcodebuild_command(derived: Path) -> list[str]:
    return [
        "xcodebuild",
        "-project",
        str(XCODEPROJ),
        "-scheme",
        "WallpaperMachineIOS",
        "-configuration",
        "Release",
        "-sdk",
        SDK_NAME,
        "-destination",
        "generic/platform=iOS",
        "-derivedDataPath",
        str(derived),
        "build",
        "CODE_SIGNING_ALLOWED=NO",
        "CODE_SIGNING_REQUIRED=NO",
        "CODE_SIGN_IDENTITY=",
        "DEVELOPMENT_TEAM=",
        "ONLY_ACTIVE_ARCH=NO",
        f"ARCHS={ARCH}",
        f"IPHONEOS_DEPLOYMENT_TARGET={DEPLOYMENT_TARGET}",
    ]


def build_app(toolchain: dict, artifacts: Path, verbose: bool) -> Path:
    env = os.environ.copy()
    env["DEVELOPER_DIR"] = toolchain["selected_xcode"]
    if DERIVED_DATA.exists():
        shutil.rmtree(DERIVED_DATA)
    run_logged(
        xcodebuild_command(DERIVED_DATA),
        artifacts / "xcodebuild.log",
        env,
        "Build unsigned Release app for arm64 iOS",
        verbose,
    )
    settings = run_capture(
        ["xcodebuild", "-project", str(XCODEPROJ), "-scheme", "WallpaperMachineIOS",
         "-configuration", "Release", "-sdk", SDK_NAME, "-destination", "generic/platform=iOS",
         "-showBuildSettings", "-json"],
        env,
    )
    (artifacts / "xcodebuild-settings.json").write_text(
        json.dumps(settings, indent=2) + "\n", encoding="utf-8"
    )
    target_build_dir = None
    product_name = None
    if settings["returncode"] == 0 and settings["stdout"].startswith("["):
        try:
            entries = json.loads(settings["stdout"])
            values = entries[0].get("buildSettings", {}) if entries else {}
            target_build_dir = values.get("TARGET_BUILD_DIR")
            product_name = values.get("FULL_PRODUCT_NAME")
        except (json.JSONDecodeError, IndexError, TypeError):
            pass
    candidates = []
    if target_build_dir and product_name:
        candidates = [Path(target_build_dir) / product_name]
    else:
        candidates = sorted((DERIVED_DATA / "Build/Products").glob("Release-iphoneos/*.app"))
    apps = [path for path in candidates if path.is_dir()]
    if len(apps) != 1:
        raise BuildError(
            "expected one built .app under Release-iphoneos, found "
            + (", ".join(rel(path) for path in apps) or "none")
        )
    app = apps[0].resolve()
    executable = app / (plistlib.loads((app / "Info.plist").read_bytes()).get("CFBundleExecutable") or "")
    if not executable.is_file():
        raise BuildError(f"{rel(executable)} is missing from the built app")
    try:
        slices = macho.parse_macho(executable)
    except macho.MachOError as error:
        raise BuildError(f"built executable is not a valid Mach-O: {error}") from error
    device = [slice for slice in slices if slice.arch == "arm64" and slice.platform == 2]
    if len(slices) != 1 or len(device) != 1:
        raise BuildError(
            "build produced "
            + ", ".join(f"{slice.arch}/{slice.platform_name}" for slice in slices)
            + "; expected one arm64 iOS device slice"
        )
    if not version_at_least(device[0].minos or "", DEPLOYMENT_TARGET_PARTS):
        raise BuildError(f"built executable minimum OS is {device[0].minos}, below {DEPLOYMENT_TARGET}")
    print(
        f"{MARK.ok} Built {rel(app)} ({device[0].arch}, {device[0].platform_name}, iOS {device[0].minos})",
        flush=True,
    )
    (artifacts / "app-path.txt").write_text(str(app) + "\n", encoding="utf-8")
    return app


def static_check() -> int:
    """Check the configuration this task owns without Xcode; never a build pass."""
    problems: list[str] = []
    required = [
        PROJECT_YML,
        INFO_PLIST,
        ROOT / ".github/workflows/ios-build.yml",
        ROOT / "scripts/ios/build.py",
        ROOT / "scripts/ios/package.py",
        ROOT / "scripts/ios/validate.py",
        ROOT / "scripts/ios/ci_setup.sh",
        RENDERER_SCRIPT,
    ]
    for path in required:
        if not path.exists():
            problems.append(f"missing {rel(path)}")
    try:
        info = plistlib.loads(INFO_PLIST.read_bytes())
    except Exception as error:
        problems.append(f"Info.plist does not parse: {error}")
        info = {}
    if info.get("CFBundleIdentifier") != "$(PRODUCT_BUNDLE_IDENTIFIER)":
        problems.append("Info.plist does not use the target's bundle identifier")
    if "en" not in (info.get("CFBundleLocalizations") or []) or "zh-Hant" not in (
        info.get("CFBundleLocalizations") or []
    ):
        problems.append("Info.plist does not declare en and zh-Hant localizations")
    try:
        import yaml  # noqa: F401  (optional; only used by --check)
    except ImportError:
        print(f"{MARK.warn} PyYAML is not installed; project.yml was not parsed", flush=True)
    else:
        spec = yaml.safe_load(PROJECT_YML.read_text(encoding="utf-8"))
        target = (spec.get("targets") or {}).get("WallpaperMachineIOS") or {}
        if target.get("platform") != "iOS" or target.get("type") != "application":
            problems.append("project.yml's WallpaperMachineIOS target is not an iOS application")
        settings = ((target.get("settings") or {}).get("base")) or {}
        if settings.get("PRODUCT_BUNDLE_IDENTIFIER") != "com.rayray1099.wallpapermachine.ios":
            problems.append("project.yml bundle identifier is not com.rayray1099.wallpapermachine.ios")
        if (spec.get("settings", {}).get("base", {}).get("SWIFT_VERSION") != "5.0"):
            problems.append("project.yml is not in Swift 5 language mode")
        if (spec.get("settings", {}).get("base", {}).get("IPHONEOS_DEPLOYMENT_TARGET") != DEPLOYMENT_TARGET):
            problems.append("project.yml deployment target is not iOS 18.0")
    workflow = (ROOT / ".github/workflows/ios-build.yml").read_text(encoding="utf-8") if (
        ROOT / ".github/workflows/ios-build.yml"
    ).is_file() else ""
    for required_text in ("macos-", "iphoneos", "build_renderer.sh", "validate.py", "package.py"):
        if required_text not in workflow:
            problems.append(f"ios-build.yml does not mention {required_text}")
    if "contents: write" in workflow or "softprops/action-gh-release" in workflow:
        problems.append("ios-build.yml can write repository contents; it must not publish releases")
    compile_result = subprocess.run(
        [sys.executable, "-m", "py_compile", *[str(ROOT / "scripts/ios" / name) for name in
         ("build.py", "package.py", "validate.py", "macho.py")]],
        capture_output=True, text=True, check=False,
    )
    if compile_result.returncode != 0:
        problems.append("scripts/ios Python does not compile: " + compile_result.stderr.strip()[:400])
    if RENDERER_SCRIPT.is_file() and not os.access(RENDERER_SCRIPT, os.X_OK):
        problems.append("scripts/ios/build_renderer.sh exists but is not executable")
    for problem in problems:
        print(f"{MARK.missing} {problem}")
    if problems:
        print(f"{MARK.missing} static configuration check failed ({len(problems)} problem(s)); "
              "this is not a build", flush=True)
        return 1
    print(
        f"{MARK.ok} static configuration check passed; this did NOT compile or validate an IPA",
        flush=True,
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--configuration", default="Release", choices=["Release"])
    parser.add_argument("--artifacts-dir", type=Path, help="Evidence directory (default: artifacts/ios/<stamp>).")
    parser.add_argument("--skip-renderer", action="store_true", help="Reuse existing renderer outputs (local only).")
    parser.add_argument("--check", action="store_true", help="Static configuration check only; no build.")
    parser.add_argument("--verbose", action="store_true", help="Echo every tool line.")
    args = parser.parse_args()

    if args.check:
        return static_check()
    if sys.platform != "darwin":
        raise SystemExit(
            "the iOS app can only be built on macOS with Xcode; run this on the GitHub "
            "macOS runner (or a Mac). Device ARM64 is cross-compiled; `--check` works anywhere."
        )
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    artifacts = (args.artifacts_dir or ROOT / f"artifacts/ios/{stamp}").resolve()
    if not artifacts.is_relative_to(ROOT):
        raise SystemExit(f"--artifacts-dir must be inside the repository: {artifacts}")
    artifacts.mkdir(parents=True, exist_ok=True)

    try:
        toolchain = detect_toolchain(artifacts)
        (artifacts / "toolchain.json").write_text(
            json.dumps(toolchain, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(
            f"{MARK.ok} Xcode {toolchain['xcode']['version'].splitlines()[0]} "
            f"with iPhoneOS SDK {toolchain['sdk']['version']}",
            flush=True,
        )
        swift_count = verify_sources()
        print(f"{MARK.ok} iOS/Sources has {swift_count} Swift file(s)", flush=True)
        build_renderer(toolchain, artifacts, args.skip_renderer, args.verbose)
        run_xcodegen(toolchain, artifacts, args.verbose)
        app = build_app(toolchain, artifacts, args.verbose)
    except BuildError as error:
        print(f"{MARK.missing} build failed: {error}", flush=True)
        return 1

    summary = {
        "source_commit": subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip(),
        "configuration": "Release",
        "sdk": toolchain["sdk"],
        "xcode": toolchain["xcode"],
        "app": rel(app),
        "renderer_archive": rel(RENDERER_DIR / "lib/libWallpaperSceneRenderer.a"),
        "bindings": [rel(RENDERER_DIR / "include" / name) for name in BINDINGS],
        "swift_sources": swift_count,
        "finished_at": datetime.now(timezone.utc).isoformat(),
    }
    (artifacts / "build-summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"{MARK.ok} App ready for packaging: {rel(app)}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
