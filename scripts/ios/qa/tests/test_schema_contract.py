#!/usr/bin/env python3
"""Schema contract: methods, request validation and result-shape validation."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

import schema_contract  # noqa: E402
from qa_test_support import device_info_result, make_schema, method, parameter, write_schema  # noqa: E402


class RequestValidation(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, ignore_errors=True))
        self.schema = make_schema(self.directory)

    def test_required_parameter_is_enforced(self):
        self.assertEqual(self.schema.check_request("launch_app", {}),
                         ["launch_app: missing required parameter 'bundle_id'"])

    def test_unknown_parameter_is_rejected(self):
        self.assertEqual(self.schema.check_request("launch_app",
                                                   {"bundle_id": "x", "wait": True}),
                         ["launch_app: unknown parameter 'wait'"])

    def test_parameter_types_are_checked(self):
        issues = self.schema.check_request("tap", {"ref": "r", "x": "left"})
        self.assertEqual(issues, ["tap: parameter 'x' must be number, got str"])

    def test_boolean_is_not_a_number(self):
        schema = make_schema(self.directory, [method("screenshot", [parameter("scale", "number")])])
        self.assertEqual(schema.check_request("screenshot", {"scale": True}),
                         ["screenshot: parameter 'scale' must be number, got bool"])

    def test_unknown_method_is_rejected(self):
        self.assertEqual(self.schema.check_request("not_a_method", {}),
                         ["method 'not_a_method' is not in the captured schema"])

    def test_empty_request_is_valid_for_no_parameter_method(self):
        self.assertEqual(self.schema.check_request("device_info", None), [])


class ResultShapes(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, ignore_errors=True))
        self.schema = make_schema(self.directory)

    def test_device_info_requires_coordinate_space(self):
        result = device_info_result()
        del result["point_width"]
        self.assertIn("device_info: result is missing 'point_width'",
                      self.schema.check_result("device_info", result))

    def test_device_info_rejects_zero_scale(self):
        result = device_info_result(scale=0)
        self.assertIn("device_info: scale must be positive",
                      self.schema.check_result("device_info", result))

    def test_found_element_requires_ref(self):
        self.assertEqual(self.schema.check_result("find_element", {"exists": True}),
                         ["find_element: a found element must carry a non-empty ref"])
        self.assertEqual(self.schema.check_result("find_element",
                                                  {"exists": False}), [])

    def test_logs_count_cannot_be_smaller_than_lines(self):
        result = {"lines": ["a", "b"], "count": 1}
        self.assertIn("logs: count 1 is smaller than 2 returned lines",
                      self.schema.check_result("logs", result))
        self.assertEqual(self.schema.check_result("logs", {"lines": ["a"], "count": 5}), [])

    def test_tap_requires_message(self):
        self.assertEqual(self.schema.check_result("tap", {"ok": True}),
                         ["tap: result is missing 'message'"])

    def test_protocol_mismatch_is_an_error(self):
        issues = self.schema.protocol_issues(device_info_result(protocol_version=2))
        self.assertEqual(len(issues["errors"]), 1)
        self.assertIn("protocol mismatch", issues["errors"][0])

    def test_missing_capabilities_are_warnings(self):
        issues = self.schema.protocol_issues(device_info_result(capabilities=[]))
        self.assertEqual(issues["errors"], [])
        self.assertIn("missing capabilities", issues["warnings"][0])

    def test_screenshot_payload_must_be_present(self):
        result = {"data": "", "format": "gif", "pixel_width": 1, "pixel_height": 1,
                  "point_width": 1, "point_height": 1, "scale": 1}
        issues = self.schema.check_result("screenshot", result)
        self.assertIn("screenshot: format must be 'png' or 'jpeg'", issues)
        self.assertIn("screenshot: data must be a non-empty base64 string", issues)


class SchemaFileValidation(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.directory, ignore_errors=True))

    def test_missing_file_is_reported(self):
        with self.assertRaises(schema_contract.SchemaError):
            schema_contract.load_schema(self.directory / "absent.json")

    def test_wrong_protocol_is_rejected(self):
        path = write_schema(self.directory)
        payload = json.loads(path.read_text(encoding="utf-8"))
        payload["protocol"] = "XML-RPC"
        path.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaises(schema_contract.SchemaError):
            schema_contract.load_schema(path)

    def test_malformed_method_entry_is_rejected(self):
        path = write_schema(self.directory, [{"description": "no name"}])
        with self.assertRaises(schema_contract.SchemaError):
            schema_contract.load_schema(path)

    def test_report_cites_hash_and_versions(self):
        schema = make_schema(self.directory)
        report = schema_contract.schema_report(schema)
        self.assertEqual(report["protocol_version"], 1)
        self.assertEqual(len(report["sha256"]), 64)
        self.assertEqual(report["server_version"], "test-1.0")


if __name__ == "__main__":
    unittest.main()
