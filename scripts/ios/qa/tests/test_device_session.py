#!/usr/bin/env python3
"""Device session: JSON-RPC errors at HTTP 200, timeouts without double acts, schema gates."""
from __future__ import annotations

import json
import shutil
import socket
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

from device_session import (  # noqa: E402
    AmbiguousOutcome, AuthenticationError, DeviceError, DeviceSession,
    DeviceUnreachable, PendingAmbiguity, ProtocolError, RpcError,
)
from evidence import EvidenceRun  # noqa: E402
from qa_test_support import (  # noqa: E402
    ScriptedClient, device_info_result, envelope, make_schema, rpc_error,
    screenshot_result, solid_image,
)


class SessionTestCase(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.schema = make_schema(self.directory)
        self.evidence = EvidenceRun.create("test", self.directory / "evidence")

    def session(self, script, **kwargs):
        client = ScriptedClient(script)
        session = DeviceSession(client, self.schema, "127.0.0.1:8200", self.evidence,
                                timeout=30, log_timeout=30,
                                sleep=kwargs.pop("sleep", lambda _: None), **kwargs)
        return client, session


class ErrorEnvelopes(SessionTestCase):
    def test_json_rpc_error_is_an_error_even_at_http_200(self):
        client, session = self.session([rpc_error(-32602, "bad params")])
        with self.assertRaises(RpcError) as raised:
            session.invoke("tap", {"ref": "r"})
        self.assertEqual(raised.exception.code, -32602)
        self.assertIn("bad params", str(raised.exception))
        self.assertEqual([call[0] for call in client.calls], ["tap"])

    def test_missing_result_is_a_protocol_error(self):
        client, session = self.session([{"jsonrpc": "2.0", "id": 1}])
        with self.assertRaises(ProtocolError):
            session.invoke("tap", {"ref": "r"})

    def test_result_shape_is_validated(self):
        client, session = self.session([envelope({"ok": True})])
        with self.assertRaises(ProtocolError) as raised:
            session.invoke("tap", {"ref": "r"})
        self.assertIn("missing 'message'", str(raised.exception))

    def test_authentication_error_is_not_retried(self):
        client, session = self.session([
            SystemExit("no token for 127.0.0.1:8200 — run `pair` first")])
        with self.assertRaises(AuthenticationError):
            session.invoke("device_info", {})
        self.assertEqual(len(client.calls), 1)

    def test_http_500_becomes_rpc_error(self):
        client, session = self.session([SystemExit("rpc failed (500): {}")])
        with self.assertRaises(RpcError) as raised:
            session.invoke("device_info", {})
        self.assertEqual(raised.exception.code, 500)

    def test_mac_mismatch_is_a_protocol_error(self):
        client, session = self.session([SystemExit("response MAC mismatch — discarding")])
        with self.assertRaises(ProtocolError):
            session.invoke("device_info", {})

    def test_connection_refused_is_unreachable(self):
        client, session = self.session([urllib.error.URLError(ConnectionRefusedError(111, "refused"))])
        with self.assertRaises(DeviceUnreachable):
            session.invoke("device_info", {})
        self.assertEqual(len(client.calls), 1)


class SchemaGates(SessionTestCase):
    def test_unknown_parameter_never_reaches_the_client(self):
        client, session = self.session([])
        with self.assertRaises(ProtocolError):
            session.invoke("launch_app", {"bundle_id": "x", "wait": True})
        self.assertEqual(client.calls, [])

    def test_missing_required_parameter_never_reaches_the_client(self):
        client, session = self.session([])
        with self.assertRaises(ProtocolError):
            session.invoke("launch_app", {})
        self.assertEqual(client.calls, [])

    def test_locked_screen_is_refused_before_ui_actions(self):
        client, session = self.session([envelope(device_info_result(
            system={"screen_locked": True}))])
        with self.assertRaises(DeviceError) as raised:
            session.device_info()
        self.assertIn("locked", str(raised.exception))

    def test_protocol_version_mismatch_is_fatal(self):
        client, session = self.session([envelope(device_info_result(protocol_version=2))])
        with self.assertRaises(ProtocolError):
            session.device_info()


class TimeoutSafety(SessionTestCase):
    def test_timeout_is_resolved_from_logs_and_never_resent(self):
        client, session = self.session([
            TimeoutError("timed out"),
            envelope({"lines": ["\u23f1 \u2713 tap 120ms"], "count": 1}),
            envelope({"message": "tapped"}),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "r1"})
        resolution = session.resolve_timeout()
        self.assertEqual(resolution.status, "completed")
        self.assertIsNone(session.pending)
        session.invoke("tap", {"ref": "r2"})
        self.assertEqual([call[0] for call in client.calls], ["tap", "logs", "tap"])

    def test_unresolved_timeout_blocks_the_next_action(self):
        client, session = self.session([
            TimeoutError("timed out"),
            envelope({"lines": ["unrelated log line"], "count": 1}),
            envelope({"lines": [], "count": 0}),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "r1"})
        resolution = session.resolve_timeout(polls=2)
        self.assertEqual(resolution.status, "unknown")
        self.assertIsNotNone(session.pending)
        with self.assertRaises(PendingAmbiguity):
            session.invoke("tap", {"ref": "r2"})
        self.assertEqual([call[0] for call in client.calls], ["tap", "logs", "logs"])

    def test_device_log_timeout_marker_keeps_lane_blocked(self):
        client, session = self.session([
            TimeoutError("timed out"),
            envelope({"lines": ["\u23f1 TIMEOUT tap 15000ms"], "count": 1}),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "r1"})
        resolution = session.resolve_timeout()
        self.assertEqual(resolution.status, "timed_out")
        self.assertIsNotNone(session.pending)
        with self.assertRaises(PendingAmbiguity):
            session.invoke("launch_app", {"bundle_id": "x"})
        self.assertEqual([call[0] for call in client.calls], ["tap", "logs"])

    def test_logs_probe_timeout_stays_unknown(self):
        client, session = self.session([
            TimeoutError("timed out"),
            TimeoutError("still wedged"),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "r1"})
        resolution = session.resolve_timeout()
        self.assertEqual(resolution.status, "unknown")
        self.assertIn("logs probe also timed out", resolution.note)
        self.assertIsNotNone(session.pending)

    def test_read_only_calls_are_allowed_while_pending(self):
        client, session = self.session([
            TimeoutError("timed out"),
            envelope({"lines": [], "count": 0}),
            envelope({"source": "wm.library"}),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "r1"})
        session.resolve_timeout(polls=1)
        source = session.page_source(visible_only=True)
        self.assertEqual(source["source"], "wm.library")

    def test_evidence_records_timeout_and_probe(self):
        client, session = self.session([
            TimeoutError("timed out"),
            envelope({"lines": ["\u23f1 \u2713 tap"], "count": 1}),
        ])
        with self.assertRaises(AmbiguousOutcome):
            session.invoke("tap", {"ref": "secret-ref"})
        session.resolve_timeout()
        events = [event for event in session.evidence.events if event["kind"] == "rpc"]
        self.assertEqual(events[0]["method"], "tap")
        self.assertIn("timeout", events[0]["error"])
        self.assertEqual(events[1]["method"], "logs")


class ScreenshotAndSummary(SessionTestCase):
    def test_screenshot_is_written_and_decoded(self):
        image = solid_image(8, 6, (12, 34, 56))
        client, session = self.session([envelope(screenshot_result(image))])
        shot = session.screenshot("screen.png", scale=1, bundle_id="com.example.app")
        self.assertTrue(shot.path.is_file())
        self.assertEqual((shot.image.width, shot.image.height), (8, 6))
        self.assertEqual(len(shot.sha256), 64)
        self.assertIn("bundle_id", client.calls[0][1])

    def test_invalid_base64_is_a_protocol_error(self):
        result = screenshot_result(solid_image(2, 2))
        result["data"] = "!!!not-base64!!!"
        client, session = self.session([envelope(result)])
        with self.assertRaises(ProtocolError):
            session.screenshot("screen.png")

    def test_non_png_payload_is_refused(self):
        result = screenshot_result(solid_image(2, 2))
        result["data"] = "bm90IGEgcG5n"  # "not a png"
        result["bytes"] = 9
        client, session = self.session([envelope(result)])
        with self.assertRaises(ProtocolError):
            session.screenshot("screen.png")

    def test_device_summary_keeps_only_safe_fields(self):
        client, session = self.session([envelope(device_info_result())])
        info = session.device_info()
        summary = session.device_summary(info)
        self.assertEqual(summary["device_name"], "QA iPad")
        self.assertNotIn("serial", json.dumps(summary).lower())


if __name__ == "__main__":
    unittest.main()
