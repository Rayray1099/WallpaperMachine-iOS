#!/usr/bin/env python3
"""Accessibility-ID contract: all of wm.* is required, static and live audits."""
from __future__ import annotations

from pathlib import Path
import shutil
import sys
import tempfile
import unittest

QA_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QA_DIR))

import ui_contract  # noqa: E402


class IdentifierParsing(unittest.TestCase):
    def test_all_contract_ids_are_uncovered(self):
        source = " ".join(f"identifier: {identifier}" for identifier in ui_contract.CONTRACT_UI_IDS)
        self.assertEqual(ui_contract.identifiers(source), sorted(ui_contract.CONTRACT_UI_IDS))
        self.assertEqual(ui_contract.missing_contract_ids(ui_contract.identifiers(source)), [])

    def test_missing_identifier_is_reported(self):
        found = [identifier for identifier in ui_contract.CONTRACT_UI_IDS
                 if identifier != "wm.export"]
        self.assertEqual(ui_contract.missing_contract_ids(found), ["wm.export"])

    def test_prefix_must_be_a_whole_identifier(self):
        self.assertEqual(ui_contract.identifiers("awm.library wm. settings wm."), [])
        self.assertEqual(ui_contract.identifiers("wm.library wm.library wm.search"),
                         ["wm.library", "wm.search"])

    def test_contract_lists_every_documented_top_level_id(self):
        self.assertEqual(ui_contract.CONTRACT_UI_IDS,
                         ("wm.library", "wm.import", "wm.search", "wm.preview",
                          "wm.settings", "wm.workshop", "wm.export"))


class StaticAudit(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def write_source(self, name: str, text: str) -> None:
        path = self.directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_missing_sources_report_every_contract_id(self):
        audit = ui_contract.static_audit(self.directory / "absent")
        self.assertEqual(audit.missing, list(ui_contract.CONTRACT_UI_IDS))

    def test_partial_sources_report_only_absent_ids(self):
        self.write_source("UI/LibraryView.swift",
                          '.accessibilityIdentifier("wm.library")\n'
                          '.accessibilityIdentifier("wm.import")\n'
                          '.accessibilityIdentifier("wm.search")\n'
                          '.accessibilityIdentifier("wm.preview")\n')
        audit = ui_contract.static_audit(self.directory)
        self.assertEqual(audit.missing, ["wm.settings", "wm.workshop", "wm.export"])

    def test_complete_sources_pass(self):
        self.write_source("UI/All.swift", "\n".join(
            f'.accessibilityIdentifier("{identifier}")'
            for identifier in ui_contract.CONTRACT_UI_IDS))
        audit = ui_contract.static_audit(self.directory)
        self.assertTrue(audit.ok, audit.missing)


class FakeSession:
    def __init__(self, source: str, found_ids=()):
        self.source = source
        self.found_ids = set(found_ids)
        self.calls = []

    def page_source(self, **params):
        self.calls.append(("page_source", params))
        return {"source": self.source}

    def find_element(self, element_id, **params):
        self.calls.append(("find_element", element_id))
        return {"exists": element_id in self.found_ids, "ref": "r" if element_id in self.found_ids else ""}


class LiveAudit(unittest.TestCase):
    def test_visible_ids_are_collected(self):
        session = FakeSession("\n".join(ui_contract.CONTRACT_UI_IDS))
        audit = ui_contract.live_audit(session, bundle_id="com.example.app")
        self.assertTrue(audit.ok)
        self.assertEqual(session.calls[0][1]["bundle_id"], "com.example.app")

    def test_missing_id_fails_and_deep_lookup_can_recover(self):
        source = "\n".join(identifier for identifier in ui_contract.CONTRACT_UI_IDS
                           if identifier != "wm.export")
        session = FakeSession(source, found_ids={"wm.export"})
        audit = ui_contract.live_audit(session, deep=True)
        self.assertTrue(audit.ok)
        self.assertIn("wm.export", audit.found)
        self.assertIn(("find_element", "wm.export"), session.calls)

    def test_deep_lookup_does_not_invent_presence(self):
        source = "\n".join(identifier for identifier in ui_contract.CONTRACT_UI_IDS
                           if identifier != "wm.export")
        session = FakeSession(source)
        audit = ui_contract.live_audit(session, deep=True)
        self.assertFalse(audit.ok)
        self.assertEqual(audit.missing, ["wm.export"])


if __name__ == "__main__":
    unittest.main()
