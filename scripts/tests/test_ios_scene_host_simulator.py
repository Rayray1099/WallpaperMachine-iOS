#!/usr/bin/env python3
"""Offline tests of actual scene-host runtime selection, ownership and verdict logic."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scene_host_simulator", SCRIPTS / "ios/check_scene_host_simulator.py")
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)

UDID = "85C4FBBC-82E5-4490-8091-0E656098A995"
OTHER_UDID = "00000000-1111-2222-3333-444444444444"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-16GB"
# Independently enumerated coverage contract; do not manufacture fixtures from the
# runner's own allowlist, which would make a mistakenly dropped requirement pass.
REQUIRED_METHODS = (
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
    "testAssetInstallationClosesEveryReaderAndBlocksNewInitialization",
    "testAssetInstallationRearmsSameURLAndFailedSessionWithoutOldReadiness",
    "testStaleInstallationTokenCannotReleaseAnotherPublicationGate",
    "testDismantledAndExplicitlyStoppedSurfacesNeverReviveAfterAssetsChange",
    "testSceneExportLeaseAndAssetPublicationAreMutuallyExclusive",
    "testManualExportModeEnabledBeforeInitAndWaitsForPreparedStatusWithoutPresentedFrame",
    "testManualExportEnableFailureStopsBeforeInitAndCleansAllocatedHandle",
    "testManualExportFinishClosesOnceAndLiveSessionsNeverUseManualABI",
    "testPreparedManualSessionIgnoresIdenticalUpdatesButEndsOnChangedSettings",
)


def sim_runtime(number="26.2", available=True, **extra):
    return {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-" + number.replace(".", "-"),
            "version": number, "isAvailable": available, **extra}


def sim_type(identifier=DEVICE, minimum="26.0", **extra):
    return {"identifier": identifier, "name": "iPad Pro 13-inch (M5)", "minRuntimeVersionString": minimum, **extra}


def owner():
    token = "1234567890abcdef" * 2
    return {"token": token, "name": runner.OWNER_PREFIX + token, "runtime": RUNTIME,
            "device_type": DEVICE, "initial_udids": [OTHER_UDID], "udid": UDID}


def inventory(row=None):
    state = owner()
    return {"devices": {RUNTIME: [{"name": state["name"], "udid": UDID,
                                  "deviceTypeIdentifier": DEVICE, "state": "Booted", **(row or {})}]}}


def results(methods=REQUIRED_METHODS):
    count = len(methods)
    summary = {"passedTests": count, "failedTests": 0, "skippedTests": 0,
               "totalTestCount": count, "expectedFailures": 0, "result": "Passed", "testFailures": []}
    tree = {"testNodes": [{"name": "All tests", "nodeType": "Test Plan", "children": [
        {"name": "WMSceneHostLifecycleTests", "nodeType": "Unit test bundle", "children": [
            {"name": "SceneHostLifecycleTests", "nodeType": "Test Suite", "children": [
                {"name": method + "()", "nodeType": "Test Case", "result": "Passed",
                 "nodeIdentifier": "SceneHostLifecycleTests/" + method + "()"} for method in methods]}]}]}]}
    return summary, tree


def leaves(tree):
    return tree["testNodes"][0]["children"][0]["children"][0]["children"]


class RuntimeSelectionTests(unittest.TestCase):
    def choose(self, runtimes, types, sdk="26.2"):
        return runner.select_simulator({"runtimes": runtimes, "devicetypes": types}, sdk)

    def test_latest_available_runtime_and_compatible_ipad_are_pinned(self):
        selected, device = self.choose([sim_runtime("18.0"), sim_runtime("26.2"), sim_runtime("26.1")],
                                      [sim_type(minimum="18.0"), sim_type()])
        self.assertEqual(selected["identifier"], RUNTIME)
        self.assertEqual(device["identifier"], DEVICE)

    def test_unavailable_runtime_and_runtime_newer_than_sdk_are_not_selected(self):
        selected, _ = self.choose([sim_runtime("26.2", False), sim_runtime("27.0"), sim_runtime("18.0")],
                                 [sim_type(minimum="18.0")])
        self.assertEqual(selected["version"], "18.0")

    def test_pre_ios18_sdk_or_runtime_fail_without_installing(self):
        for sdk, runtimes in (("17.5", [sim_runtime("18.0")]), ("26.2", [sim_runtime("17.5")])):
            with self.subTest(sdk=sdk), self.assertRaises(ValueError):
                self.choose(runtimes, [sim_type(minimum="17.0")], sdk)

    def test_non_ios_platform_and_non_ipad_type_do_not_qualify(self):
        for runtime, device in (({**sim_runtime(), "identifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-2"}, sim_type()),
                                (sim_runtime(), sim_type("com.apple.CoreSimulator.SimDeviceType.iPhone-17"))):
            with self.subTest(runtime=runtime), self.assertRaises(ValueError):
                self.choose([runtime], [device])

    def test_runtime_supported_device_list_and_type_version_range_are_enforced(self):
        runtime = sim_runtime(supportedDeviceTypes=[{"identifier": DEVICE}])
        for device in (sim_type(DEVICE + "-other"), sim_type(minimum="27.0"),
                       sim_type(maxRuntimeVersionString="26.1")):
            with self.subTest(device=device), self.assertRaises(ValueError):
                self.choose([runtime], [device])

    def test_unavailable_value_is_not_truthy_string(self):
        with self.assertRaises(ValueError):
            self.choose([sim_runtime(available="YES")], [sim_type()])

    def test_malformed_and_prerelease_versions_fail_closed(self):
        for value in (None, "26.2 beta", "iOS 26.2", "", 26.2, "26.2.1.3.4"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                runner.version(value)


class ResultVerdictTests(unittest.TestCase):
    def test_actual_tree_cases_match_summary_and_have_integer_counts(self):
        summary, tree = results()
        actual = runner.inspect_results(summary, tree)
        self.assertEqual((actual["total"], actual["passed"], actual["failed"], actual["skipped"]), (len(REQUIRED_METHODS), len(REQUIRED_METHODS), 0, 0))
        self.assertEqual(len(actual["cases"]), len(REQUIRED_METHODS))
        self.assertTrue(all(name.startswith("SceneHostLifecycleTests/") for name in actual["cases"]))

    def test_zero_or_insufficient_test_runs_cannot_pass(self):
        for count in (0, 1, 9, 10, 14, 15, 16, 20, 21, 23):
            with self.subTest(count=count), self.assertRaisesRegex(ValueError, "exactly " + str(len(REQUIRED_METHODS))):
                runner.inspect_results(*results(REQUIRED_METHODS[:count]))

    def test_every_named_behavior_is_required_even_with_matching_counts(self):
        for index in range(len(REQUIRED_METHODS)):
            methods = list(REQUIRED_METHODS)
            methods[index] = "testUnrelatedPassingBehavior"
            with self.subTest(missing=REQUIRED_METHODS[index]), self.assertRaisesRegex(ValueError, "case set differs"):
                runner.inspect_results(*results(methods))

    def test_old_sixteen_cases_plus_unrelated_fillers_are_not_current_coverage(self):
        stale = REQUIRED_METHODS[:16] + tuple("testLegacyPadding" + str(index) for index in range(len(REQUIRED_METHODS) - 16))
        with self.assertRaisesRegex(ValueError, "case set differs"):
            runner.inspect_results(*results(stale))

    def test_unexpected_extra_case_is_not_silently_accepted(self):
        with self.assertRaisesRegex(ValueError, "exactly " + str(len(REQUIRED_METHODS))):
            runner.inspect_results(*results(REQUIRED_METHODS + ("testUnrelatedPassingBehavior",)))

    def test_known_fully_qualified_identities_and_case_order_are_supported(self):
        for prefix, separator in (("", "/"), ("WMSceneHostLifecycleTests/", "/"),
                                  ("WMSceneHostLifecycleTests.", ".")):
            summary, tree = results(tuple(reversed(REQUIRED_METHODS)))
            for case in leaves(tree):
                case["nodeIdentifier"] = prefix + "SceneHostLifecycleTests" + separator + case["name"]
            with self.subTest(prefix=prefix):
                self.assertEqual(runner.inspect_results(summary, tree)["total"], len(REQUIRED_METHODS))

    def test_leaf_identifier_not_ancestor_label_proves_case_identity(self):
        for identity in ("OtherTests/" + REQUIRED_METHODS[0] + "()",
                         "OtherBundle/SceneHostLifecycleTests/" + REQUIRED_METHODS[0] + "()",
                         "SceneHostLifecycleTestsExtra/" + REQUIRED_METHODS[0] + "()",
                         "SceneHostLifecycleTests/" + REQUIRED_METHODS[1] + "()", None, 17):
            summary, tree = results()
            leaves(tree)[0]["nodeIdentifier"] = identity
            with self.subTest(identity=identity), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_missing_identifier_or_disagreeing_leaf_name_cannot_pass(self):
        for change in ({"nodeIdentifier": ""}, {"name": "testUnrelatedPassingBehavior()"},
                       {"name": None}, {"name": REQUIRED_METHODS[0] + "garbage"}):
            summary, tree = results()
            leaves(tree)[0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_duplicate_method_under_different_qualified_id_is_rejected(self):
        summary, tree = results()
        leaves(tree)[1] = {**leaves(tree)[0], "nodeIdentifier": "WMSceneHostLifecycleTests/" + leaves(tree)[0]["nodeIdentifier"]}
        with self.assertRaisesRegex(ValueError, "identities"):
            runner.inspect_results(summary, tree)

    def test_nested_case_results_are_not_counted_as_a_single_success(self):
        summary, tree = results()
        leaves(tree)[0]["children"] = [{"name": "unexpected invocation", "result": "Failed"}]
        with self.assertRaisesRegex(ValueError, "nested"):
            runner.inspect_results(summary, tree)

    def test_missing_or_nonnumeric_summary_fields_fail(self):
        for field in ("passedTests", "failedTests", "skippedTests", "totalTestCount"):
            for value in (None, "10", True, -1):
                summary, tree = results()
                summary[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    runner.inspect_results(summary, tree)

    def test_skipped_failed_or_expected_failure_is_not_pass(self):
        for change in ({"skippedTests": 1}, {"failedTests": 1}, {"expectedFailures": 1},
                       {"result": "Failed"}, {"result": "Unknown"},
                       {"testFailures": [{"failureText": "test host could not launch"}]}):
            summary, tree = results()
            summary.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_summary_count_mismatch_cannot_pass(self):
        summary, tree = results()
        summary["passedTests"] = 11
        with self.assertRaises(ValueError):
            runner.inspect_results(summary, tree)

    def test_summary_alone_and_unknown_apple_tree_formats_fail(self):
        summary, _ = results()
        for tree in ({}, {"testNodes": {}}, {"testNodes": []}, {"testNodes": ["bad"]}):
            with self.subTest(tree=tree), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_test_case_failure_wins_over_passing_summary(self):
        for state in ("Failed", "Skipped", "Expected Failure", "Not Run", None):
            summary, tree = results()
            leaves(tree)[0]["result"] = state
            with self.subTest(state=state), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_wrong_suite_or_similarly_named_suite_is_not_coverage(self):
        for name in ("OtherTests", "NotSceneHostLifecycleTests", "SceneHostLifecycleTestsExtra"):
            summary, tree = results()
            suite = tree["testNodes"][0]["children"][0]["children"][0]
            suite["name"] = name
            for case in leaves(tree):
                case["nodeIdentifier"] = name + "/" + case["name"]
            with self.subTest(name=name), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_duplicated_or_missing_actual_case_is_rejected(self):
        for duplicate in (False, True):
            summary, tree = results()
            if duplicate:
                leaves(tree)[1] = leaves(tree)[0]
            else:
                leaves(tree).pop()
            with self.subTest(duplicate=duplicate), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)


class OwnershipTests(unittest.TestCase):
    def test_only_exact_newly_created_udid_is_owned(self):
        identifier, device = runner.owned_device(owner(), UDID.lower() + "\n", inventory())
        self.assertEqual(identifier, UDID)
        self.assertEqual(device["name"], owner()["name"])

    def test_absent_owned_device_needs_no_delete(self):
        self.assertEqual(runner.owned_device(owner(), UDID, {"devices": {}}), (UDID, None))

    def test_preexisting_user_device_cannot_be_owned(self):
        state = owner()
        state["initial_udids"].append(UDID)
        with self.assertRaisesRegex(ValueError, "existed before"):
            runner.owned_device(state, UDID, inventory())

    def test_missing_initial_inventory_proof_refuses_cleanup(self):
        state = owner()
        del state["initial_udids"]
        with self.assertRaisesRegex(ValueError, "initial simulator inventory"):
            runner.owned_device(state, UDID, inventory())

    def test_arbitrary_or_multiple_uuid_stdout_is_rejected(self):
        for text in ("booted", UDID + "\n" + OTHER_UDID, "{" + UDID + "}", "85c4fbbc82e5449080910e656098a995"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                runner.owned_device(owner(), text, inventory())

    def test_changed_identity_and_ambiguous_inventory_refuse_cleanup(self):
        for changed in ({"name": "personal iPad"}, {"deviceTypeIdentifier": "other"}):
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                runner.owned_device(owner(), UDID, inventory(changed))
        document = inventory()
        document["devices"][RUNTIME].append(document["devices"][RUNTIME][0])
        with self.assertRaises(ValueError):
            runner.owned_device(owner(), UDID, document)
        document = inventory()
        document["devices"]["other-runtime"] = document["devices"].pop(RUNTIME)
        with self.assertRaises(ValueError):
            runner.owned_device(owner(), UDID, document)

    def test_changed_manifest_token_name_and_udid_refuse_cleanup(self):
        for change in ({"token": "bad"}, {"name": "owned"}, {"udid": OTHER_UDID}):
            state = {**owner(), **change}
            with self.subTest(change=change), self.assertRaises(ValueError):
                runner.owned_device(state, UDID, inventory())


class FakeRunner:
    def __init__(self, before, after=None):
        self.inventories = [before, after if after is not None else {"devices": {}}]
        self.commands = []

    def inventory(self, name, cleanup=False):
        return self.inventories.pop(0)

    def run(self, name, command, **kwargs):
        self.commands.append(command)
        return "", 0


class CleanupAndCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wm-scene-host-parser-")
        self.addCleanup(temporary.cleanup)
        self.out = Path(temporary.name)

    def ownership_files(self, state=None, stdout=UDID):
        runner.save_json(self.out / "simulator-owner.json", state or owner())
        (self.out / "simulator-create.stdout.log").write_text(stdout, encoding="utf-8")

    def test_cleanup_shuts_down_deletes_and_verifies_only_created_uuid(self):
        self.ownership_files()
        fake = FakeRunner(inventory())
        actual = runner.cleanup_owned(fake, self.out)
        self.assertEqual(fake.commands, [["xcrun", "simctl", "shutdown", UDID], ["xcrun", "simctl", "delete", UDID]])
        self.assertEqual(actual["remaining_owned_devices"], 0)
        self.assertEqual(actual["status"], "deleted")

    def test_shutdown_device_does_not_need_shutdown_and_second_cleanup_is_idempotent(self):
        self.ownership_files()
        fake = FakeRunner(inventory({"state": "Shutdown"}))
        runner.cleanup_owned(fake, self.out)
        self.assertEqual(fake.commands, [["xcrun", "simctl", "delete", UDID]])
        second = FakeRunner({"devices": {}})
        self.assertEqual(runner.cleanup_owned(second, self.out)["status"], "already-absent")
        self.assertEqual(second.commands, [])

    def test_no_manifest_never_accesses_simulators(self):
        fake = FakeRunner(None)
        self.assertEqual(runner.cleanup_owned(fake, self.out)["status"], "not-created")
        self.assertEqual(fake.inventories, [None, {"devices": {}}])

    def test_cancelled_create_without_uuid_does_not_delete_by_name(self):
        self.ownership_files(stdout="")
        fake = FakeRunner(inventory())
        with self.assertRaisesRegex(RuntimeError, "no returned UUID"):
            runner.cleanup_owned(fake, self.out)
        self.assertEqual(fake.commands, [])

    def test_cancelled_create_with_returned_uuid_can_be_cleaned_from_saved_output(self):
        state = owner()
        del state["udid"]
        self.ownership_files(state)
        self.assertEqual(runner.cleanup_owned(FakeRunner(inventory()), self.out)["status"], "deleted")

    def test_cleanup_fails_if_owned_device_remains(self):
        self.ownership_files()
        with self.assertRaisesRegex(RuntimeError, "still exists"):
            runner.cleanup_owned(FakeRunner(inventory(), inventory()), self.out)

    def test_cleanup_rejects_existing_device_without_mutating_anything(self):
        state = owner()
        state["initial_udids"].append(UDID)
        self.ownership_files(state)
        fake = FakeRunner(inventory())
        with self.assertRaises(ValueError):
            runner.cleanup_owned(fake, self.out)
        self.assertEqual(fake.commands, [])

    def test_build_command_is_unsigned_isolated_testhost_with_owned_destination(self):
        command = runner.xcodebuild_command(self.out / "isolated.xcodeproj", UDID, self.out)
        self.assertEqual(command[:2], ["xcodebuild", "test"])
        self.assertEqual(command[command.index("-destination") + 1], "id=" + UDID)
        self.assertEqual(command[command.index("-sdk") + 1], "iphonesimulator")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertIn("-only-testing:WMSceneHostLifecycleTests/SceneHostLifecycleTests", command)
        self.assertEqual(command[command.index("-resultBundlePath") + 1], str(self.out / "SceneHost.xcresult"))
        self.assertNotIn("-allowProvisioningUpdates", command)

    def test_portable_dry_run_never_runs_commands_or_writes_output(self):
        destination = self.out / "new-output"
        with patch.object(runner.subprocess, "Popen", side_effect=AssertionError("must not run tools")), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(["--dry-run", "--artifacts-dir", str(destination)]), 0)
        self.assertFalse(destination.exists())

    def test_windows_execution_refuses_before_writes_or_simulator_commands(self):
        destination = self.out / "new-output"
        with patch.object(runner.platform, "system", return_value="Windows"), patch.object(runner.subprocess, "Popen", side_effect=AssertionError("must not run tools")), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                runner.main(["--artifacts-dir", str(destination)])
        self.assertEqual(error.exception.code, 2)
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
