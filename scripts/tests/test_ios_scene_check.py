# SPDX-License-Identifier: GPL-3.0-only
"""Offline verdict tests for native CI's actual GTest JSON report parser.

Extract only the parser function from the shell script's Python heredoc: importing
these tests must never execute native builds, subprocesses, or device/GPU checks.
"""
from __future__ import annotations

import ast
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ios" / "check_scene_startup.sh"


def load_report_parser(name="inspect_tests"):
    source = SCRIPT.read_text(encoding="utf-8")
    python = source.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
    parsed = ast.parse(python, filename=str(SCRIPT))
    functions = [node for node in parsed.body
                 if isinstance(node, ast.FunctionDef) and node.name == name]
    if len(functions) != 1:
        raise AssertionError("expected one actual " + name + " parser")
    namespace = {"json": json}
    module = ast.Module(body=functions, type_ignores=[])
    exec(compile(module, str(SCRIPT), "exec"), namespace)
    return namespace[name]


inspect_tests = load_report_parser()
inspect_contract = load_report_parser("inspect_contract")


def passed(name="Passed"):
    return {"name": name, "status": "RUN", "result": "COMPLETED"}


def skipped(reason="no Metal device in this process"):
    return {"name": "Skipped", "status": "RUN", "result": "SKIPPED",
            "skipped": [{"message": reason}]}


class IOSSceneCheckReportTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="wm-scene-report-test-")
        self.addCleanup(temporary.cleanup)
        self.report = Path(temporary.name) / "gtest.json"

    def inspect(self, cases, gpu=False, **summary):
        # GTest v1.14 uses testsuites for suites and testsuite for each suite's
        # case array. Summary counters are not evidence of case execution.
        document = {"testsuites": [{"name": "Regression", "testsuite": cases}], **summary}
        self.report.write_text(json.dumps(document), encoding="utf-8")
        return inspect_tests(self.report, gpu)

    def test_completed_cases_have_integer_counts_and_full_names(self):
        result = self.inspect([passed("One"), passed("Two")], tests="999", failures="0")
        self.assertEqual((result["tests"], result["passed"], result["skipped"]), (2, 2, 0))
        for key in ("tests", "passed", "skipped"):
            self.assertIs(type(result[key]), int)
        self.assertEqual([case["name"] for case in result["cases"]],
                         ["Regression.One", "Regression.Two"])
        self.assertTrue(all(case["status"] == "passed" for case in result["cases"]))

    def test_zero_matched_tests_cannot_pass_from_summary_counters(self):
        with self.assertRaisesRegex(ValueError, "matched no tests"):
            self.inspect([], tests=100, failures=0)
        self.report.write_text(json.dumps({"tests": 100, "failures": 0}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "matched no tests"):
            inspect_tests(self.report, False)

    def test_disabled_case_is_not_executed_coverage(self):
        disabled = {"name": "DISABLED_Regression", "status": "NOTRUN", "result": "SUPPRESSED"}
        for gpu in (False, True):
            with self.subTest(gpu=gpu), self.assertRaisesRegex(ValueError, "unexpected skip"):
                self.inspect([passed(), disabled], gpu=gpu)

    def test_unknown_or_missing_execution_status_cannot_pass(self):
        for changes in ({"status": "UNKNOWN"}, {"result": "UNKNOWN"},
                        {"status": None}, {"result": None}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "no completed execution"):
                self.inspect([{**passed(), **changes}])

    def test_cpu_suite_may_not_skip_even_without_metal(self):
        with self.assertRaisesRegex(ValueError, "unexpected skip"):
            self.inspect([passed(), skipped()], gpu=False)

    def test_gpu_no_metal_skip_is_counted_without_claiming_pass(self):
        result = self.inspect([skipped()], gpu=True)
        self.assertEqual((result["tests"], result["passed"], result["skipped"]), (1, 0, 1))
        self.assertEqual(result["cases"][0]["status"], "skipped")
        self.assertIn("no Metal device", result["cases"][0]["reason"])
        mixed = self.inspect([passed(), skipped()], gpu=True)
        self.assertEqual((mixed["tests"], mixed["passed"], mixed["skipped"]), (2, 1, 1))

    def test_missing_fixture_gpu_skip_is_failure_not_optional_coverage(self):
        with self.assertRaisesRegex(ValueError, "unexpected skip"):
            self.inspect([skipped("set WM_NATIVE_SCENE_FIXTURE to the generated packed project directory")], gpu=True)

    def test_duplicate_test_identity_is_not_two_executed_cases(self):
        with self.assertRaisesRegex(ValueError, "duplicate test identities"):
            self.inspect([passed("One"), passed("One")])

    def test_manual_gpu_requires_exact_named_case_not_unrelated_green_report(self):
        expected = {"MetalSceneDraw.ManualExportUsesFixedSimulationTimeDespiteSlowConsumer"}
        method = "ManualExportUsesFixedSimulationTimeDespiteSlowConsumer"
        for suite, methods in (("Other", [method]), ("MetalSceneDraw", ["Unrelated"]),
                               ("MetalSceneDraw", [method, "Unrelated"])):
            with self.subTest(suite=suite, methods=methods):
                self.report.write_text(json.dumps({"testsuites": [
                    {"name": suite, "testsuite": [passed(name) for name in methods]}]}), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "exactly the required test identities"):
                    inspect_tests(self.report, True, expected_names=expected)
        self.report.write_text(json.dumps({"testsuites": [
            {"name": "MetalSceneDraw", "testsuite": [passed(method)]}]}), encoding="utf-8")
        result = inspect_tests(self.report, True, expected_names=expected)
        self.assertEqual((result["passed"], result["skipped"]), (1, 0))

    def test_contract_requires_exact_current_release_completion_verdict(self):
        expected = "Scene frame export contract: 18000 sequential frames, admission/cancel/exactly-once PASS"
        for contents in (expected + "\n", "$ /owned/path/scene_frame_export_contract_test\n" + expected + "\n"):
            self.report.write_text(contents, encoding="utf-8")
            result = inspect_contract(self.report)
            self.assertEqual((result["tests"], result["passed"], result["skipped"]), (1, 1, 0))
            self.assertFalse(result["gpu_required"])
        for contents in ("", "PASS", expected.replace("18000", "480"), expected + "\n" + expected,
                         expected + "\nERROR later failure", "$ /owned/path/scene_frame_export_contract_test\n"):
            with self.subTest(contents=contents):
                self.report.write_text(contents, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "exactly its current completion verdict"):
                    inspect_contract(self.report)

    def test_failed_case_wins_over_skip_marker_and_zero_failure_summary(self):
        failed = {**skipped(), "failures": [{"failure": "a rendered pixel differed"}]}
        with self.assertRaisesRegex(ValueError, "contains failed tests"):
            self.inspect([failed], gpu=True, failures=0)
        with self.assertRaisesRegex(ValueError, "contains failed tests"):
            self.inspect([{**passed(), "failures": [{"failure": "loader failed"}]}])


if __name__ == "__main__":
    unittest.main()
