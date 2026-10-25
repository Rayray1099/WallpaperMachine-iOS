#!/usr/bin/env python3
"""Portable strict-verdict/ownership checks; not a substitute for Apple XCTest."""
from __future__ import annotations

import copy
import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("pc_integration_simulator", SCRIPTS / "ios/check_pc_integration_simulator.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

# Enumerated independently so accidentally dropping a runner requirement fails.
REQUIRED = {
    "PCConverterClientTests": (
        "testAcceptsOnlyExplicitPrivateIPv4ConnectionCapabilities",
        "testRejectsPublicAmbiguousAndCredentialBearingConnectionURLs",
        "testDownloadCapabilityNeverChangesOriginJobOrRoute",
        "testConversionKeepsFullDurationAndFixedNativeFitOptions",
        "testManagedVideoResolutionRejectsEscapesEmptyAndSymlinks",
        "testReceiptRequiresDoneStateBoundedBytesAndLowercaseSHA256",
        "testArchiveVerificationChecksSignatureSizeAndStreamingDigest",
    ),
    "SceneSharedAssetsInstallerTests": (
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
    ),
}
UDID = "85C4FBBC-82E5-4490-8091-0E656098A995"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-18-5"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-16GB"


def results():
    count = sum(map(len, REQUIRED.values()))
    summary = {"passedTests": count, "failedTests": 0, "skippedTests": 0, "totalTestCount": count,
               "expectedFailures": 0, "result": "Passed", "testFailures": []}
    tree = {"testNodes": [{"nodeType": "Test Plan", "children": [
        {"nodeType": "Test Suite", "name": cls, "children": [
            {"nodeType": "Test Case", "name": method + "()", "nodeIdentifier": cls + "/" + method + "()",
             "result": "Passed"} for method in methods]} for cls, methods in REQUIRED.items()]}]}
    return summary, tree


def leaves(tree):
    return [node for suite in tree["testNodes"][0]["children"] for node in suite["children"]]


def owner():
    token = "1234567890abcdef" * 2
    return {"token": token, "name": "WMPCIntegration-" + token, "runtime": RUNTIME,
            "device_type": DEVICE, "initial_udids": [], "udid": UDID}


def inventory(state=None):
    state = state or owner()
    return {"devices": {RUNTIME: [{"name": state["name"], "udid": UDID, "deviceTypeIdentifier": DEVICE,
                                   "state": "Booted"}]}}


class PCIntegrationVerdictTests(unittest.TestCase):
    def test_accepts_exact_native_case_set(self):
        summary, tree = results()
        verdict = runner.inspect_results(summary, tree)
        self.assertEqual(verdict["passed"], 19)
        self.assertEqual(verdict["by_class"], {"PCConverterClientTests": 7, "SceneSharedAssetsInstallerTests": 12})
        self.assertEqual(runner.EXPECTED, {key: frozenset(value) for key, value in REQUIRED.items()})

    def test_rejects_skips_failures_missing_and_boolean_counts(self):
        for key, value in [("skippedTests", 1), ("failedTests", 1), ("expectedFailures", 1),
                           ("passedTests", 18), ("totalTestCount", 20), ("passedTests", True), ("result", "Failed")]:
            summary, tree = results()
            summary[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)
        for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount"):
            summary, tree = results()
            del summary[key]
            with self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)

    def test_rejects_unexpected_missing_duplicate_and_wrong_class_leaves(self):
        mutations = [lambda row: row.update(nodeIdentifier="SceneHostLifecycleTests/testOther()"),
                     lambda row: row.update(name="testOther()"), lambda row: row.update(result="Skipped"),
                     lambda row: row.update(children=[{}]), lambda row: row.update(nodeIdentifier=42)]
        for mutate in mutations:
            summary, tree = results()
            mutate(leaves(tree)[0])
            with self.assertRaises(ValueError):
                runner.inspect_results(summary, tree)
        summary, tree = results()
        tree["testNodes"][0]["children"][0]["children"].pop()
        with self.assertRaises(ValueError):
            runner.inspect_results(summary, tree)
        summary, tree = results()
        rows = tree["testNodes"][0]["children"][0]["children"]
        rows[-1] = copy.deepcopy(rows[0])
        with self.assertRaises(ValueError):
            runner.inspect_results(summary, tree)

    def test_accepts_fully_qualified_matching_leaf_identity(self):
        summary, tree = results()
        for row in leaves(tree):
            row["nodeIdentifier"] = "WMPCIntegrationTests/" + row["nodeIdentifier"]
        self.assertEqual(runner.inspect_results(summary, tree)["passed"], 19)

    def test_actual_test_sources_match_allowlist_and_sha_manifest(self):
        manifest = runner.source_manifest()
        self.assertIn("iOS/Sources/Export/PCConverterClient.swift", manifest)
        self.assertIn("iOS/Sources/Renderer/SceneSharedAssetsInstaller.swift", manifest)
        self.assertTrue(all(len(digest) == 64 for digest in manifest.values()))
        self.assertFalse(any("artifacts/" in path for path in manifest))

    def test_command_pins_owned_simulator_and_both_test_classes(self):
        command = runner.test_command(UDID, Path("out"))
        self.assertIn("id=" + UDID, command)
        self.assertIn("-only-testing:WMPCIntegrationTests/PCConverterClientTests", command)
        self.assertIn("-only-testing:WMPCIntegrationTests/SceneSharedAssetsInstallerTests", command)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", command)
        self.assertNotIn("-allowProvisioningUpdates", command)


