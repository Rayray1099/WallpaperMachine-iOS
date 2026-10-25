#!/usr/bin/env python3
"""Run isolated UIKit scene-host XCTest on a newly created, headless iPad simulator."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shlex
import signal
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.glyphs import markers
from lib.paths import ARTIFACTS, ROOT
from lib.xcode import interesting, summarize

SPEC = ROOT / "iOS/Tests/SceneHost/project.yml"
SCHEME = "WMSceneHostHarness"
TEST_TARGET = "WMSceneHostLifecycleTests"
TEST_CLASS = "SceneHostLifecycleTests"
# Required behavioral cases, not a count that unrelated or stale cases can satisfy.
EXPECTED_TEST_METHODS = frozenset({
    "testPositiveBoundsWithoutWindowDoNotAllocateAnEngine",
    "testAttachmentUsesPhysicalPixelsAndSetsQualityBeforeConfig",
    "testSameURLSettingsAndQualityReuseTheEngineAndDrawable",
    "testNewURLDeletesOldEngineOnceAndResetsQualityAndReadiness",
    "testFailedURLDoesNotRetryButAnotherURLRecovers",
    "testShutdownBeforeFirstLayoutPreventsQueuedInitialization",
    "testZeroSizeDefersQualityUntilPositiveLayoutWithoutRebuildingSurface",
    "testStartupDeadlineAccumulatesTenActiveSecondsThenFiveAfterHoursPaused",
    "testCompletedFramesDoNotHideStatusUntilAFrameIsPresented",
    "testBackendReasonWinsOverOldPresentedFramesAndDeadline",
    "testFinishFailureAfterAnOldFrameIsTerminalAndNeverUsesDeletedHandle",
    "testSuccessfulAllocationReturningNullShowsFailureWithoutInitializingEngine",
    "testInitialAPIFailureStopsBeforeMetalAndConfigurationAndCleansUpOnce",
    "testReconfigurationReleasesOldLayerSizeBeforePublishingNewSize",
    "testEqualBoundsDisplayScaleChangeReconfiguresPhysicalPixelsOnSameEngine",
    "testDetachedEnginePausesAndDefersSettingsUntilReattachment",
})
MINIMUM_TESTS = len(EXPECTED_TEST_METHODS)
OWNER_PREFIX = "WMSceneHostHarness-"
MARK = markers()


def version(text):
    """Parse Apple's numeric SDK/runtime versions without accepting prerelease text."""
    if not isinstance(text, str) or not re.fullmatch(r"\d+(?:\.\d+){0,3}", text):
        raise ValueError(f"invalid numeric Apple version: {text!r}")
    return tuple(int(part) for part in text.split(".")) + (0,) * (4 - len(text.split(".")))


def select_simulator(inventory, sdk_version):
    """Choose the newest available iOS 18+ runtime and a compatible iPad type."""
    sdk = version(sdk_version)
    if sdk < version("18.0"):
        raise ValueError("selected iPhoneSimulator SDK is older than iOS 18")
    runtimes = []
    for runtime in inventory.get("runtimes", []):
        if (runtime.get("isAvailable") is True
                and str(runtime.get("identifier", "")).startswith("com.apple.CoreSimulator.SimRuntime.iOS-")):
            number = version(runtime.get("version"))
            if version("18.0") <= number <= sdk:
                runtimes.append((number, runtime))
    for number, runtime in sorted(runtimes, key=lambda item: item[0], reverse=True):
        supported = {item["identifier"] for item in runtime.get("supportedDeviceTypes", [])
                     if isinstance(item, dict) and isinstance(item.get("identifier"), str)}
        candidates = []
        for device in inventory.get("devicetypes", []):
            identifier = device.get("identifier", "")
            if not identifier.startswith("com.apple.CoreSimulator.SimDeviceType.iPad"):
                continue
            if supported and identifier not in supported:
                continue
            lower = version(device.get("minRuntimeVersionString", "0"))
            upper = version(device.get("maxRuntimeVersionString", "65535"))
            if lower <= number <= upper:
                candidates.append((lower, device.get("name", ""), device))
        if candidates:
            return runtime, max(candidates, key=lambda item: item[:2])[2]
    raise ValueError("no available iOS 18+ simulator runtime with a compatible iPad device type; nothing is downloaded")


def device_rows(inventory):
    devices = inventory.get("devices")
    if not isinstance(devices, dict):
        raise ValueError("simctl inventory has no devices object")
    return [(runtime, row) for runtime, rows in devices.items() for row in rows]


