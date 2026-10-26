#!/usr/bin/env bash
# Native macOS/arm64 scene startup regressions, not an iOS app or device test.
# Builds six selected engine binaries only. No windows, device RPC, sound output,
# application launch, simulator, screen capture or installed wallpaper assets.
# GPU cases explicitly skip only when their own Metal availability check says so;
# the real asynchronous SceneWallpaper loader cases must execute on every host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
exec python3 - "$ROOT" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess
import sys
import time

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(description="Build and execute native macOS scene startup tests (no app/device).")
parser.add_argument("--artifacts-dir", type=Path, default=root / "artifacts/ios-scene-startup")
parser.add_argument("--dry-run", action="store_true", help="Print command plan without running tools or writing files.")
args = parser.parse_args(sys.argv[2:])
out = args.artifacts_dir.resolve()
build = out / "engine"
fixture = out / "fixture"
binaries = ["scene_failure_policy_test", "tex_container_tests", "scene_harness_selftest", "ios_scene_startup_render_test",
            "scene_frame_export_contract_test", "metal_scene_draw_smoke"]
runs = [
    ("loader-cpu", binaries[0], "SceneLoadFailurePolicy.*", False),
    ("containers-cpu", binaries[1], "*", False),
    ("failure-recovery-gpu", binaries[0], "SceneFailurePolicy.*", True),
    ("synthetic-render-gpu", binaries[2], "SceneHarness.*", True),
    ("packed-fixture-gpu", binaries[3], "*", True),
    ("manual-export-gpu", binaries[5], "MetalSceneDraw.ManualExportUsesFixedSimulationTimeDespiteSlowConsumer", True),
]
shader = root / "Renderer/target/release/libwm_shader.a"
commands = [
    ("shader-build", ["cargo", "build", "--locked", "-p", "wm-shader", "--features", "ffi", "--release"], root / "Renderer", 1200),
    ("configure", ["cmake", "-S", str(root / "Renderer/Engine"), "-B", str(build), "-G", "Ninja",
                   "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                   "-DBUILD_TESTS=ON", "-DRUST_SHADER_FFI=ON", "-DRUST_SHADER_STATICLIB=" + str(shader),
                   "-DCMAKE_C_COMPILER_LAUNCHER=ccache", "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"], root, 300),
    ("build", ["cmake", "--build", str(build), "--target", *binaries, "--parallel", "3"], root, 1200),
    ("fixture", ["python3", str(root / "scripts/ios/make_native_scene_fixture.py"), "--output", str(fixture)], root, 60),
]
if args.dry_run:
    print("macOS arm64 only; host libraries: brew install cmake ninja pkg-config ccache quickjs-ng freetype lz4 nlohmann-json argparse")
    print("Use the Renderer workspace nightly toolchain; do not reuse any iOS dependency archives.")
    for name, command, cwd, timeout in commands:
        print(f"{name} (cwd={cwd}; timeout={timeout}s): {shlex.join(command)}")
    for name, binary, pattern, gpu in runs:
        print(f"{name} ({'explicit no-Metal skip allowed' if gpu else 'must pass, no skips'}): " + shlex.join([
            str(build / "tests" / binary), "--gtest_filter=" + pattern, "--gtest_output=json:" + str(out / (name + ".json"))]))
    print("manual-export-cpu (release assertions remain active): " + str(build / "tests" / binaries[4]))
    print("WM_NATIVE_SCENE_FIXTURE=" + str(fixture / "WM-QA-Native-Quadrants"))
    raise SystemExit(0)
if platform.system() != "Darwin" or platform.machine() != "arm64":
    parser.error("actual tests require a native macOS arm64 runner; --dry-run is portable")

out.mkdir(parents=True, exist_ok=True)
report = {"schema": 1, "host": {"system": platform.system(), "arch": platform.machine()},
          "scope": "macOS native engine CPU loader and private GPU rendering, not physical iPad presentation",
          "device_tested": False, "desktop_automation": False, "audio_output": False,
          "build_steps": [], "test_runs": [], "verdict": "failed"}
started = time.monotonic()
env = os.environ.copy()
# Match scripts/build.py's native engine environment. None of the iOS prefixes,
# SDKROOT or deployment-target values may leak into the host build.
for key in ("CMAKE_PREFIX_PATH", "CMAKE_FRAMEWORK_PATH", "CMAKE_INCLUDE_PATH", "CMAKE_LIBRARY_PATH",
            "PKG_CONFIG_PATH", "PKG_CONFIG_LIBDIR", "SDKROOT", "IPHONEOS_DEPLOYMENT_TARGET",
            "CARGO_BUILD_TARGET", "CARGO_TARGET_DIR", "RUSTUP_TOOLCHAIN", "WE_TEST_SIMULATE_NO_METAL"):
    env.pop(key, None)

