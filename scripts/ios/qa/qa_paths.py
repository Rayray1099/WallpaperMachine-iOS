#!/usr/bin/env python3
"""Shared paths and constants for the iOS QA harness.

The harness lives in the repository (`scripts/ios/qa/`) but the official iCTRL
client and its schema are machine-local: they are downloaded from the device into
`<checkout parent>/.local/ictrl/` and are never vendored. Evidence goes to the
Git-ignored `artifacts/qa/` tree only.
"""
from __future__ import annotations

import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from lib.paths import ARTIFACTS, ROOT  # noqa: E402

QA_ARTIFACTS = ARTIFACTS / "qa"
PROJECT_PARENT = ROOT.parent
IOS_SOURCES = ROOT / "iOS" / "Sources"
IOS_TESTS = ROOT / "iOS" / "Tests"
IOS_PROJECT_YML = ROOT / "iOS" / "project.yml"
DEVICE_LANE = QA_ARTIFACTS / "device-lane.json"

CLIENT_ENV = "WM_QA_ICTRL_CLIENT"
SCHEMA_ENV = "WM_QA_ICTRL_SCHEMA"
HOST_ENV = "ICTRL_HOST"
DEFAULT_HOST = "127.0.0.1:8200"
BUNDLE_ID = "com.rayray1099.wallpapermachine.ios"

OFFICIAL_CLIENT_CANDIDATES = (
    PROJECT_PARENT / ".local" / "ictrl" / "ictrl_rpc.py",
    ROOT / ".local" / "ictrl" / "ictrl_rpc.py",
    Path.home() / ".ictrl" / "bin" / "ictrl_rpc.py",
)
SCHEMA_CANDIDATES = (
    PROJECT_PARENT / ".local" / "ictrl" / "schema.json",
    ROOT / ".local" / "ictrl" / "schema.json",
    Path.home() / ".ictrl" / "bin" / "schema.json",
)