def canonical_udid(text):
    value = str(uuid.UUID(text.strip())).upper()
    if text.strip().upper() != value:
        raise ValueError("simctl did not return one canonical simulator UUID")
    return value


def owned_device(state, create_stdout, inventory):
    """Prove ownership from create output, initial inventory and exact new identity."""
    token = state.get("token", "")
    if not re.fullmatch(r"[0-9a-f]{32}", token) or state.get("name") != OWNER_PREFIX + token:
        raise ValueError("invalid simulator ownership token/name; refusing cleanup")
    identifier = canonical_udid(create_stdout)
    if state.get("udid") not in (None, identifier):
        raise ValueError("created UUID differs from ownership manifest; refusing cleanup")
    initial = state.get("initial_udids")
    if not isinstance(initial, list) or any(not isinstance(item, str) for item in initial):
        raise ValueError("missing initial simulator inventory proof; refusing cleanup")
    if identifier in (item.upper() for item in initial):
        raise ValueError("created UUID existed before this run; refusing cleanup")
    matches = [(runtime, row) for runtime, row in device_rows(inventory)
               if str(row.get("udid", "")).upper() == identifier]
    if not matches:
        return identifier, None
    if len(matches) != 1:
        raise ValueError("ambiguous created UUID; refusing cleanup")
    runtime, row = matches[0]
    if (row.get("name") != state.get("name") or runtime != state.get("runtime")
            or row.get("deviceTypeIdentifier") != state.get("device_type")):
        raise ValueError("created simulator identity no longer matches this run; refusing cleanup")
    return identifier, row


def case_method(name, identifier):
    """Require agreeing XCTest leaf names and recognized, fully qualified identities."""
    if not isinstance(name, str) or not isinstance(identifier, str):
        raise ValueError("test case is missing a string name or nodeIdentifier")
    leaf = re.fullmatch(r"(test[A-Za-z0-9_]+)(?:\(\))?", name)
    identity = re.fullmatch(
        r"(?:" + TEST_TARGET + r"[/.])?" + TEST_CLASS + r"[/.](test[A-Za-z0-9_]+)(?:\(\))?",
        identifier,
    )
    if leaf is None or identity is None or leaf.group(1) != identity.group(1):
        raise ValueError("unexpected or inconsistent scene-host test identity: " + repr((name, identifier)))
    return leaf.group(1)


def inspect_results(summary, test_tree):
    """Require the exact behavioral case set, zero skips/failures and agreeing counts."""
    counts = {}
    for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount"):
        value = summary.get(key)
        if type(value) is not int or value < 0:
            raise ValueError(f"xcresult summary is missing a nonnegative integer {key}")
        counts[key] = value
    expected = summary.get("expectedFailures", 0)
    if type(expected) is not int or expected != 0:
        raise ValueError("expected failures are not passing coverage")
    if summary.get("result") != "Passed" or summary.get("testFailures"):
        raise ValueError("xcresult reports test failure or a suite that could not run")
    if counts["failedTests"] or counts["skippedTests"]:
        raise ValueError("scene-host tests failed or skipped; no passing verdict")
    if counts["totalTestCount"] != MINIMUM_TESTS or counts["passedTests"] != counts["totalTestCount"]:
        raise ValueError(f"need exactly {MINIMUM_TESTS} executed, passing required scene-host tests")
    nodes = test_tree.get("testNodes")
    if not isinstance(nodes, list):
        raise ValueError("unknown xcresult test-tree format: missing testNodes")
    cases = []
    methods = []

    def visit(node):
        if not isinstance(node, dict):
            raise ValueError("unknown xcresult test node")
        if node.get("nodeType") == "Test Case":
            name = node.get("name")
            identifier = node.get("nodeIdentifier")
            methods.append(case_method(name, identifier))
            if node.get("result") != "Passed":
                raise ValueError("test case did not pass: " + name)
            if node.get("children"):
                raise ValueError("unexpected nested test-case results")
            cases.append(identifier)
            return
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("unknown xcresult children format")
        for child in children:
            visit(child)

    for node in nodes:
        visit(node)
    if len(cases) != counts["totalTestCount"] or len(set(methods)) != len(methods):
        raise ValueError("actual scene-host test-case identities do not match summary counts")
    missing = EXPECTED_TEST_METHODS - set(methods)
    unexpected = set(methods) - EXPECTED_TEST_METHODS
    if missing or unexpected:
        raise ValueError("required scene-host case set differs: missing=" + repr(sorted(missing))
                         + "; unexpected=" + repr(sorted(unexpected)))
    return {"total": counts["totalTestCount"], "passed": counts["passedTests"],
            "failed": counts["failedTests"], "skipped": counts["skippedTests"], "cases": cases}


