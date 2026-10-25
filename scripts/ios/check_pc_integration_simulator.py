#!/usr/bin/env python3
"""Run real PC/shared-assets and CPU scene-adapter Apple XCTest on an owned simulator."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lib.paths import ARTIFACTS, ROOT
# Reuse only tool execution, installed-toolchain/runtime selection and UUID parsing.
# The scene-host case allowlist/verdict is deliberately not imported or reused.
from ios.check_scene_host_simulator import Runner, canonical_udid, device_rows, select_simulator, selected_xcode

SPEC = ROOT / "iOS/Tests/PCIntegration/project.yml"
SCHEME = "WMPCIntegrationHarness"
TEST_TARGET = "WMPCIntegrationTests"
OWNER_PREFIX = "WMPCIntegration-"
EXPECTED = {
    "PCConverterClientTests": frozenset({
        "testAcceptsOnlyExplicitPrivateIPv4ConnectionCapabilities",
        "testRejectsPublicAmbiguousAndCredentialBearingConnectionURLs",
        "testDownloadCapabilityNeverChangesOriginJobOrRoute",
        "testConversionKeepsFullDurationAndFixedNativeFitOptions",
        "testManagedVideoResolutionRejectsEscapesEmptyAndSymlinks",
        "testReceiptRequiresDoneStateBoundedBytesAndLowercaseSHA256",
        "testArchiveVerificationChecksSignatureSizeAndStreamingDigest",
    }),
    "SceneSharedAssetsInstallerTests": frozenset({
        "testValidInstallVerifiesExactPayloadAndSourceUnchanged",
        "testExistingAssetsAreRetainedAsSeparateBackup",
        "testUnsafeMemberNamesAreRejectedBeforePublication",
        "testDuplicateAndCaseFoldedEntriesAreRejected",
        "testImplicitDirectoryCaseAndFilePrefixCollisionsAreRejected",
        "testSymlinkSpecialAndExecutableEntriesAreRejected",
        "testMissingShaderWrongSchemaAndHashAreRejected",
        "testAllQuotaDimensionsAreEnforcedBeforePublication",
        "testPublicationGateFailurePreservesOldAssets",
        "testCorruptPayloadCRCIsRejectedWithoutPublishing",
        "testFailedSecondPublicationRenameRestoresOldDirectory",
        "testSymlinkMountAndParentAreRejected",
    }),
    "SceneWallpaperExportTests": frozenset({
        "testBGRAAndRGBAAreDecodedByCoreGraphicsWithoutSwappingChannelsOrRows",
        "testUnrelatedLayerAndContextResponsesAreIgnored",
        "testSynchronousResponseIsSafeAndEveryCaptureUsesUniqueContext",
        "testQueuedResponseCannotSurviveSessionInvalidation",
        "testCancellationEndsPromptlyAndLateResponseCannotAnswerNextRequest",
        "testTimeoutCleansRequestAndAllowsSubsequentCapture",
        "testReadinessLossWhileWaitingDoesNotReturnFrame",
        "testNotReadyAndAlreadyCancelledCallsDoNotPostReadback",
        "testConcurrentRequestIsRejectedWithoutStealingFirstContinuation",
        "testMalformedAndOversizedMatchingPayloadsAreRejectedAndReset",
        "testCaptureBoundsDoNotUpscaleAndRejectUnsafeSurfaceBeforePosting",
        "testNativeResolutionBudgetDoesNotSilentlyInheritWebLimit",
        "testProviderUsesLiveNilSourceTimeAndMonotonicPacingAcrossSessions",
        "testProviderRejectsWrongSourceFakeTimelineAndResolutionMismatch",
        "testProviderFailsSlowFinalCaptureAndDoesNotLowerFPSOrStayPrepared",
        "testProviderRejectsLateWakeBeforeAnotherNativeReadback",
        "testProviderRejectsInvalidRepeatedAndRewindingTimestamps",
        "testProviderCancellationAndFinishDoNotWaitForUncancellableSource",
        "testProviderFinishInterruptsPacingAndOldWakeCannotReviveSession",
        "testProviderLossOfReadinessAfterCaptureResetsSession",
    }),
}
TEST_SOURCES = {
    "PCConverterClientTests": ROOT / "iOS/Tests/Unit/Export/PCConverterClientTests.swift",
    "SceneSharedAssetsInstallerTests": ROOT / "iOS/Tests/Unit/Renderer/SceneSharedAssetsInstallerTests.swift",
    "SceneWallpaperExportTests": ROOT / "iOS/Tests/Unit/Export/SceneWallpaperExportTests.swift",
}
PRODUCTION_SOURCES = tuple("iOS/Sources/" + name for name in (
    "Models/WallpaperModels.swift", "Export/PCConverterConnection.swift", "Export/PCConverterClient.swift",
    "Export/PCConverterView.swift", "Export/ExportDevice.swift", "Export/ExportGeometry.swift",
    "Export/WallpaperExportSettings.swift", "Export/TendiesScreenClass.swift", "Export/TendiesManifest.swift",
    "Export/KeyedArchiveBuilder.swift", "Export/ZipArchiveWriter.swift",
    "Renderer/SceneSharedAssetsInstaller.swift", "Renderer/SceneSharedAssetsView.swift",
    "Media/MediaFrame.swift", "Export/WallpaperFrameProvider.swift", "Export/MediaCaptureFrameProvider.swift",
    "Export/LiveCaptureTiming.swift", "Renderer/SceneNativeFrameCapture.swift", "Export/SceneWallpaperExportProvider.swift",
))


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def source_manifest():
    paths = [ROOT / path for path in PRODUCTION_SOURCES]
    paths += [SPEC, SPEC.parent / "PCIntegrationApp.swift", *TEST_SOURCES.values(),
              ROOT / "iOS/Tests/Support/IOSTestSupport.swift", Path(__file__).resolve(),
              ROOT / "scripts/ios/check_scene_host_simulator.py", ROOT / "scripts/lib/xcode.py",
              ROOT / "scripts/lib/paths.py", ROOT / ".github/workflows/ios-pc-integration-test.yml"]
    required_compiled = {ROOT / path for path in PRODUCTION_SOURCES}
    required_compiled.update([SPEC.parent / "PCIntegrationApp.swift", *TEST_SOURCES.values(),
                              ROOT / "iOS/Tests/Support/IOSTestSupport.swift"])
    declared = re.findall(r"^\s*- path: (\S+)\s*$", SPEC.read_text(encoding="utf-8"), re.MULTILINE)
    compiled = [(SPEC.parent / path).resolve() for path in declared]
    if len(set(compiled)) != len(compiled) or set(compiled) != {path.resolve() for path in required_compiled}:
        raise ValueError("standalone Xcode project must compile exactly the actual source/test closure")
    for cls, path in TEST_SOURCES.items():
        actual = re.findall(r"^\s*func\s+(test\w+)\s*\(", path.read_text(encoding="utf-8"), re.MULTILINE)
        if len(set(actual)) != len(actual) or set(actual) != EXPECTED[cls]:
            raise ValueError("source cases differ from strict XCTest contract: " + cls)
    return {str(path.relative_to(ROOT)).replace("\\", "/"): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


def validate_generated_project(project, project_directory):
    """Resolve PBX group paths, not just YAML declarations, before creating a simulator."""
    objects = project["objects"]
    root = objects[project["rootObject"]]
    resolved = {}

    def visit(identifier, parent, ancestors):
        if identifier in ancestors:
            raise ValueError("cyclic generated Xcode groups")
        node = objects[identifier]
        path = node.get("path", "")
        tree = node.get("sourceTree", "<group>")
        if tree == "<group>":
            location = (parent / path).resolve()
        elif tree == "SOURCE_ROOT":
            location = (project_directory / path).resolve()
        elif tree == "<absolute>":
            location = Path(path).resolve()
        else:
            return  # SDK/framework/product references are not source inputs.
        if node.get("isa") == "PBXFileReference":
            if identifier in resolved and resolved[identifier] != location:
                raise ValueError("ambiguous generated source reference")
            resolved[identifier] = location
        else:
            for child in node.get("children", []):
                visit(child, location, ancestors | {identifier})

    visit(root["mainGroup"], project_directory, set())
    expected = {
        SCHEME: {(ROOT / path).resolve() for path in PRODUCTION_SOURCES} | {(SPEC.parent / "PCIntegrationApp.swift").resolve()},
        TEST_TARGET: {path.resolve() for path in TEST_SOURCES.values()} | {(ROOT / "iOS/Tests/Support/IOSTestSupport.swift").resolve()},
    }
    actual = {}
    for target_id in root["targets"]:
        target = objects[target_id]
        if target.get("isa") != "PBXNativeTarget":
            continue
        name = target["name"]
        files = []
        for phase_id in target.get("buildPhases", []):
            phase = objects[phase_id]
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for build_id in phase.get("files", []):
                reference = objects[build_id]["fileRef"]
                if reference not in resolved:
                    raise ValueError("unresolved generated Xcode source input")
                files.append(resolved[reference])
        if name not in expected or len(set(files)) != len(files) or set(files) != expected[name]:
            raise ValueError("generated Xcode sources differ from actual closure for " + name + ": " + repr(list(map(str, files))))
        if any(not path.is_file() for path in files):
            raise ValueError("generated Xcode source input does not exist for " + name)
        actual[name] = sorted(str(path.relative_to(ROOT)).replace("\\", "/") for path in files)
    if set(actual) != set(expected):
        raise ValueError("missing generated Xcode target")
    return actual


def report_summary(report):
    passed = report.get("tests", {}).get("passed", 0)
    native_passed = report.get("verdict") == "passed" and passed == sum(map(len, EXPECTED.values()))
    compilation = ("Production client/importer and CPU scene-capture adapters compiled unchanged; real Apple frameworks, ZIPFoundation and XCTest."
                   if native_passed else
                   "Configured actual production sources; native compilation/test gate did not pass. No compilation or XCTest pass is claimed.")
    return (f"## Native PC/assets/CPU scene-adapter Apple XCTest: {report['verdict']}\n\n"
            f"- Verified actual passed cases: {passed}; requires all {sum(map(len, EXPECTED.values()))}, zero skips/failures.\n"
            f"- {compilation}\n"
            "- Scene mailbox/clock tests use a dummy CAMetalLayer identity and synthetic pixels; no GPU surface or native renderer.\n"
            "- No remote upload/download, scene host/controller/C ABI, physical iPad, renderer, Flash or installation pass claimed.\n"
            f"- Owned simulator cleanup: {report.get('cleanup', {}).get('status')}.\n")


def inspect_results(summary, tree):
    required = {(cls, method) for cls, methods in EXPECTED.items() for method in methods}
    for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount"):
        if type(summary.get(key)) is not int or summary[key] < 0:
            raise ValueError("invalid xcresult count: " + key)
    if (summary.get("result") != "Passed" or summary.get("testFailures")
            or type(summary.get("expectedFailures", 0)) is not int or summary.get("expectedFailures", 0) != 0
            or summary["failedTests"] != 0 or summary["skippedTests"] != 0
            or summary["passedTests"] != len(required) or summary["totalTestCount"] != len(required)):
        raise ValueError("need exactly all required native cases passed, zero skipped/failed/expected failures")
    if not isinstance(tree.get("testNodes"), list):
        raise ValueError("missing xcresult testNodes")
    found = []
    identities = []

    def visit(node):
        if not isinstance(node, dict):
            raise ValueError("unknown xcresult node")
        if node.get("nodeType") == "Test Case":
            name, identity = node.get("name"), node.get("nodeIdentifier")
            if not isinstance(name, str) or not isinstance(identity, str):
                raise ValueError("missing native test identity")
            leaf = re.fullmatch(r"(test\w+)(?:\(\))?", name)
            classes = "|".join(re.escape(cls) for cls in EXPECTED)
            match = re.fullmatch(r"(?:" + re.escape(TEST_TARGET) + r"[/.])?(" + classes + r")[/.](test\w+)(?:\(\))?", identity)
            if (not leaf or not match or leaf[1] != match[2] or node.get("result") != "Passed" or node.get("children")):
                raise ValueError("invalid/failed/skipped native test identity: " + identity)
            found.append((match[1], match[2]))
            identities.append(identity)
            return
        children = node.get("children", [])
        if not isinstance(children, list):
            raise ValueError("invalid xcresult children")
        for child in children:
            visit(child)

    for node in tree["testNodes"]:
        visit(node)
    if len(found) != len(required) or len(set(found)) != len(found) or set(found) != required:
        raise ValueError("native test leaf set does not exactly match required cases")
    return {"total": len(found), "passed": len(found), "failed": 0, "skipped": 0,
            "by_class": {cls: len(methods) for cls, methods in EXPECTED.items()}, "cases": identities}


def owned_device(state, create_stdout, inventory):
    token = state.get("token", "")
    if not re.fullmatch(r"[0-9a-f]{32}", token) or state.get("name") != OWNER_PREFIX + token:
        raise ValueError("invalid PC integration simulator owner")
    identifier = canonical_udid(create_stdout)
    if state.get("udid") not in (None, identifier):
        raise ValueError("create output differs from owned UUID")
    initial = state.get("initial_udids")
    if not isinstance(initial, list) or any(not isinstance(item, str) for item in initial):
        raise ValueError("missing original simulator inventory")
    if identifier in {item.upper() for item in initial}:
        raise ValueError("created simulator existed before this run")
    matches = [(runtime, row) for runtime, row in device_rows(inventory) if str(row.get("udid", "")).upper() == identifier]
    if not matches:
        return identifier, None
    if len(matches) != 1:
        raise ValueError("ambiguous owned UUID")
    runtime, row = matches[0]
    if (runtime != state.get("runtime") or row.get("name") != state.get("name")
            or row.get("deviceTypeIdentifier") != state.get("device_type")):
        raise ValueError("owned simulator identity changed; refusing cleanup")
    return identifier, row


def cleanup_owned(runner, out):
    manifest = out / "simulator-owner.json"
    if not manifest.is_file():
        return {"status": "not-created", "remaining_owned_devices": 0}
    state = json.loads(manifest.read_text(encoding="utf-8"))
    create = out / "simulator-create.stdout.log"
    inventory = runner.inventory("cleanup-inventory", cleanup=True)
    if not create.is_file() or not create.read_text(encoding="utf-8").strip():
        if any(row.get("name") == state.get("name") for _, row in device_rows(inventory)):
            raise ValueError("owned-name simulator exists without returned UUID; cannot prove deletion ownership")
        return {"status": "create-not-completed", "remaining_owned_devices": 0}
    identifier, row = owned_device(state, create.read_text(encoding="utf-8"), inventory)
    if row is not None:
        if row.get("state") != "Shutdown":
            runner.run("simulator-shutdown", ["xcrun", "simctl", "shutdown", identifier], check=False, cleanup=True)
        runner.run("simulator-delete", ["xcrun", "simctl", "delete", identifier], cleanup=True)
    after = runner.inventory("cleanup-verify", cleanup=True)
    if any(str(row.get("udid", "")).upper() == identifier for _, row in device_rows(after)):
        raise RuntimeError("owned simulator remains after cleanup")
    return {"status": "deleted" if row else "already-absent", "udid": identifier, "remaining_owned_devices": 0}


def test_command(udid, out):
    return ["xcodebuild", "test", "-project", str(SPEC.parent / (SCHEME + ".xcodeproj")),
            "-scheme", SCHEME, "-configuration", "Debug", "-sdk", "iphonesimulator", "-destination", "id=" + udid,
            "-destination-timeout", "180", "-parallel-testing-enabled", "NO",
            "-maximum-concurrent-test-simulator-destinations", "1", "-disable-concurrent-destination-testing",
            *["-only-testing:" + TEST_TARGET + "/" + cls for cls in EXPECTED],
            "-derivedDataPath", str(out / "DerivedData"), "-resultBundlePath", str(out / "PCIntegration.xcresult"),
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY="]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts-dir", type=Path)
    parser.add_argument("--cleanup-only", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.dry_run:
        manifest = source_manifest()
        print(f"Compile unchanged production sources; {len(manifest)} SHA-pinned inputs, {sum(map(len, EXPECTED.values()))} exact native cases.")
        print("Apple XCTest + real CryptoKit/ZIPFoundation/CoreGraphics, CPU-only synthetic scene mailbox/pacing; no GPU/host/controller/C ABI/device/network conversion/Flash coverage.")
        print("Installed stable Xcode/runtime only; missing runtime or skipped case fails; owned UUID-only shutdown/delete.")
        return 0
    if platform.system() != "Darwin":
        parser.error("actual Apple XCTest/cleanup requires macOS; --dry-run and parser unit tests are portable")
    if args.cleanup_only and args.artifacts_dir is None:
        parser.error("cleanup requires the exact run artifacts directory")
    out = (args.artifacts_dir or ARTIFACTS / "ios-pc-integration" / ("run-" + uuid.uuid4().hex)).resolve()
    if args.cleanup_only:
        if not out.is_dir():
            return 0
        runner = Runner(out, os.environ.copy())
        toolchain = out / "toolchain.json"
        if toolchain.is_file():
            runner.env["DEVELOPER_DIR"] = json.loads(toolchain.read_text())["selected_developer_dir"]
        save(out / "workflow-cleanup.json", cleanup_owned(runner, out))
        return 0
    out.mkdir(parents=True, exist_ok=False)
    runner = Runner(out, os.environ.copy(), timeout_seconds=24 * 60)
    report = {"schema": 1, "verdict": "failed", "started_utc": datetime.now(timezone.utc).isoformat(),
              "physical_device_access": False, "renderer_tested": False, "remote_transfer_tested": False,
              "wallpaper_installation_tested": False, "api_substitutes": False,
              "scene_test_source": "CPU synthetic notification mailbox and clock; dummy CAMetalLayer identity only",
              "scene_host_controller_tested": False, "gpu_tested": False, "native_c_abi_tested": False}
    previous_handler = signal.getsignal(signal.SIGTERM)

    def interrupted(signum, frame):
        raise InterruptedError("CI cancelled; cleaning up only this run's simulator")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        before = source_manifest()
        save(out / "source-sha256.json", before)
        revision, _ = runner.run("source-revision", ["git", "rev-parse", "HEAD"])
        report["source_revision"] = revision
        toolchain = selected_xcode(runner)
        sdk, _ = runner.run("simulator-sdk", ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"])
        toolchain["sdk_version"] = sdk
        save(out / "toolchain.json", toolchain)
        report["toolchain"] = toolchain
        inventory = runner.inventory("initial-inventory")
        runtime, device = select_simulator(inventory, sdk)
        report["simulator_pin"] = {"runtime": runtime, "device_type": device}
        runner.run("xcodegen", ["xcodegen", "generate", "--spec", str(SPEC), "--project", str(SPEC.parent)])
        pbxproj = SPEC.parent / (SCHEME + ".xcodeproj") / "project.pbxproj"
        raw, _ = runner.run("generated-project-json", ["plutil", "-convert", "json", "-o", "-", str(pbxproj)])
        generated = json.loads(raw)
        save(out / "generated-project.json", generated)
        report["generated_source_inputs"] = validate_generated_project(generated, SPEC.parent)
        token = uuid.uuid4().hex
        owner = {"token": token, "name": OWNER_PREFIX + token, "runtime": runtime["identifier"],
                 "device_type": device["identifier"], "initial_udids": [row["udid"].upper() for _, row in device_rows(inventory)]}
        save(out / "simulator-owner.json", owner)
        raw, _ = runner.run("simulator-create", ["xcrun", "simctl", "create", owner["name"], device["identifier"], runtime["identifier"]])
        owner["udid"] = canonical_udid(raw)
        save(out / "simulator-owner.json", owner)
        identifier, row = owned_device(owner, raw, runner.inventory("created-inventory"))
        if row is None:
            raise RuntimeError("created simulator is not present")
        runner.run("simulator-boot", ["xcrun", "simctl", "boot", identifier], timeout=120)
        runner.run("simulator-ready", ["xcrun", "simctl", "bootstatus", identifier, "-b"], timeout=480)
        _, build_exit = runner.run("xcodebuild-test", test_command(identifier, out), timeout=1200, check=False)
        bundle = out / "PCIntegration.xcresult"
        if not bundle.is_dir():
            raise RuntimeError(f"xcodebuild exit {build_exit}; no Apple XCTest result")
        raw, _ = runner.run("xcresult-summary", ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(bundle)])
        summary = json.loads(raw)
        save(out / "xcresult-summary.json", summary)
        raw, _ = runner.run("xcresult-tests", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)])
        tree = json.loads(raw)
        save(out / "xcresult-tests.json", tree)
        report["tests"] = inspect_results(summary, tree)
        if build_exit != 0:
            raise RuntimeError("native test command failed despite result data")
        after = source_manifest()
        save(out / "source-sha256-after.json", after)
        revision_after, _ = runner.run("source-revision-after", ["git", "rev-parse", "HEAD"])
        if before != after or revision != revision_after:
            raise RuntimeError("source SHA/revision changed during native tests; verdict rejected")
        report["source_sha_unchanged"] = True
        report["verdict"] = "passed"
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report["error"] = str(error) or type(error).__name__
        print(report["error"], file=sys.stderr)
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            report["cleanup"] = cleanup_owned(runner, out)
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            report["cleanup"] = {"status": "failed", "error": str(error)}
            report["verdict"] = "failed"
        report["commands"] = runner.steps
        save(out / "report.json", report)
        summary = report_summary(report)
        (out / "summary.md").write_text(summary, encoding="utf-8")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as stream:
                stream.write(summary)
        print(summary)
        signal.signal(signal.SIGTERM, previous_handler)
    return 0 if report["verdict"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