def capture(command):
    return subprocess.check_output(command, cwd=root, env=env, text=True, timeout=30).strip()

def run_logged(name, command, cwd, timeout, command_env):
    log = out / (name + ".log")
    print(f"{name}: {shlex.join(command)}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        stream.write("$ " + shlex.join(command) + "\n")
        stream.flush()
        try:
            completed = subprocess.run(command, cwd=cwd, env=command_env, stdout=stream,
                                       stderr=subprocess.STDOUT, timeout=timeout, check=False)
            code = completed.returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    return {"name": name, "exit": code, "log": log.name}

def inspect_contract(path):
    # A zero exit plus an old/truncated/generic PASS is not current coverage.
    expected = "Scene frame export contract: 18000 sequential frames, admission/cancel/exactly-once PASS"
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    # run_logged prefixes the exact command as one shell-style line.
    if lines and lines[0].startswith("$ "):
        lines = lines[1:]
    if lines != [expected]:
        raise ValueError("manual frame-export contract did not emit exactly its current completion verdict")
    return {"gpu_required": False, "tests": 1, "passed": 1, "skipped": 0,
            "cases": [{"name": "SceneFrameExport.Contract", "status": "passed", "reason": "explicit release checks"}],
            "status": "passed"}


def inspect_tests(path, gpu, expected_names=None):
    data = json.loads(path.read_text(encoding="utf-8"))
    cases = []
    for suite in data.get("testsuites", []):
        for test in suite.get("testsuite", []):
            skip = test.get("result") == "SKIPPED" or test.get("status") == "NOTRUN" or bool(test.get("skipped"))
            failures = test.get("failures", [])
            if not skip and (test.get("status") != "RUN" or test.get("result") != "COMPLETED"):
                raise ValueError("test has no completed execution: " + suite["name"] + "." + test["name"])
            reason = " ".join(str(item.get("message", "")) for item in test.get("skipped", []))
            cases.append({"name": suite["name"] + "." + test["name"],
                          "status": "failed" if failures else "skipped" if skip else "passed", "reason": reason})
    if not cases:
        raise ValueError("test filter matched no tests; this is not passing coverage")
    names = [case["name"] for case in cases]
    if len(names) != len(set(names)):
        raise ValueError("GTest report contains duplicate test identities")
    if expected_names is not None and set(names) != set(expected_names):
        raise ValueError("GTest report does not contain exactly the required test identities")
    if any(case["status"] == "failed" for case in cases):
        raise ValueError("GTest report contains failed tests")
    for case in cases:
        if case["status"] == "skipped" and (not gpu or "no Metal device" not in case["reason"]):
            raise ValueError("unexpected skip: " + case["name"] + ": " + case["reason"])
    return {"tests": len(cases), "passed": sum(c["status"] == "passed" for c in cases),
            "skipped": sum(c["status"] == "skipped" for c in cases), "cases": cases}

try:
    prefix = Path(capture(["brew", "--prefix"]))
    packages = ["quickjs-ng", "freetype", "lz4", "nlohmann-json", "argparse"]
    prefixes = [prefix / "opt" / package for package in packages]
    env["PATH"] = str(prefix / "bin") + os.pathsep + env.get("PATH", "")
    env["CMAKE_PREFIX_PATH"] = ";".join(map(str, [*prefixes, prefix]))
    env["PKG_CONFIG_PATH"] = ":".join(str(p / "lib/pkgconfig") for p in prefixes)
    env["SDKROOT"] = capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"])
    # Resolve compiler binaries from the same selected Xcode as SDKROOT. A
    # machine-wide default (Xcode 16.4 on macos-15) lacks C++20 std::jthread.
    env["CC"] = capture(["xcrun", "--sdk", "macosx", "--find", "clang"])
    env["CXX"] = capture(["xcrun", "--sdk", "macosx", "--find", "clang++"])
    env["OBJCXX"] = env["CXX"]
    report["xcode"] = capture(["xcodebuild", "-version"])
    report["developer_dir"] = env.get("DEVELOPER_DIR", "xcode-select default")
    report["sdkroot"] = env["SDKROOT"]
    report["cxx"] = env["CXX"]
    env["WM_NATIVE_SCENE_FIXTURE"] = str(fixture / "WM-QA-Native-Quadrants")
    if fixture.exists():
        raise RuntimeError("fixture output already exists; select a fresh --artifacts-dir (nothing is deleted)")
    report["commit"] = capture(["git", "rev-parse", "HEAD"])
    report["toolchain"] = subprocess.check_output(["rustc", "--version"], cwd=root / "Renderer", env=env, text=True, timeout=120).strip()
    # Compile only: reject an incompatible selected SDK before the engine build.
    # No probe program is linked or run, and no GPU/audio/device API is touched.
    smoke = out / "cxx20-jthread.cpp"
    smoke.write_text("#include <thread>\n#include <stop_token>\nvoid check() { std::jthread worker([](std::stop_token) {}); worker.request_stop(); }\n", encoding="utf-8")
    step = run_logged("cxx20-jthread", [env["CXX"], "-std=c++20", "-arch", "arm64", "-isysroot", env["SDKROOT"],
                      "-mmacosx-version-min=15.0", "-fsyntax-only", str(smoke)], root, 60, env)
    report["build_steps"].append(step)
    if step["exit"] != 0:
        raise RuntimeError("selected Xcode does not provide required C++20 jthread/stop_token; see " + str(out / step["log"]))
    for name, command, cwd, timeout in commands:
        step_env = env.copy()
        # Proc-macro dylibs must use the Rust compiler's own deployment default;
        # pin only the C++ engine, as scripts/build.py's cargo_environment does.
        if name == "shader-build":
            step_env.pop("MACOSX_DEPLOYMENT_TARGET", None)
        step = run_logged(name, command, cwd, timeout, step_env)
        report["build_steps"].append(step)
        if step["exit"] != 0:
            raise RuntimeError(f"{name} failed ({step['exit']}); see {out / step['log']}")
    contract = run_logged("manual-export-cpu", [str(build / "tests" / binaries[4])], root, 60, env)
    report["test_runs"].append(contract)
    if contract["exit"] != 0:
        raise RuntimeError("manual frame-export contract failed; see " + str(out / contract["log"]))
    # The release binary uses explicit checks, not NDEBUG-disabled assert calls.
    contract.update(inspect_contract(out / contract["log"]))
    for name, binary, pattern, gpu in runs:
        json_path = out / (name + ".json")
        # A stale GTest JSON must never turn an invocation failure into a pass.
        before = json_path.stat().st_mtime_ns if json_path.exists() else None
        command = [str(build / "tests" / binary), "--gtest_filter=" + pattern, "--gtest_output=json:" + str(json_path)]
        result = run_logged(name, command, root, 300, env)
        result["gpu_required"] = gpu
        report["test_runs"].append(result)
        if result["exit"] != 0:
            raise RuntimeError(f"{name} failed ({result['exit']}); see {out / result['log']}")
        if not json_path.exists() or json_path.stat().st_mtime_ns == before:
            raise RuntimeError(name + " did not write a fresh GTest JSON report")
        expected = {pattern} if name == "manual-export-gpu" else None
        result.update(inspect_tests(json_path, gpu, expected_names=expected))
        result["status"] = "skipped-no-metal" if result["skipped"] == result["tests"] else "passed"
        print(f"{name}: {result['passed']} passed, {result['skipped']} skipped", flush=True)
    gpu_runs = [r for r in report["test_runs"] if r["gpu_required"]]
    report["gpu_tests_passed"] = sum(r["passed"] for r in gpu_runs)
    report["gpu_tests_skipped"] = sum(r["skipped"] for r in gpu_runs)
    report["cpu_tests_passed"] = sum(r["passed"] for r in report["test_runs"] if not r["gpu_required"])
    report["verdict"] = "cpu-passed-gpu-skipped" if report["gpu_tests_skipped"] else "cpu-and-macos-gpu-passed"
except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
    report["error"] = str(error)
    print("ERROR: " + str(error), file=sys.stderr)
finally:
    report["elapsed_seconds"] = round(time.monotonic() - started, 2)
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    summary = ["## Native macOS scene startup regression", "",
               "- Verdict: `" + report["verdict"] + "`",
               "- CPU loader executes the real asynchronous SceneWallpaper handlers; no GPU prerequisite.",
               "- GPU tests use private process-owned images/layers only; no window or audio output."]
    for result in report["test_runs"]:
        summary.append(f"- {result['name']}: {result.get('passed', 0)} passed, {result.get('skipped', 0)} skipped (exit {result['exit']})")
        for case in result.get("cases", []):
            if case["status"] == "skipped":
                summary.append("  - SKIP `" + case["name"] + "`: " + case["reason"].replace("\n", " "))
    if "error" in report:
        summary.append("- Error: " + report["error"])
    summary += ["", "A skipped GPU test is not a rendered frame. Physical iPad/Metal drawable presentation is NOT verified.", ""]
    text = "\n".join(summary)
    (out / "summary.md").write_text(text, encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(text)
    print(text)
raise SystemExit(1 if report["verdict"] == "failed" else 0)
PY