def xcodebuild_command(project, udid, out):
    return ["xcodebuild", "test", "-project", str(project), "-scheme", SCHEME,
            "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + udid,
            "-destination-timeout", "180", "-parallel-testing-enabled", "NO",
            "-maximum-concurrent-test-simulator-destinations", "1", "-disable-concurrent-destination-testing",
            "-only-testing:" + TEST_TARGET + "/" + TEST_CLASS,
            "-derivedDataPath", str(out / "DerivedData"), "-resultBundlePath", str(out / "SceneHost.xcresult"),
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]


class Runner:
    def __init__(self, out, env, timeout_seconds=1200):
        self.out = out
        self.env = env
        self.deadline = time.monotonic() + timeout_seconds
        self.steps = []

    def run(self, name, command, timeout=60, check=True, cleanup=False):
        remaining = timeout if cleanup else min(timeout, self.deadline - time.monotonic())
        if remaining <= 0:
            raise TimeoutError("20-minute scene-host execution deadline reached")
        stdout_path = self.out / (name + ".stdout.log")
        stderr_path = self.out / (name + ".stderr.log")
        step = {"name": name, "command": list(map(str, command)), "exit": None}
        self.steps.append(step)
        started = time.monotonic()
        print(f"{MARK.step} {name}", flush=True)
        with stdout_path.open("w", encoding="utf-8") as stdout, stderr_path.open("w", encoding="utf-8") as stderr:
            process = subprocess.Popen(command, cwd=ROOT, env=self.env, stdout=stdout, stderr=stderr,
                                       text=True, start_new_session=True)
            try:
                step["exit"] = process.wait(timeout=remaining)
            except BaseException:
                # xcodebuild can have compiler/test children. Stop only our process group.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                except ProcessLookupError:
                    process.wait()
                step["exit"] = process.returncode
                raise
            finally:
                step["elapsed_seconds"] = round(time.monotonic() - started, 2)
        output = stdout_path.read_text(encoding="utf-8", errors="replace")
        errors = stderr_path.read_text(encoding="utf-8", errors="replace")
        if step["exit"] != 0 and check:
            detail = "\n".join((output + "\n" + errors).splitlines()[-30:])
            raise RuntimeError(f"{name} failed (exit {step['exit']}):\n{detail}")
        return output.strip(), step["exit"]

    def inventory(self, name, cleanup=False):
        text, _ = self.run(name, ["xcrun", "simctl", "list", "--json"], cleanup=cleanup)
        return json.loads(text)


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def cleanup_owned(runner, out):
    state_path = out / "simulator-owner.json"
    if not state_path.is_file():
        return {"status": "not-created", "remaining_owned_devices": 0}
    state = json.loads(state_path.read_text(encoding="utf-8"))
    create_path = out / "simulator-create.stdout.log"
    if not create_path.is_file() or not create_path.read_text(encoding="utf-8").strip():
        # A cancelled create must not silently leave a uniquely named pending device.
        inventory = runner.inventory("cleanup-pending-inventory", cleanup=True)
        if any(row.get("name") == state.get("name") for _, row in device_rows(inventory)):
            raise RuntimeError("simulator creation has no returned UUID but an owned-name device exists; refusing unproven cleanup")
        return {"status": "create-not-completed", "remaining_owned_devices": 0}
    identifier, row = owned_device(state, create_path.read_text(encoding="utf-8"),
                                   runner.inventory("cleanup-inventory", cleanup=True))
    if row is not None:
        if row.get("state") != "Shutdown":
            runner.run("simulator-shutdown", ["xcrun", "simctl", "shutdown", identifier], check=False, cleanup=True)
        runner.run("simulator-delete", ["xcrun", "simctl", "delete", identifier], cleanup=True)
    after = runner.inventory("cleanup-verify", cleanup=True)
    remaining = sum(str(item.get("udid", "")).upper() == identifier for _, item in device_rows(after))
    if remaining:
        raise RuntimeError("created simulator still exists after cleanup")
    return {"status": "deleted" if row else "already-absent", "udid": identifier, "remaining_owned_devices": remaining}


