#!/usr/bin/env python3
"""Device-lane leases: only the Lead's unexpired grant permits live access."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

import lane  # noqa: E402


class LaneLease(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.lease_path = self.directory / "device-lane.json"

    def rewrite(self, **changes):
        payload = json.loads(self.lease_path.read_text(encoding="utf-8"))
        payload.update(changes)
        self.lease_path.write_text(json.dumps(payload), encoding="utf-8")

    def test_missing_lease_blocks_live_access(self):
        with self.assertRaises(lane.LeaseError) as raised:
            lane.load_lease(self.lease_path)
        self.assertIn("Lead must grant", str(raised.exception))

    def test_lead_grant_is_active(self):
        lease = lane.grant(self.lease_path, by="Lead", minutes=30)
        loaded = lane.load_lease(self.lease_path)
        self.assertEqual(loaded.holder, "QA Agent")
        self.assertEqual(loaded.granted_by, "Lead")
        self.assertTrue(loaded.active())
        self.assertEqual(lease.note, "")

    def test_grant_by_someone_else_does_not_authorize_qa(self):
        lane.grant(self.lease_path, by="Intern", minutes=30)
        with self.assertRaises(lane.LeaseError) as raised:
            lane.load_lease(self.lease_path)
        self.assertIn("not 'Lead'", str(raised.exception))

    def test_other_holder_is_refused(self):
        lane.grant(self.lease_path, by="Lead", minutes=30)
        self.rewrite(holder="Renderer Agent")
        with self.assertRaises(lane.LeaseError) as raised:
            lane.load_lease(self.lease_path)
        self.assertIn("Renderer Agent", str(raised.exception))

    def test_expired_lease_is_refused(self):
        lane.grant(self.lease_path, by="Lead", minutes=30)
        past = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
        self.rewrite(expires_at=past)
        with self.assertRaises(lane.LeaseError) as raised:
            lane.load_lease(self.lease_path)
        self.assertIn("expired", str(raised.exception))

    def test_future_expiry_can_be_checked_against_injected_now(self):
        lease = lane.grant(self.lease_path, by="Lead", minutes=10)
        self.assertTrue(lease.active(datetime.now(timezone.utc)))
        self.assertFalse(lease.active(lease.expires_at + timedelta(seconds=1)))

    def test_release_removes_the_lease(self):
        lane.grant(self.lease_path, by="Lead", minutes=5)
        self.assertTrue(lane.release(self.lease_path))
        self.assertFalse(self.lease_path.exists())
        self.assertFalse(lane.release(self.lease_path))

    def test_status_reports_expiry_without_raising(self):
        lane.grant(self.lease_path, by="Lead", minutes=5)
        status = lane.status(self.lease_path)
        self.assertTrue(status["active"])
        self.assertEqual(status["granted_by"], "Lead")
        self.assertIn("expires_at", status)

    def test_invalid_minutes_are_rejected(self):
        with self.assertRaises(lane.LeaseError):
            lane.grant(self.lease_path, by="Lead", minutes=0)
        with self.assertRaises(lane.LeaseError):
            lane.grant(self.lease_path, by="Lead", minutes=241)
        self.assertFalse(self.lease_path.exists())


if __name__ == "__main__":
    unittest.main()