class GeneratedProjectTests(unittest.TestCase):
    def project(self):
        objects = {"root": {"mainGroup": "main", "targets": ["app", "tests"]},
                   "main": {"isa": "PBXGroup", "sourceTree": "<group>", "children": []}}
        inputs = {
            "app": (runner.SCHEME, [runner.ROOT / path for path in runner.PRODUCTION_SOURCES] + [runner.SPEC.parent / "PCIntegrationApp.swift"]),
            "tests": (runner.TEST_TARGET, [*runner.TEST_SOURCES.values(), runner.ROOT / "iOS/Tests/Support/IOSTestSupport.swift"]),
        }
        for target, (name, paths) in inputs.items():
            phase = target + "-sources"
            objects[target] = {"isa": "PBXNativeTarget", "name": name, "buildPhases": [phase]}
            objects[phase] = {"isa": "PBXSourcesBuildPhase", "files": []}
            for index, path in enumerate(paths):
                ref, build = target + "-ref-" + str(index), target + "-build-" + str(index)
                objects[ref] = {"isa": "PBXFileReference", "sourceTree": "SOURCE_ROOT", "path": str(path.resolve())}
                objects[build] = {"fileRef": ref}
                objects["main"]["children"].append(ref)
                objects[phase]["files"].append(build)
        return {"objects": objects, "rootObject": "root"}

    def test_resolves_exact_existing_source_inputs(self):
        result = runner.validate_generated_project(self.project(), runner.SPEC.parent)
        self.assertEqual(len(result[runner.SCHEME]), 14)
        self.assertEqual(len(result[runner.TEST_TARGET]), 3)

    def test_rejects_doubled_external_group_path_before_simulator_creation(self):
        project = self.project()
        objects = project["objects"]
        ref = "tests-ref-0"
        objects["main"]["children"].remove(ref)
        objects["main"]["children"].append("bad-group")
        objects["bad-group"] = {"isa": "PBXGroup", "sourceTree": "<group>", "path": "../", "children": [ref]}
        objects[ref].update(sourceTree="<group>", path="iOS/Tests/Unit/Export/PCConverterClientTests.swift")
        with self.assertRaises(ValueError):
            runner.validate_generated_project(project, runner.SPEC.parent)

    def test_rejects_missing_duplicate_or_wrong_target_source(self):
        for mode in ("missing", "duplicate", "wrong-target"):
            project = self.project()
            files = project["objects"]["tests-sources"]["files"]
            if mode == "missing":
                files.pop()
            elif mode == "duplicate":
                files.append(files[0])
            else:
                files[0] = "app-build-0"
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                runner.validate_generated_project(project, runner.SPEC.parent)

    def test_failed_gate_never_claims_compilation_or_xctest_pass(self):
        text = runner.report_summary({"verdict": "failed"})
        self.assertIn("No compilation or XCTest pass is claimed", text)
        self.assertNotIn("compiled unchanged", text)
        passed = runner.report_summary({"verdict": "passed", "tests": {"passed": 19}})
        self.assertIn("compiled unchanged", passed)


class PCIntegrationOwnershipTests(unittest.TestCase):
    def test_accepts_only_our_new_uuid_and_exact_identity(self):
        state = owner()
        identifier, row = runner.owned_device(state, UDID + "\n", inventory())
        self.assertEqual(identifier, UDID)
        self.assertEqual(row["name"], state["name"])
        self.assertIsNone(runner.owned_device(state, UDID, {"devices": {RUNTIME: []}})[1])

    def test_rejects_preexisting_uuid_changed_name_type_runtime_and_scene_owner(self):
        for field, value in [("initial_udids", [UDID]), ("name", "WMSceneHostHarness-" + owner()["token"]),
                             ("token", "not-ours"), ("udid", "00000000-1111-2222-3333-444444444444")]:
            state = owner()
            state[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                runner.owned_device(state, UDID, inventory())
        for field in ("name", "deviceTypeIdentifier"):
            inv = inventory()
            inv["devices"][RUNTIME][0][field] = "changed"
            with self.assertRaises(ValueError):
                runner.owned_device(owner(), UDID, inv)
        with self.assertRaises(ValueError):
            runner.owned_device(owner(), UDID, {"devices": {"different-runtime": inventory()["devices"][RUNTIME]}})

    def test_missing_runtime_fails_without_any_installation(self):
        with self.assertRaises(ValueError):
            runner.select_simulator({"runtimes": [], "devicetypes": []}, "18.5")


if __name__ == "__main__":
    unittest.main()