def selected_xcode(runner):
    current, _ = runner.run("xcode-select-current", ["xcode-select", "-p"])
    candidates = []
    for app in Path("/Applications").glob("Xcode*.app"):
        match = re.fullmatch(r"Xcode_(\d+(?:\.\d+)*)\.app", app.name)
        if match and (app / "Contents/Developer/usr/bin/xcodebuild").is_file():
            candidates.append((version(match.group(1)), app / "Contents/Developer"))
    if candidates:
        chosen = max(candidates, key=lambda item: item[0])[1]
    else:
        chosen = Path(current)
        if not (chosen / "usr/bin/xcodebuild").is_file() or re.search(r"beta|rc", str(chosen), re.IGNORECASE):
            raise RuntimeError("no installed stable Xcode available")
    runner.env["DEVELOPER_DIR"] = str(chosen)
    text, _ = runner.run("xcode-version", ["xcodebuild", "-version"])
    if re.search(r"beta|release candidate", text, re.IGNORECASE):
        raise RuntimeError("selected Xcode is not stable")
    return {"original_xcode_select": current, "selected_developer_dir": str(chosen), "version": text,
            "selection_changes_system_default": False}


def write_report(out, report):
    save_json(out / "report.json", report)
    counts = report.get("tests", {})
    text = "\n".join([
        "## Isolated iOS UIKit scene-host tests", "",
        f"- Verdict: `{report['verdict']}`",
        f"- Actual XCTest: {counts.get('passed', 0)} passed, {counts.get('failed', 0)} failed, {counts.get('skipped', 0)} skipped of {counts.get('total', 0)}.",
        "- Coverage: actual SceneWallpaperView.swift and UIKit layout/lifecycle; native C ABI is a test-only recorder.",
        "- No real Metal renderer, frames, physical iPad, user desktop, UI automation or audio hardware tested.",
        f"- Created simulator cleanup: `{report.get('cleanup', {}).get('status', 'not-reached')}`; remaining owned devices: {report.get('cleanup', {}).get('remaining_owned_devices', 'unknown')}.",
        *( ["- Error: " + report["error"]] if report.get("error") else []), "",
    ])
    (out / "summary.md").write_text(text, encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
            stream.write(text)
    print(text)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="Print the plan without tools, simulator access or file writes.")
    parser.add_argument("--cleanup-only", action="store_true", help="Retry cleanup using this run's verified ownership evidence only.")
    args = parser.parse_args(argv)
    out = (args.artifacts_dir or ARTIFACTS / "ios-scene-host-simulator" / (
        "run-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8])).resolve()
    if args.dry_run:
        print("macOS CI only; select installed stable Xcode via DEVELOPER_DIR (no xcode-select writes).")
        print("Read iPhoneSimulator SDK and simctl list --json; pin newest available compatible iOS 18+ runtime/iPad type.")
        print("Create a unique simulator; boot + bootstatus headlessly. Never open Simulator.app or use a physical device.")
        print(shlex.join(xcodebuild_command(SPEC.parent / (SCHEME + ".xcodeproj"), "CREATED-UDID", out)))
        print(f"Require exactly all {MINIMUM_TESTS} named {TEST_CLASS} cases, zero failures/skips and matching xcresult summary/tree.")
        print("Finally shutdown/delete only the UUID returned by our create; verify it is absent. Keep logs + xcresult, no IPA.")
        return 0
    if platform.system() != "Darwin":
        parser.error("actual execution/cleanup requires macOS; --dry-run and offline parser tests are portable")
    if args.cleanup_only:
        if args.artifacts_dir is None:
            parser.error("--cleanup-only requires the exact --artifacts-dir from this run")
        if not out.is_dir():
            print("No run artifacts; no simulator cleanup attempted.")
            return 0
        runner = Runner(out, os.environ.copy())
        try:
            toolchain_path = out / "toolchain.json"
            if toolchain_path.is_file():
                runner.env["DEVELOPER_DIR"] = json.loads(toolchain_path.read_text(encoding="utf-8"))["selected_developer_dir"]
            result = cleanup_owned(runner, out)
            save_json(out / "workflow-cleanup.json", result)
            print(json.dumps(result))
            return 0
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            print(f"Cleanup failed: {error}", file=sys.stderr)
            return 1
    out.mkdir(parents=True, exist_ok=False)
    runner = Runner(out, os.environ.copy())
    report = {"schema": 1, "verdict": "failed", "scope": "actual UIKit host with mocked native C ABI",
              "physical_device_access": False, "desktop_automation": False, "audio_hardware": False,
              "native_renderer_tested": False, "started_utc": datetime.now(timezone.utc).isoformat()}
    started = time.monotonic()
    previous_handler = signal.getsignal(signal.SIGTERM)

    def interrupted(signum, frame):
        raise InterruptedError("CI termination requested; cleaning up our simulator")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        toolchain = selected_xcode(runner)
        sdk, _ = runner.run("simulator-sdk-version", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
        sdk_path, _ = runner.run("simulator-sdk-path", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
        toolchain["sdk"] = {"name": "iphonesimulator", "version": sdk, "path": sdk_path}
        save_json(out / "toolchain.json", toolchain)
        report["toolchain"] = toolchain
        inventory = runner.inventory("simulator-inventory")
        runtime, device = select_simulator(inventory, sdk)
        report["simulator_pin"] = {"runtime": runtime, "device_type": device}
        runner.run("xcodegen-version", ["xcodegen", "--version"])
        runner.run("xcodegen", ["xcodegen", "generate", "--spec", str(SPEC), "--project", str(SPEC.parent)])
        token = uuid.uuid4().hex
        owner = {"schema": 1, "token": token, "name": OWNER_PREFIX + token, "runtime": runtime["identifier"],
                 "device_type": device["identifier"], "initial_udids": [str(row["udid"]).upper() for _, row in device_rows(inventory)]}
        save_json(out / "simulator-owner.json", owner)
        raw, _ = runner.run("simulator-create", ["xcrun", "simctl", "create", owner["name"], device["identifier"], runtime["identifier"]])
        owner["udid"] = canonical_udid(raw)
        save_json(out / "simulator-owner.json", owner)
        identifier, row = owned_device(owner, raw, runner.inventory("simulator-created-inventory"))
        if row is None:
            raise RuntimeError("new simulator is absent from simctl inventory")
        report["created_udid"] = identifier
        runner.run("simulator-boot", ["xcrun", "simctl", "boot", identifier], timeout=120)
        runner.run("simulator-bootstatus", ["xcrun", "simctl", "bootstatus", identifier, "-b"], timeout=480)
        project = SPEC.parent / (SCHEME + ".xcodeproj")
        _, build_code = runner.run("xcodebuild-test", xcodebuild_command(project, identifier, out), timeout=1200, check=False)
        bundle = out / "SceneHost.xcresult"
        if not bundle.is_dir():
            raise RuntimeError(f"xcodebuild exit {build_code}; no xcresult test verdict")
        raw_summary, _ = runner.run("xcresult-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)])
        summary = json.loads(raw_summary)
        save_json(out / "xcresult-summary.json", summary)
        report["xcresult_summary"] = summary
        if isinstance(summary, dict):
            print("\n".join(summarize(summary)[0]), flush=True)
            report["tests"] = {"passed": summary.get("passedTests", 0), "failed": summary.get("failedTests", 0),
                               "skipped": summary.get("skippedTests", 0), "total": summary.get("totalTestCount", 0)}
        raw_tree, _ = runner.run("xcresult-tests", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)])
        tree = json.loads(raw_tree)
        save_json(out / "xcresult-tests.json", tree)
        report["tests"] = inspect_results(summary, tree)
        if build_code != 0:
            raise RuntimeError(f"xcodebuild test failed (exit {build_code}); result data never overrides tool failure")
        report["verdict"] = "passed"
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report["error"] = str(error) or type(error).__name__
        print(f"{MARK.missing} {report['error']}", file=sys.stderr)
        log = out / "xcodebuild-test.stdout.log"
        if log.is_file():
            failures = [line for line in log.read_text(encoding="utf-8", errors="replace").splitlines() if interesting(line)]
            print("\n".join(failures[-60:]), file=sys.stderr)
    finally:
        # Ignore repeated cancellation while the narrow, independently bounded cleanup runs.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            report["cleanup"] = cleanup_owned(runner, out)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            report["cleanup"] = {"status": "failed", "error": str(error)}
            report["error"] = report.get("error", "") + " Cleanup failed: " + str(error)
            report["verdict"] = "failed"
        report["elapsed_seconds"] = round(time.monotonic() - started, 2)
        report["commands"] = runner.steps
        write_report(out, report)
        signal.signal(signal.SIGTERM, previous_handler)
    return 0 if report["verdict"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
